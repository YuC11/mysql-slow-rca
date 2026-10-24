#!/usr/bin/env bash
# 结束清理：回收演示脚本留下的"脏数据"，与 00-up.sh 成对
# 用法：
#   bash demo/scripts/99-down.sh          # 轻量清理：保留容器与业务数据，清演示残留
#   bash demo/scripts/99-down.sh --all    # 彻底清理：删容器/数据卷/日志，回到未初始化状态
#
# 轻量清理覆盖六层残留：
#   会话（user1 空闲连接）→ 对象（演示表/过程/复制库/账号）→ 结构（演示加的索引/列）
#   → 数据（被演示改动的业务行）→ 参数（SET PERSIST / 运行时改动）→ 状态与文件（digest/慢日志//tmp）
set -u
cd "$(dirname "$0")/../.."
source demo/scripts/lib.sh

ALL=0
[ "${1:-}" = "--all" ] && ALL=1

cleanup_files(){
  rm -f /tmp/case2_* /tmp/case3_* /tmp/case4_* 2>/dev/null
}

# ==================================================================
if [ "$ALL" = "1" ]; then
  hr "彻底清理：删除容器、数据卷与全部演示产物"
  docker rm -f mysql-demo mysql-replica >/dev/null 2>&1 || true
  docker volume rm mysql-demo-data >/dev/null 2>&1 || true
  rm -f demo/logs/* 2>/dev/null
  rm -rf demo/baselines 2>/dev/null
  cleanup_files
  echo ">> 已回到未初始化状态。重建环境：bash demo/scripts/00-up.sh"
  exit 0
fi

# ==================================================================
hr "轻量清理：保留容器与业务数据，清除演示残留"

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx mysql-demo; then
  echo ">> mysql-demo 未运行，仅清理文件残留"
  cleanup_files
  exit 0
fi

sub "1. 会话：KILL 全部 user1 连接（case3 空闲连接等残留）"
$ROOT -N -e "SELECT CONCAT('KILL ', id, ';') FROM information_schema.processlist WHERE user='user1';" \
  2>/dev/null > /tmp/99down_kill.txt
[ -s /tmp/99down_kill.txt ] && $ROOT < /tmp/99down_kill.txt 2>/dev/null
N=$(wc -l < /tmp/99down_kill.txt | tr -d ' ')
echo "   已清理 ${N} 个 user1 连接"
rm -f /tmp/99down_kill.txt

sub "2. 对象：演示专用表 / 存储过程 / 复制库 / 复制账号"
$ROOT -e "
  DROP TABLE IF EXISTS shopdb.cfg_test, shopdb.demo_stats, shopdb.demo_bloat, shopdb.purge_demo;
  DROP PROCEDURE IF EXISTS shopdb.p_insert;
  DROP DATABASE IF EXISTS repltest;
  DROP USER IF EXISTS 'repl'@'%';" 2>/dev/null
echo "   已清理 cfg_test / demo_stats / demo_bloat / purge_demo / p_insert / repltest / repl"

sub "3. 结构：case1 加的索引、case2 残留的列"
$ROOT -e "ALTER TABLE shopdb.order_items DROP INDEX idx_sku;" 2>/dev/null \
  || echo "   (idx_sku 不存在，跳过)"
$ROOT -e "ALTER TABLE shopdb.orders DROP INDEX idx_created_cust_amount;" 2>/dev/null \
  || echo "   (idx_created_cust_amount 不存在，跳过)"
if [ "$($ROOT -N -e "SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema='shopdb' AND table_name='orders' AND column_name='tmp_demo_col';" 2>/dev/null)" = "1" ]; then
  $ROOT -e "ALTER TABLE shopdb.orders DROP COLUMN tmp_demo_col;" 2>/dev/null
  echo "   已删除残留列 orders.tmp_demo_col"
else
  echo "   (tmp_demo_col 不存在，跳过)"
fi

sub "4. 数据：恢复被演示改动过的业务行"
$ROOT -e "
  UPDATE inventory i JOIN products p ON i.product_id = p.id SET i.stock = p.stock;
  UPDATE orders SET remark = '客户备注：需要开发票，加急处理' WHERE id = 1;
  UPDATE inventory_log SET change_qty = -1 WHERE biz_no = 'BIZ00000001';
  DELETE FROM promo_code WHERE id = 1005;" 2>/dev/null
echo "   inventory 按对账恢复；orders.id=1 remark、inventory_log.biz_no=BIZ00000001、promo_code 1005 已还原"

sub "5. 参数：RESET PERSIST + 恢复运行时改动"
$ROOT -e "RESET PERSIST;" 2>/dev/null || true
$ROOT -e "
  SET GLOBAL sync_binlog = 1;
  SET GLOBAL innodb_flush_log_at_trx_commit = 1;
  SET GLOBAL innodb_buffer_pool_size = 128*1024*1024;
  SET GLOBAL general_log = OFF;" 2>/dev/null
echo "   已清除 mysqld-auto.cnf 并恢复 sync_binlog/flush_log_at_trx_commit/buffer pool/general_log"

sub "6. 状态：digest / 状态计数器 / 慢日志"
$ROOT -e "TRUNCATE performance_schema.events_statements_summary_by_digest; FLUSH STATUS;" 2>/dev/null
reset_slowlog
echo "   digest 与状态计数器已清零，慢日志已清空"

sub "7. 复制：从库可达则停掉并重置通道"
R13307="mysql --defaults-extra-file=${CONF_DIR}/.my-root.cnf -h127.0.0.1 -P13307"
if $R13307 -N -e "SELECT 1" >/dev/null 2>&1; then
  $R13307 -e "STOP REPLICA; RESET REPLICA ALL;" 2>/dev/null
  echo "   从库通道已停止并重置"
else
  echo "   从库未运行，跳过"
fi

sub "8. 文件：/tmp 演示残留"
cleanup_files
echo "   已清理 /tmp/case2_* /tmp/case3_* /tmp/case4_*（case1~5.out 证据文件保留）"

hr "清理后自检"
$ROOT -e "
SELECT
  CONCAT('演示对象残留: ', (
    (SELECT COUNT(*) FROM information_schema.tables    WHERE table_schema='shopdb' AND table_name IN ('cfg_test','demo_stats','demo_bloat','purge_demo'))
  + (SELECT COUNT(*) FROM information_schema.routines  WHERE routine_schema='shopdb' AND routine_name='p_insert')
  + (SELECT COUNT(*) FROM information_schema.schemata  WHERE schema_name='repltest')
  + (SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='shopdb' AND index_name IN ('idx_sku','idx_created_cust_amount'))
  + (SELECT COUNT(*) FROM information_schema.columns   WHERE table_schema='shopdb' AND column_name='tmp_demo_col'))) AS item,
  CONCAT('user1 连接: ', (SELECT COUNT(*) FROM information_schema.processlist WHERE user='user1')) AS item2,
  CONCAT('持久化参数: ', (SELECT COUNT(*) FROM performance_schema.persisted_variables)) AS item3;" 2>/dev/null
echo ">> 完成"
