-- ============================================================
-- SQL-реализация реестра бизнес-правил (Реестр правил и метрик.md)
-- БД: Project_DQ
-- Объект контроля: витрина ЕГАИС public.doc_oper
-- Эталон:          сырой слой приёмки public.list_doc
--
-- Единый формат строки результата, чтобы pipeline (dq_pipeline.py)
-- мог прогнать весь файл одним запросом и залогировать каждую строку:
--   rule_id, entity, dimension, total_rows, passed_rows, failed_rows,
--   pass_rate_pct, threshold_pct, status
-- ============================================================

WITH

dq01 AS (
    SELECT
        'DQ-01' AS rule_id, 'Операция' AS entity, 'Полнота' AS dimension,
        count(*) AS total_rows,
        count(*) FILTER (
            WHERE org_id IS NOT NULL AND operation IS NOT NULL AND date_operation IS NOT NULL
              AND type_doc IS NOT NULL AND cod_alco IS NOT NULL AND qua IS NOT NULL
              AND doc_1 IS NOT NULL AND doc_2 IS NOT NULL
        ) AS passed_rows,
        100.0 AS threshold_pct
    FROM public.doc_oper
),

dq02 AS (
    SELECT
        'DQ-02', 'Операция', 'Полнота загрузки',
        (SELECT count(*) FROM public.list_doc) AS total_rows,
        (SELECT count(*) FROM public.doc_oper) AS passed_rows,
        99.0
),

dq03 AS (
    SELECT
        'DQ-03', 'Организация', 'Валидность',
        count(*) AS total_rows,
        count(*) FILTER (WHERE org_id ~ '^0\d{7}$') AS passed_rows,
        99.0
    FROM public.doc_oper
),

dq04 AS (
    SELECT
        'DQ-04', 'Организация', 'Точность',
        count(*) AS total_rows,
        count(*) FILTER (WHERE d.org_id = l.client_id) AS passed_rows,
        99.0
    FROM public.doc_oper d
    JOIN public.list_doc l ON l.sid = d.id
),

dq05 AS (
    SELECT
        'DQ-05', 'Операция', 'Уникальность',
        count(*) AS total_rows,
        count(DISTINCT id) AS passed_rows,
        100.0
    FROM public.doc_oper
),

dq06 AS (
    SELECT
        'DQ-06', 'Документ учёта', 'Валидность',
        count(*) AS total_rows,
        count(*) FILTER (WHERE type_doc IN ('chek', 'spis')) AS passed_rows,
        100.0
    FROM public.doc_oper
),

dq07 AS (
    SELECT
        'DQ-07', 'Операция', 'Согласованность',
        count(*) AS total_rows,
        count(*) FILTER (
            WHERE (type_doc = 'chek' AND qua > 0) OR (type_doc = 'spis' AND qua < 0)
        ) AS passed_rows,
        100.0
    FROM public.doc_oper
),

dq08 AS (
    SELECT
        'DQ-08', 'Операция', 'Своевременность',
        count(*) AS total_rows,
        -- Окно хранения оперативной витрины — 365 дней. Верхняя граница ловит
        -- даты из будущего, нижняя — записи, которые должны были уехать в архив.
        count(*) FILTER (
            WHERE date_operation <= now() AND date_operation >= now() - interval '365 days'
        ) AS passed_rows,
        100.0
    FROM public.doc_oper
),

dq09 AS (
    SELECT
        'DQ-09', 'Товар', 'Валидность',
        count(*) AS total_rows,
        count(*) FILTER (
            WHERE cod_alco > 0 AND length(cod_alco::text) BETWEEN 15 AND 19
        ) AS passed_rows,
        99.0
    FROM public.doc_oper
),

dq10 AS (
    SELECT
        'DQ-10', 'Справка А / Справка Б', 'Валидность',
        count(*) AS total_rows,
        count(*) FILTER (WHERE doc_1 ~ '^1_\d{10}$' AND doc_2 ~ '^2_\d{10}$') AS passed_rows,
        99.0
    FROM public.doc_oper
),

dq11 AS (
    -- Строки витрины, которых не было в принятом потоке («сироты»).
    -- Ненулевое значение = записи попали в витрину в обход приёмки.
    SELECT
        'DQ-11', 'Операция', 'Целостность',
        count(*) AS total_rows,
        count(*) FILTER (
            WHERE EXISTS (SELECT 1 FROM public.list_doc l WHERE l.sid = d.id)
        ) AS passed_rows,
        100.0
    FROM public.doc_oper d
),

dq12 AS (
    -- Иерархия справок: справка Б (перемещение) обязана принадлежать ровно одной
    -- справке А (партии). Справка Б, встретившаяся под двумя разными справками А,
    -- означает пересортицу партий: перемещение приписано чужому товару.
    -- Единица измерения здесь — справка Б, а не строка операции.
    SELECT
        'DQ-12', 'Справка Б', 'Целостность (иерархия справок)',
        count(*) AS total_rows,
        count(*) FILTER (WHERE form_a_cnt = 1) AS passed_rows,
        100.0
    FROM (
        SELECT doc_2, count(DISTINCT doc_1) AS form_a_cnt
        FROM public.doc_oper
        GROUP BY doc_2
    ) b
),

dq13 AS (
    -- Однородность партии: в рамках одной справки А код продукции один.
    -- Несколько кодов под одной справкой А = партия «расползлась» по товарам,
    -- прослеживаемость по 171-ФЗ теряется.
    SELECT
        'DQ-13', 'Партия (справка А)', 'Согласованность (товар партии)',
        count(*) AS total_rows,
        count(*) FILTER (WHERE product_cnt = 1) AS passed_rows,
        100.0
    FROM (
        SELECT doc_1, count(DISTINCT cod_alco) AS product_cnt
        FROM public.doc_oper
        GROUP BY doc_1
    ) a
),

dq14 AS (
    -- Баланс перемещения по организации: сколько получено по справке Б, столько
    -- максимум и может быть списано. В принятом потоке сумма количеств в разрезе
    -- (организация, справка Б) неотрицательна всегда: у 80% пар она ровно 0
    -- (партия реализована полностью), у остальных положительна (остаток на складе).
    --
    -- Отрицательный баланс в витрине означает, что часть операций пары до неё не
    -- доехала или уехала под другим кодом организации. Это главное правило для
    -- разбора инцидентов: оно показывает не «сколько строк плохие», а какие именно
    -- пары «организация × перемещение» больше не сходятся.
    SELECT
        'DQ-14', 'Перемещение × организация', 'Согласованность (баланс)',
        count(*) AS total_rows,
        count(*) FILTER (WHERE balance >= 0) AS passed_rows,
        99.0
    FROM (
        SELECT org_id, doc_2, sum(qua) AS balance
        FROM public.doc_oper
        GROUP BY org_id, doc_2
    ) b
),

all_rules AS (
    SELECT * FROM dq01 UNION ALL
    SELECT * FROM dq02 UNION ALL
    SELECT * FROM dq03 UNION ALL
    SELECT * FROM dq04 UNION ALL
    SELECT * FROM dq05 UNION ALL
    SELECT * FROM dq06 UNION ALL
    SELECT * FROM dq07 UNION ALL
    SELECT * FROM dq08 UNION ALL
    SELECT * FROM dq09 UNION ALL
    SELECT * FROM dq10 UNION ALL
    SELECT * FROM dq11 UNION ALL
    SELECT * FROM dq12 UNION ALL
    SELECT * FROM dq13 UNION ALL
    SELECT * FROM dq14
)

SELECT
    rule_id,
    entity,
    dimension,
    total_rows,
    passed_rows,
    (total_rows - passed_rows) AS failed_rows,
    round(100.0 * passed_rows / NULLIF(total_rows, 0), 2) AS pass_rate_pct,
    threshold_pct,
    CASE WHEN round(100.0 * passed_rows / NULLIF(total_rows, 0), 2) >= threshold_pct
         THEN 'PASS' ELSE 'FAIL' END AS status
FROM all_rules
ORDER BY rule_id;
