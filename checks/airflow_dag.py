

from __future__ import annotations
import os
import sys
from datetime import datetime
from pathlib import Path
from airflow.sdk import dag, task


DAG_DIR = Path(__file__).resolve().parent
RULES_SQL = DAG_DIR.parent / "sql" / "02_dq_rules.sql"
LOG_FILE = Path(os.environ.get("AIRFLOW_HOME", Path.home() / "airflow")) / "logs" / "dq_alko" / "dq_pipeline.log"

PG_CONN_ID = "project_dq_postgres"

default_args = {
    "owner": "dq-team",
}


def notify_on_failure(context):
    """on_failure_callback — точка интеграции со Slack/Email/PagerDuty."""
    import logging

    log = logging.getLogger("airflow.task")
    ti = context.get("task_instance")
    summary = ti.xcom_pull(task_ids="run_dq_checks", key="dq_summary") if ti else None
    if summary:
        log.error(
            "[ALERT] DQ pipeline FAILED. run_id=%s, критичные правила: %s. "
            "Разбор — по шаблону docs/Отчёт по инциденту.md",
            summary.get("run_id"), summary.get("critical_failures"),
        )
    else:
        log.error("[ALERT] DQ pipeline упал до записи результатов — см. лог таска.")


@dag(
    dag_id="dq_monitoring_list_doc_doc_oper",
    description="Ежедневный DQ-контроль витрины ЕГАИС: приёмка list_doc -> витрина doc_oper",
    default_args=default_args,
    start_date=datetime(2026, 8, 1),
    schedule="0 6 * * *", 
    catchup=False,
    max_active_runs=1,
    tags=["data_quality", "egais", "project_dq"],
)
def dq_monitoring_list_doc_doc_oper():

    @task(on_failure_callback=notify_on_failure)
    def run_dq_checks():
        """Прогоняет 14 правил из 02_dq_rules.sql и логирует прогон в dq_run_history."""
        import logging

        log = logging.getLogger("airflow.task")


        try:
            from airflow.sdk import BaseHook

            conn = BaseHook.get_connection(PG_CONN_ID)
            os.environ["DQ_PG_HOST"] = conn.host
            os.environ["DQ_PG_PORT"] = str(conn.port or 5432)
            os.environ["DQ_PG_USER"] = conn.login
            os.environ["DQ_PG_PASSWORD"] = conn.password or ""
            os.environ["DQ_PG_DBNAME"] = conn.schema
            log.info("Креды взяты из Airflow Connection '%s' (%s/%s)", PG_CONN_ID, conn.host, conn.schema)
        except Exception as exc:
            log.warning(
                "Connection '%s' недоступен (%s) — используется фолбэк из dq_pipeline.get_db_config()",
                PG_CONN_ID, exc,
            )

        os.environ["DQ_RULES_SQL"] = str(RULES_SQL)
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        os.environ["DQ_LOG_PATH"] = str(LOG_FILE)

        # 2. Импорт пайплайна из соседнего файла (см. .airflowignore рядом)
        if str(DAG_DIR) not in sys.path:
            sys.path.insert(0, str(DAG_DIR))
        import dq_pipeline

        summary = dq_pipeline.run_pipeline(triggered_by="airflow")


        payload = {
            "run_id": int(summary["run_id"]),
            "overall_status": summary["overall_status"],
            "failed_count": int(summary["failed_count"]),
            "critical_failures": list(summary["critical_failures"]),
            "rules": [
                {
                    "rule_id": r["rule_id"],
                    "status": r["status"],
                    "pass_rate_pct": float(r["pass_rate_pct"]),
                    "threshold_pct": float(r["threshold_pct"]),
                    "failed_rows": int(r["failed_rows"]),
                }
                for r in summary["results"]
            ],
        }


        from airflow.sdk import get_current_context

        get_current_context()["ti"].xcom_push(key="dq_summary", value=payload)

        for r in payload["rules"]:
            log.info("%s pass_rate=%.2f%% (порог %.1f%%) -> %s",
                     r["rule_id"], r["pass_rate_pct"], r["threshold_pct"], r["status"])

        if payload["critical_failures"]:
            raise RuntimeError(
                f"Критичные DQ-правила провалены: {payload['critical_failures']}. "
                f"Детали — public.dq_check_results, run_id={payload['run_id']}."
            )
        return payload

    @task()
    def gate_downstream_publish(summary: dict):
        """Выполняется только при all_success — «данные с дефектами в контур контроля не публикуем»."""
        import logging

        logging.getLogger("airflow.task").info(
            "DQ-проверки пройдены (run_id=%s): витрина doc_oper допущена в контур контроля.",
            summary["run_id"],
        )

    gate_downstream_publish(run_dq_checks())


dq_monitoring_list_doc_doc_oper()
