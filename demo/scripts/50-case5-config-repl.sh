#!/usr/bin/env bash
# 案例五：配置、架构与复制问题
# 用法：bash demo/scripts/50-case5-config-repl.sh
set -u
cd "$(dirname "$0")/../.."
source demo/scripts/lib.sh

# ==================================================================
hr "1. 配置体检：先看“默认值陷阱”"
$ROOT -e "SHOW VARIABLES WHERE Variable_name IN
  ('innodb_buffer_pool_size','innodb_buffer_pool_instances','innodb_log_buffer_size',
   'max_connections','table_open_cache','open_files_limit','tmp_table_size',
   'sort_buffer_size','join_buffer_size','sync_binlog',
   'innodb_flush_log_at_trx_commit','innodb_io_capacity','innodb_flush_method');" 2>/dev/null
echo
echo "对照：buffer pool 128M vs 数据量约 620MB → 命中率天然上不去"

# ------------------------------------------------------------------
hr "2. 配置影响实测：双 1 刷盘（sync_binlog=1 + flush_log_at_trx_commit=1）的代价"
$ROOT -e "USE shopdb;
  DROP TABLE IF EXISTS cfg_test;
  CREATE TABLE cfg_test (id INT AUTO_INCREMENT PRIMARY KEY, v INT, c_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3));
  DROP PROCEDURE IF EXISTS p_insert;
  DELIMITER //
  CREATE PROCEDURE p_insert(IN n INT)
  BEGIN
    DECLARE i INT DEFAULT 0;
    WHILE i < n DO
      INSERT INTO cfg_test(v) VALUES (i);
      COMMIT;
      SET i = i + 1;
    END WHILE;
  END//
  DELIMITER ;" 2>/dev/null

run_insert(){
  local n=$1
  $ROOT -N -e "USE shopdb; TRUNCATE cfg_test; SET @t=NOW(6); CALL p_insert($n); SELECT ROUND(TIMESTAMPDIFF(MICROSECOND,@t,NOW(6))/1000,1);" 2>/dev/null
}

echo "① sync_binlog=1, flush_log_at_trx_commit=1（最安全，最慢）"
$ROOT -e "SET GLOBAL sync_binlog=1; SET GLOBAL innodb_flush_log_at_trx_commit=1;" 2>/dev/null
T1=$(run_insert 200); echo "   200 次单行提交耗时：${T1} ms"

echo "② sync_binlog=0, flush_log_at_trx_commit=2（性能优先，宕机可能丢 1s）"
$ROOT -e "SET GLOBAL sync_binlog=0; SET GLOBAL innodb_flush_log_at_trx_commit=2;" 2>/dev/null
T2=$(run_insert 200); echo "   200 次单行提交耗时：${T2} ms"

$ROOT -e "SET GLOBAL sync_binlog=1; SET GLOBAL innodb_flush_log_at_trx_commit=1;" 2>/dev/null
echo "   结论：T1/T2 的倍数就是“每次提交都 fsync”买到的持久性价格"

sub "在线调整 buffer pool（8.0 支持在线扩缩，5.7 需重启）"
$ROOT -e "SET GLOBAL innodb_buffer_pool_size=256*1024*1024; SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" 2>/dev/null
$ROOT -e "SET GLOBAL innodb_buffer_pool_size=128*1024*1024;" 2>/dev/null

sub "SET PERSIST：写进 mysqld-auto.cnf，重启也生效"
$ROOT -e "SET PERSIST max_connections=50; SELECT * FROM performance_schema.persisted_variables;" 2>/dev/null

# ==================================================================
hr "3. 表膨胀/碎片：删了数据为什么没变快"
$ROOT -e "DROP TABLE IF EXISTS shopdb.demo_bloat;
  CREATE TABLE shopdb.demo_bloat (
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    payload    VARCHAR(255) NOT NULL,
    created_at DATETIME NOT NULL,
    PRIMARY KEY (id)
  ) ENGINE=InnoDB;" 2>/dev/null
sub "① 插入 10 万行（每行约 200 字节）"
$ROOT -e "INSERT INTO shopdb.demo_bloat (payload, created_at)
  SELECT REPEAT('x', 200), created_at FROM shopdb.orders WHERE id <= 100000;" >/dev/null 2>&1
$ROOT -e "ANALYZE TABLE shopdb.demo_bloat;" >/dev/null 2>&1
$ROOT -e "SELECT table_rows AS 行数,
       ROUND(data_length/1024/1024,1) AS data_mb,
       ROUND(data_free/1024/1024,1) AS free_mb
  FROM information_schema.tables
  WHERE table_schema='shopdb' AND table_name='demo_bloat';" 2>/dev/null
docker exec mysql-demo sh -c 'ls -lh /var/lib/mysql/shopdb/demo_bloat.ibd' 2>/dev/null

sub "② DELETE 80%：行数掉了，磁盘文件一分不小（页内全是空洞）"
$ROOT -e "DELETE FROM shopdb.demo_bloat WHERE id % 5 <> 0;" >/dev/null 2>&1
$ROOT -e "ANALYZE TABLE shopdb.demo_bloat;" >/dev/null 2>&1
$ROOT -e "SELECT table_rows AS 行数,
       ROUND(data_length/1024/1024,1) AS data_mb,
       ROUND(data_free/1024/1024,1) AS free_mb
  FROM information_schema.tables
  WHERE table_schema='shopdb' AND table_name='demo_bloat';" 2>/dev/null
docker exec mysql-demo sh -c 'ls -lh /var/lib/mysql/shopdb/demo_bloat.ibd' 2>/dev/null
echo "后果：文件不缩小、buffer pool 里装的全是半空的页、全表扫描仍要走过空洞页——"
echo "'DELETE 了一半数据，查询一点没变快'就是这么来的"

sub "③ OPTIMIZE TABLE：重建表，空间真正还给操作系统"
$ROOT -e "OPTIMIZE TABLE shopdb.demo_bloat;" 2>/dev/null
$ROOT -e "SELECT table_rows AS 行数,
       ROUND(data_length/1024/1024,1) AS data_mb,
       ROUND(data_free/1024/1024,1) AS free_mb
  FROM information_schema.tables
  WHERE table_schema='shopdb' AND table_name='demo_bloat';" 2>/dev/null
docker exec mysql-demo sh -c 'ls -lh /var/lib/mysql/shopdb/demo_bloat.ibd' 2>/dev/null
echo "注意：OPTIMIZE = ALTER ... ENGINE=InnoDB，重建期间该表不可写（8.0 支持 INPLACE 但仍锁 DML）；"
echo "线上大表请用 gh-ost / pt-online-schema-change。归档类'删旧数据'场景更优解是分区表 DROP PARTITION。"
$ROOT -e "DROP TABLE shopdb.demo_bloat;" 2>/dev/null

# ==================================================================
hr "4. 复制：从库延迟的产生与定位"
if ! docker ps --format '{{.Names}}' | grep -qx mysql-replica; then
  echo ">> 启动从库容器（13307）"
  docker rm -f mysql-replica >/dev/null 2>&1
  docker run -d --name mysql-replica \
    --memory=1g --memory-swap=1g --cpus=1 \
    -p 13307:3306 \
    -e MYSQL_ROOT_PASSWORD=root123 \
    -v "$PWD/demo/conf/my.cnf:/etc/mysql/conf.d/demo.cnf:ro" \
    mysql:8.0 --server-id=2 --replicate-do-db=repltest >/dev/null
  for i in $(seq 1 60); do
    docker exec mysql-replica mysqladmin ping -uroot -proot123 --silent >/dev/null 2>&1 && break
    sleep 2
  done
fi
R="mysql --defaults-extra-file=demo/scripts/.my-root.cnf -h127.0.0.1 -P13307"
if ! $R -N -e "SELECT 1" >/dev/null 2>&1; then
  echo "!! 从库（13307）未就绪，复制演示终止（请检查 docker 状态后重跑本脚本）"
  exit 1
fi

sub "从库重置为干净状态（清残留库/中继日志/本地 GTID，保证脚本可重复执行）"
# 注意 replicate-do-db 的两个坑：
# 1) 无默认库的 DROP/CREATE DATABASE 语句不会通过复制传到从库 —— 库要手工建
# 2) gtid_purged 对齐位点时，位点之前的所有事务（含建表 DDL）都会被从库跳过
#    —— 表也要手工预建，否则回放第一个 INSERT 就报 1146 Table doesn't exist
$R -e "DROP DATABASE IF EXISTS repltest; CREATE DATABASE repltest;
  USE repltest;
  CREATE TABLE big_order (
    id BIGINT AUTO_INCREMENT PRIMARY KEY, order_no VARCHAR(32), amount DECIMAL(12,2),
    status TINYINT, remark VARCHAR(128), created_at DATETIME, KEY idx_status (status));" 2>/dev/null
$R -e "STOP REPLICA; RESET REPLICA ALL; RESET MASTER;" 2>/dev/null

sub "主库准备复制账号与测试表（DROP+CREATE 保证建表 DDL 一定进 binlog）"
$ROOT -e "
  CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED WITH mysql_native_password BY 'repl123';
  GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';" 2>/dev/null
$ROOT -e "DROP DATABASE IF EXISTS repltest; CREATE DATABASE repltest;
  USE repltest;
  CREATE TABLE big_order (
    id BIGINT AUTO_INCREMENT PRIMARY KEY, order_no VARCHAR(32), amount DECIMAL(12,2),
    status TINYINT, remark VARCHAR(128), created_at DATETIME, KEY idx_status (status));" 2>/dev/null

GTID=$($ROOT -N -e "SELECT @@gtid_executed;" 2>/dev/null)
echo "主库 gtid_executed：$GTID"

sub "从库对齐 GTID 位点并启动复制"
$R -e "STOP REPLICA; RESET REPLICA ALL;" 2>/dev/null
$R -e "SET GLOBAL gtid_purged='$GTID';" 2>/dev/null
$R -e "CHANGE REPLICATION SOURCE TO
        SOURCE_HOST='host.docker.internal', SOURCE_PORT=13306,
        SOURCE_USER='repl', SOURCE_PASSWORD='repl123',
        SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1;" 2>/dev/null
$R -e "START REPLICA;" 2>/dev/null
sleep 3
$R -e "SHOW REPLICA STATUS\G" 2>/dev/null | grep -E "Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_Error:|Executed_Gtid_Set" | head -6

sub "关键盲区：单个大事务回放期间，Seconds_Behind_Source 可能一直是 0"
sub "制造大事务：30 万行一次性提交"
$ROOT -e "USE repltest;
  INSERT INTO big_order (order_no, amount, status, remark, created_at)
  SELECT CONCAT('R', LPAD(n,9,'0')), ROUND(RAND()*1000,2), FLOOR(RAND()*5), REPEAT('x',100), NOW()
  FROM (SELECT a.n + b.n*10 + c.n*100 + d.n*1000 + e.n*10000 + f.n*100000 AS n
        FROM (SELECT 0 n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
              UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
             (SELECT 0 n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
              UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b,
             (SELECT 0 n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
              UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) c,
             (SELECT 0 n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
              UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) d,
             (SELECT 0 n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
              UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) e,
             (SELECT 0 n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
              UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) f
       ) t WHERE n < 300000;" 2>/dev/null
echo "主库提交完成，开始观察从库回放"

sub "Seconds_Behind_Source 变化（每 0.5s 采样）"
for i in $(seq 1 12); do
  V=$($R -N -e "SHOW REPLICA STATUS\G" 2>/dev/null | awk '/Seconds_Behind_Source/{print $2}')
  echo "  t+$(echo "$i*0.5" | bc)s  lag=${V:-0}s"
  sleep 0.5
done

sub "回放完成后核对"
sleep 2
$R -e "SHOW REPLICA STATUS\G" 2>/dev/null | grep -E "Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Relay_Log_Space" | head -5
$R -e "SELECT COUNT(*) AS replica_rows, MIN(id) min_id, MAX(id) max_id FROM repltest.big_order;" 2>/dev/null
$ROOT -e "SELECT COUNT(*) AS master_rows FROM repltest.big_order;" 2>/dev/null

sub "并行回放相关参数（决定大事务能否被拆开）"
$R -e "SHOW VARIABLES WHERE Variable_name IN
  ('replica_parallel_workers','replica_parallel_type','replica_preserve_commit_order',
   'replica_pending_jobs_size_max','slave_parallel_workers');" 2>/dev/null

sub "performance_schema：回放线程粒度"
$R -e "SELECT WORKER_ID, SERVICE_STATE, LAST_ERROR_MESSAGE
       FROM performance_schema.replication_applier_status_by_worker;" 2>/dev/null
