"""
DQ-пайплайн контура приёмки ЕГАИС: контроль витрины doc_oper относительно
принятого от организаций потока list_doc.

Что делает:
  1. Подключается к Project_DQ.
  2. Прогоняет 14 бизнес-правил из ../sql/02_dq_rules.sql.
  3. Логирует результат каждого правила и сводку прогона в таблицы
     dq_run_history / dq_check_results (../sql/03_dq_results_schema.sql).
  4. Пишет тот же результат в лог-файл (dq_pipeline.log) — для истории вне БД
     и для примера того, что будет видно в логах Airflow-таска.
  5. Возвращает ненулевой exit code, если есть хотя бы один FAILED-rule с severity Critical
     (DQ-02, DQ-03, DQ-04, DQ-11) — этим кодом управляется алертинг/остановка DAG на шаге 4.

Запуск локально:  python dq_pipeline.py [--triggered-by manual]
Запуск из Airflow: см. airflow_dag.py — тот же модуль импортируется и вызывается run_pipeline().
"""

import argparse
import logging
import os
import sys
from datetime import datetime
from pathlib import Path

import psycopg2

# ---------------------------------------------------------------------------
# Конфигурация подключения.
# В Airflow-окружении значения приходят из Airflow Connection
# "project_dq_postgres" через переменные DQ_PG_* — см. airflow_dag.py.
# Здесь — фолбэк для локального/ad-hoc запуска.
# ---------------------------------------------------------------------------
def get_db_config():
    """Конфиг собирается В МОМЕНТ ВЫЗОВА, а не на импорте модуля.

    Важно для Airflow: DAG импортирует этот модуль при парсинге, а креды из
    Airflow Connection выставляются в окружение позже, уже внутри таска. Если
    читать os.environ на импорте, значения из Connection будут проигнорированы
    и пайплайн молча уйдёт на локальный фолбэк.
    """
    return {
        "host": os.environ.get("DQ_PG_HOST", "localhost"),
        "port": int(os.environ.get("DQ_PG_PORT", "5432")),
        "user": os.environ.get("DQ_PG_USER", "postgres"),
        # Пароль берётся только из окружения: в Airflow — из Connection
        # project_dq_postgres, локально — из переменной DQ_PG_PASSWORD.
        # Значения по умолчанию здесь быть не должно (см. .env.example).
        "password": os.environ["DQ_PG_PASSWORD"],
        "dbname": os.environ.get("DQ_PG_DBNAME", "Project_DQ"),
        "connect_timeout": 10,
    }

# Critical-правила из Реестр правил и метрик.md — их провал должен останавливать
# downstream-задачи / поднимать инцидент, а не просто писаться в лог.
# DQ-11 (строки без источника) в этом списке потому, что данные, не проходившие
# приёмку, в юридически значимой витрине недопустимы в принципе.
# DQ-14 (баланс перемещения) — потому что несходящийся баланс означает недостоверную
# картину товародвижения: именно по нему разбираются инциденты.
CRITICAL_RULES = {"DQ-02", "DQ-03", "DQ-04", "DQ-11", "DQ-14"}

THIS_DIR = Path(__file__).resolve().parent
# Пути переопределяются переменными окружения — на Airflow-хосте файлы лежат
# в <dags_folder>/dq_alko/, а лог пишется в logs/, а не в папку с DAG'ами.
RULES_SQL_PATH = Path(os.environ.get("DQ_RULES_SQL", THIS_DIR.parent / "sql" / "02_dq_rules.sql"))
LOG_PATH = Path(os.environ.get("DQ_LOG_PATH", THIS_DIR / "dq_pipeline.log"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_PATH, encoding="utf-8"), logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger("dq_pipeline")


def get_connection():
    return psycopg2.connect(**get_db_config())


def run_rules(conn):
    """Выполняет 02_dq_rules.sql и возвращает список словарей — по одному на правило."""
    rules_sql_path = Path(os.environ.get("DQ_RULES_SQL", RULES_SQL_PATH))
    with open(rules_sql_path, "r", encoding="utf-8") as f:
        sql = f.read()

    with conn.cursor() as cur:
        cur.execute(sql)
        cols = [d[0] for d in cur.description]
        rows = [dict(zip(cols, row)) for row in cur.fetchall()]
    return rows


def log_run(conn, results, triggered_by, started_at, finished_at):
    """Пишет сводку прогона и построчные результаты в dq_run_history/dq_check_results."""
    total = len(results)
    passed = sum(1 for r in results if r["status"] == "PASS")
    failed = total - passed
    overall_status = "PASS" if failed == 0 else "FAIL"

    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO public.dq_run_history
                (triggered_by, run_started_at, run_finished_at, total_rules, passed_rules, failed_rules, overall_status)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            RETURNING run_id;
            """,
            (triggered_by, started_at, finished_at, total, passed, failed, overall_status),
        )
        run_id = cur.fetchone()[0]

        for r in results:
            cur.execute(
                """
                INSERT INTO public.dq_check_results
                    (run_id, rule_id, entity, dimension, total_rows, passed_rows, failed_rows,
                     pass_rate_pct, threshold_pct, status, checked_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);
                """,
                (
                    run_id, r["rule_id"], r["entity"], r["dimension"], r["total_rows"],
                    r["passed_rows"], r["failed_rows"], r["pass_rate_pct"], r["threshold_pct"],
                    r["status"], finished_at,
                ),
            )
    conn.commit()
    return run_id, overall_status, failed


def run_pipeline(triggered_by="manual"):
    """Основная точка входа — используется и локальным CLI, и Airflow DAG."""
    started_at = datetime.now()
    logger.info("=== DQ pipeline run started (triggered_by=%s) ===", triggered_by)

    conn = get_connection()
    try:
        results = run_rules(conn)

        for r in results:
            level = logging.INFO if r["status"] == "PASS" else logging.WARNING
            logger.log(
                level,
                "%s [%s / %s] pass_rate=%6.2f%% (threshold=%.1f%%) -> %s",
                r["rule_id"], r["entity"], r["dimension"],
                r["pass_rate_pct"], r["threshold_pct"], r["status"],
            )

        finished_at = datetime.now()
        run_id, overall_status, failed_count = log_run(conn, results, triggered_by, started_at, finished_at)

        critical_failures = [r["rule_id"] for r in results if r["status"] == "FAIL" and r["rule_id"] in CRITICAL_RULES]

        logger.info(
            "=== Run #%s finished: %s (%d/%d rules failed, critical failures: %s) ===",
            run_id, overall_status, failed_count, len(results), critical_failures or "none",
        )

        return {
            "run_id": run_id,
            "overall_status": overall_status,
            "failed_count": failed_count,
            "critical_failures": critical_failures,
            "results": results,
        }
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description="DQ pipeline for public.doc_oper / public.list_doc")
    parser.add_argument("--triggered-by", default="manual")
    args = parser.parse_args()

    summary = run_pipeline(triggered_by=args.triggered_by)

    # Критичные правила упали -> сигнализируем вызывающему процессу (Airflow) через exit code,
    # чтобы downstream-задачи (например, "публикация отчёта в BI") не выполнялись на грязных данных.
    if summary["critical_failures"]:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
