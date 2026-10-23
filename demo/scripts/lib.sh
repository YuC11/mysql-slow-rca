#!/usr/bin/env bash
# 公共函数库：所有案例脚本 source 本文件
PORT=${PORT:-13306}
# 凭据走 defaults 文件（600 权限），避免命令行明文密码与 Warning 刷屏
CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MYSQL="mysql --defaults-extra-file=${CONF_DIR}/.my-user1.cnf -h127.0.0.1 -P${PORT} shopdb"
ROOT="mysql --defaults-extra-file=${CONF_DIR}/.my-root.cnf -h127.0.0.1 -P${PORT}"
SLOWLOG=demo/logs/slow.log

hr(){ printf '\n\033[1;36m========== %s ==========\033[0m\n' "$1"; }
sub(){ printf '\n\033[1;33m--- %s ---\033[0m\n' "$1"; }

# 服务端口径计时：清空 digest 统计 → 执行 N 次 → 读 performance_schema
# 排除客户端启动开销，比 time/mysqlslap 更接近真实 SQL 耗时
bench(){
  local sql="$1" n="${2:-3}"
  $ROOT -e "TRUNCATE performance_schema.events_statements_summary_by_digest" 2>/dev/null
  for _ in $(seq "$n"); do $MYSQL -e "$sql" >/dev/null 2>&1; done
  $ROOT -N -e "
    SELECT CONCAT('执行 ${n} 次 → 平均 ', ROUND(AVG_TIMER_WAIT/1e12, 4), ' s/次',
                  ' | 扫描行数 ', SUM_ROWS_EXAMINED,
                  ' | 无索引访问 ', SUM_NO_INDEX_USED, ' 次',
                  ' | 磁盘临时表 ', SUM_CREATED_TMP_DISK_TABLES)
    FROM performance_schema.events_statements_summary_by_digest
    WHERE SCHEMA_NAME='shopdb' AND DIGEST_TEXT NOT LIKE 'TRUNCATE%'
    ORDER BY SUM_TIMER_WAIT DESC LIMIT 1;" 2>/dev/null
}

# 重置慢日志：先关闭再清空，避免 mysqld 持有旧 offset 继续追加
reset_slowlog(){
  $ROOT -e "SET GLOBAL slow_query_log=OFF;" 2>/dev/null
  : > "$SLOWLOG"
  $ROOT -e "SET GLOBAL slow_query_log=ON;" 2>/dev/null
}

# 当前 digest 排行榜（Top N 按总耗时）
digest_top(){
  $ROOT -e "
    SELECT LEFT(DIGEST_TEXT, 70) AS sql_digest, COUNT_STAR AS 次数,
           ROUND(SUM_TIMER_WAIT/1e12, 3) AS 总耗时s,
           ROUND(AVG_TIMER_WAIT/1e12, 4) AS 平均s,
           SUM_ROWS_EXAMINED AS 扫描行数, SUM_NO_INDEX_USED AS 无索引,
           SUM_CREATED_TMP_DISK_TABLES AS 磁盘临时表
    FROM performance_schema.events_statements_summary_by_digest
    WHERE SCHEMA_NAME='shopdb'
    ORDER BY SUM_TIMER_WAIT DESC LIMIT ${1:-5}\G" 2>/dev/null
}
