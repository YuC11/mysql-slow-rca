#!/usr/bin/env bash
# 基线快照：支撑手册反复强调的"看趋势，不看瞬时值"
# 用法：
#   bash demo/scripts/baseline.sh save [tag]      # 采集快照，默认 tag=时间戳
#   bash demo/scripts/baseline.sh diff <t1> [t2]  # 对比两个快照；t2 省略时对比当前实时值
#   bash demo/scripts/baseline.sh list            # 列出已存快照
#
# 快照内容：状态计数器 / digest Top10 / 各表容量与碎片 / 关键配置
# diff 输出：计数器绝对增量 + 按 Uptime 差值折算的每分钟速率
set -u
cd "$(dirname "$0")/../.."
source demo/scripts/lib.sh

BASE_DIR=demo/baselines
mkdir -p "$BASE_DIR"

COUNTERS="Threads_connected Threads_running Max_used_connections Slow_queries
Innodb_row_lock_waits Innodb_row_lock_time_avg
Innodb_buffer_pool_reads Innodb_buffer_pool_read_requests
Innodb_data_read Innodb_data_reads Innodb_data_writes
Created_tmp_tables Created_tmp_disk_tables Sort_merge_passes
Bytes_sent Bytes_received Aborted_connects Connection_errors_max_connections
Questions Com_commit Com_rollback"

snapshot_file(){ echo "$BASE_DIR/$1.txt"; }

capture(){  # 输出快照内容到 stdout，参数为 tag
  local tag="$1"
  local epoch uptime
  epoch=$(date +%s)
  uptime=$($ROOT -N -e "SELECT VARIABLE_VALUE+0 FROM performance_schema.global_status WHERE VARIABLE_NAME='Uptime';" 2>/dev/null)
  echo "# TAG ${tag}"
  echo "# EPOCH ${epoch}"
  echo "# TIME $(date -r "${epoch}" '+%Y-%m-%dT%H:%M:%S')"
  echo "# UPTIME ${uptime:-0}"
  echo "# ---- counters ----"
  local name
  for name in $COUNTERS; do
    local v
    v=$($ROOT -N -e "SELECT VARIABLE_VALUE+0 FROM performance_schema.global_status WHERE VARIABLE_NAME='${name}';" 2>/dev/null)
    echo "C ${name} ${v:-0}"
  done
  echo "# ---- tables ----"
  $ROOT -N -e "SELECT CONCAT('T ', table_name, ' ', table_rows, ' ', data_length, ' ', data_free)
    FROM information_schema.tables WHERE table_schema='shopdb' ORDER BY table_name;" 2>/dev/null
  echo "# ---- config ----"
  $ROOT -N -e "SELECT CONCAT('V ', VARIABLE_NAME, ' ', VARIABLE_VALUE)
    FROM performance_schema.global_variables
    WHERE VARIABLE_NAME IN ('innodb_buffer_pool_size','max_connections','long_query_time',
      'tmp_table_size','max_heap_table_size','sort_buffer_size','sync_binlog',
      'innodb_flush_log_at_trx_commit');" 2>/dev/null
  echo "# ---- digest top10 ----"
  $ROOT -N -e "SELECT CONCAT('D ', LEFT(DIGEST_TEXT,60), ' | 次数 ', COUNT_STAR,
      ' | 总耗时s ', ROUND(SUM_TIMER_WAIT/1e12,3), ' | 扫描行 ', SUM_ROWS_EXAMINED)
    FROM performance_schema.events_statements_summary_by_digest
    WHERE SCHEMA_NAME='shopdb'
      AND DIGEST_TEXT NOT LIKE '%information%'
      AND DIGEST_TEXT NOT LIKE '%performance%'
      AND DIGEST_TEXT NOT LIKE '%version_comment%'
    ORDER BY SUM_TIMER_WAIT DESC LIMIT 10;" 2>/dev/null
}

read_meta(){  # file -> key -> value: 从快照头读 epoch/uptime
  awk -v k="$2" '$1=="#" && $2==k {print $3; exit}' "$1"
}

cmd=${1:-}
case "$cmd" in
save)
  tag=${2:-$(date '+%Y%m%d_%H%M%S')}
  f=$(snapshot_file "$tag")
  capture "$tag" > "$f"
  echo ">> 快照已保存：${f}"
  echo "   $(grep -c '^C ' "$f") 个计数器，$(grep -c '^T ' "$f") 张表，uptime=$(read_meta "$f" UPTIME)s"
  ;;
diff)
  if [ $# -lt 2 ]; then echo "用法：baseline.sh diff <t1> [t2]（t2 省略则对比当前实时值）" >&2; exit 1; fi
  f1=$(snapshot_file "$2")
  [ -f "$f1" ] || { echo "快照不存在：${f1}" >&2; exit 1; }
  if [ $# -ge 3 ]; then
    f2=$(snapshot_file "$3"); [ -f "$f2" ] || { echo "快照不存在：${f2}" >&2; exit 1; }
    label1="$2"; label2="$3"
  else
    f2=$(mktemp /tmp/baseline_live.XXXXXX)
    capture "__live__" > "$f2"
    label1="$2"; label2="(当前实时)"
    LIVE_TMP=1
  fi
  up1=$(read_meta "$f1" UPTIME); up2=$(read_meta "$f2" UPTIME)
  mins=$(awk "BEGIN{d=${up2:-0}-${up1:-0}; if (d<=0) print 0; else printf \"%.2f\", d/60}")
  t1=$(read_meta "$f1" TIME); t2=$(read_meta "$f2" TIME)
  hr "快照对比：${label1} → ${label2}"
  echo "时间：${t1} → ${t2}   间隔 ${mins} 分钟（按 Uptime 差值折算）"
  echo
  awk -v mins="$mins" '
    FNR==1 { fn++ }
    fn==1 && $1=="C" { c[$2]=$3 }
    fn==2 && $1=="C" {
      d = $3 - c[$2]
      if (d != 0) {
        line = sprintf("%-40s %15s → %-15s 增量 %+d", $2, c[$2], $3, d)
        if (mins+0 > 0) line = line sprintf("（%.2f/分钟）", d/mins)
        print line
      }
    }
  ' "$f1" "$f2"
  echo
  sub "buffer pool 命中率（区间内）"
  awk '
    FNR==1 { fn++ }
    fn==1 && $1=="C" { c[$2]=$3 }
    fn==2 && $1=="C" { l[$2]=$3 }
    END {
      r1 = c["Innodb_buffer_pool_reads"];     q1 = c["Innodb_buffer_pool_read_requests"]
      r2 = l["Innodb_buffer_pool_reads"];     q2 = l["Innodb_buffer_pool_read_requests"]
      dr = r2-r1; dq = q2-q1
      if (dq > 0) printf "  区间逻辑读 %+d，物理读 %+d，区间命中率 %.3f%%\n", dq, dr, 100*(1-dr/dq)
      else        print   "  区间内无逻辑读，无法计算"
    }
  ' "$f1" "$f2"
  sub "表容量与碎片变化"
  awk '
    FNR==1 { fn++ }
    fn==1 && $1=="T" { rows[$2]=$3; dl[$2]=$4; df[$2]=$5 }
    fn==2 && $1=="T" {
      if (rows[$2]!=$3 || dl[$2]!=$4 || df[$2]!=$5)
        printf "  %-16s 行数 %s → %s，数据 %dMB → %dMB，碎片 %dMB → %dMB\n", \
          $2, rows[$2], $3, dl[$2]/1048576, $4/1048576, df[$2]/1048576, $5/1048576
    }
  ' "$f1" "$f2"
  echo
  sub "digest Top10（后一快照口径）"
  grep '^D ' "$f2" | head -10 | sed 's/^D //'
  [ "${LIVE_TMP:-0}" = "1" ] && rm -f "$f2"
  ;;
list)
  ls -1 "$BASE_DIR"/*.txt 2>/dev/null | sed 's|.*/||; s|\.txt$||' || echo "（无快照）"
  ;;
*)
  echo "用法：baseline.sh save [tag] | diff <t1> [t2] | list" >&2
  exit 1
  ;;
esac
