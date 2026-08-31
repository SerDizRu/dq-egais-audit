-- ============================================================
-- Observability: таблицы истории прогонов DQ-пайплайна
-- БД: Project_DQ
-- ============================================================

DROP TABLE IF EXISTS public.dq_check_results;
DROP TABLE IF EXISTS public.dq_run_history;

CREATE TABLE public.dq_run_history (
    run_id          bigserial PRIMARY KEY,
    triggered_by    varchar(50)   NOT NULL,          -- 'manual' | 'airflow' | 'backfill_demo'
    run_started_at  timestamp     NOT NULL,
    run_finished_at timestamp     NOT NULL,
    total_rules     int           NOT NULL,
    passed_rules    int           NOT NULL,
    failed_rules    int           NOT NULL,
    overall_status  varchar(20)   NOT NULL            -- 'PASS' | 'FAIL'
);

CREATE TABLE public.dq_check_results (
    id              bigserial PRIMARY KEY,
    run_id          bigint        NOT NULL REFERENCES public.dq_run_history(run_id),
    rule_id         varchar(10)   NOT NULL,           -- DQ-01 .. DQ-10
    entity          varchar(100)  NOT NULL,
    dimension       varchar(50)   NOT NULL,
    total_rows      bigint        NOT NULL,
    passed_rows     bigint        NOT NULL,
    failed_rows     bigint        NOT NULL,
    pass_rate_pct   numeric(6,2)  NOT NULL,
    threshold_pct   numeric(6,2)  NOT NULL,
    status          varchar(10)   NOT NULL,           -- 'PASS' | 'FAIL'
    checked_at      timestamp     NOT NULL
);

CREATE INDEX idx_dq_check_results_run    ON public.dq_check_results (run_id);
CREATE INDEX idx_dq_check_results_rule   ON public.dq_check_results (rule_id);
CREATE INDEX idx_dq_run_history_started  ON public.dq_run_history (run_started_at);

COMMENT ON TABLE public.dq_run_history IS 'История запусков DQ-пайплайна (dq_pipeline.py) — один прогон = одна строка';
COMMENT ON TABLE public.dq_check_results IS 'Результат каждого из 14 правил (Реестр правил и метрик.md) в рамках прогона';
