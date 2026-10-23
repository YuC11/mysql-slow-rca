#!/usr/bin/env bash
# 案例三：连接数 / 应用连接池耗尽
# 用法：bash demo/scripts/30-case3-connections.sh
set -u
cd "$(dirname "$0")/../.."
source demo/scripts/lib.sh

FIFO=/tmp/case3_$$.fifo
PIDFILE=/tmp/case3_pids_$$
rm -f "$PIDFILE"
cleanup(){
  [ -f "$PIDFILE" ] && xargs kill < "$PIDFILE" 2>/dev/null
  pkill -f "mysqlslap .*SELECT c.city" 2>/dev/null
  rm -f "$FIFO" "$PIDFILE" /tmp/case3_conn_*.log
}
trap cleanup EXIT

$ROOT -e "FLUSH STATUS;" 2>/dev/null
hr "1. 容量现状"
$ROOT -e "SHOW VARIABLES WHERE Variable_name IN
  ('max_connections','max_user_connections','wait_timeout','interactive_timeout','thread_cache_size');" 2>/dev/null
$ROOT -e "SHOW STATUS WHERE Variable_name IN
  ('Threads_connected','Threads_running','Max_used_connections','Aborted_connects','Connection_errors_max_connections');" 2>/dev/null
echo "连接池容量测算：3 个 Pod × maxPoolSize 20 = 60 > max_connections 50 → 必然打满"

# ------------------------------------------------------------------
hr "2. 情形 A：Threads_running 打满（慢 SQL 占住工作线程，连接数并未超限）"
Q="SELECT c.city, COUNT(*) cnt, SUM(o.pay_amount) amt FROM orders o JOIN customers c ON c.id=o.customer_id WHERE o.created_at >= '2024-06-01' AND o.created_at < '2024-07-01' GROUP BY c.city ORDER BY amt DESC"
mysqlslap --defaults-extra-file=demo/scripts/.my-user1.cnf -h127.0.0.1 -P${PORT} --create-schema=shopdb \
  -c 20 -i 1 --number-of-queries=240 --query="$Q" >/tmp/case3_slap.log 2>&1 &
sleep 2
sub "压测进行中：并发 20，慢 SQL 平均 0.5s"
$ROOT -e "SHOW STATUS WHERE Variable_name IN ('Threads_connected','Threads_running');" 2>/dev/null
$ROOT -e "SELECT command, state, COUNT(*) c FROM information_schema.processlist
          WHERE command <> 'Daemon' GROUP BY command, state ORDER BY c DESC LIMIT 6;" 2>/dev/null
wait

# ------------------------------------------------------------------
hr "3. 情形 B：连接池把 max_connections 占满（大量 Sleep 连接）"
mkfifo "$FIFO"; exec 9<>"$FIFO"
for i in $(seq 1 60); do
  $MYSQL < "$FIFO" >"/tmp/case3_conn_$i.log" 2>&1 &
  echo $! >> "$PIDFILE"
  disown 2>/dev/null || true
done
sleep 6
sub "应用侧最先拿到的报错"
grep -h "ERROR 1040" /tmp/case3_conn_*.log 2>/dev/null | sort | uniq -c | head -3

sub "① 总量：Threads_connected 已到 51（50 + root 保留连接）"
$ROOT -e "SHOW STATUS WHERE Variable_name IN
  ('Threads_connected','Threads_running','Max_used_connections','Aborted_connects','Connection_errors_max_connections');" 2>/dev/null

sub "② 按 用户 / 来源IP / 状态 聚合"
$ROOT -e "SELECT user, SUBSTRING_INDEX(host, ':', 1) AS ip, command, COUNT(*) AS conns
          FROM information_schema.processlist
          GROUP BY user, ip, command ORDER BY conns DESC;" 2>/dev/null

sub "③ 明细：Sleep 多 = 连接池闲置/泄漏；Query 多且 time 大 = 慢 SQL 占线程"
$ROOT -e "SELECT id, user, SUBSTRING_INDEX(host, ':', 1) ip, db, command, time, state
          FROM information_schema.processlist
          WHERE command <> 'Daemon' ORDER BY time DESC LIMIT 8;" 2>/dev/null

sub "④ performance_schema.threads：连接与 OS 线程一一对应"
$ROOT -e "SELECT TYPE, PROCESSLIST_COMMAND, COUNT(*) c
          FROM performance_schema.threads
          WHERE TYPE='FOREGROUND' GROUP BY TYPE, PROCESSLIST_COMMAND;" 2>/dev/null

sub "⑤ root 仍有 1 个保留连接可登录（max_connections+1），这是最后的救火通道"
$ROOT -e "SELECT 'root 登录成功' AS rescue;" 2>/dev/null

# ------------------------------------------------------------------
hr "4. 处置：先止血，再定位根因"
$ROOT -e "SELECT COUNT(*) AS 可清理的空闲连接 FROM information_schema.processlist
          WHERE command='Sleep' AND user='user1' AND time > 5;" 2>/dev/null
$ROOT -N -e "SELECT CONCAT('KILL ', id, ';') FROM information_schema.processlist
             WHERE command='Sleep' AND user='user1' AND time > 5;" 2>/dev/null > /tmp/case3_kill.sql
$ROOT < /tmp/case3_kill.sql 2>/dev/null
sleep 2
$ROOT -e "SHOW STATUS WHERE Variable_name IN ('Threads_connected','Threads_running');" 2>/dev/null

# ------------------------------------------------------------------
hr "5. 关键参数与容量口径"
$ROOT -e "SHOW VARIABLES WHERE Variable_name IN
  ('max_connections','wait_timeout','interactive_timeout','thread_cache_size','back_log');" 2>/dev/null
cat <<'EOF'

容量公式：
  应用最大连接数 = Pod 数 × maxPoolSize × (1 + 突发冗余)
  DB max_connections ≥ Σ(各应用最大连接数) + 运维/备份/监控预留 20%
  经验：每连接约 0.3~1MB 基础内存；max_connections 不是越大越好，
        决定吞吐的是 Threads_running（并发执行数），而不是 Threads_connected
EOF
