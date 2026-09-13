BEGIN;
SET LOCAL TIME ZONE 'Europe/Moscow';

-- Порядок блокировок совпадает с загрузчиком: получаем завершённый пакет DWH.
LOCK TABLE dwh.d_craftsman, dwh.d_customer, dwh.d_product, dwh.f_order IN SHARE MODE;
LOCK TABLE dwh.customer_report_datamart,
    dwh.load_dates_customer_report_datamart IN SHARE ROW EXCLUSIVE MODE;

CREATE TEMP TABLE tmp_customer_bounds ON COMMIT DROP AS
SELECT COALESCE(MAX(load_dttm), '-infinity'::timestamp) AS previous_load,
       clock_timestamp()::timestamp AS current_load
FROM dwh.load_dates_customer_report_datamart;

-- Дельта определяет ключи для перерасчёта, а не набор суммируемых заказов.
CREATE TEMP TABLE tmp_customer_changed_keys ON COMMIT DROP AS
SELECT DISTINCT fo.customer_id, TO_CHAR(fo.order_created_date, 'YYYY-MM') AS report_period
FROM dwh.f_order fo
JOIN dwh.d_customer dc ON dc.customer_id = fo.customer_id
JOIN dwh.d_product dp ON dp.product_id = fo.product_id
CROSS JOIN tmp_customer_bounds b
WHERE (fo.load_dttm > b.previous_load AND fo.load_dttm <= b.current_load)
   OR (dc.load_dttm > b.previous_load AND dc.load_dttm <= b.current_load)
   OR (dp.load_dttm > b.previous_load AND dp.load_dttm <= b.current_load)
   OR NOT EXISTS (
       SELECT 1 FROM dwh.customer_report_datamart dm
       WHERE dm.customer_id = fo.customer_id
         AND dm.report_period = TO_CHAR(fo.order_created_date, 'YYYY-MM')
   );
CREATE UNIQUE INDEX ON tmp_customer_changed_keys (customer_id, report_period);

CREATE TEMP TABLE tmp_customer_orders ON COMMIT DROP AS
SELECT fo.order_id, fo.customer_id, fo.craftsman_id, fo.order_status,
       fo.order_completion_date - fo.order_created_date AS duration_days,
       dc.customer_name, dc.customer_address, dc.customer_birthday, dc.customer_email,
       dp.product_price, dp.product_type, k.report_period
FROM tmp_customer_changed_keys k
JOIN dwh.f_order fo
  ON fo.customer_id = k.customer_id
 AND fo.order_created_date >= (k.report_period || '-01')::date
 AND fo.order_created_date < (k.report_period || '-01')::date + INTERVAL '1 month'
JOIN dwh.d_customer dc ON dc.customer_id = fo.customer_id
JOIN dwh.d_product dp ON dp.product_id = fo.product_id;

CREATE TEMP TABLE tmp_customer_result ON COMMIT DROP AS
WITH totals AS (
    SELECT customer_id, customer_name, customer_address, customer_birthday, customer_email,
           SUM(product_price)::numeric(18,2) AS customer_money,
           (SUM(product_price) * 0.10)::numeric(18,2) AS platform_money,
           COUNT(*) AS count_order,
           AVG(product_price)::numeric(18,2) AS avg_price_order,
           (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY duration_days)
               FILTER (WHERE order_status = 'done'))::numeric(10,1)
               AS median_time_order_completed,
           COUNT(*) FILTER (WHERE order_status = 'created') AS count_order_created,
           COUNT(*) FILTER (WHERE order_status = 'in progress') AS count_order_in_progress,
           COUNT(*) FILTER (WHERE order_status = 'delivery') AS count_order_delivery,
           COUNT(*) FILTER (WHERE order_status = 'done') AS count_order_done,
           COUNT(*) FILTER (WHERE order_status <> 'done') AS count_order_not_done,
           report_period
    FROM tmp_customer_orders
    GROUP BY customer_id, customer_name, customer_address,
             customer_birthday, customer_email, report_period
), categories AS (
    SELECT customer_id, report_period, product_type,
           ROW_NUMBER() OVER (
               PARTITION BY customer_id, report_period
               ORDER BY COUNT(*) DESC, product_type COLLATE "C"
           ) AS position
    FROM tmp_customer_orders
    GROUP BY customer_id, report_period, product_type
), craftsmen AS (
    SELECT customer_id, report_period, craftsman_id,
           ROW_NUMBER() OVER (
               PARTITION BY customer_id, report_period
               ORDER BY COUNT(*) DESC, craftsman_id
           ) AS position
    FROM tmp_customer_orders
    GROUP BY customer_id, report_period, craftsman_id
)
SELECT t.*, c.product_type AS top_product_category, m.craftsman_id AS top_craftsman_id
FROM totals t
JOIN categories c USING (customer_id, report_period)
JOIN craftsmen m USING (customer_id, report_period)
WHERE c.position = 1 AND m.position = 1;

-- Один UPSERT по полному ключу не смешивает разные месяцы одного заказчика.
INSERT INTO dwh.customer_report_datamart AS target (
    customer_id, customer_name, customer_address, customer_birthday, customer_email,
    customer_money, platform_money, count_order, avg_price_order,
    median_time_order_completed, top_product_category, top_craftsman_id,
    count_order_created, count_order_in_progress, count_order_delivery,
    count_order_done, count_order_not_done, report_period
)
SELECT customer_id, customer_name, customer_address, customer_birthday, customer_email,
       customer_money, platform_money, count_order, avg_price_order,
       median_time_order_completed, top_product_category, top_craftsman_id,
       count_order_created, count_order_in_progress, count_order_delivery,
       count_order_done, count_order_not_done, report_period
FROM tmp_customer_result
ON CONFLICT (customer_id, report_period) DO UPDATE SET
    customer_name = EXCLUDED.customer_name,
    customer_address = EXCLUDED.customer_address,
    customer_birthday = EXCLUDED.customer_birthday,
    customer_email = EXCLUDED.customer_email,
    customer_money = EXCLUDED.customer_money,
    platform_money = EXCLUDED.platform_money,
    count_order = EXCLUDED.count_order,
    avg_price_order = EXCLUDED.avg_price_order,
    median_time_order_completed = EXCLUDED.median_time_order_completed,
    top_product_category = EXCLUDED.top_product_category,
    top_craftsman_id = EXCLUDED.top_craftsman_id,
    count_order_created = EXCLUDED.count_order_created,
    count_order_in_progress = EXCLUDED.count_order_in_progress,
    count_order_delivery = EXCLUDED.count_order_delivery,
    count_order_done = EXCLUDED.count_order_done,
    count_order_not_done = EXCLUDED.count_order_not_done
WHERE (target.customer_name, target.customer_address, target.customer_birthday,
       target.customer_email, target.customer_money, target.platform_money,
       target.count_order, target.avg_price_order, target.median_time_order_completed,
       target.top_product_category, target.top_craftsman_id, target.count_order_created,
       target.count_order_in_progress, target.count_order_delivery,
       target.count_order_done, target.count_order_not_done)
  IS DISTINCT FROM
      (EXCLUDED.customer_name, EXCLUDED.customer_address, EXCLUDED.customer_birthday,
       EXCLUDED.customer_email, EXCLUDED.customer_money, EXCLUDED.platform_money,
       EXCLUDED.count_order, EXCLUDED.avg_price_order, EXCLUDED.median_time_order_completed,
       EXCLUDED.top_product_category, EXCLUDED.top_craftsman_id, EXCLUDED.count_order_created,
       EXCLUDED.count_order_in_progress, EXCLUDED.count_order_delivery,
       EXCLUDED.count_order_done, EXCLUDED.count_order_not_done);

-- Граница фиксируется в той же транзакции, только после успешного расчёта.
INSERT INTO dwh.load_dates_customer_report_datamart (load_dttm)
SELECT current_load FROM tmp_customer_bounds;

SELECT (SELECT COUNT(*) FROM tmp_customer_changed_keys) AS recalculated_customer_months,
       (SELECT COUNT(*) FROM tmp_customer_orders) AS examined_orders;
COMMIT;
