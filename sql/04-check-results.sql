-- Независимая полная сверка; постоянные таблицы не изменяются.
BEGIN;
LOCK TABLE source1.craft_market_wide,
    source2.craft_market_masters_products, source2.craft_market_orders_customers,
    source3.craft_market_orders, source3.craft_market_craftsmans,
    source3.craft_market_customers,
    external_source.craft_products_orders, external_source.customers IN SHARE MODE;
LOCK TABLE dwh.d_craftsman, dwh.d_customer, dwh.d_product, dwh.f_order,
    dwh.customer_report_datamart, dwh.load_dates_customer_report_datamart IN SHARE MODE;

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
        SELECT FROM tmp_source_craftsmen s WHERE NOT EXISTS (
            SELECT FROM dwh.d_craftsman d
            WHERE (d.craftsman_name, d.craftsman_address, d.craftsman_birthday, d.craftsman_email)
                IS NOT DISTINCT FROM (s.craftsman_name, s.craftsman_address, s.craftsman_birthday, s.craftsman_email)
        )
    ) OR EXISTS (
        SELECT FROM tmp_source_products s WHERE NOT EXISTS (
            SELECT FROM dwh.d_product d
            WHERE (d.product_name, d.product_description, d.product_type, d.product_price)
                IS NOT DISTINCT FROM (s.product_name, s.product_description, s.product_type, s.product_price)
        )
    ) OR EXISTS (
        SELECT FROM tmp_source_customers s WHERE NOT EXISTS (
            SELECT FROM dwh.d_customer d
            WHERE (d.customer_name, d.customer_address, d.customer_birthday, d.customer_email)
                IS NOT DISTINCT FROM (s.customer_name, s.customer_address, s.customer_birthday, s.customer_email)
        )
    ) THEN
        RAISE EXCEPTION 'DWH dimensions do not match all source records';
    END IF;
END;
$$;

CREATE TEMP TABLE tmp_expected_facts ON COMMIT DROP AS
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

CREATE TEMP TABLE tmp_expected_report ON COMMIT DROP AS
WITH orders AS (
    SELECT f.customer_id, f.craftsman_id, p.product_price, p.product_type, f.order_status,
           f.order_completion_date - f.order_created_date AS days,
           c.customer_name, c.customer_address, c.customer_birthday, c.customer_email,
           TO_CHAR(f.order_created_date, 'YYYY-MM') AS report_period
    FROM dwh.f_order f
    JOIN dwh.d_customer c USING (customer_id)
    JOIN dwh.d_product p USING (product_id)
), totals AS (
    SELECT customer_id, customer_name, customer_address, customer_birthday, customer_email,
           SUM(product_price)::numeric(18,2) AS customer_money,
           (SUM(product_price)::numeric / 10)::numeric(18,2) AS platform_money,
           COUNT(*) AS count_order,
           (SUM(product_price)::numeric / COUNT(*))::numeric(18,2) AS avg_price_order,
           ARRAY_AGG(days ORDER BY days)
               FILTER (WHERE order_status = 'done' AND days IS NOT NULL) AS completed_days,
           SUM(CASE WHEN order_status = 'created' THEN 1 ELSE 0 END)::bigint AS count_order_created,
           SUM(CASE WHEN order_status = 'in progress' THEN 1 ELSE 0 END)::bigint AS count_order_in_progress,
           SUM(CASE WHEN order_status = 'delivery' THEN 1 ELSE 0 END)::bigint AS count_order_delivery,
           SUM(CASE WHEN order_status = 'done' THEN 1 ELSE 0 END)::bigint AS count_order_done,
           SUM(CASE WHEN order_status <> 'done' THEN 1 ELSE 0 END)::bigint AS count_order_not_done,
           report_period
    FROM orders
    GROUP BY customer_id, customer_name, customer_address, customer_birthday, customer_email, report_period
), categories AS (
    SELECT DISTINCT ON (customer_id, report_period) customer_id, report_period, product_type
    FROM orders
    GROUP BY customer_id, report_period, product_type
    ORDER BY customer_id, report_period, COUNT(*) DESC, product_type COLLATE "C"
), craftsmen AS (
    SELECT DISTINCT ON (customer_id, report_period) customer_id, report_period, craftsman_id
    FROM orders
    GROUP BY customer_id, report_period, craftsman_id
    ORDER BY customer_id, report_period, COUNT(*) DESC, craftsman_id
)
SELECT t.customer_id, t.customer_name, t.customer_address, t.customer_birthday, t.customer_email,
       t.customer_money, t.platform_money, t.count_order, t.avg_price_order,
       ((completed_days[(CARDINALITY(completed_days) + 1) / 2]::numeric
         + completed_days[(CARDINALITY(completed_days) + 2) / 2]::numeric) / 2)::numeric(10,1)
         AS median_time_order_completed,
       c.product_type AS top_product_category, m.craftsman_id AS top_craftsman_id,
       t.count_order_created, t.count_order_in_progress, t.count_order_delivery,
       t.count_order_done, t.count_order_not_done, t.report_period
FROM totals t JOIN categories c USING (customer_id, report_period)
JOIN craftsmen m USING (customer_id, report_period);

DO $$
BEGIN
    IF EXISTS (
        (SELECT to_jsonb(e) FROM tmp_expected_facts e
         EXCEPT ALL SELECT to_jsonb(f) - 'order_id' - 'load_dttm' FROM dwh.f_order f)
        UNION ALL
        (SELECT to_jsonb(f) - 'order_id' - 'load_dttm' FROM dwh.f_order f
         EXCEPT ALL SELECT to_jsonb(e) FROM tmp_expected_facts e)
    ) THEN
        RAISE EXCEPTION 'DWH facts differ from normalized source orders';
    END IF;
    IF EXISTS (
        (SELECT to_jsonb(e) FROM tmp_expected_report e
         EXCEPT ALL SELECT to_jsonb(d) - 'id' FROM dwh.customer_report_datamart d)
        UNION ALL
        (SELECT to_jsonb(d) - 'id' FROM dwh.customer_report_datamart d
         EXCEPT ALL SELECT to_jsonb(e) FROM tmp_expected_report e)
    ) THEN
        RAISE EXCEPTION 'Incremental report differs from independent full recomputation';
    END IF;
    IF EXISTS (
        SELECT FROM dwh.customer_report_datamart
        GROUP BY customer_id, report_period HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'Duplicate customer-month rows';
    END IF;
    IF (SELECT COUNT(*) FROM dwh.f_order) <>
       (SELECT COALESCE(SUM(count_order), 0) FROM dwh.customer_report_datamart) THEN
        RAISE EXCEPTION 'Order counts differ between DWH and datamart';
    END IF;
END;
$$;

SELECT 'PASS' AS result, 'sources, facts and full recomputation agree' AS check_name;
SELECT source_name, COUNT(*) AS source_orders FROM tmp_sources GROUP BY source_name ORDER BY source_name;
SELECT (SELECT COUNT(*) FROM dwh.d_craftsman) AS craftsmen,
       (SELECT COUNT(*) FROM dwh.d_customer) AS customers,
       (SELECT COUNT(*) FROM dwh.d_product) AS products,
       (SELECT COUNT(*) FROM dwh.f_order) AS orders,
       COUNT(*) AS customer_months,
       SUM(customer_money) AS customer_money, SUM(platform_money) AS platform_money
FROM dwh.customer_report_datamart;
COMMIT;
