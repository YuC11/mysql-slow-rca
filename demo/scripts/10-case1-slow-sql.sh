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

# ------------------------------------------------------------------
Q6="SELECT id, order_no, total_amount FROM orders WHERE order_no = 'SO0000001234'"
Q6BAD="SELECT id, order_no, total_amount FROM orders WHERE order_no = 1234"
hr "11. 慢查询 #6：隐式类型转换——varchar 列 = 数字，索引直接失效"
sub "正确写法：字符串常量"
bench "$Q6"
$MYSQL -e "EXPLAIN $Q6\G" 2>/dev/null
sub "错误写法：order_no = 1234（数字），全表扫描 100 万行"
bench "$Q6BAD"
$MYSQL -e "EXPLAIN $Q6BAD\G" 2>/dev/null
sub "SHOW WARNINGS：优化器亲口告诉你为什么放弃索引"
$MYSQL -e "EXPLAIN $Q6BAD; SHOW WARNINGS;" 2>/dev/null | head -6
echo "更隐蔽的是正确性：'SO000001234' 转数字=0，这条查询一行都查不到——不但慢，还悄悄查错了"

# ------------------------------------------------------------------
hr "12. 慢查询 #7：统计信息过期——优化器拿着旧地图走路"
echo "建专用表 demo_stats（STATS_AUTO_RECALC=0，统计信息只在显式 ANALYZE 时更新）"
$ROOT -e "DROP TABLE IF EXISTS shopdb.demo_stats;
  CREATE TABLE shopdb.demo_stats (
    id     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    status TINYINT NOT NULL,
    pad    BIGINT NOT NULL,
    PRIMARY KEY (id),
    KEY idx_status (status)
  ) ENGINE=InnoDB STATS_AUTO_RECALC=0;" 2>/dev/null
echo "阶段一：插 200 行并 ANALYZE，字典统计记下 200 行"
$ROOT -e "INSERT INTO shopdb.demo_stats (status, pad)
  SELECT 0, id FROM shopdb.orders WHERE id <= 200;
  ANALYZE TABLE shopdb.demo_stats;" >/dev/null 2>&1
sub "① 字典统计（mysql.innodb_table_stats）：n_rows=200"
$ROOT -e "SELECT * FROM mysql.innodb_table_stats WHERE table_name='demo_stats';" 2>/dev/null
echo "阶段二：再灌 50 万行，不做 ANALYZE（模拟'大变更后没人更新统计'）"
$ROOT -e "INSERT INTO shopdb.demo_stats (status, pad)
  SELECT 0, id FROM shopdb.orders WHERE id <= 500000;" >/dev/null 2>&1
sub "② 字典统计还停在 200 —— 统计确实过期了"
$ROOT -e "SELECT n_rows AS 过期的n_rows, '实际行数 ↓' AS note FROM mysql.innodb_table_stats WHERE table_name='demo_stats';
  SELECT COUNT(*) AS 实际行数 FROM shopdb.demo_stats;" 2>/dev/null
sub "③ 但 EXPLAIN 的 rows 居然是准的——8.0 连全扫估算都会下潜 B+ 树实时数"
$MYSQL -e "EXPLAIN SELECT * FROM demo_stats\G" 2>/dev/null | grep -E "type:|key:|rows:|Extra:"
sub "④ 那过期的字典统计到底喂给谁？——JOIN 的基数估算"
$ROOT -e "SELECT index_name, stat_name, stat_value AS ndv,
       ROUND((SELECT n_rows FROM mysql.innodb_table_stats
               WHERE table_name='demo_stats' AND database_name='shopdb') / stat_value, 1) AS 平均每值行数
  FROM mysql.innodb_index_stats
  WHERE table_name='demo_stats' AND stat_name LIKE 'n_diff%';" 2>/dev/null
echo "   说明：等值/范围条件有 index dive 实时兜底，所以单表查询大多不会因统计过期翻车；"
echo "   但 JOIN 没有具体值可下探，只能用上面的 n_diff（平均每值多少行）估算内表探测成本——"
echo "   字典统计过期时，JOIN 顺序与 NLJ/Hash 的选择就建立在旧数据上。"
echo "   生产上'大变更之后 JOIN 突然变慢、ANALYZE 一下就好'，根因就在这里。"
echo "阶段三：ANALYZE TABLE 把地图更新回来"
$ROOT -e "ANALYZE TABLE shopdb.demo_stats;" >/dev/null 2>&1
sub "⑤ 字典统计恢复准确"
$ROOT -e "SELECT n_rows FROM mysql.innodb_table_stats WHERE table_name='demo_stats';" 2>/dev/null
$ROOT -e "DROP TABLE shopdb.demo_stats;" 2>/dev/null
