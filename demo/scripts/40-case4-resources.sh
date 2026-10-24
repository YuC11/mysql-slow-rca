#!/usr/bin/env bash
# 案例四：服务器资源瓶颈（CPU / 内存 / 磁盘 IO / 网络）
# 用法：bash demo/scripts/40-case4-resources.sh
set -u
cd "$(dirname "$0")/../.."
source demo/scripts/lib.sh

hr "0. 资源基线"
docker stats --no-stream --format '容器 {{.Name}}  CPU={{.CPUPerc}}  内存={{.MemUsage}}' mysql-demo 2>/dev/null
$ROOT -e "SHOW VARIABLES WHERE Variable_name IN
  ('innodb_buffer_pool_size','tmp_table_size','max_heap_table_size','sort_buffer_size','join_buffer_size');" 2>/dev/null

# ==================================================================
hr "1. CPU 瓶颈：计算密集型 SQL 把单核打满"
QCPU="SELECT COUNT(*) FROM orders WHERE MD5(order_no) LIKE '%abc%'"
bench "$QCPU" 1
docker stats --no-stream --format '执行中 CPU={{.CPUPerc}}' mysql-demo 2>/dev/null
sub "EXPLAIN：全表扫描 + 每行一次 MD5"
$MYSQL -e "EXPLAIN $QCPU\G" 2>/dev/null
sub "16 并发把 CPU 堆满（注意：RAND() 在 WHERE 里，实际是全表扫描）"
mysqlslap --defaults-extra-file=demo/scripts/.my-user1.cnf -h127.0.0.1 -P${PORT} --create-schema=shopdb \
  -c 16 -i 2 --number-of-queries=64 \
  --query="SELECT id, order_no FROM orders WHERE id = FLOOR(1 + RAND()*1000000)" >/dev/null 2>&1 &
S=$!; sleep 3
docker stats --no-stream --format '压测中 CPU={{.CPUPerc}} 内存={{.MemUsage}}' mysql-demo 2>/dev/null
$ROOT -e "SHOW STATUS WHERE Variable_name IN ('Threads_running','Threads_connected');" 2>/dev/null
wait $S 2>/dev/null

# ==================================================================
hr "2. 内存瓶颈：buffer pool 只有 128M，热数据放不下"
sub "全表扫一遍前后，物理读的变化"
$ROOT -e "SHOW GLOBAL STATUS WHERE Variable_name IN
  ('Innodb_buffer_pool_read_requests','Innodb_buffer_pool_reads','Innodb_buffer_pool_pages_free','Innodb_buffer_pool_pages_data');" 2>/dev/null
$MYSQL -e "SELECT COUNT(*) FROM payments;" >/dev/null 2>&1
$ROOT -e "SHOW GLOBAL STATUS WHERE Variable_name IN
  ('Innodb_buffer_pool_read_requests','Innodb_buffer_pool_reads','Innodb_buffer_pool_pages_free','Innodb_buffer_pool_pages_data');" 2>/dev/null

sub "命中率（低于 99% 就要警惕）"
$ROOT -e "SELECT
  ROUND(100 * (1 - v_reads.v / v_req.v), 3) AS 命中率_pct,
  v_req.v AS 逻辑读, v_reads.v AS 物理读
 FROM (SELECT VARIABLE_VALUE+0 v FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_read_requests') v_req,
      (SELECT VARIABLE_VALUE+0 v FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads') v_reads;" 2>/dev/null

sub "内存总量分布（sys schema）"
$ROOT -e "SELECT * FROM sys.memory_global_total;" 2>/dev/null
$ROOT -e "SELECT CURRENT_NUMBER_OF_BYTES_USED/1024/1024 AS MB, EVENT_NAME
          FROM performance_schema.memory_summary_global_by_event_name
          ORDER BY CURRENT_NUMBER_OF_BYTES_USED DESC LIMIT 5;" 2>/dev/null

sub "SHOW ENGINE INNODB STATUS → BUFFER POOL AND MEMORY"
$ROOT -e "SHOW ENGINE INNODB STATUS\G" 2>/dev/null | sed -n '/BUFFER POOL AND MEMORY/,/^ROW OPERATIONS/p' | head -16

# ==================================================================
hr "3. 磁盘 IO：全表扫描 + 排序溢出"
sub "host 侧 iostat（观察 tps / MB/s 抬升；macOS 与 Linux 语法不同）"
case "$(uname -s)" in
  Darwin) ( iostat -d -w 1 -c 3 2>/dev/null ) & ;;
  Linux)  ( iostat -dx 1 3 2>/dev/null ) & ;;
  *)
    if command -v iostat >/dev/null 2>&1; then
      ( iostat -d 1 3 2>/dev/null ) &
    else
      echo "（未找到 iostat，跳过 host 侧采样；可看容器内 /proc/diskstats）"
    fi
    ;;
esac
sub "MySQL 侧 IO 计数"
$ROOT -e "SHOW GLOBAL STATUS WHERE Variable_name IN
  ('Innodb_data_read','Innodb_data_reads','Innodb_os_log_written','Innodb_data_writes');" 2>/dev/null
$MYSQL -e "SELECT COUNT(*), SUM(amount) FROM order_items WHERE sku LIKE 'SKU0001%';" >/dev/null 2>&1
$ROOT -e "SHOW GLOBAL STATUS WHERE Variable_name IN
  ('Innodb_data_read','Innodb_data_reads','Innodb_os_log_written','Innodb_data_writes');" 2>/dev/null
wait

# ==================================================================
hr "4. 临时表 / 排序：小 tmp_table_size 把排序挤到磁盘"
$ROOT -e "SHOW VARIABLES WHERE Variable_name IN ('tmp_table_size','max_heap_table_size','internal_tmp_disk_storage_engine');" 2>/dev/null
$ROOT -e "USE shopdb;
  SELECT c.city, COUNT(*) cnt, SUM(o.pay_amount) amt FROM orders o JOIN customers c ON c.id=o.customer_id
  WHERE o.created_at >= '2024-06-01' AND o.created_at < '2024-07-01'
  GROUP BY c.city ORDER BY amt DESC;
  SHOW SESSION STATUS WHERE Variable_name IN
  ('Created_tmp_tables','Created_tmp_disk_tables','Sort_merge_passes','Sort_rows');" 2>/dev/null | tail -5

# ==================================================================
hr "5. 网络：大结果集把带宽打满"
B1=$($ROOT -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Bytes_sent'")
/usr/bin/time -p $MYSQL -e "SELECT * FROM orders LIMIT 300000;" >/dev/null 2>/tmp/case4_time.txt
B2=$($ROOT -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Bytes_sent'")
grep real /tmp/case4_time.txt
echo "本次结果集传输：$(( (B2 - B1) / 1024 / 1024 )) MB"
echo "300000 行 × 约 150 字节 ≈ 45MB，跨公网/跨可用区时 RTT 会放大成大问题"

# ==================================================================
hr "6. buffer pool 预热：重启后为什么前几分钟慢"
echo "注意：本节会 docker restart mysql-demo（重启后 buffer pool 清空、计数器归零）"
QW="SELECT c.city, COUNT(*) cnt, SUM(o.pay_amount) amt FROM orders o JOIN customers c ON c.id=o.customer_id WHERE o.created_at >= '2024-06-01' AND o.created_at < '2024-07-01' GROUP BY c.city ORDER BY amt DESC"
sub "① 重启前（池是热的）：同一条报表 SQL 的基线"
bench "$QW" 1
sub "② 重启实例"
docker restart mysql-demo >/dev/null 2>&1
for i in $(seq 1 60); do
  $ROOT -N -e "SELECT 1" >/dev/null 2>&1 && break
  sleep 2
done
echo "   实例已就绪（Uptime=$($ROOT -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Uptime';" 2>/dev/null)s）"
sub "③ 冷启动后连续执行同一条 SQL：耗时与命中率的爬升曲线"
for i in 1 2 3 4; do
  echo "--- 第 ${i} 遍 ---"
  bench "$QW" 1
  $ROOT -e "SELECT
    ROUND(100*(1-(SELECT VARIABLE_VALUE+0 FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads')
              /(SELECT VARIABLE_VALUE+0 FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_read_requests')+0.0),3) AS 命中率_pct,
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_pages_data') AS pages_in_pool;" 2>/dev/null
done
echo "解读：第 1 遍几乎全是物理读（命中率低、耗时最高），此后热点页被逐批载入，"
echo "耗时与命中率逐步逼近重启前水平——这就是'重启后短时间慢、会自愈'的机制，"
echo "也是云数据库'预热/内存保障'功能的卖点。若长时间不恢复 → 内存确实不够（回到 §7.3）。"
