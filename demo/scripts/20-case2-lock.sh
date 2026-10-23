#!/usr/bin/env bash
# 案例二：锁竞争与长事务
# 用法：bash demo/scripts/20-case2-lock.sh
set -u
cd "$(dirname "$0")/../.."
source demo/scripts/lib.sh

INNODB_STATUS(){ $ROOT -e "SHOW ENGINE INNODB STATUS\G" 2>/dev/null; }

hr "0. 基线：当前确实没有锁等待"
$ROOT -e "SELECT COUNT(*) AS lock_waits FROM sys.innodb_lock_waits;
          SHOW STATUS LIKE 'Innodb_row_lock%';" 2>/dev/null

# ==================================================================
hr "1. 行锁等待：热点库存行（秒杀扣减）"
echo "会话 A：BEGIN → 扣减 product_id=1 → 不提交，持锁 15s"
$MYSQL -e "BEGIN; UPDATE inventory SET stock=stock-1 WHERE product_id=1; SELECT SLEEP(15); COMMIT;" >/dev/null 2>&1 &
A=$!
sleep 2
echo "会话 B：扣减同一行，被阻塞（innodb_lock_wait_timeout=8）"
$MYSQL -e "SET SESSION innodb_lock_wait_timeout=8; UPDATE inventory SET stock=stock-1 WHERE product_id=1;" >/tmp/case2_b.log 2>&1 &
B=$!
sleep 3

sub "① sys.innodb_lock_waits：谁在等谁"
$ROOT -e "SELECT wait_age, waiting_pid, waiting_query, blocking_pid, blocking_query, locked_table, locked_index, locked_type
          FROM sys.innodb_lock_waits\G" 2>/dev/null

sub "② performance_schema.data_locks：锁的粒度与模式"
$ROOT -e "SELECT ENGINE_TRANSACTION_ID trx, OBJECT_NAME tbl, INDEX_NAME idx,
                 LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
          FROM performance_schema.data_locks\G" 2>/dev/null

sub "③ information_schema.innodb_trx：事务画像"
$ROOT -e "SELECT trx_id, trx_state, trx_started,
                 TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_s,
                 trx_rows_locked, trx_rows_modified, trx_isolation_level,
                 LEFT(trx_query, 60) AS cur_sql
          FROM information_schema.innodb_trx ORDER BY trx_started\G" 2>/dev/null

sub "④ SHOW ENGINE INNODB STATUS → TRANSACTIONS"
INNODB_STATUS | sed -n '/^TRANSACTIONS/,/^FILE I\/O/p' | head -30

wait $A $B 2>/dev/null
echo "会话 B 的结果："; cat /tmp/case2_b.log 2>/dev/null | grep -v Warning

# ==================================================================
hr "2. 无索引更新 → 锁全表（最容易被忽视的锁放大）"
$ROOT -e "SELECT COUNT(*) AS 表行数 FROM shopdb.inventory_log;" 2>/dev/null
echo "会话 A：UPDATE inventory_log ... WHERE biz_no='BIZ00000001'（biz_no 无索引）"
$MYSQL -e "BEGIN; UPDATE inventory_log SET change_qty=0 WHERE biz_no='BIZ00000001'; SELECT SLEEP(12); COMMIT;" >/dev/null 2>&1 &
A=$!
sleep 4
$ROOT -e "SELECT COUNT(*) AS 本次事务持有的锁数量 FROM performance_schema.data_locks;" 2>/dev/null
$ROOT -e "SELECT trx_rows_locked, trx_rows_modified FROM information_schema.innodb_trx\G" 2>/dev/null
wait $A 2>/dev/null

# ==================================================================
hr "3. 长事务：一条不提交的事务拖住 purge 与 DDL"
echo "会话 A：BEGIN → 更新一行 → 挂起 20s（模拟事务里调用外部接口）"
$MYSQL -e "BEGIN; UPDATE orders SET remark='长事务演示' WHERE id=1; SELECT SLEEP(20); COMMIT;" >/dev/null 2>&1 &
A=$!
sleep 2
$ROOT -e "SELECT trx_id, trx_state, TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_s,
                 trx_rows_locked, trx_rows_modified, LEFT(trx_query,40) q
          FROM information_schema.innodb_trx\G" 2>/dev/null
sub "History list length（undo 无法 purge 的直接证据）"
INNODB_STATUS | grep -E "History list length|Trx id counter|Purge done" | head -5

sub "长事务阻塞 DDL（MDL），进而阻塞该表所有请求"
$ROOT -e "ALTER TABLE shopdb.orders ADD COLUMN tmp_demo_col INT;" >/tmp/case2_ddl.log 2>&1 &
D=$!
sleep 3
$MYSQL -e "SELECT id FROM orders WHERE id=1;" >/tmp/case2_q.log 2>&1 &
Q=$!
sleep 2
$ROOT -e "SELECT id, user, db, command, time, state, LEFT(info,50) info
          FROM information_schema.processlist WHERE command <> 'Daemon'\G" 2>/dev/null
wait $A 2>/dev/null; sleep 2
wait $D 2>/dev/null; wait $Q 2>/dev/null
$ROOT -e "ALTER TABLE shopdb.orders DROP COLUMN tmp_demo_col;" 2>/dev/null

# ==================================================================
hr "4. 死锁：两个事务交叉更新"
$MYSQL -e "BEGIN; UPDATE inventory SET stock=stock+1 WHERE product_id=1; SELECT SLEEP(3);
           UPDATE inventory SET stock=stock+1 WHERE product_id=2; COMMIT;" >/tmp/case2_d1.log 2>&1 &
D1=$!
sleep 0.5
$MYSQL -e "BEGIN; UPDATE inventory SET stock=stock+1 WHERE product_id=2; SELECT SLEEP(3);
           UPDATE inventory SET stock=stock+1 WHERE product_id=1; COMMIT;" >/tmp/case2_d2.log 2>&1 &
D2=$!
wait $D1 $D2 2>/dev/null
echo "两个会话的返回："
grep -h -E "ERROR|Deadlock" /tmp/case2_d1.log /tmp/case2_d2.log 2>/dev/null | head -4
sub "SHOW ENGINE INNODB STATUS → LATEST DETECTED DEADLOCK"
INNODB_STATUS | sed -n '/LATEST DETECTED DEADLOCK/,/^TRANSACTIONS/p' | head -45

# ==================================================================
hr "5. 间隙锁：RR 隔离级别下范围条件锁住“不存在的行”"
echo "promo_code 的 id：1000,1010,1020...（稀疏），1005 并不存在"
echo "会话 A：SELECT ... WHERE id BETWEEN 1000 AND 1010 FOR UPDATE; 持锁 12s"
$MYSQL -e "BEGIN; SELECT id FROM promo_code WHERE id BETWEEN 1000 AND 1010 FOR UPDATE; SELECT SLEEP(12); COMMIT;" >/dev/null 2>&1 &
A=$!
sleep 2
sub "锁范围：LOCK_MODE=X 表示 next-key lock（记录锁 + 间隙锁）"
$ROOT -e "SELECT OBJECT_NAME tbl, INDEX_NAME idx, LOCK_MODE, LOCK_STATUS, LOCK_DATA
          FROM performance_schema.data_locks WHERE OBJECT_NAME='promo_code'\G" 2>/dev/null | head -50
echo "会话 B：插入 id=1005（落在间隙 (1000,1010) 里），被阻塞"
$MYSQL -e "SET SESSION innodb_lock_wait_timeout=4;
           INSERT INTO promo_code (id, code, batch_no, status, created_at)
           VALUES (1005, 'PC-GAP-TEST', 'B2025', 0, NOW());" 2>&1 | grep -v Warning | head -3
wait $A 2>/dev/null

# ==================================================================
hr "6. 治理要点与关键参数"
$ROOT -e "SHOW VARIABLES WHERE Variable_name IN
  ('innodb_lock_wait_timeout','innodb_deadlock_detect','transaction_isolation',
   'innodb_print_all_deadlocks','innodb_rollback_on_timeout');" 2>/dev/null
