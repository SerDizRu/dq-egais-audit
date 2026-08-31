

-- 1) STAT: TOTAL RUNS (+ прирост за последние 7 дней)
SELECT
    count(*) AS total_runs,
    count(*) FILTER (WHERE run_started_at >= now() - interval '7 days') AS runs_last_7d
FROM dq_run_history;

-- 2) STAT: LATEST RUN STATUS
SELECT overall_status, run_started_at, failed_rules, total_rules
FROM dq_run_history
ORDER BY run_started_at DESC
LIMIT 1;

-- 3) STAT: RULE PASS RATE (доля правил, прошедших в последнем прогоне)
SELECT
    round(100.0 * passed_rules / total_rules, 1) AS rule_pass_rate_pct
FROM dq_run_history
ORDER BY run_started_at DESC
LIMIT 1;

-- 4) STAT: DEFECT ROWS (сумма failed_rows по критичным правилам в последнем прогоне)
SELECT sum(failed_rows) AS critical_defect_rows
FROM dq_check_results c
JOIN dq_run_history r ON r.run_id = c.run_id
WHERE r.run_id = (SELECT run_id FROM dq_run_history ORDER BY run_started_at DESC LIMIT 1)
  AND c.rule_id IN ('DQ-02', 'DQ-03', 'DQ-04', 'DQ-11');

-- 5) PANEL: PASS RATE BY RULE (horizontal bar, последний прогон)
SELECT
    c.rule_id, c.dimension, c.pass_rate_pct, c.threshold_pct, c.status
FROM dq_check_results c
WHERE c.run_id = (SELECT run_id FROM dq_run_history ORDER BY run_started_at DESC LIMIT 1)
ORDER BY c.pass_rate_pct ASC;

-- 6) PANEL: TREND — PASS RATE ПО ПРАВИЛАМ ВО ВРЕМЕНИ (time series)
SELECT
    r.run_started_at AS "time",
    c.rule_id,
    c.pass_rate_pct
FROM dq_check_results c
JOIN dq_run_history r ON r.run_id = c.run_id
WHERE c.rule_id IN ('DQ-02', 'DQ-03', 'DQ-04', 'DQ-11')
ORDER BY 1, 2;

-- 7) SPARKLINE: ОБЩАЯ ДОЛЯ ПРОШЕДШИХ ПРАВИЛ ПО ДНЯМ
SELECT
    date_trunc('day', run_started_at) AS "time",
    round(avg(100.0 * passed_rules / total_rules), 1) AS avg_rule_pass_rate_pct
FROM dq_run_history
GROUP BY 1
ORDER BY 1;

-- 8) TABLE: ИСТОРИЯ ПОСЛЕДНИХ 20 ПРОГОНОВ
SELECT
    run_id, triggered_by, run_started_at, overall_status,
    passed_rules, failed_rules, total_rules
FROM dq_run_history
ORDER BY run_started_at DESC
LIMIT 20;

-- 9) TABLE: ДЕТАЛИ ПОСЛЕДНЕГО FAIL-ПРОГОНА (для расследования, см. Отчёт по инциденту.md)
SELECT c.rule_id, c.entity, c.dimension, c.total_rows, c.failed_rows, c.pass_rate_pct, c.threshold_pct
FROM dq_check_results c
WHERE c.run_id = (
    SELECT run_id FROM dq_run_history WHERE overall_status = 'FAIL' ORDER BY run_started_at DESC LIMIT 1
)
AND c.status = 'FAIL'
ORDER BY c.pass_rate_pct ASC;
