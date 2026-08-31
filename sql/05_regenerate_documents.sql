
BEGIN;

-- ------------------------------------------------------------
-- 1. Приёмка: раздаём номера справок и коды продукции по иерархии партия -> перемещение
-- ------------------------------------------------------------
WITH ordered AS (
    SELECT sid,
           (row_number() OVER (ORDER BY oper_date, sid) - 1) AS rn
    FROM public.list_doc
),
hierarchy AS (
    SELECT sid,
           rn / 100       AS batch_no,   -- номер партии       (справка А)
           (rn % 100) / 5 AS move_no     -- номер перемещения   (справка Б внутри партии)
    FROM ordered
)
UPDATE public.list_doc l
SET form_a     = '1_' || lpad((1000000 + h.batch_no)::text, 10, '0'),
    form_b     = '2_' || lpad((1000000 + h.batch_no * 20 + h.move_no)::text, 10, '0'),
    -- Код продукции детерминирован партией: 18 цифр, как в исходных данных.
    product_id = 370000000000000000 + h.batch_no * 7919
FROM hierarchy h
WHERE l.sid = h.sid;

-- ------------------------------------------------------------
-- 2. Витрина: зеркалим принятые значения по бизнес-ключу.
--    Строки, не доехавшие до витрины (заложенный дефект полноты), остаются
--    отсутствующими — UPDATE их просто не находит.
-- ------------------------------------------------------------
UPDATE public.doc_oper d
SET doc_1    = l.form_a,
    doc_2    = l.form_b,
    cod_alco = l.product_id
FROM public.list_doc l
WHERE l.sid = d.id;

COMMIT;

-- ------------------------------------------------------------
-- 3. Контроль результата (должно выполниться всё сразу)
-- ------------------------------------------------------------
-- 3.1 Кардинальность: справок А намного меньше, чем операций
SELECT 'list_doc' AS t,
       count(*)                AS operations,
       count(DISTINCT form_a)  AS spravka_a,
       count(DISTINCT form_b)  AS spravka_b,
       count(DISTINCT product_id) AS products,
       round(count(*)::numeric / count(DISTINCT form_a), 1) AS ops_per_batch
FROM public.list_doc;

-- 3.2 Иерархия: каждая справка Б принадлежит ровно одной справке А
SELECT count(*) AS form_b_with_many_form_a
FROM (SELECT form_b FROM public.list_doc GROUP BY form_b HAVING count(DISTINCT form_a) > 1) x;

-- 3.3 Партия однородна по товару: одна справка А — один код продукции
SELECT count(*) AS form_a_with_many_products
FROM (SELECT form_a FROM public.list_doc GROUP BY form_a HAVING count(DISTINCT product_id) > 1) x;

-- 3.4 Форматы не сломаны
SELECT count(*) FILTER (WHERE form_a !~ '^1_\d{10}$') AS bad_form_a,
       count(*) FILTER (WHERE form_b !~ '^2_\d{10}$') AS bad_form_b,
       count(*) FILTER (WHERE length(product_id::text) NOT BETWEEN 15 AND 19) AS bad_product_len
FROM public.list_doc;

-- 3.5 Заложенные дефекты на месте: 100 000 потерь и 90 000 искажённых кодов
SELECT (SELECT count(*) FROM public.list_doc)  AS source_rows,
       (SELECT count(*) FROM public.doc_oper)  AS mart_rows,
       (SELECT count(*) FROM public.doc_oper d
        JOIN public.list_doc l ON l.sid = d.id
        WHERE d.org_id <> l.client_id)         AS damaged_org_id,
       (SELECT count(*) FROM public.doc_oper d
        JOIN public.list_doc l ON l.sid = d.id
        WHERE d.doc_1 <> l.form_a OR d.doc_2 <> l.form_b OR d.cod_alco <> l.product_id)
                                               AS mart_vs_source_doc_mismatch;
