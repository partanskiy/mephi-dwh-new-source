-- Копируем только старые источники. Кавычки отличают реальные схемы
-- для чтения от изолированных схем, которые подставляет tests/run.py.
INSERT INTO source1.craft_market_wide SELECT * FROM "source1"."craft_market_wide";
INSERT INTO source2.craft_market_masters_products SELECT * FROM "source2"."craft_market_masters_products";
INSERT INTO source2.craft_market_orders_customers SELECT * FROM "source2"."craft_market_orders_customers";
INSERT INTO source3.craft_market_craftsmans SELECT * FROM "source3"."craft_market_craftsmans";
INSERT INTO source3.craft_market_customers SELECT * FROM "source3"."craft_market_customers";
INSERT INTO source3.craft_market_orders SELECT * FROM "source3"."craft_market_orders";

-- external_source в этом сценарии намеренно пустой. Это проверка реальных
-- старых источников, а не свидетельство загрузки отсутствующего нового.
-- RUN: 00-create-order-fact.sql
-- RUN: 00-create-order-fact.sql
-- RUN: 02-create-customer-datamart.sql
-- RUN: 01-load-dwh.sql
-- RUN: 03-update-customer-datamart.sql
-- RUN: 04-check-results.sql
CREATE TEMP TABLE saved_real_report AS
SELECT ctid::text AS location, to_jsonb(t) AS data FROM dwh.customer_report_datamart t;
-- RUN: 01-load-dwh.sql
-- RUN: 03-update-customer-datamart.sql
-- RUN: 04-check-results.sql
SELECT pg_temp.assert_true(NOT EXISTS (
    SELECT * FROM saved_real_report EXCEPT ALL
    SELECT ctid::text, to_jsonb(t) FROM dwh.customer_report_datamart t
), 'real source snapshot: unchanged report on rerun');
