-- Синтетическая схема повторяет проверенные типы учебной БД.
-- run.py заменяет имена схем на уникальные и в конце выполняет ROLLBACK.
CREATE TABLE dwh.d_craftsman (
    craftsman_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    craftsman_name VARCHAR NOT NULL, craftsman_address VARCHAR NOT NULL,
    craftsman_birthday DATE NOT NULL, craftsman_email VARCHAR NOT NULL,
    load_dttm TIMESTAMP NOT NULL
);
CREATE TABLE dwh.d_customer (
    customer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_name VARCHAR, customer_address VARCHAR, customer_birthday DATE,
    customer_email VARCHAR NOT NULL, load_dttm TIMESTAMP NOT NULL
);
CREATE TABLE dwh.d_product (
    product_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_name VARCHAR NOT NULL, product_description VARCHAR NOT NULL,
    product_type VARCHAR NOT NULL, product_price BIGINT NOT NULL,
    load_dttm TIMESTAMP NOT NULL
);
CREATE TABLE source1.craft_market_wide (
    id BIGINT PRIMARY KEY,
    craftsman_id BIGINT, craftsman_name VARCHAR, craftsman_address VARCHAR,
    craftsman_birthday DATE, craftsman_email VARCHAR,
    product_id BIGINT, product_name VARCHAR, product_description VARCHAR,
    product_type VARCHAR, product_price BIGINT,
    order_id BIGINT, order_created_date DATE, order_completion_date DATE, order_status VARCHAR,
    customer_id BIGINT, customer_name VARCHAR, customer_address VARCHAR,
    customer_birthday DATE, customer_email VARCHAR
);
CREATE TABLE source2.craft_market_masters_products AS
SELECT craftsman_id, craftsman_name, craftsman_address, craftsman_birthday, craftsman_email,
       product_id, product_name, product_description, product_type, product_price
FROM source1.craft_market_wide WITH NO DATA;
CREATE TABLE source2.craft_market_orders_customers AS
SELECT order_id, craftsman_id, product_id, order_created_date, order_completion_date,
       order_status, customer_id, customer_name, customer_address, customer_birthday, customer_email
FROM source1.craft_market_wide WITH NO DATA;
CREATE TABLE source3.craft_market_craftsmans AS
SELECT craftsman_id, craftsman_name, craftsman_address, craftsman_birthday, craftsman_email
FROM source1.craft_market_wide WITH NO DATA;
CREATE TABLE source3.craft_market_customers AS
SELECT customer_id, customer_name, customer_address, customer_birthday, customer_email
FROM source1.craft_market_wide WITH NO DATA;
CREATE TABLE source3.craft_market_orders AS
SELECT order_id, product_id, craftsman_id, customer_id, order_created_date,
       order_completion_date, order_status, product_name, product_description, product_type, product_price
FROM source1.craft_market_wide WITH NO DATA;
CREATE TABLE external_source.craft_products_orders AS
SELECT order_id, order_created_date, order_completion_date, order_status,
       craftsman_id, craftsman_name, craftsman_address, craftsman_birthday, craftsman_email,
       product_id, product_name, product_description, product_type, product_price, customer_id
FROM source1.craft_market_wide WITH NO DATA;
CREATE TABLE external_source.customers AS
SELECT * FROM source3.craft_market_customers WITH NO DATA;

CREATE FUNCTION pg_temp.assert_true(condition BOOLEAN, label TEXT) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAILED: %', label;
    END IF;
    RAISE NOTICE 'PASS: %', label;
END;
$$;

CREATE FUNCTION pg_temp.expect_error(script TEXT, expected TEXT) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE script;
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = expected THEN
            RAISE NOTICE 'PASS: expected failure: %', expected;
            RETURN;
        END IF;
        RAISE;
    END;
    RAISE EXCEPTION 'Expected failure did not occur: %', expected;
END;
$$;
