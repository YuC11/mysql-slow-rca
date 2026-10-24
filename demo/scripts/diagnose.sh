#!/usr/bin/env bash
# 自动分流诊断：把手册 §2 的"决策树"脚本化
# 用法：bash demo/scripts/diagnose.sh > demo/logs/diagnose.out 2>&1
#
# 做3件事：
#   1. 采集手册 §2.3 的"五个黄金信号" + 连接分布 / digest Top / 长事务 / 锁等待 / 复制状态
#   2. 每项按手册 §2.3 / §2.6 的阈值给 [PASS]/[WARN]/[FAIL] 判定
#   3. 按决策树自动归类到案例一~五，输出"优先排查建议"（含证据）
# 注意：累计型计数器（命中率、Slow_queries 等）只反映开机以来的均值，判定口径见各行的说明。
set -u
cd "$(dirname "$0")/../.."
source demo/scripts/lib.sh

CORES=$(docker exec mysql-demo sh -c '
  if [ -f /sys/fs/cgroup/cpu.max ]; then
    read q p < /sys/fs/cgroup/cpu.max
  else
    q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us); p=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
  fi
  [ -n "$q" ] && [ "$q" != "max" ] && [ "$p" -gt 0 ] 2>/dev/null && echo $(( (q + p - 1) / p ))' 2>/dev/null)
CORES=${CORES:-2}
[ "$CORES" -lt 1 ] 2>/dev/null && CORES=2

hr "0. 实例信息"
$ROOT -e "SELECT VERSION() AS ver, @@hostname AS host, NOW() AS at_time,
  ROUND(UPTIME/86400,1) AS uptime_days, @@max_connections AS max_conn;" 2>/dev/null
echo "（容器核数：${CORES}，判定阈值随核数联动）"

hr "1. 五个黄金信号（阈值见手册 §2.3 / §2.6）"
read -r TR TC MAXC SLOW LCKC LCKW BPREADS BPREQ TMPDISK UP LT60 LT10 \
  <<< "$($ROOT -N -e "
    SELECT
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Threads_running')+0,
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Threads_connected')+0,
      (SELECT VARIABLE_VALUE FROM performance_schema.global_variables WHERE VARIABLE_NAME='max_connections')+0,
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Slow_queries')+0,
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_row_lock_current_waits')+0,
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_row_lock_waits')+0,
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads')+0,
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_read_requests')+0,
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Created_tmp_disk_tables')+0,
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Uptime')+0,
      (SELECT COUNT(*) FROM information_schema.innodb_trx WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 60),
      (SELECT COUNT(*) FROM information_schema.innodb_trx WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 10);" 2>/dev/null)"
TR=${TR:-0}; TC=${TC:-0}; MAXC=${MAXC:-50}; SLOW=${SLOW:-0}; LCKC=${LCKC:-0}; LCKW=${LCKW:-0}
BPREADS=${BPREADS:-0}; BPREQ=${BPREQ:-1}; TMPDISK=${TMPDISK:-0}; UP=${UP:-1}; LT60=${LT60:-0}; LT10=${LT10:-0}

CONN_PCT=$(awk "BEGIN{printf \"%.0f\", 100*$TC/$MAXC}")
HIT_PCT=$(awk "BEGIN{printf \"%.3f\", 100*(1-$BPREADS/$BPREQ)}")
SLOW_RATE=$(awk "BEGIN{printf \"%.1f\", $SLOW/($UP/60)}")

# —— 判定与命中收集（HITS 为"案例X|证据"数组）——
HITS=()
hit(){ HITS+=("$1|$2"); }

[ "$TR" -gt $((CORES*2)) ] && { echo "[WARN] Threads_running=${TR}（> 核数${CORES}×2=$((CORES*2))，有语句在排队，先查慢SQL/锁）"
                                hit "案例二" "Threads_running=${TR} 高于核数2倍，语句在排队"; } \
                         || echo "[PASS] Threads_running=${TR}（阈值 ≤ 核数${CORES}×2=$((CORES*2))）"

if   [ "$CONN_PCT" -ge 95 ]; then echo "[FAIL] Threads_connected=${TC} / 上限${MAXC}（${CONN_PCT}%，即将打满，应用将收到 1040）"
                                hit "案例三" "连接已用 ${CONN_PCT}%（${TC}/${MAXC}）"
elif [ "$CONN_PCT" -ge 80 ]; then echo "[WARN] Threads_connected=${TC} / 上限${MAXC}（${CONN_PCT}%，超过 80% 预警线）"
                                hit "案例三" "连接已用 ${CONN_PCT}%（${TC}/${MAXC}）"
else                              echo "[PASS] Threads_connected=${TC} / 上限${MAXC}（${CONN_PCT}%）"
fi

echo "[INFO] Slow_queries=${SLOW}（累计，≈${SLOW_RATE} 次/分钟；累计值不能单独判定，以 digest 排行为准）"

if   [ "$LCKC" -gt 0 ]; then echo "[FAIL] 行锁等待中 Innodb_row_lock_current_waits=${LCKC}（有会话正在等锁）"
                             hit "案例二" "Innodb_row_lock_current_waits=$LCKC"
else
  echo "[PASS] 行锁等待中 Innodb_row_lock_current_waits=0（历史累计 Innodb_row_lock_waits=${LCKW}）"
  [ "$LCKW" -gt 0 ] && echo "       （历史发生过锁等待，判断当前是否活跃请看第 5 节）"
fi

if   awk "BEGIN{exit !($HIT_PCT < 97)}"; then echo "[FAIL] buffer pool 命中率 ${HIT_PCT}%（< 97%，内存严重不足或全表扫描泛滥）"
                                             hit "案例四" "buffer pool 命中率 ${HIT_PCT}% < 97%"
elif awk "BEGIN{exit !($HIT_PCT < 99)}"; then echo "[WARN] buffer pool 命中率 ${HIT_PCT}%（< 99%，注意：这是开机以来的累计值，趋势见 baseline diff）"
                                             hit "案例四" "buffer pool 命中率 ${HIT_PCT}% < 99%"
else                                          echo "[PASS] buffer pool 命中率 ${HIT_PCT}%（≥ 99%；累计口径，重启后前期偏低属正常）"
fi

echo "[INFO] Created_tmp_disk_tables=${TMPDISK}（累计；>0 说明发生过排序/聚合落盘，结合 digest 看是哪条 SQL）"

hr "2. 连接都去哪了（按 用户/来源/状态 聚合）"
DIST=$($ROOT -e "
  SELECT user, SUBSTRING_INDEX(host, ':', 1) AS ip, command, state, COUNT(*) AS conns
  FROM information_schema.processlist
  WHERE command <> 'Daemon'
  GROUP BY user, ip, command, state ORDER BY conns DESC;" 2>/dev/null)
echo "$DIST"
SLEEP_N=$(echo "$DIST" | awk -F'\t' '$3=="Sleep"{s+=$5} END{print s+0}')
TOTAL_N=$(echo "$DIST" | awk -F'\t' 'NR>0{t+=$5} END{print t+0}')
if [ "$TOTAL_N" -gt 0 ] && [ "$CONN_PCT" -ge 80 ] \
   && awk "BEGIN{exit !($SLEEP_N >= 0.9*$TOTAL_N)}"; then
  echo "[FAIL] ${SLEEP_N}/${TOTAL_N} 个连接处于 Sleep 且总量已到 ${CONN_PCT}% —— 连接池配置过大 / 连接泄漏，而非线程不足"
  hit "案例三" "${SLEEP_N}/${TOTAL_N} 个连接为 Sleep 且占用 ${CONN_PCT}%"
elif [ "$SLEEP_N" -gt 0 ]; then
  echo "[PASS] 有 ${SLEEP_N} 个 Sleep 连接，未达预警线；持续只增不减再查泄漏"
fi

hr "3. 慢 SQL 排行（digest 按总耗时 Top10，标注无索引/磁盘临时表）"
digest_top 10
NOIDX=$($ROOT -N -e "
  SELECT COUNT(*) FROM performance_schema.events_statements_summary_by_digest
  WHERE SCHEMA_NAME='shopdb'
    AND DIGEST_TEXT NOT LIKE '%information%'
    AND DIGEST_TEXT NOT LIKE '%performance%'
    AND DIGEST_TEXT NOT LIKE '%version_comment%'
    AND (SUM_NO_INDEX_USED > 0 OR SUM_CREATED_TMP_DISK_TABLES > 0);" 2>/dev/null)
NOIDX=${NOIDX:-0}
[ "$NOIDX" -gt 0 ] && { echo "[FAIL] ${NOIDX} 条 SQL 指纹存在无索引访问或磁盘临时表（见上方标注）"
                       hit "案例一" "digest 中 ${NOIDX} 条 SQL 无索引访问/磁盘临时表"; } \
                || echo "[PASS] digest Top10 均无无索引访问、无磁盘临时表"

hr "4. 长事务（>60s 必须处置）"
$ROOT -e "
  SELECT trx_id, trx_state, TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_s,
         trx_rows_locked, trx_rows_modified, LEFT(trx_query, 60) AS cur_sql
  FROM information_schema.innodb_trx ORDER BY trx_started;" 2>/dev/null
[ "$LT60" -gt 0 ] && { echo "[FAIL] ${LT60} 个事务运行超过 60s（放大锁等待、拖住 purge 与 MDL）"
                      hit "案例二" "${LT60} 个事务 age > 60s"; } \
               || { [ "$LT10" -gt 0 ] && echo "[WARN] ${LT10} 个事务运行超过 10s（未到红线，关注是否持续）" \
                                    && hit "案例二" "${LT10} 个事务 age > 10s" \
                                  || echo "[PASS] 无超过 10s 的事务"; }

hr "5. 锁等待关系（sys.innodb_lock_waits）"
LROWS=$($ROOT -N -e "SELECT COUNT(*) FROM sys.innodb_lock_waits;" 2>/dev/null)
LROWS=${LROWS:-0}
if [ "$LROWS" -gt 0 ]; then
  $ROOT -e "SELECT wait_age, waiting_pid, waiting_query, blocking_pid, blocking_query,
         locked_table, locked_index, locked_type FROM sys.innodb_lock_waits\G" 2>/dev/null
  echo "[FAIL] ${LROWS} 组锁等待：持锁者不提交，等待者全部排队"
  hit "案例二" "sys.innodb_lock_waits 有 ${LROWS} 组等待"
else
  echo "[PASS] 当前无锁等待链"
fi

hr "6. 复制状态（优先探测本环境从库 13307，其次本机 REPLICA 配置）"
R13307="mysql --defaults-extra-file=${CONF_DIR}/.my-root.cnf -h127.0.0.1 -P13307"
if $R13307 -N -e "SELECT 1" >/dev/null 2>&1; then
  REPL=$($R13307 -e "SHOW REPLICA STATUS\G" 2>/dev/null)
  [ -n "$REPL" ] && echo "（数据来自从库 mysql-replica:13307）"
else
  REPL=$($ROOT -e "SHOW REPLICA STATUS\G" 2>/dev/null)
fi
if [ -n "$REPL" ]; then
  echo "$REPL" | grep -E "Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_Error:|Relay_Log_Space" | head -6
  IOR=$(echo "$REPL"  | awk -F': ' '/Replica_IO_Running:/{print $2}'   | head -1)
  SQLR=$(echo "$REPL" | awk -F': ' '/Replica_SQL_Running:/{print $2}'  | head -1)
  SBS=$(echo "$REPL"  | awk -F': ' '/Seconds_Behind_Source:/{print $2}'| head -1)
  if [ "$IOR" != "Yes" ] || [ "$SQLR" != "Yes" ]; then
    echo "[FAIL] 复制线程异常（IO=${IOR} SQL=${SQLR}），看 Last_Error"
    hit "案例五" "复制线程 IO=$IOR SQL=$SQLR"
  elif [ "${SBS:-0}" -gt 60 ]; then
    echo "[FAIL] 从库延迟 ${SBS}s（> 60s）"
    hit "案例五" "Seconds_Behind_Source=${SBS}s"
  elif [ "${SBS:-0}" -gt 10 ]; then
    echo "[WARN] 从库延迟 ${SBS}s（> 10s；注意大事务期间该指标存在盲区，见手册 §8.3）"
    hit "案例五" "Seconds_Behind_Source=${SBS}s"
  else
    echo "[PASS] 复制正常，延迟 ${SBS:-0}s"
  fi
else
  echo "（未配置复制，跳过）"
fi

hr "7. 容器资源（对照案例四）"
docker stats --no-stream --format 'CPU={{.CPUPerc}}  内存={{.MemUsage}}' mysql-demo 2>/dev/null \
  || echo "（docker 不可用，跳过；请人工确认 CPU / iowait）"

# ==================================================================
hr "8. 诊断结论（按手册 §2.4 决策树归类）"
if [ "${#HITS[@]}" -eq 0 ]; then
  echo "未命中任何异常信号，数据库侧暂时健康。"
  echo "若业务仍反馈\"慢\"：回到手册 §2.2 做应用侧分段（连接池等待 / 网络 / DB 执行 / 结果集传输），"
  echo "不要在数据库上继续找。"
else
  echo "命中 ${#HITS[@]} 项异常信号，优先排查顺序如下（先看链条源头，再看最显眼的症状）："
  echo
  SEEN=""
  for h in "${HITS[@]}"; do
    CASE="${h%%|*}"; EV="${h#*|}"
    case ",$SEEN," in *",$CASE,"*) note="（同上，多一处的佐证）";; *) note="";; esac
    SEEN="$SEEN,$CASE"
    echo "  → ${CASE}  证据：${EV}${note}"
  done
  echo
  case ",$SEEN," in
    *",案例三,"*",案例一,"*|*",案例一,"*",案例三,"*)
      echo "⚠ 因果链提醒：\"连接打满\"与\"慢 SQL\"同时命中——连接问题多半是慢 SQL 占住工作线程的结果，"
      echo "  先优化 SQL（手册 §4），不要先调 max_connections（只会把问题推迟）。";;
    *",案例三,"*)
      echo "⚠ 连接打满但 digest 未见问题 SQL：先翻慢日志确认是否慢 SQL 占线程（digest 可能已被清理），"
      echo "  再决定是调连接池还是优化 SQL。";;
  esac
  echo
  echo "下一步：跳到对应案例章节复现与定位；处置后用 baseline.sh diff 对比前后指标。"
fi
