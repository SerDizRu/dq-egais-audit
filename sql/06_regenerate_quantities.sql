-- ============================================================
-- Перегенерация организаций, типов документов и количеств под балансовую модель.
-- БД: Project_DQ
--
-- ЗАЧЕМ. Проверка баланса перемещения — главный рабочий инструмент разбора
-- инцидентов, но на прежних данных она была бессмысленна: перемещение (справка Б)
-- состояло из пяти операций пяти РАЗНЫХ организаций по одной штуке, поэтому
-- сумма количеств в разрезе (организация, справка Б) равнялась самой операции и
-- у половины групп была отрицательной по построению.
--
-- БИЗНЕС-МОДЕЛЬ ПОСЛЕ ПЕРЕГЕНЕРАЦИИ
--   Справка Б сопровождает поставку партии конкретному участнику рынка.
--   Получатель приходует товар (chek, количество > 0), а затем списывает его
--   в продажу или на перемещение дальше (spis, количество < 0). Поэтому:
--
--     sum(quantity) по (client_id, form_b) НИКОГДА не отрицательна:
--     нельзя списать больше, чем получено по этой справке;
--
--     у БОЛЬШИНСТВА пар сумма ровно 0 — партия полностью реализована;
--     у остальных сумма положительна — часть партии ещё на складе.
--
--   Отрицательный баланс в витрине означает, что часть операций пары потерялась
--   или уехала под другой код организации. Это правило DQ-14.
--
-- СТРУКТУРА ПЕРЕМЕЩЕНИЯ (5 операций)
--   2 или 3 прихода (чередуется, чтобы сохранить пропорцию chek/spis ≈ 50/50),
--   остальные — списания; сумма списаний равна сумме приходов у 80% перемещений
--   и составляет 60% от неё у оставшихся 20% (остаток на складе).
--
-- ЧТО СОХРАНЯЕТСЯ
--   * состав строк: 1 000 000 в приёмке, 900 000 в витрине;
--   * оба дефекта витрины: 100 000 непогруженных операций и ТЕ ЖЕ 90 000 строк
--     с потерянным ведущим нулём в org_id;
--   * иерархия справок А/Б и коды продукции из sql/05_regenerate_documents.sql;
--   * согласованность знака количества с типом документа (правило DQ-07).
--
-- Запуск:  psql -h <host> -U postgres -d Project_DQ -f sql/06_regenerate_quantities.sql
-- Время:   ~2-4 минуты.
-- ============================================================

-- ------------------------------------------------------------
-- 0. Запоминаем, какие строки витрины несут искажённый код организации,
--    чтобы после пересборки воспроизвести дефект на тех же самых операциях.
-- ------------------------------------------------------------
DROP TABLE IF EXISTS public.tmp_damaged_ids;
CREATE TABLE public.tmp_damaged_ids AS
SELECT d.id
FROM public.doc_oper d
JOIN public.list_doc l ON l.sid = d.id
WHERE d.org_id <> l.client_id;

CREATE UNIQUE INDEX ON public.tmp_damaged_ids (id);

BEGIN;

-- ------------------------------------------------------------
-- 1. Приёмка: организация перемещения, тип документа, количества приходов
-- ------------------------------------------------------------
WITH orgs AS (
    SELECT client_id, (row_number() OVER (ORDER BY client_id) - 1) AS idx
    FROM (SELECT DISTINCT client_id FROM public.list_doc) t
),
org_count AS (SELECT count(*) AS n FROM orgs),
base AS (
    SELECT
        sid,
        form_b,
        -- порядковый номер операции внутри перемещения: 0..4
        (row_number() OVER (PARTITION BY form_b ORDER BY oper_date, sid) - 1) AS k,
        -- числовая часть номера справки Б — детерминированный источник «случайности»
        substring(form_b from 3)::bigint AS move_seq
    FROM public.list_doc
),
assigned AS (
    SELECT
        b.sid,
        b.k,
        b.move_seq,
        -- 2 или 3 прихода в перемещении: сохраняет пропорцию chek/spis около 50/50
        (2 + (b.move_seq % 2))::int AS n_chek,
        o.client_id AS org
    FROM base b
    CROSS JOIN org_count c
    JOIN orgs o ON o.idx = (b.move_seq * 7919) % c.n
)
UPDATE public.list_doc l
SET client_id = a.org,
    doc_type  = CASE WHEN a.k < a.n_chek THEN 'chek' ELSE 'spis' END,
    quantity  = CASE
                    WHEN a.k < a.n_chek
                    -- приход: 10.00 … 499.99, детерминирован номером справки и позицией
                    THEN round(10 + ((a.move_seq * 37 + a.k * 101) % 490)
                                  + ((a.move_seq * 13 + a.k * 7) % 100) / 100.0, 2)
                    ELSE l.quantity   -- списания пересчитываются на шаге 2
                END
FROM assigned a
WHERE l.sid = a.sid;

-- ------------------------------------------------------------
-- 2. Приёмка: списания распределяют сумму приходов своего перемещения
-- ------------------------------------------------------------
WITH inflow AS (
    SELECT form_b,
           sum(quantity) AS total_in,
           substring(form_b from 3)::bigint AS move_seq
    FROM public.list_doc
    WHERE doc_type = 'chek'
    GROUP BY form_b
),
outflow AS (
    SELECT sid, form_b,
           row_number() OVER (PARTITION BY form_b ORDER BY oper_date, sid) AS j,
           count(*)     OVER (PARTITION BY form_b)                         AS m
    FROM public.list_doc
    WHERE doc_type = 'spis'
),
calc AS (
    SELECT
        o.sid, o.j, o.m,
        -- каждое пятое перемещение оставляет 40% партии на складе -> баланс > 0
        round(i.total_in * CASE WHEN i.move_seq % 5 = 0 THEN 0.6 ELSE 1.0 END, 2) AS total_out
    FROM outflow o
    JOIN inflow i ON i.form_b = o.form_b
),
shares AS (
    SELECT
        sid, j, m, total_out,
        round(total_out / m, 2) AS even_share
    FROM calc
)
UPDATE public.list_doc l
SET quantity = - CASE
                    WHEN s.j < s.m THEN s.even_share
                    -- последнему списанию достаётся остаток: сумма сходится точно
                    ELSE s.total_out - s.even_share * (s.m - 1)
                END
FROM shares s
WHERE l.sid = s.sid;

-- ------------------------------------------------------------
-- 3. Витрина: зеркалим принятые значения по бизнес-ключу
-- ------------------------------------------------------------
UPDATE public.doc_oper d
SET org_id   = l.client_id,
    type_doc = l.doc_type,
    qua      = l.quantity
FROM public.list_doc l
WHERE l.sid = d.id;

-- ------------------------------------------------------------
-- 4. Воспроизводим дефект: у тех же 90 000 операций код организации
--    теряет ведущий ноль
-- ------------------------------------------------------------
UPDATE public.doc_oper d
SET org_id = substring(d.org_id from 2)
FROM public.tmp_damaged_ids t
WHERE d.id = t.id;

COMMIT;

DROP TABLE IF EXISTS public.tmp_damaged_ids;

-- ------------------------------------------------------------
-- 5. Контроль результата
-- ------------------------------------------------------------
-- 5.1 Баланс в приёмке: отрицательных нет, у большинства ровно ноль
WITH g AS (
    SELECT client_id, form_b, sum(quantity) AS balance
    FROM public.list_doc GROUP BY 1, 2
)
SELECT count(*)                                    AS pairs,
       count(*) FILTER (WHERE balance < 0)         AS negative_balance,
       count(*) FILTER (WHERE balance = 0)         AS zero_balance,
       round(100.0 * count(*) FILTER (WHERE balance = 0) / count(*), 1) AS zero_pct
FROM g;

-- 5.2 Баланс в витрине: правило DQ-14 обязано падать
WITH g AS (
    SELECT org_id, doc_2, sum(qua) AS balance
    FROM public.doc_oper GROUP BY 1, 2
)
SELECT count(*)                            AS pairs,
       count(*) FILTER (WHERE balance < 0) AS negative_balance,
       round(100.0 * count(*) FILTER (WHERE balance >= 0) / count(*), 2) AS pass_rate_pct
FROM g;

-- 5.3 Дефекты и согласованность на месте
SELECT (SELECT count(*) FROM public.list_doc)                                   AS source_rows,
       (SELECT count(*) FROM public.doc_oper)                                   AS mart_rows,
       (SELECT count(*) FROM public.doc_oper d JOIN public.list_doc l ON l.sid = d.id
         WHERE d.org_id <> l.client_id)                                         AS damaged_org_id,
       (SELECT count(*) FROM public.doc_oper
         WHERE NOT ((type_doc = 'chek' AND qua > 0) OR (type_doc = 'spis' AND qua < 0)))
                                                                                AS sign_violations,
       (SELECT count(*) FROM public.list_doc WHERE doc_type = 'chek')           AS chek_rows,
       (SELECT count(*) FROM public.list_doc WHERE doc_type = 'spis')           AS spis_rows;
