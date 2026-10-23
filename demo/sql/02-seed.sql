-- ============================================================
-- 造数：确定性伪随机，便于反复演示得到相近结果
-- 预计耗时 1~3 分钟（容器 512M / 2C）
-- ============================================================
USE shopdb;

SET SESSION sql_log_bin = 0;          -- 造数不进 binlog，后面单独做主从
SET SESSION unique_checks = 0;
SET SESSION foreign_key_checks = 0;
SET GLOBAL innodb_flush_log_at_trx_commit = 2;

-- 客户 5w
INSERT INTO customers (customer_no, name, phone, city, level, created_at)
SELECT CONCAT('C', LPAD(n, 6, '0')),
       CONCAT('客户', n),
       CONCAT('138', LPAD((n * 7919) % 100000000, 8, '0')),
       ELT(1 + n % 10, '北京','上海','广州','深圳','杭州','成都','武汉','南京','西安','苏州'),
       1 + n % 5,
       TIMESTAMPADD(SECOND, (n * 31) % 86400, TIMESTAMPADD(DAY, n % 700, '2023-01-01 00:00:00'))
FROM nums WHERE n < 50000;

-- 商品 5k
INSERT INTO products (sku, name, category_id, price, stock, status, updated_at)
SELECT CONCAT('SKU', LPAD(n, 6, '0')),
       CONCAT('商品-', ELT(1 + n % 20, '手机','耳机','笔记本','键盘','鼠标','显示器','相机','音箱','充电器','保护壳',
                                         'T恤','运动鞋','背包','水杯','台灯','沙发','床垫','锅具','零食','咖啡'), '-', n),
       1 + n % 50,
       ROUND(9.9 + ((n * 37) % 500000) / 100, 2),
       (n * 17) % 1000,
       IF(n % 97 = 0, 0, 1),
       NOW()
FROM nums WHERE n < 5000;

-- 订单 100w，时间跨度 2024-01-01 起 540 天
INSERT INTO orders (order_no, customer_id, status, total_amount, pay_amount, channel, remark, created_at, paid_at)
SELECT CONCAT('SO', LPAD(n, 10, '0')),
       1 + (n * 7919) % 50000,
       CASE WHEN n % 100 < 52 THEN 3
            WHEN n % 100 < 68 THEN 2
            WHEN n % 100 < 84 THEN 1
            WHEN n % 100 < 94 THEN 4
            ELSE 0 END,
       t.amt,
       t.amt - (n % 50) / 10,
       1 + n % 4,
       IF(n % 23 = 0, '客户备注：需要开发票，加急处理', NULL),
       t.ts,
       IF(n % 100 < 84, TIMESTAMPADD(MINUTE, 5, t.ts), NULL)
FROM (
  SELECT n,
         ROUND(19.9 + ((n * 37) % 200000) / 100, 2) AS amt,
         TIMESTAMPADD(SECOND, (n * 61) % 86400,
           TIMESTAMPADD(DAY, (n * 13) % 540, '2024-01-01 00:00:00'))   AS ts
  FROM nums WHERE n < 1000000
) t;

-- 订单明细 200w（每个订单 2 行）
INSERT INTO order_items (order_id, product_id, sku, qty, unit_price, amount)
SELECT 1 + (n % 1000000),
       1 + (n * 7919) % 5000,
       CONCAT('SKU', LPAD((n * 7919) % 5000, 6, '0')),
       1 + n % 3,
       ROUND(9.9 + (((n * 7919) % 5000) * 37 % 500000) / 100, 2),
       ROUND((1 + n % 3) * (9.9 + (((n * 7919) % 5000) * 37 % 500000) / 100), 2)
FROM nums WHERE n < 1000000;

INSERT INTO order_items (order_id, product_id, sku, qty, unit_price, amount)
SELECT 1 + ((n + 1000000) % 1000000),
       1 + ((n + 1000000) * 7919) % 5000,
       CONCAT('SKU', LPAD(((n + 1000000) * 7919) % 5000, 6, '0')),
       1 + (n + 1000000) % 3,
       ROUND(9.9 + ((((n + 1000000) * 7919) % 5000) * 37 % 500000) / 100, 2),
       ROUND((1 + (n + 1000000) % 3) * (9.9 + ((((n + 1000000) * 7919) % 5000) * 37 % 500000) / 100), 2)
FROM nums WHERE n < 1000000;

-- 支付流水 90w
INSERT INTO payments (payment_no, order_id, channel, amount, status, created_at)
SELECT CONCAT('P', LPAD(n, 10, '0')),
       1 + n,
       1 + n % 4,
       ROUND(19.9 + ((n * 37) % 200000) / 100, 2),
       IF(n % 50 = 0, 2, 1),
       TIMESTAMPADD(SECOND, (n * 61) % 86400,
         TIMESTAMPADD(DAY, (n * 13) % 540, '2024-01-01 00:00:00'))
FROM nums WHERE n < 900000;

-- 库存
INSERT INTO inventory (product_id, stock, version)
SELECT id, stock, 0 FROM products;

-- 库存流水 10w
INSERT INTO inventory_log (product_id, change_qty, biz_no, created_at)
SELECT 1 + n % 5000, -(1 + n % 3), CONCAT('BIZ', LPAD(n, 8, '0')), NOW()
FROM nums WHERE n < 100000;

DROP TABLE nums, nums10;

ANALYZE TABLE customers, products, orders, order_items, payments, inventory;

SET GLOBAL innodb_flush_log_at_trx_commit = 1;
SELECT 'seed done' AS msg;
