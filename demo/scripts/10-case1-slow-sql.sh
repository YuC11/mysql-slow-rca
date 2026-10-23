#!/usr/bin/env bash
# 案例一：慢查询 / SQL 效率低
# 用法：bash demo/scripts/10-case1-slow-sql.sh
set -u
cd "$(dirname "$0")/../.."
source demo/scripts/lib.sh

reset_slowlog

hr "0. 清理上一次演示加的索引（保证可重复）"
$MYSQL -e "ALTER TABLE order_items DROP INDEX idx_sku;" 2>/dev/null || echo "(idx_sku 不存在)"
$MYSQL -e "ALTER TABLE orders DROP INDEX idx_created_cust_amount;" 2>/dev/null || echo "(idx_created_cust_amount 不存在)"

# ------------------------------------------------------------------
Q1="SELECT id, order_no, customer_id, total_amount, created_at FROM orders ORDER BY created_at DESC LIMIT 900000, 20"
hr "1. 慢查询 #1：深分页 LIMIT 900000,20"
bench "$Q1"
sub "EXPLAIN"
$MYSQL -e "EXPLAIN $Q1\G" 2>/dev/null
sub "EXPLAIN ANALYZE"
$MYSQL -e "EXPLAIN ANALYZE $Q1\G" 2>/dev/null

# ------------------------------------------------------------------
Q2="SELECT COUNT(*) AS cnt, SUM(amount) AS amt FROM order_items WHERE sku='SKU001234'"
hr "2. 慢查询 #2：order_items.sku 无索引"
bench "$Q2"
sub "EXPLAIN"
$MYSQL -e "EXPLAIN $Q2\G" 2>/dev/null
sub "Handler 统计（全表扫描的铁证）"
$ROOT -e "FLUSH STATUS; USE shopdb; $Q2; SHOW SESSION STATUS LIKE 'Handler_read%';" 2>/dev/null

# ------------------------------------------------------------------
Q3="SELECT COUNT(*) FROM orders WHERE DATE(created_at)='2024-06-01'"
hr "3. 慢查询 #3：索引列上套函数 DATE(created_at)"
bench "$Q3"
sub "EXPLAIN"
$MYSQL -e "EXPLAIN $Q3\G" 2>/dev/null

# ------------------------------------------------------------------
Q4="SELECT id, order_no, total_amount FROM orders WHERE order_no LIKE '%0000012345'"
hr "4. 慢查询 #4：左模糊 LIKE '%...'"
bench "$Q4"
sub "EXPLAIN"
$MYSQL -e "EXPLAIN $Q4\G" 2>/dev/null

# ------------------------------------------------------------------
Q5="SELECT c.city, COUNT(*) cnt, ROUND(SUM(o.pay_amount),2) amt
    FROM orders o JOIN customers c ON c.id=o.customer_id
    WHERE o.created_at >= '2024-06-01' AND o.created_at < '2024-07-01'
    GROUP BY c.city ORDER BY amt DESC"
hr "5. 慢查询 #5：运营报表（JOIN + GROUP BY + 排序）"
bench "$Q5"
sub "EXPLAIN"
$MYSQL -e "EXPLAIN $Q5\G" 2>/dev/null
sub "EXPLAIN ANALYZE"
$MYSQL -e "EXPLAIN ANALYZE $Q5\G" 2>/dev/null

# ------------------------------------------------------------------
hr "6. 慢日志分析（log_slow_extra=ON）"
sub "原始慢日志（节选最新 2 段）"
tail -n 34 "$SLOWLOG"
sub "mysqldumpslow -s t（按总耗时排序）"
mysqldumpslow -s t -t 5 "$SLOWLOG" 2>/dev/null | head -18
sub "performance_schema digest 排行榜"
digest_top 5

# ------------------------------------------------------------------
hr "7. 优化一：深分页改游标分页（Keyset Pagination）"
Q1FIX="SELECT id, order_no, customer_id, total_amount, created_at FROM orders
       WHERE created_at < '2024-02-23 23:42:41' ORDER BY created_at DESC LIMIT 20"
bench "$Q1FIX"
$MYSQL -e "EXPLAIN ANALYZE $Q1FIX\G" 2>/dev/null

hr "8. 优化二：order_items.sku 加索引"
$MYSQL -e "ALTER TABLE order_items ADD INDEX idx_sku (sku), ALGORITHM=INPLACE, LOCK=NONE;" 2>/dev/null
bench "$Q2"
$MYSQL -e "EXPLAIN $Q2\G" 2>/dev/null

hr "9. 优化三：函数改写为范围查询"
Q3FIX="SELECT COUNT(*) FROM orders WHERE created_at >= '2024-06-01' AND created_at < '2024-06-02'"
bench "$Q3FIX"
$MYSQL -e "EXPLAIN $Q3FIX\G" 2>/dev/null

hr "10. 优化四：报表加覆盖索引 (created_at, customer_id, pay_amount)"
$MYSQL -e "ALTER TABLE orders ADD INDEX idx_created_cust_amount (created_at, customer_id, pay_amount), ALGORITHM=INPLACE, LOCK=NONE;" 2>/dev/null
bench "$Q5"
$MYSQL -e "EXPLAIN $Q5\G" 2>/dev/null
