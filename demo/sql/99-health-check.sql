-- ============================================================
-- 一键巡检：定位"变慢"属于哪一类
-- 用法：mysql -h127.0.0.1 -P13306 -uroot -proot123 < demo/sql/99-health-check.sql
-- ============================================================

SELECT '===== 1. 五个黄金信号 =====' AS '';

SELECT '连接' AS 指标,
       CONCAT('Threads_running=', (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Threads_running'),
              ' / Threads_connected=', (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Threads_connected'),
              ' / 上限=', (SELECT VARIABLE_VALUE FROM performance_schema.global_variables WHERE VARIABLE_NAME='max_connections')) AS 值
UNION ALL
SELECT '慢查询', CONCAT('Slow_queries=', (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Slow_queries'))
UNION ALL
SELECT '锁等待', CONCAT('Innodb_row_lock_waits=', (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_row_lock_waits'),
                       ' / current=', (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_row_lock_current_waits'))
UNION ALL
SELECT '命中率', CONCAT(ROUND(100*(1-r.v/q.v),3), '%')
FROM (SELECT VARIABLE_VALUE+0 v FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads') r,
     (SELECT VARIABLE_VALUE+0 v FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_read_requests') q
UNION ALL
SELECT '临时表', CONCAT('Created_tmp_disk_tables=', (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Created_tmp_disk_tables'));

SELECT '===== 2. 连接都去哪了 =====' AS '';

SELECT user, SUBSTRING_INDEX(host, ':', 1) AS ip, command, state, COUNT(*) AS conns
FROM information_schema.processlist
WHERE command <> 'Daemon'
GROUP BY user, ip, command, state
ORDER BY conns DESC;

SELECT '===== 3. 谁跑得最久 / 谁在等 =====' AS '';

SELECT id, user, SUBSTRING_INDEX(host, ':', 1) AS ip, db, command, time, state, LEFT(info, 60) AS sql_head
FROM information_schema.processlist
WHERE command <> 'Daemon'
ORDER BY time DESC
LIMIT 10;

SELECT '===== 4. 长事务（>10s 就值得看一眼） =====' AS '';

SELECT trx_id, trx_state, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_s,
       trx_rows_locked, trx_rows_modified, trx_isolation_level,
       LEFT(trx_query, 60) AS cur_sql
FROM information_schema.innodb_trx
ORDER BY trx_started;

SELECT '===== 5. 锁等待关系 =====' AS '';

SELECT wait_age, waiting_pid, waiting_query,
       blocking_pid, blocking_query,
       locked_table, locked_index, locked_type
FROM sys.innodb_lock_waits\G

SELECT '===== 6. 慢 SQL Top10（按总耗时） =====' AS '';

SELECT LEFT(DIGEST_TEXT, 80) AS sql_digest,
       COUNT_STAR AS 次数,
       ROUND(SUM_TIMER_WAIT/1e12, 3) AS 总耗时s,
       ROUND(AVG_TIMER_WAIT/1e12, 4) AS 平均s,
       SUM_ROWS_EXAMINED AS 扫描行数,
       SUM_NO_INDEX_USED AS 无索引次数,
       SUM_CREATED_TMP_DISK_TABLES AS 磁盘临时表
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME IS NOT NULL
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;

SELECT '===== 7. 复制状态 =====' AS '';

SHOW REPLICA STATUS\G

SELECT '===== 8. 关键配置 =====' AS '';

SELECT VARIABLE_NAME, VARIABLE_VALUE
FROM performance_schema.global_variables
WHERE VARIABLE_NAME IN (
  'innodb_buffer_pool_size', 'max_connections', 'innodb_flush_log_at_trx_commit',
  'sync_binlog', 'tmp_table_size', 'sort_buffer_size', 'long_query_time',
  'innodb_lock_wait_timeout', 'transaction_isolation', 'innodb_io_capacity'
);
