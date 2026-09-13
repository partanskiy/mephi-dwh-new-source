BEGIN;

CREATE TABLE IF NOT EXISTS dwh.customer_report_datamart (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES dwh.d_customer (customer_id),
    customer_name VARCHAR,
    customer_address VARCHAR,
    customer_birthday DATE,
    customer_email VARCHAR NOT NULL,
    customer_money NUMERIC(18,2) NOT NULL CHECK (customer_money >= 0),
    platform_money NUMERIC(18,2) NOT NULL CHECK (platform_money >= 0),
    count_order BIGINT NOT NULL CHECK (count_order > 0),
    avg_price_order NUMERIC(18,2) NOT NULL CHECK (avg_price_order >= 0),
    median_time_order_completed NUMERIC(10,1)
        CHECK (median_time_order_completed >= 0),
    top_product_category VARCHAR NOT NULL,
    top_craftsman_id BIGINT NOT NULL REFERENCES dwh.d_craftsman (craftsman_id),
    count_order_created BIGINT NOT NULL CHECK (count_order_created >= 0),
    count_order_in_progress BIGINT NOT NULL CHECK (count_order_in_progress >= 0),
    count_order_delivery BIGINT NOT NULL CHECK (count_order_delivery >= 0),
    count_order_done BIGINT NOT NULL CHECK (count_order_done >= 0),
    count_order_not_done BIGINT NOT NULL CHECK (count_order_not_done >= 0),
    report_period VARCHAR(7) NOT NULL
        CHECK (report_period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
    CONSTRAINT customer_report_datamart_customer_period_key
        UNIQUE (customer_id, report_period),
    CHECK (count_order_done + count_order_not_done = count_order),
    CHECK (count_order_created + count_order_in_progress
           + count_order_delivery + count_order_done = count_order)
);

COMMENT ON TABLE dwh.customer_report_datamart IS 'Одна строка на заказчика и месяц создания заказов';
COMMENT ON COLUMN dwh.customer_report_datamart.id IS 'Идентификатор записи витрины';
COMMENT ON COLUMN dwh.customer_report_datamart.customer_id IS 'Идентификатор заказчика в DWH';
COMMENT ON COLUMN dwh.customer_report_datamart.customer_name IS 'Ф. И. О. заказчика; допускается NULL, как в d_customer';
COMMENT ON COLUMN dwh.customer_report_datamart.customer_address IS 'Адрес заказчика';
COMMENT ON COLUMN dwh.customer_report_datamart.customer_birthday IS 'Дата рождения заказчика';
COMMENT ON COLUMN dwh.customer_report_datamart.customer_email IS 'Электронная почта заказчика';
COMMENT ON COLUMN dwh.customer_report_datamart.customer_money IS 'Сумма стоимости всех заказов за месяц, до вычета комиссии';
COMMENT ON COLUMN dwh.customer_report_datamart.platform_money IS 'Комиссия платформы: 10% суммы стоимости заказов за месяц';
COMMENT ON COLUMN dwh.customer_report_datamart.count_order IS 'Количество заказов за месяц';
COMMENT ON COLUMN dwh.customer_report_datamart.avg_price_order IS 'Средняя стоимость заказа за месяц';
COMMENT ON COLUMN dwh.customer_report_datamart.median_time_order_completed IS 'Медиана длительности завершённых заказов в днях; NULL, если нет известных длительностей';
COMMENT ON COLUMN dwh.customer_report_datamart.top_product_category IS 'Категория с наибольшим числом заказов за месяц; при равенстве первая по сортировке C';
COMMENT ON COLUMN dwh.customer_report_datamart.top_craftsman_id IS 'Самый популярный мастер за месяц; при равенстве минимальный идентификатор';
COMMENT ON COLUMN dwh.customer_report_datamart.count_order_created IS 'Число заказов в статусе created';
COMMENT ON COLUMN dwh.customer_report_datamart.count_order_in_progress IS 'Число заказов в статусе in progress';
COMMENT ON COLUMN dwh.customer_report_datamart.count_order_delivery IS 'Число заказов в статусе delivery';
COMMENT ON COLUMN dwh.customer_report_datamart.count_order_done IS 'Число заказов в статусе done';
COMMENT ON COLUMN dwh.customer_report_datamart.count_order_not_done IS 'Число заказов в статусах, отличных от done';
COMMENT ON COLUMN dwh.customer_report_datamart.report_period IS 'Месяц создания заказа в формате YYYY-MM';

CREATE TABLE IF NOT EXISTS dwh.load_dates_customer_report_datamart (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    load_dttm TIMESTAMP WITHOUT TIME ZONE NOT NULL
);
COMMENT ON TABLE dwh.load_dates_customer_report_datamart IS 'Журнал успешно зафиксированных обновлений витрины по заказчикам';
COMMENT ON COLUMN dwh.load_dates_customer_report_datamart.id IS 'Идентификатор запуска';
COMMENT ON COLUMN dwh.load_dates_customer_report_datamart.load_dttm IS 'Верхняя граница обработанных изменений, Europe/Moscow, с точностью до микросекунд';

COMMIT;
