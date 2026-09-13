-- Подготовка недостающего объекта предыдущего модуля.
-- Существующие измерения и источники не пересоздаются.
BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS d_craftsman_business_key
    ON dwh.d_craftsman (craftsman_name, craftsman_email);
CREATE UNIQUE INDEX IF NOT EXISTS d_customer_business_key
    ON dwh.d_customer (customer_name, customer_email) NULLS NOT DISTINCT;
CREATE UNIQUE INDEX IF NOT EXISTS d_product_business_key
    ON dwh.d_product (product_name, product_description, product_price);

CREATE TABLE IF NOT EXISTS dwh.f_order (
    order_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id BIGINT NOT NULL REFERENCES dwh.d_product (product_id),
    craftsman_id BIGINT NOT NULL REFERENCES dwh.d_craftsman (craftsman_id),
    customer_id BIGINT NOT NULL REFERENCES dwh.d_customer (customer_id),
    order_created_date DATE NOT NULL,
    order_completion_date DATE,
    order_status VARCHAR NOT NULL
        CHECK (order_status IN ('created', 'in progress', 'delivery', 'done')),
    load_dttm TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    CHECK (order_completion_date >= order_created_date)
);

CREATE UNIQUE INDEX IF NOT EXISTS f_order_business_key
    ON dwh.f_order (product_id, craftsman_id, customer_id, order_created_date);
CREATE INDEX IF NOT EXISTS f_order_customer_date_idx
    ON dwh.f_order (customer_id, order_created_date);
CREATE INDEX IF NOT EXISTS f_order_product_idx ON dwh.f_order (product_id);

COMMENT ON TABLE dwh.f_order IS 'Заказы маркетплейса; бизнес-ключ сохранён из загрузчика курса';
COMMENT ON COLUMN dwh.f_order.load_dttm IS 'Момент изменения записи; часовой пояс Europe/Moscow';

COMMIT;
