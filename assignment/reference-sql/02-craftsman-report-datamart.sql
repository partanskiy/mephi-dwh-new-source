-- DDL витрины данных
DROP TABLE IF EXISTS dwh.craftsman_report_datamart;

CREATE TABLE IF NOT EXISTS dwh.craftsman_report_datamart (
    id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL, -- идентификатор записи
    craftsman_id BIGINT NOT NULL, -- идентификатор мастера
    craftsman_name VARCHAR NOT NULL, -- Ф.И.О. мастера
    craftsman_address VARCHAR NOT NULL, -- адрес мастера
    craftsman_birthday DATE NOT NULL, -- дата рождения мастера
    craftsman_email VARCHAR NOT NULL, -- электронная почта мастера
    craftsman_money NUMERIC(15,2) NOT NULL, -- сумма, которую заработал мастер (-10% на платформы) за месяц
    platform_money BIGINT NOT NULL, -- сумма, которую заработала платформа от продаж мастера за месяц
    count_order BIGINT NOT NULL, -- количество заказов у мастера за месяц
    avg_price_order NUMERIC(10,2) NOT NULL, -- средняя стоимость одного заказа у мастера за месяц
    avg_age_customer NUMERIC(3,1) NOT NULL, -- средний возраст покупателей
    median_time_order_completed NUMERIC(10,1), -- медианное время в днях от момента создания заказа до его завершения за месяц
    top_product_category VARCHAR NOT NULL, -- самая популярная категория товаров у этого мастера за месяц
    count_order_created BIGINT NOT NULL, -- количество созданных заказов за месяц
    count_order_in_progress BIGINT NOT NULL, -- количество заказов в процессе изготовки за месяц
    count_order_delivery BIGINT NOT NULL, -- количество заказов в доставке за месяц
    count_order_done BIGINT NOT NULL, -- количество завершённых заказов за месяц
    count_order_not_done BIGINT NOT NULL, -- количество незавершённых заказов за месяц
    report_period VARCHAR NOT NULL, -- отчётный период год и месяц
    CONSTRAINT craftsman_report_datamart_pk PRIMARY KEY (id)
);

-- DDL таблицы инкрементальных загрузок
DROP TABLE IF EXISTS dwh.load_dates_craftsman_report_datamart;

CREATE TABLE IF NOT EXISTS dwh.load_dates_craftsman_report_datamart (
    id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    load_dttm DATE NOT NULL,
    CONSTRAINT load_dates_craftsman_report_datamart_pk PRIMARY KEY (id)
);

WITH
dwh_delta AS ( -- определяем, какие данные были изменены в витрине или добавлены в DWH. Формируем дельту изменений
    SELECT
            dc.craftsman_id AS craftsman_id,
            dc.craftsman_name AS craftsman_name,
            dc.craftsman_address AS craftsman_address,
            dc.craftsman_birthday AS craftsman_birthday,
            dc.craftsman_email AS craftsman_email,
            fo.order_id AS order_id,
            dp.product_id AS product_id,
            dp.product_price AS product_price,
            dp.product_type AS product_type,
            DATE_PART('year', AGE(dcs.customer_birthday)) AS customer_age,
            fo.order_completion_date - fo.order_created_date AS diff_order_date,
            fo.order_status AS order_status,
            TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period,
            crd.craftsman_id AS exist_craftsman_id,
            dc.load_dttm AS craftsman_load_dttm,
            dcs.load_dttm AS customers_load_dttm,
            dp.load_dttm AS products_load_dttm
            FROM dwh.f_order fo
                INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id
                INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id
                INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
                LEFT JOIN dwh.craftsman_report_datamart crd ON dc.craftsman_id = crd.craftsman_id
                    WHERE (fo.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart)) OR
                            (dc.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart)) OR
                            (dcs.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart)) OR
                            (dp.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart))
),
dwh_update_delta AS ( -- делаем выборку мастеров ручной работы, по которым были изменения в DWH. По этим мастерам данные в витрине нужно будет обновить
    SELECT
            dd.exist_craftsman_id AS craftsman_id
            FROM dwh_delta dd
                WHERE dd.exist_craftsman_id IS NOT NULL
),
dwh_delta_insert_result AS ( -- делаем расчёт витрины по новым данным. Этой информации по мастерам в рамках расчётного периода раньше не было, это новые данные. Их можно просто вставить (insert) в витрину без обновления
    SELECT
            T4.craftsman_id AS craftsman_id,
            T4.craftsman_name AS craftsman_name,
            T4.craftsman_address AS craftsman_address,
            T4.craftsman_birthday AS craftsman_birthday,
            T4.craftsman_email AS craftsman_email,
            T4.craftsman_money AS craftsman_money,
            T4.platform_money AS platform_money,
            T4.count_order AS count_order,
            T4.avg_price_order AS avg_price_order,
            T4.avg_age_customer AS avg_age_customer,
            T4.product_type AS top_product_category,
            T4.median_time_order_completed AS median_time_order_completed,
            T4.count_order_created AS count_order_created,
            T4.count_order_in_progress AS count_order_in_progress,
            T4.count_order_delivery AS count_order_delivery,
            T4.count_order_done AS count_order_done,
            T4.count_order_not_done AS count_order_not_done,
            T4.report_period AS report_period
            FROM (
                SELECT     -- в этой выборке объединяем две внутренние выборки по расчёту столбцов витрины и применяем оконную функцию для определения самой популярной категории товаров
                        *,
                        RANK() OVER(PARTITION BY T2.craftsman_id ORDER BY count_product DESC) AS rank_count_product
                        FROM (
                            SELECT -- в этой выборке делаем расчёт по большинству столбцов, так как все они требуют одной и той же группировки, кроме столбца с самой популярной категорией товаров у мастера. Для этого столбца сделаем отдельную выборку с другой группировкой и выполним JOIN
                                T1.craftsman_id AS craftsman_id,
                                T1.craftsman_name AS craftsman_name,
                                T1.craftsman_address AS craftsman_address,
                                T1.craftsman_birthday AS craftsman_birthday,
                                T1.craftsman_email AS craftsman_email,
                                SUM(T1.product_price) - (SUM(T1.product_price) * 0.1) AS craftsman_money,
                                SUM(T1.product_price) * 0.1 AS platform_money,
                                COUNT(order_id) AS count_order,
                                AVG(T1.product_price) AS avg_price_order,
                                AVG(T1.customer_age) AS avg_age_customer,
                                PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
                                SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created,
                                SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress,
                                SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery,
                                SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done,
                                SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
                                T1.report_period AS report_period
                                FROM dwh_delta AS T1
                                    WHERE T1.exist_craftsman_id IS NULL
                                        GROUP BY T1.craftsman_id, T1.craftsman_name, T1.craftsman_address, T1.craftsman_birthday, T1.craftsman_email, T1.report_period
                            ) AS T2
                                INNER JOIN (
                                    SELECT     -- Эта выборка поможет определить самый популярный товар у мастера ручной работы. Эта выборка не делается в предыдущем запросе, так как нужна другая группировка. Для данных этой выборки можно применить оконную функцию, которая и покажет самую популярную категорию товаров у мастера
                                            dd.craftsman_id AS craftsman_id_for_product_type,
                                            dd.product_type,
                                            COUNT(dd.product_id) AS count_product
                                            FROM dwh_delta AS dd
                                                GROUP BY dd.craftsman_id, dd.product_type
                                                    ORDER BY count_product DESC) AS T3 ON T2.craftsman_id = T3.craftsman_id_for_product_type
                ) AS T4 WHERE T4.rank_count_product = 1 ORDER BY report_period -- условие помогает оставить в выборке первую по популярности категорию товаров
),
dwh_delta_update_result AS ( -- делаем перерасчёт для существующих записей витринs, так как данные обновились за отчётные периоды. Логика похожа на insert, но нужно достать конкретные данные из DWH
    SELECT
            T4.craftsman_id AS craftsman_id,
            T4.craftsman_name AS craftsman_name,
            T4.craftsman_address AS craftsman_address,
            T4.craftsman_birthday AS craftsman_birthday,
            T4.craftsman_email AS craftsman_email,
            T4.craftsman_money AS craftsman_money,
            T4.platform_money AS platform_money,
            T4.count_order AS count_order,
            T4.avg_price_order AS avg_price_order,
            T4.avg_age_customer AS avg_age_customer,
            T4.product_type AS top_product_category,
            T4.median_time_order_completed AS median_time_order_completed,
            T4.count_order_created AS count_order_created,
            T4.count_order_in_progress AS count_order_in_progress,
            T4.count_order_delivery AS count_order_delivery,
            T4.count_order_done AS count_order_done,
            T4.count_order_not_done AS count_order_not_done,
            T4.report_period AS report_period
            FROM (
                SELECT     -- в этой выборке объединяем две внутренние выборки по расчёту столбцов витрины и применяем оконную функцию для определения самой популярной категории товаров
                        *,
                        RANK() OVER(PARTITION BY T2.craftsman_id ORDER BY count_product DESC) AS rank_count_product
                        FROM (
                            SELECT -- в этой выборке делаем расчёт по большинству столбцов, так как все они требуют одной и той же группировки, кроме столбца с самой популярной категорией товаров у мастера. Для этого столбца сделаем отдельную выборку с другой группировкой и выполним JOIN
                                T1.craftsman_id AS craftsman_id,
                                T1.craftsman_name AS craftsman_name,
                                T1.craftsman_address AS craftsman_address,
                                T1.craftsman_birthday AS craftsman_birthday,
                                T1.craftsman_email AS craftsman_email,
                                SUM(T1.product_price) - (SUM(T1.product_price) * 0.1) AS craftsman_money,
                                SUM(T1.product_price) * 0.1 AS platform_money,
                                COUNT(order_id) AS count_order,
                                AVG(T1.product_price) AS avg_price_order,
                                AVG(T1.customer_age) AS avg_age_customer,
                                PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
                                SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created,
                                SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress,
                                SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery,
                                SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done,
                                SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
                                T1.report_period AS report_period
                                FROM (
                                    SELECT     -- в этой выборке достаём из DWH обновлённые или новые данные по мастерам, которые уже есть в витрине
                                            dc.craftsman_id AS craftsman_id,
                                            dc.craftsman_name AS craftsman_name,
                                            dc.craftsman_address AS craftsman_address,
                                            dc.craftsman_birthday AS craftsman_birthday,
                                            dc.craftsman_email AS craftsman_email,
                                            fo.order_id AS order_id,
                                            dp.product_id AS product_id,
                                            dp.product_price AS product_price,
                                            dp.product_type AS product_type,
                                            DATE_PART('year', AGE(dcs.customer_birthday)) AS customer_age,
                                            fo.order_completion_date - fo.order_created_date AS diff_order_date,
                                            fo.order_status AS order_status,
                                            TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period
                                            FROM dwh.f_order fo
                                                INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id
                                                INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id
                                                INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
                                                INNER JOIN dwh_update_delta ud ON fo.craftsman_id = ud.craftsman_id
                                ) AS T1
                                    GROUP BY T1.craftsman_id, T1.craftsman_name, T1.craftsman_address, T1.craftsman_birthday, T1.craftsman_email, T1.report_period
                            ) AS T2
                                INNER JOIN (
                                    SELECT     -- Эта выборка поможет определить самый популярный товар у мастера. Эта выборка не делается в предыдущем запросе, так как нужна другая группировка. Для данных этой выборки можно применить оконную функцию, которая и покажет самую популярную категорию товаров у мастера
                                            dd.craftsman_id AS craftsman_id_for_product_type,
                                            dd.product_type,
                                            COUNT(dd.product_id) AS count_product
                                            FROM dwh_delta AS dd
                                                GROUP BY dd.craftsman_id, dd.product_type
                                                    ORDER BY count_product DESC) AS T3 ON T2.craftsman_id = T3.craftsman_id_for_product_type
                ) AS T4 WHERE T4.rank_count_product = 1 ORDER BY report_period
),
insert_delta AS ( -- выполняем insert новых расчитанных данных для витрины
    INSERT INTO dwh.craftsman_report_datamart (
        craftsman_id,
        craftsman_name,
        craftsman_address,
        craftsman_birthday,
        craftsman_email,
        craftsman_money,
        platform_money,
        count_order,
        avg_price_order,
        avg_age_customer,
        median_time_order_completed,
        top_product_category,
        count_order_created,
        count_order_in_progress,
        count_order_delivery,
        count_order_done,
        count_order_not_done,
        report_period
    ) SELECT
            craftsman_id,
            craftsman_name,
            craftsman_address,
            craftsman_birthday,
            craftsman_email,
            craftsman_money,
            platform_money,
            count_order,
            avg_price_order,
            avg_age_customer,
            median_time_order_completed,
            top_product_category,
            count_order_created,
            count_order_in_progress,
            count_order_delivery,
            count_order_done,
            count_order_not_done,
            report_period
            FROM dwh_delta_insert_result
),
update_delta AS ( -- выполняем обновление показателей в отчёте по уже существующим мастерам
    UPDATE dwh.craftsman_report_datamart SET
        craftsman_name = updates.craftsman_name,
        craftsman_address = updates.craftsman_address,
        craftsman_birthday = updates.craftsman_birthday,
        craftsman_email = updates.craftsman_email,
        craftsman_money = updates.craftsman_money,
        platform_money = updates.platform_money,
        count_order = updates.count_order,
        avg_price_order = updates.avg_price_order,
        avg_age_customer = updates.avg_age_customer,
        median_time_order_completed = updates.median_time_order_completed,
        top_product_category = updates.top_product_category,
        count_order_created = updates.count_order_created,
        count_order_in_progress = updates.count_order_in_progress,
        count_order_delivery = updates.count_order_delivery,
        count_order_done = updates.count_order_done,
        count_order_not_done = updates.count_order_not_done,
        report_period = updates.report_period
    FROM (
        SELECT
            craftsman_id,
            craftsman_name,
            craftsman_address,
            craftsman_birthday,
            craftsman_email,
            craftsman_money,
            platform_money,
            count_order,
            avg_price_order,
            avg_age_customer,
            median_time_order_completed,
            top_product_category,
            count_order_created,
            count_order_in_progress,
            count_order_delivery,
            count_order_done,
            count_order_not_done,
            report_period
            FROM dwh_delta_update_result) AS updates
    WHERE dwh.craftsman_report_datamart.craftsman_id = updates.craftsman_id
),
insert_load_date AS ( -- делаем запись в таблицу загрузок о том, когда была совершена загрузка, чтобы в следующий раз взять данные, которые будут добавлены или изменены после этой даты
    INSERT INTO dwh.load_dates_craftsman_report_datamart (
        load_dttm
    )
    SELECT GREATEST(COALESCE(MAX(craftsman_load_dttm), NOW()),
                    COALESCE(MAX(customers_load_dttm), NOW()),
                    COALESCE(MAX(products_load_dttm), NOW()))
        FROM dwh_delta
)
SELECT 'increment datamart'; -- инициализируем запрос CTE
