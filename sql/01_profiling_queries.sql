
-- 1) Объём данных
SELECT 'list_doc' AS table_name, count(*) AS row_count FROM public.list_doc
UNION ALL
SELECT 'doc_oper', count(*) FROM public.doc_oper;

-- 2) Схемное профилирование: список колонок и типов в обеих таблицах
SELECT table_name, column_name, data_type, ordinal_position
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name IN ('list_doc', 'doc_oper')
ORDER BY table_name, ordinal_position;

-- 3) Полнота обязательных полей doc_oper (доля NULL по каждой колонке)
SELECT
    count(*) AS total_rows,
    round(100.0 * count(*) FILTER (WHERE org_id IS NULL) / count(*), 3) AS null_pct_org_id,
    round(100.0 * count(*) FILTER (WHERE operation IS NULL) / count(*), 3) AS null_pct_operation,
    round(100.0 * count(*) FILTER (WHERE date_operation IS NULL) / count(*), 3) AS null_pct_date_operation,
    round(100.0 * count(*) FILTER (WHERE type_doc IS NULL) / count(*), 3) AS null_pct_type_doc,
    round(100.0 * count(*) FILTER (WHERE cod_alco IS NULL) / count(*), 3) AS null_pct_cod_alco,
    round(100.0 * count(*) FILTER (WHERE qua IS NULL) / count(*), 3) AS null_pct_qua,
    round(100.0 * count(*) FILTER (WHERE doc_2 IS NULL) / count(*), 3) AS null_pct_doc_2,
    round(100.0 * count(*) FILTER (WHERE doc_1 IS NULL) / count(*), 3) AS null_pct_doc_1
FROM public.doc_oper;

-- 4) Полнота ЗАГРУЗКИ: сколько операций из эталона не долетело до doc_oper
SELECT
    (SELECT count(*) FROM public.list_doc) AS source_rows,
    (SELECT count(*) FROM public.doc_oper) AS loaded_rows,
    (SELECT count(*) FROM public.list_doc l
     WHERE NOT EXISTS (SELECT 1 FROM public.doc_oper d WHERE d.id = l.sid)) AS missing_rows,
    round(100.0 * (SELECT count(*) FROM public.doc_oper)
                 / (SELECT count(*) FROM public.list_doc), 2) AS load_completeness_pct;

-- 5) Уникальность id/sid (дубли по бизнес-ключу)
SELECT 'doc_oper.id' AS key_col, count(*) AS total, count(DISTINCT id) AS distinct_vals
FROM public.doc_oper
UNION ALL
SELECT 'list_doc.sid', count(*), count(DISTINCT sid)
FROM public.list_doc;

-- 6) Точность (accuracy): сверка org_id с эталонным client_id по sid=id
SELECT
    count(*) AS matched_rows,
    count(*) FILTER (WHERE d.org_id = l.client_id) AS accurate_rows,
    count(*) FILTER (WHERE d.org_id <> l.client_id) AS inaccurate_rows,
    round(100.0 * count(*) FILTER (WHERE d.org_id = l.client_id) / count(*), 2) AS accuracy_pct
FROM public.doc_oper d
JOIN public.list_doc l ON l.sid = d.id;

-- 7) Валидность формата org_id (ожидаемый формат: 8 цифр, с ведущим нулём)
SELECT
    count(*) AS total_rows,
    count(*) FILTER (WHERE org_id ~ '^0\d{7}$') AS valid_format,
    count(*) FILTER (WHERE org_id !~ '^0\d{7}$') AS invalid_format,
    round(100.0 * count(*) FILTER (WHERE org_id ~ '^0\d{7}$') / count(*), 2) AS valid_format_pct
FROM public.doc_oper;

-- 8) Классификация невалидных org_id по длине (для понимания природы дефекта)
SELECT length(org_id) AS org_id_len, count(*) AS cnt
FROM public.doc_oper
GROUP BY 1
ORDER BY 1;

-- 9) Допустимые значения (validity) type_doc
SELECT type_doc, count(*) AS cnt,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM public.doc_oper
GROUP BY type_doc
ORDER BY cnt DESC;

-- 10) Согласованность знака qua с типом документа
SELECT
    type_doc,
    count(*) FILTER (WHERE qua > 0) AS positive_qua,
    count(*) FILTER (WHERE qua < 0) AS negative_qua,
    count(*) FILTER (WHERE qua = 0) AS zero_qua
FROM public.doc_oper
GROUP BY type_doc;

-- 11) Распределение количественных полей
SELECT
    min(qua) AS min_qua, max(qua) AS max_qua, round(avg(qua), 2) AS avg_qua,
    min(cod_alco) AS min_cod_alco, max(cod_alco) AS max_cod_alco
FROM public.doc_oper;

-- 12) Временной диапазон и свежесть
SELECT
    min(date_operation) AS earliest_op,
    max(date_operation) AS latest_op,
    count(*) FILTER (WHERE date_operation > now()) AS future_dated_rows
FROM public.doc_oper;

-- 13) Валидность формата doc_1/doc_2 (Форма А / Форма Б, ожидаемо "1_<10 цифр>" / "2_<10 цифр>")
SELECT
    count(*) FILTER (WHERE doc_1 !~ '^1_\d{10}$') AS invalid_doc_1,
    count(*) FILTER (WHERE doc_2 !~ '^2_\d{10}$') AS invalid_doc_2
FROM public.doc_oper;

-- 14) Дубликаты по неключевым признакам (потенциальные повторные загрузки)
SELECT count(*) AS duplicate_groups FROM (
    SELECT org_id, date_operation, cod_alco, qua, doc_1, doc_2
    FROM public.doc_oper
    GROUP BY 1,2,3,4,5,6
    HAVING count(*) > 1
) x;


-- 15) Строки-«сироты»: есть в витрине, но их не было в принятом источнике.
--     Прямой признак вставки записей в обход загрузки.
SELECT count(*) AS orphan_rows
FROM public.doc_oper d
WHERE NOT EXISTS (SELECT 1 FROM public.list_doc l WHERE l.sid = d.id);

-- 16) Потерянные операции: единый блок (сбой одной пачки) или размазаны по потоку?
SELECT count(*) AS missing_rows, min(sid) AS min_sid, max(sid) AS max_sid,
       count(DISTINCT oper_date::date) AS distinct_days
FROM public.list_doc l
WHERE NOT EXISTS (SELECT 1 FROM public.doc_oper d WHERE d.id = l.sid);

-- 17) Равномерность потерь по дням (ровный профиль => систематика, а не разовый сбой)
SELECT round(avg(c), 1) AS avg_per_day, min(c) AS min_day, max(c) AS max_day, count(*) AS days
FROM (
    SELECT oper_date::date AS d, count(*) AS c
    FROM public.list_doc l
    WHERE NOT EXISTS (SELECT 1 FROM public.doc_oper x WHERE x.id = l.sid)
    GROUP BY 1
) t;

-- 18) Равномерность искажения org_id по дням
SELECT round(avg(c), 1) AS avg_per_day, min(c) AS min_day, max(c) AS max_day, count(*) AS days
FROM (
    SELECT date_operation::date AS d, count(*) AS c
    FROM public.doc_oper
    WHERE org_id !~ '^0\d{7}$'
    GROUP BY 1
) t;

-- 19) Восстанавливается ли код организации простым возвратом ведущего нуля?
--     100% восстановление => потеря значащего нуля при числовом приведении типа.
SELECT count(*) FILTER (WHERE '0' || d.org_id = l.client_id) AS restorable_by_leading_zero,
       count(*) AS total_broken
FROM public.doc_oper d
JOIN public.list_doc l ON l.sid = d.id
WHERE d.org_id <> l.client_id;

-- 20) У испорченных строк остальные поля совпадают с источником?
--     Ручная правка задела бы и соседние атрибуты.
SELECT count(*) FILTER (
           WHERE d.qua = l.quantity AND d.date_operation = l.oper_date
             AND d.cod_alco = l.product_id AND d.doc_1 = l.form_a AND d.doc_2 = l.form_b
       ) AS other_fields_intact,
       count(*) AS broken_rows
FROM public.doc_oper d
JOIN public.list_doc l ON l.sid = d.id
WHERE d.org_id <> l.client_id;

-- 21) Избирательность дефекта: затронуты конкретные организации или все подряд?
SELECT (SELECT count(DISTINCT client_id) FROM public.list_doc) AS orgs_total,
       (SELECT count(DISTINCT org_id) FROM public.doc_oper WHERE org_id !~ '^0\d{7}$') AS orgs_with_broken_code,
       (SELECT count(DISTINCT client_id) FROM public.list_doc l
        WHERE NOT EXISTS (SELECT 1 FROM public.doc_oper d WHERE d.id = l.sid)) AS orgs_with_lost_rows;
