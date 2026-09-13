-- RUN: 00-create-order-fact.sql
-- RUN: 00-create-order-fact.sql
-- RUN: 02-create-customer-datamart.sql
-- RUN: 02-create-customer-datamart.sql
-- RUN: 01-load-dwh.sql
-- RUN: 03-update-customer-datamart.sql
SELECT pg_temp.assert_true((SELECT COUNT(*) = 0 FROM dwh.customer_report_datamart), 'empty initial load');

CREATE TEMP TABLE fixture_customers AS
SELECT * FROM (VALUES
    (100::bigint, 'Customer A'::varchar, 'Address A'::varchar, DATE '1990-01-01', 'a@example.invalid'::varchar),
    (200, NULL, NULL, NULL, 'b@example.invalid'),
    (300, 'No orders', 'Address C', DATE '2000-01-01', 'c@example.invalid')
) v(customer_id, customer_name, customer_address, customer_birthday, customer_email);
CREATE TEMP TABLE fixture_masters AS
SELECT * FROM (VALUES
    (1::bigint, 'Master 1'::varchar, 'Address 1'::varchar, DATE '1980-01-01', 'm1@example.invalid'::varchar),
    (2, 'Master 2', 'Address 2', DATE '1981-01-01', 'm2@example.invalid'),
    (3, 'Master 3', 'Address 3', DATE '1982-01-01', 'm3@example.invalid')
) v(craftsman_id, craftsman_name, craftsman_address, craftsman_birthday, craftsman_email);
CREATE TEMP TABLE fixture_products AS
SELECT * FROM (VALUES
    (1::bigint, 'P1'::varchar, 'Description 1'::varchar, 'A'::varchar, 11::bigint),
    (2, 'P2', 'Description 2', 'B', 20), (3, 'P3', 'Description 3', 'A', 30),
    (4, 'P4', 'Description 4', 'B', 40), (5, 'P5', 'Description 5', 'C', 50),
    (6, 'P6', 'Description 6', 'C', 60), (7, 'P7', 'Description 7', 'D', 7)
) v(product_id, product_name, product_description, product_type, product_price);
CREATE TEMP TABLE fixture_orders AS
SELECT * FROM (VALUES
    (1::bigint, 'source1', 100::bigint, 1::bigint, 1::bigint, DATE '2022-01-01', DATE '2022-01-02', 'done'::varchar),
    (2, 'source2', 100, 2, 2, DATE '2022-01-02', DATE '2022-01-06', 'done'),
    (3, 'source3', 100, 1, 3, DATE '2022-01-03', NULL, 'delivery'),
    (4, 'external_source', 100, 2, 4, DATE '2022-01-04', NULL, 'in progress'),
    (5, 'external_source', 100, 3, 5, DATE '2022-01-05', NULL, 'created'),
    (6, 'external_source', 100, 3, 5, DATE '2022-02-01', DATE '2022-02-04', 'done'),
    (7, 'source1', 100, 3, 6, DATE '2022-02-02', DATE '2022-02-06', 'done'),
    (8, 'external_source', 200, 1, 7, DATE '2022-01-01', NULL, 'created')
) v(order_id, source_name, customer_id, craftsman_id, product_id,
    order_created_date, order_completion_date, order_status);
CREATE TEMP TABLE fixture_wide AS
SELECT o.order_id AS id, m.*, p.*, o.order_id, o.order_created_date,
       o.order_completion_date, o.order_status, c.*, o.source_name
FROM fixture_orders o JOIN fixture_masters m USING (craftsman_id)
JOIN fixture_products p USING (product_id) JOIN fixture_customers c USING (customer_id);

INSERT INTO source1.craft_market_wide
SELECT id, craftsman_id, craftsman_name, craftsman_address, craftsman_birthday, craftsman_email,
       product_id, product_name, product_description, product_type, product_price,
       order_id, order_created_date, order_completion_date, order_status,
       customer_id, customer_name, customer_address, customer_birthday, customer_email
FROM fixture_wide WHERE source_name = 'source1';
INSERT INTO source2.craft_market_masters_products
SELECT craftsman_id, craftsman_name, craftsman_address, craftsman_birthday, craftsman_email,
       product_id, product_name, product_description, product_type, product_price
FROM fixture_wide WHERE source_name = 'source2';
INSERT INTO source2.craft_market_orders_customers
SELECT order_id, craftsman_id, product_id, order_created_date, order_completion_date, order_status,
       customer_id, customer_name, customer_address, customer_birthday, customer_email
FROM fixture_wide WHERE source_name = 'source2';
INSERT INTO source3.craft_market_craftsmans SELECT * FROM fixture_masters WHERE craftsman_id = 1;
INSERT INTO source3.craft_market_customers SELECT * FROM fixture_customers WHERE customer_id = 100;
INSERT INTO source3.craft_market_orders
SELECT order_id, product_id, craftsman_id, customer_id, order_created_date,
       order_completion_date, order_status, product_name, product_description, product_type, product_price
FROM fixture_wide WHERE source_name = 'source3';
INSERT INTO external_source.customers SELECT * FROM fixture_customers;
INSERT INTO external_source.craft_products_orders
SELECT order_id, order_created_date, order_completion_date, order_status,
       craftsman_id, craftsman_name, craftsman_address, craftsman_birthday, craftsman_email,
       product_id, product_name, product_description, product_type, product_price, customer_id
FROM fixture_wide WHERE source_name = 'external_source';

-- RUN: 01-load-dwh.sql
-- RUN: 03-update-customer-datamart.sql
SELECT pg_temp.assert_true(
    (SELECT COUNT(*) = 8 FROM dwh.f_order) AND (SELECT COUNT(*) = 3 FROM dwh.d_customer),
    'four sources and customer without orders');
SELECT pg_temp.assert_true((SELECT COUNT(*) = 3 FROM dwh.customer_report_datamart), 'customer-month grain');
SELECT pg_temp.assert_true((SELECT customer_money = 151 AND platform_money = 15.10
    AND count_order = 5 AND avg_price_order = 30.20 AND median_time_order_completed = 2.5
    AND top_product_category = 'A' AND count_order_created = 1 AND count_order_in_progress = 1
    AND count_order_delivery = 1 AND count_order_done = 2 AND count_order_not_done = 3
    AND top_craftsman_id = (SELECT MIN(craftsman_id) FROM dwh.d_craftsman
                           WHERE craftsman_email IN ('m1@example.invalid', 'm2@example.invalid'))
    FROM dwh.customer_report_datamart WHERE customer_email = 'a@example.invalid' AND report_period = '2022-01'),
    'all metrics, fractional commission, even median and deterministic ties');
SELECT pg_temp.assert_true((SELECT customer_money = 110 AND median_time_order_completed = 3.5
    AND top_product_category = 'C' FROM dwh.customer_report_datamart
    WHERE customer_email = 'a@example.invalid' AND report_period = '2022-02'), 'independent monthly rankings');
SELECT pg_temp.assert_true((SELECT customer_name IS NULL AND customer_address IS NULL
    AND customer_birthday IS NULL AND median_time_order_completed IS NULL AND platform_money = 0.70
    FROM dwh.customer_report_datamart WHERE customer_email = 'b@example.invalid'), 'nullable customer and no completed orders');

CREATE TEMP TABLE first_dwh AS
SELECT 'customer' AS kind, to_jsonb(t) AS data FROM dwh.d_customer t
UNION ALL SELECT 'craftsman', to_jsonb(t) FROM dwh.d_craftsman t
UNION ALL SELECT 'product', to_jsonb(t) FROM dwh.d_product t
UNION ALL SELECT 'order', to_jsonb(t) FROM dwh.f_order t;
CREATE TEMP TABLE first_report AS
SELECT ctid::text AS location, to_jsonb(t) AS data FROM dwh.customer_report_datamart t;
-- RUN: 01-load-dwh.sql
-- RUN: 03-update-customer-datamart.sql
SELECT pg_temp.assert_true(NOT EXISTS (
    SELECT kind, data FROM first_dwh EXCEPT ALL (
        SELECT 'customer', to_jsonb(t) FROM dwh.d_customer t
        UNION ALL SELECT 'craftsman', to_jsonb(t) FROM dwh.d_craftsman t
        UNION ALL SELECT 'product', to_jsonb(t) FROM dwh.d_product t
        UNION ALL SELECT 'order', to_jsonb(t) FROM dwh.f_order t
    )), 'unchanged DWH rows and load timestamps on rerun');
SELECT pg_temp.assert_true(NOT EXISTS (
    SELECT * FROM first_report EXCEPT ALL
    SELECT ctid::text, to_jsonb(t) FROM dwh.customer_report_datamart t
), 'empty delta preserves report identifiers and physical rows');

-- Одинаковый заказ из другого источника не удваивается.
INSERT INTO external_source.craft_products_orders
SELECT order_id, order_created_date, order_completion_date, order_status,
       craftsman_id, craftsman_name, craftsman_address, craftsman_birthday, craftsman_email,
       product_id, product_name, product_description, product_type, product_price, customer_id
FROM fixture_wide WHERE order_id = 1;
-- RUN: 01-load-dwh.sql
SELECT pg_temp.assert_true((SELECT COUNT(*) = 8 FROM dwh.f_order), 'overlapping source copy is deduplicated');

INSERT INTO external_source.craft_products_orders
SELECT 109, DATE '2022-01-07', DATE '2022-01-09', 'done',
       craftsman_id, craftsman_name, craftsman_address, craftsman_birthday, craftsman_email,
       product_id, product_name, product_description, product_type, product_price, customer_id
FROM fixture_wide WHERE order_id = 1;
-- RUN: 01-load-dwh.sql
-- RUN: 03-update-customer-datamart.sql
SELECT pg_temp.assert_true((SELECT customer_money = 162 AND count_order = 6
    AND median_time_order_completed = 2 AND top_product_category = 'A'
    FROM dwh.customer_report_datamart WHERE customer_email = 'a@example.invalid' AND report_period = '2022-01'),
    'late order recalculates full month and odd median');

INSERT INTO external_source.craft_products_orders
SELECT 110, DATE '2022-03-01', NULL, 'created',
       craftsman_id, craftsman_name, craftsman_address, craftsman_birthday, craftsman_email,
       product_id, product_name, product_description, product_type, product_price, customer_id
FROM fixture_wide WHERE order_id = 2;
-- RUN: 01-load-dwh.sql
-- RUN: 03-update-customer-datamart.sql
SELECT pg_temp.assert_true((SELECT COUNT(*) = 4 FROM dwh.customer_report_datamart)
    AND (SELECT count_order = 1 AND customer_money = 20 FROM dwh.customer_report_datamart
         WHERE customer_email = 'a@example.invalid' AND report_period = '2022-03'), 'new month of existing customer');

UPDATE source3.craft_market_orders SET order_status = 'done', order_completion_date = DATE '2022-01-09'
WHERE order_id = 3;
-- RUN: 01-load-dwh.sql
-- RUN: 03-update-customer-datamart.sql
SELECT pg_temp.assert_true((SELECT count_order_done = 4 AND count_order_not_done = 2
    AND median_time_order_completed = 3 FROM dwh.customer_report_datamart
    WHERE customer_email = 'a@example.invalid' AND report_period = '2022-01'), 'fact-only update in the same day');

INSERT INTO external_source.customers
VALUES (400, 'Customer D', 'Address D', DATE '1995-01-01', 'd@example.invalid');
INSERT INTO external_source.craft_products_orders
SELECT 111, DATE '2022-01-20', NULL, 'created',
       craftsman_id, craftsman_name, craftsman_address, craftsman_birthday, craftsman_email,
       product_id, product_name, product_description, product_type, product_price, 400
FROM fixture_wide WHERE order_id = 1;
-- RUN: 01-load-dwh.sql
-- RUN: 03-update-customer-datamart.sql
SELECT pg_temp.assert_true((SELECT count_order = 1 AND customer_money = 11
    AND median_time_order_completed IS NULL FROM dwh.customer_report_datamart
    WHERE customer_email = 'd@example.invalid' AND report_period = '2022-01'), 'new customer after initial load');

UPDATE dwh.d_customer SET customer_address = 'Updated', load_dttm = clock_timestamp()
WHERE customer_email = 'a@example.invalid';
-- RUN: 03-update-customer-datamart.sql
SELECT pg_temp.assert_true((SELECT COUNT(*) = 3 FROM dwh.customer_report_datamart
    WHERE customer_email = 'a@example.invalid' AND customer_address = 'Updated'), 'customer change affects all its months');
UPDATE dwh.d_product SET product_type = 'Z', load_dttm = clock_timestamp() WHERE product_name = 'P1';
-- RUN: 03-update-customer-datamart.sql
SELECT pg_temp.assert_true((SELECT top_product_category = 'B' FROM dwh.customer_report_datamart
    WHERE customer_email = 'a@example.invalid' AND report_period = '2022-01'), 'product change recalculates category using full month');
SELECT pg_temp.assert_true(NOT EXISTS (
    SELECT * FROM first_report WHERE data->>'customer_email' = 'b@example.invalid'
    EXCEPT ALL SELECT ctid::text, to_jsonb(t) FROM dwh.customer_report_datamart t
    WHERE customer_email = 'b@example.invalid'
), 'unaffected customer is not rewritten');

UPDATE external_source.customers SET customer_address = 'Conflicting' WHERE customer_id = 100;
-- EXPECT-ERROR: 01-load-dwh.sql | Conflicting dimension attributes for the same business key
UPDATE external_source.customers SET customer_address = 'Address A' WHERE customer_id = 100;
DELETE FROM external_source.customers WHERE customer_id = 200;
-- EXPECT-ERROR: 01-load-dwh.sql | Source joins lost or multiplied orders
INSERT INTO external_source.customers SELECT * FROM fixture_customers WHERE customer_id = 200;
INSERT INTO external_source.craft_products_orders
SELECT 999, order_created_date, order_completion_date, order_status,
       craftsman_id, craftsman_name, craftsman_address, craftsman_birthday, craftsman_email,
       product_id, product_name, product_description, product_type, product_price, customer_id
FROM external_source.craft_products_orders WHERE order_id = 109;
-- EXPECT-ERROR: 01-load-dwh.sql | Distinct source orders collide on the legacy DWH business key
DELETE FROM external_source.craft_products_orders WHERE order_id = 999;

CREATE FUNCTION pg_temp.reject_report() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'forced report failure';
END;
$$;
CREATE TRIGGER test_reject_report BEFORE INSERT OR UPDATE ON dwh.customer_report_datamart
FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_report();
CREATE TEMP TABLE before_failure AS SELECT COUNT(*) AS runs FROM dwh.load_dates_customer_report_datamart;
UPDATE dwh.f_order SET order_completion_date = order_completion_date + 1, load_dttm = clock_timestamp()
WHERE product_id = (SELECT product_id FROM dwh.d_product WHERE product_name = 'P1')
  AND order_created_date = DATE '2022-01-01';
-- EXPECT-ERROR: 03-update-customer-datamart.sql | forced report failure
SELECT pg_temp.assert_true((SELECT COUNT(*) FROM dwh.load_dates_customer_report_datamart)
    = (SELECT runs FROM before_failure), 'failed report does not advance watermark');
DROP TRIGGER test_reject_report ON dwh.customer_report_datamart;
-- RUN: 03-update-customer-datamart.sql
SELECT pg_temp.assert_true((SELECT COUNT(*) FROM dwh.load_dates_customer_report_datamart)
    = (SELECT runs + 1 FROM before_failure), 'successful retry advances watermark');

-- Приводим исходные данные в соответствие с проверенными изменениями DWH.
UPDATE source1.craft_market_wide SET customer_address = 'Updated' WHERE customer_id = 100;
UPDATE source2.craft_market_orders_customers SET customer_address = 'Updated' WHERE customer_id = 100;
UPDATE source3.craft_market_customers SET customer_address = 'Updated' WHERE customer_id = 100;
UPDATE external_source.customers SET customer_address = 'Updated' WHERE customer_id = 100;
UPDATE source1.craft_market_wide SET product_type = 'Z' WHERE product_name = 'P1';
UPDATE external_source.craft_products_orders SET product_type = 'Z' WHERE product_name = 'P1';
UPDATE source1.craft_market_wide SET order_completion_date = DATE '2022-01-03' WHERE order_id = 1;
UPDATE external_source.craft_products_orders SET order_completion_date = DATE '2022-01-03' WHERE order_id = 1;
-- RUN: 01-load-dwh.sql
-- RUN: 03-update-customer-datamart.sql
-- RUN: 04-check-results.sql
SELECT pg_temp.assert_true((SELECT SUM(count_order) = 11 AND SUM(customer_money) = 310
    AND SUM(platform_money) = 31.00 FROM dwh.customer_report_datamart), 'final totals');
