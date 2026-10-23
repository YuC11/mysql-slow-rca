-- ============================================================
-- 企业级示例库：电商交易（shopdb）
-- 表结构与索引按"真实业务 + 常见设计缺陷"混合设计，
-- 便于演示慢查询、锁、连接数等问题
-- ============================================================
CREATE DATABASE IF NOT EXISTS shopdb
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE shopdb;

SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS inventory_log, inventory, payments, order_items, orders, products, customers, nums, nums10;
SET FOREIGN_KEY_CHECKS = 1;

-- 客户
CREATE TABLE customers (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  customer_no VARCHAR(32)     NOT NULL,
  name        VARCHAR(64)     NOT NULL,
  phone       VARCHAR(20)     NOT NULL COMMENT '注意：没有索引，演示按手机号查询',
  city        VARCHAR(32)     NOT NULL,
  level       TINYINT         NOT NULL DEFAULT 1,
  created_at  DATETIME        NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_customer_no (customer_no),
  KEY idx_city (city),
  KEY idx_created_at (created_at)
) ENGINE=InnoDB COMMENT='客户表 5w';

-- 商品
CREATE TABLE products (
  id          INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  sku         VARCHAR(32)   NOT NULL,
  name        VARCHAR(128)  NOT NULL,
  category_id INT           NOT NULL,
  price       DECIMAL(10,2) NOT NULL,
  stock       INT           NOT NULL DEFAULT 0,
  status      TINYINT       NOT NULL DEFAULT 1,
  updated_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_sku (sku),
  KEY idx_category (category_id),
  KEY idx_status_stock (status, stock)
) ENGINE=InnoDB COMMENT='商品表 5k';

-- 订单主表：100w
CREATE TABLE orders (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_no     VARCHAR(32)     NOT NULL,
  customer_id  BIGINT UNSIGNED NOT NULL,
  status       TINYINT         NOT NULL COMMENT '0待支付 1已支付 2已发货 3已完成 4已取消',
  total_amount DECIMAL(12,2)   NOT NULL,
  pay_amount   DECIMAL(12,2)   NOT NULL,
  channel      TINYINT         NOT NULL COMMENT '1小程序 2App 3H5 4POS',
  remark       VARCHAR(255)    DEFAULT NULL,
  created_at   DATETIME        NOT NULL,
  paid_at      DATETIME        DEFAULT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_order_no (order_no),
  KEY idx_customer_created (customer_id, created_at),
  KEY idx_created_at (created_at),
  KEY idx_status (status)
) ENGINE=InnoDB COMMENT='订单主表 100w';

-- 订单明细：200w
CREATE TABLE order_items (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id   BIGINT UNSIGNED NOT NULL,
  product_id INT UNSIGNED    NOT NULL,
  sku        VARCHAR(32)     NOT NULL COMMENT '注意：没有索引，演示按 SKU 统计',
  qty        INT             NOT NULL,
  unit_price DECIMAL(10,2)   NOT NULL,
  amount     DECIMAL(12,2)   NOT NULL,
  PRIMARY KEY (id),
  KEY idx_order_id (order_id),
  KEY idx_product_id (product_id)
) ENGINE=InnoDB COMMENT='订单明细 200w';

-- 支付流水：90w
CREATE TABLE payments (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  payment_no  VARCHAR(32)     NOT NULL,
  order_id    BIGINT UNSIGNED NOT NULL,
  channel     TINYINT         NOT NULL,
  amount      DECIMAL(12,2)   NOT NULL,
  status      TINYINT         NOT NULL COMMENT '0处理中 1成功 2失败',
  created_at  DATETIME        NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_payment_no (payment_no),
  KEY idx_order_id (order_id),
  KEY idx_created_at (created_at)
) ENGINE=InnoDB COMMENT='支付流水 90w';

-- 库存（热点行，演示行锁/长事务）
CREATE TABLE inventory (
  product_id INT UNSIGNED NOT NULL,
  stock      INT          NOT NULL,
  version    INT          NOT NULL DEFAULT 0,
  updated_at DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (product_id)
) ENGINE=InnoDB COMMENT='库存 5k';

-- 库存流水（演示无索引更新导致锁全表）
CREATE TABLE inventory_log (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  product_id INT UNSIGNED    NOT NULL,
  change_qty INT             NOT NULL,
  biz_no     VARCHAR(32)     NOT NULL,
  created_at DATETIME        NOT NULL,
  PRIMARY KEY (id),
  KEY idx_product (product_id)
) ENGINE=InnoDB;

-- 优惠码（id 稀疏发放，演示 RR 下的间隙锁）
CREATE TABLE promo_code (
  id         INT UNSIGNED NOT NULL,
  code       VARCHAR(32)  NOT NULL,
  batch_no   VARCHAR(16)  NOT NULL,
  status     TINYINT      NOT NULL DEFAULT 0 COMMENT '0未发放 1已发放 2已核销',
  created_at DATETIME     NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_code (code)
) ENGINE=InnoDB COMMENT='优惠码 20 行，id 1000~1190 步长 10';

INSERT INTO promo_code
SELECT 1000 + n*10, CONCAT('PC', LPAD(1000 + n*10, 8, '0')), 'B2025', n % 3, NOW()
FROM (SELECT 0 n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
      UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9
      UNION SELECT 10 UNION SELECT 11 UNION SELECT 12 UNION SELECT 13 UNION SELECT 14
      UNION SELECT 15 UNION SELECT 16 UNION SELECT 17 UNION SELECT 18 UNION SELECT 19) t;

-- 造数辅助表
CREATE TABLE nums10 (n INT NOT NULL PRIMARY KEY) ENGINE=InnoDB;
INSERT INTO nums10 VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

CREATE TABLE nums (n INT NOT NULL PRIMARY KEY) ENGINE=InnoDB;
INSERT INTO nums
SELECT a.n + b.n*10 + c.n*100 + d.n*1000 + e.n*10000 + f.n*100000
FROM nums10 a, nums10 b, nums10 c, nums10 d, nums10 e, nums10 f;
