BEGIN;
SET LOCAL TIME ZONE 'Europe/Moscow';

-- Четыре согласованных снимка источников и единственный писатель DWH.
LOCK TABLE source1.craft_market_wide,
    source2.craft_market_masters_products, source2.craft_market_orders_customers,
    source3.craft_market_orders, source3.craft_market_craftsmans,
    source3.craft_market_customers,
    external_source.craft_products_orders, external_source.customers IN SHARE MODE;
LOCK TABLE dwh.d_craftsman, dwh.d_customer, dwh.d_product, dwh.f_order
    IN SHARE ROW EXCLUSIVE MODE;

-- clock_timestamp вызывается после блокировок, чтобы ожидавший запуск
-- не получил метку раньше уже обработанной границы витрины.
CREATE TEMP TABLE tmp_load_clock ON COMMIT DROP AS
SELECT clock_timestamp()::timestamp AS batch_dttm;

CREATE TEMP TABLE tmp_sources ON COMMIT DROP AS
SELECT 'source1'::text AS source_name, order_id AS source_order_id,
       order_created_date, order_completion_date, order_status,
       craftsman_name, craftsman_address, craftsman_birthday, craftsman_email,
       product_name, product_description, product_type, product_price,
       customer_name, customer_address, customer_birthday, customer_email
FROM source1.craft_market_wide
UNION ALL
SELECT 'source2', o.order_id, o.order_created_date, o.order_completion_date, o.order_status,
       p.craftsman_name, p.craftsman_address, p.craftsman_birthday, p.craftsman_email,
       p.product_name, p.product_description, p.product_type, p.product_price,
       o.customer_name, o.customer_address, o.customer_birthday, o.customer_email
FROM source2.craft_market_masters_products p
JOIN source2.craft_market_orders_customers o
  ON o.product_id = p.product_id AND o.craftsman_id = p.craftsman_id
UNION ALL
SELECT 'source3', o.order_id, o.order_created_date, o.order_completion_date, o.order_status,
       m.craftsman_name, m.craftsman_address, m.craftsman_birthday, m.craftsman_email,
       o.product_name, o.product_description, o.product_type, o.product_price,
       c.customer_name, c.customer_address, c.customer_birthday, c.customer_email
FROM source3.craft_market_orders o
JOIN source3.craft_market_craftsmans m ON m.craftsman_id = o.craftsman_id
JOIN source3.craft_market_customers c ON c.customer_id = o.customer_id
UNION ALL
SELECT 'external_source', o.order_id, o.order_created_date, o.order_completion_date, o.order_status,
       o.craftsman_name, o.craftsman_address, o.craftsman_birthday, o.craftsman_email,
       o.product_name, o.product_description, o.product_type, o.product_price,
       c.customer_name, c.customer_address, c.customer_birthday, c.customer_email
FROM external_source.craft_products_orders o
JOIN external_source.customers c ON c.customer_id = o.customer_id;

-- Самостоятельные измерения загружаются и при отсутствии заказов.
CREATE TEMP TABLE tmp_source_craftsmen ON COMMIT DROP AS
SELECT craftsman_name, craftsman_address, craftsman_birthday, craftsman_email FROM tmp_sources
UNION
SELECT craftsman_name, craftsman_address, craftsman_birthday, craftsman_email
FROM source2.craft_market_masters_products
UNION
SELECT craftsman_name, craftsman_address, craftsman_birthday, craftsman_email
FROM source3.craft_market_craftsmans;

CREATE TEMP TABLE tmp_source_products ON COMMIT DROP AS
SELECT product_name, product_description, product_type, product_price FROM tmp_sources
UNION
SELECT product_name, product_description, product_type, product_price
FROM source2.craft_market_masters_products;

CREATE TEMP TABLE tmp_source_customers ON COMMIT DROP AS
SELECT customer_name, customer_address, customer_birthday, customer_email FROM tmp_sources
UNION
SELECT customer_name, customer_address, customer_birthday, customer_email
FROM source3.craft_market_customers
UNION
SELECT customer_name, customer_address, customer_birthday, customer_email
FROM external_source.customers;

-- Не пропускаем строки после JOIN и не выбираем произвольные версии измерений.
DO $$
BEGIN
    IF (SELECT COUNT(*) FROM tmp_sources) <>
       (SELECT COUNT(*) FROM source1.craft_market_wide) +
       (SELECT COUNT(*) FROM source2.craft_market_orders_customers) +
       (SELECT COUNT(*) FROM source3.craft_market_orders) +
       (SELECT COUNT(*) FROM external_source.craft_products_orders) THEN
        RAISE EXCEPTION 'Source joins lost or multiplied orders';
    END IF;
    IF EXISTS (
        SELECT FROM tmp_sources GROUP BY source_name, source_order_id HAVING COUNT(*) <> 1
    ) THEN
        RAISE EXCEPTION 'Source order identifiers are not unique after joins';
    END IF;
    IF EXISTS (
        SELECT FROM tmp_sources
        WHERE order_created_date IS NULL OR order_status IS NULL
           OR order_status NOT IN ('created', 'in progress', 'delivery', 'done')
           OR order_completion_date < order_created_date
           OR craftsman_name IS NULL OR craftsman_address IS NULL
           OR craftsman_birthday IS NULL OR craftsman_email IS NULL
           OR product_name IS NULL OR product_description IS NULL
           OR product_type IS NULL OR product_price IS NULL OR product_price < 0
           OR customer_email IS NULL
    ) THEN
        RAISE EXCEPTION 'Source contains invalid required values, dates, prices or statuses';
    END IF;
    IF EXISTS (
        SELECT FROM tmp_source_craftsmen GROUP BY craftsman_name, craftsman_email
        HAVING COUNT(DISTINCT (craftsman_address, craftsman_birthday)) > 1
    ) OR EXISTS (
        SELECT FROM tmp_source_customers GROUP BY customer_name, customer_email
        HAVING COUNT(DISTINCT (customer_address, customer_birthday)) > 1
    ) OR EXISTS (
        SELECT FROM tmp_source_products GROUP BY product_name, product_description, product_price
        HAVING COUNT(DISTINCT product_type) > 1
    ) THEN
        RAISE EXCEPTION 'Conflicting dimension attributes for the same business key';
    END IF;
    IF EXISTS (
        SELECT FROM tmp_sources
        GROUP BY source_name, craftsman_name, craftsman_email, customer_name, customer_email,
                 product_name, product_description, product_price, order_created_date
        HAVING COUNT(DISTINCT source_order_id) > 1
    ) THEN
        RAISE EXCEPTION 'Distinct source orders collide on the legacy DWH business key';
    END IF;
END;
$$;

MERGE INTO dwh.d_craftsman d
USING tmp_source_craftsmen s
ON d.craftsman_name = s.craftsman_name AND d.craftsman_email = s.craftsman_email
WHEN MATCHED AND (d.craftsman_address, d.craftsman_birthday)
    IS DISTINCT FROM (s.craftsman_address, s.craftsman_birthday) THEN
    UPDATE SET craftsman_address = s.craftsman_address,
               craftsman_birthday = s.craftsman_birthday,
               load_dttm = (SELECT batch_dttm FROM tmp_load_clock)
WHEN NOT MATCHED THEN
    INSERT (craftsman_name, craftsman_address, craftsman_birthday, craftsman_email, load_dttm)
    VALUES (s.craftsman_name, s.craftsman_address, s.craftsman_birthday, s.craftsman_email,
            (SELECT batch_dttm FROM tmp_load_clock));

MERGE INTO dwh.d_product d
USING tmp_source_products s
ON d.product_name = s.product_name AND d.product_description = s.product_description
   AND d.product_price = s.product_price
WHEN MATCHED AND d.product_type IS DISTINCT FROM s.product_type THEN
    UPDATE SET product_type = s.product_type, load_dttm = (SELECT batch_dttm FROM tmp_load_clock)
WHEN NOT MATCHED THEN
    INSERT (product_name, product_description, product_type, product_price, load_dttm)
    VALUES (s.product_name, s.product_description, s.product_type, s.product_price,
            (SELECT batch_dttm FROM tmp_load_clock));

MERGE INTO dwh.d_customer d
USING tmp_source_customers s
ON d.customer_name IS NOT DISTINCT FROM s.customer_name AND d.customer_email = s.customer_email
WHEN MATCHED AND (d.customer_address, d.customer_birthday)
    IS DISTINCT FROM (s.customer_address, s.customer_birthday) THEN
    UPDATE SET customer_address = s.customer_address, customer_birthday = s.customer_birthday,
               load_dttm = (SELECT batch_dttm FROM tmp_load_clock)
WHEN NOT MATCHED THEN
    INSERT (customer_name, customer_address, customer_birthday, customer_email, load_dttm)
    VALUES (s.customer_name, s.customer_address, s.customer_birthday, s.customer_email,
            (SELECT batch_dttm FROM tmp_load_clock));

-- Повтор одного заказа в разных источниках с одинаковыми атрибутами
-- сводится к одной записи по бизнес-ключу, как в модели курса.
CREATE TEMP TABLE tmp_sources_fact ON COMMIT DROP AS
SELECT DISTINCT dp.product_id, dm.craftsman_id, dc.customer_id,
       s.order_created_date, s.order_completion_date, s.order_status
FROM tmp_sources s
JOIN dwh.d_craftsman dm
  ON dm.craftsman_name = s.craftsman_name AND dm.craftsman_email = s.craftsman_email
JOIN dwh.d_customer dc
  ON dc.customer_name IS NOT DISTINCT FROM s.customer_name AND dc.customer_email = s.customer_email
JOIN dwh.d_product dp
  ON dp.product_name = s.product_name AND dp.product_description = s.product_description
 AND dp.product_price = s.product_price;

DO $$
BEGIN
    IF EXISTS (
        SELECT FROM tmp_sources_fact
        GROUP BY product_id, craftsman_id, customer_id, order_created_date HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'Conflicting facts for the same DWH business key';
    END IF;
END;
$$;

MERGE INTO dwh.f_order f
USING tmp_sources_fact s
ON f.product_id = s.product_id AND f.craftsman_id = s.craftsman_id
   AND f.customer_id = s.customer_id AND f.order_created_date = s.order_created_date
WHEN MATCHED AND (f.order_completion_date, f.order_status)
    IS DISTINCT FROM (s.order_completion_date, s.order_status) THEN
    UPDATE SET order_completion_date = s.order_completion_date, order_status = s.order_status,
               load_dttm = (SELECT batch_dttm FROM tmp_load_clock)
WHEN NOT MATCHED THEN
    INSERT (product_id, craftsman_id, customer_id, order_created_date,
            order_completion_date, order_status, load_dttm)
    VALUES (s.product_id, s.craftsman_id, s.customer_id, s.order_created_date,
            s.order_completion_date, s.order_status, (SELECT batch_dttm FROM tmp_load_clock));

SELECT source_name, COUNT(*) AS source_orders FROM tmp_sources GROUP BY source_name ORDER BY source_name;
SELECT COUNT(*) AS normalized_orders FROM tmp_sources_fact;
COMMIT;
