# MySQL 变慢的五类根因：判断、定位与可复现演示

> 适用版本：MySQL 8.0（本文实测 8.0.46）
> 演示环境：Docker，2核1G 限流，`user1 / passwd1`，库 `shopdb`
> 文中所有命令与输出均为本机实跑结果，可直接复现

---

## 目录

- [0. 这份文档解决什么问题](#0-这份文档解决什么问题)
- [1. 演示环境](#1-演示环境)
- [2. 先判断：是不是 MySQL 的锅](#2-先判断是不是-mysql-的锅)
- [3. 通用底座：配置、日志、EXPLAIN](#3-通用底座配置日志explain)
- [4. 案例一：慢查询 / SQL 效率低](#4-案例一慢查询--sql-效率低)
- [5. 案例二：锁竞争与长事务](#5-案例二锁竞争与长事务)
- [6. 案例三：连接数 / 连接池耗尽](#6-案例三连接数--连接池耗尽)
- [7. 案例四：服务器资源瓶颈](#7-案例四服务器资源瓶颈)
- [8. 案例五：配置、架构与复制](#8-案例五配置架构与复制)
- [9. 附录](#9-附录)

---

## 0. 这份文档解决什么问题

线上反馈"MySQL 变慢了"，最常见的困境不是不会敲命令，而是：

1. **不知道先看什么**——一头扎进 `SHOW PROCESSLIST`，看到的全是 `Sleep`；
2. **看到了指标但不会归因**——CPU 高就加 CPU，连接多就调 `max_connections`，治标不治本；
3. **分类混乱**——把"慢 SQL 导致连接堆积"当成"连接数问题"来修。

本文把"变慢"拆成五类根因，先给**判断方法**（怎么在 5 分钟内确定是哪一类），再给**逐案例的复现、定位、修复、验证**。每一类都配了真实的执行计划和日志输出。

| 你的现象 | 大概率类别 | 跳到 |
|---|---|---|
| 个别接口慢，慢日志里全是全表扫描 | 慢查询 / SQL 效率 | **§4 案例一** |
| RT 抖动，`Threads_running` 高但都在等锁，库存/账户类更新卡住 | 锁竞争 / 长事务 | **§5 案例二** |
| 应用报 `1040 Too many connections`、连接池获取超时 | 连接数 / 连接池 | **§6 案例三** |
| 所有 SQL 一起变慢，CPU 打满或 iowait 高 | 资源瓶颈 | **§7 案例四** |
| 只有写慢 / 只有从库慢 / 重启后更慢 | 配置、架构、复制 | **§8 案例五** |

---

## 1. 演示环境

### 1.1 一键拉起

```bash
cd mysql-monitor
bash demo/scripts/00-up.sh          # 启动容器 + 建表 + 造数（约 1 分钟）
RESET=1 bash demo/scripts/00-up.sh  # 想重来时
```

容器参数刻意做成"最小规格云数据库"的样子：

```
--memory=1g --cpus=2         # 2核1G，很多生产事故就发生在这个规格上
innodb_buffer_pool_size=128M # 8.0 默认值，只有数据量的 1/5
max_connections=50           # 故意调小，方便演示打满
tmp_table_size=2M            # 故意调小，方便演示磁盘临时表
long_query_time=0.2          # 演示用阈值，生产常见 0.1~1
slow_query_log=ON, log_slow_extra=ON
gtid_mode=ON, binlog_format=ROW
```

### 1.2 企业级示例库

不是 `t1/t2` 玩具表，而是电商交易的真实结构（`demo/sql/01-schema.sql`）：

| 表 | 行数 | 说明 | 故意留的"坑" |
|---|---|---|---|
| `orders` 订单 | 100 万 | 状态、金额、渠道、创建时间 | `remark`、`total_amount` 无索引 |
| `order_items` 明细 | 200 万 | 每单 2 行 | `sku` 无索引 |
| `payments` 支付流水 | 90 万 | 渠道、状态 | — |
| `customers` 客户 | 5 万 | 手机号、城市 | `phone` 无索引 |
| `inventory` 库存 | 5000 | 热点行扣减 | 演示行锁 |
| `inventory_log` 库存流水 | 10 万 | `biz_no` 无索引 | 演示"锁全表" |
| `promo_code` 优惠码 | 20 | id 稀疏（1000,1010…） | 演示间隙锁 |

### 1.3 账号分工（也是生产里的正确姿势）

```bash
# 业务账号：只跑业务 SQL，没有诊断权限
mysql -h127.0.0.1 -P13306 -uuser1 -ppasswd1 shopdb

# DBA 账号：看 performance_schema、KILL 会话、改参数
mysql -h127.0.0.1 -P13306 -uroot -proot123
```

> 这一点很重要：**应用账号不应该有 `PROCESS` / `SUPER` 权限**。本文所有诊断命令都用 root 执行，业务 SQL 用 `user1` 执行，模拟真实权限边界。

---

## 2. 先判断：是不是 MySQL 的锅

### 2.1 这五类分得合理吗

先给结论：**分类基本合理，但它是"并列清单"，不是"排查路径"**。直接按清单一条条试，效率很低。三个补充：

**① 少了第 0 类：不是 MySQL 的问题。**
线上"数据库慢"的投诉里，有相当比例最终定位在应用侧（GC、线程池满、下游 RPC 超时）、网络侧（跨可用区 RTT、丢包、DNS）或中间件（连接池、代理）。不先排除这一类，后面五类全是白忙。

**② 五类之间有因果链，不是互斥的。**
典型链条：`缺索引的慢 SQL → 占住工作线程 → 连接池排队 → 连接打满 → 应用雪崩`。此时你看到的是"连接数问题"，根因却是"慢 SQL"。**判断的任务是找到链条的源头，不是找到最显眼的症状。**

**③ 每一类内部还要再分"突发"和"渐变"。**
突发（发布后开始、大促开始）优先查变更：新 SQL、新索引缺失、参数改动、流量突增。
渐变（每周慢一点）优先查增长：数据量、索引失效、表膨胀、复制延迟累积。

所以正确的顺序是：

```
是不是 MySQL 的锅 → 是哪一类（看信号）→ 这一类里的哪个具体对象（SQL/锁/连接/资源/配置）
```

### 2.2 第一次分流：三分钟排除"不是数据库"

在应用侧埋点，把一次请求拆成四段：

```
总耗时 = 连接池等待 + 网络往返 + DB 执行 + 结果集传输/反序列化
```

| 分段 | 怎么测 | 异常特征 |
|---|---|---|
| 连接池等待 | HikariCP `connectionTimeout`、`poolWaitTime` 指标 | 等待 > 10ms 且 DB 执行很快 → 连接池/连接数问题 |
| 网络往返 | 客户端 `tcpdump`、`ping`、`tcpping` | RTT 从 0.3ms 涨到 3ms → 网络/跨可用区 |
| DB 执行 | 慢日志 `Query_time`、`performance_schema` | 只有这段高 → 真的是 DB |
| 结果集传输 | `Bytes_sent`、客户端反序列化耗时 | 大结果集、`SELECT *`、N+1 查询 |

经验值：**DB 执行时间占比 < 30% 时，不要动数据库。**

### 2.3 第二次分流：五个黄金信号

进到数据库后，先看五个数（一条 SQL 就能拿全，见 2.5）：

| 信号 | 命令/来源 | 正常 | 异常含义 |
|---|---|---|---|
| `Threads_running` | `SHOW STATUS` | 个位数~CPU 核数×2 | 持续高于核数 → 有语句在排队执行，先查慢 SQL/锁 |
| `Threads_connected` | `SHOW STATUS` | 稳定，有回落 | 只涨不落 → 连接泄漏/池过大/慢 SQL 占住 |
| 慢查询数 | 慢日志、digest 表 | 平稳 | 突增 → SQL 效率或数据量变化 |
| `Innodb_row_lock_waits` | `SHOW STATUS` | 接近 0 | 增长 → 锁竞争 |
| buffer pool 命中率 | `Innodb_buffer_pool_reads/read_requests` | > 99.9% | < 99% → 内存不足或全表扫描 |

再加两个资源信号：容器/主机的 CPU 使用率、磁盘 `iowait`（或 `Innodb_data_reads` 增速）。

### 2.4 决策树：从症状到类别

```
应用报错/超时
├─ 报 1040 Too many connections / 连接池获取超时
│   └─► 案例三（但必须回头查：是不是慢 SQL 占着连接）
├─ 报 1205 Lock wait timeout / 1213 Deadlock
│   └─► 案例二
├─ 只是慢，不报错
│   ├─ SHOW PROCESSLIST：大量 Sleep
│   │   └─► 连接池配置/泄漏（案例三）+ 检查 wait_timeout
│   ├─ SHOW PROCESSLIST：大量 Query，且 Time 很大
│   │   ├─ 慢日志/digest 里 SQL 本身差（全表扫描、filesort、临时表）
│   │   │   └─► 案例一
│   │   ├─ 都在等锁（state = Waiting for ... lock）
│   │   │   └─► 案例二
│   │   └─ SQL 都不差，但 CPU/IO 饱和
│   │       └─► 案例四
│   └─ 只有写慢 / 只有从库慢 / 重启后短时间慢
│       └─► 案例五
└─ 数据库指标都正常，但应用说慢
    └─► 不是 MySQL 的锅（回到 2.2）
```

### 2.5 一键体检 SQL

`demo/sql/99-health-check.sql`，核心是下面这一段（root 执行）：

```sql
SELECT '连接' AS 指标, CONCAT('Threads_running=', v1.v, ' / Threads_connected=', v2.v) AS 值
FROM (SELECT VARIABLE_VALUE v FROM performance_schema.global_status WHERE VARIABLE_NAME='Threads_running') v1,
     (SELECT VARIABLE_VALUE v FROM performance_schema.global_status WHERE VARIABLE_NAME='Threads_connected') v2
UNION ALL
SELECT '慢查询', CONCAT('Slow_queries=', v) FROM performance_schema.global_status WHERE VARIABLE_NAME='Slow_queries'
UNION ALL
SELECT '锁等待', CONCAT('Innodb_row_lock_waits=', v) FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_row_lock_waits'
UNION ALL
SELECT '命中率', CONCAT(ROUND(100*(1-r.v/q.v),3), '%')
FROM (SELECT VARIABLE_VALUE+0 v FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads') r,
     (SELECT VARIABLE_VALUE+0 v FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_read_requests') q;
```

实跑输出（新版含 `判定` 列，阈值来自 §2.3/§2.6）：

```
指标               值                                            判定
连接数             Threads_running=2 / Threads_connected=1 / 上限=50   PASS
慢查询             Slow_queries=5                                INFO 累计值，以digest排行为准
行锁等待           Innodb_row_lock_waits=0 / current=0           PASS（历史累计见值）
buffer pool 命中率  99.928%                                       PASS 累计口径
磁盘临时表          Created_tmp_disk_tables=4                     WARN 发生过落盘，看digest定位SQL
```

把这套判定再往前推一步，就是两个配套脚本：

```bash
# 自动分流诊断：采集五个黄金信号+连接分布+digest+长事务+锁等待+复制状态，
# 逐项 PASS/WARN/FAIL，末尾按 §2.4 决策树自动归类"优先排查案例X（证据：…）"
bash demo/scripts/diagnose.sh > demo/logs/diagnose.out 2>&1

# 基线快照：支撑"看趋势，不看瞬时值"——save 存快照，diff 出区间增量与每分钟速率
bash demo/scripts/baseline.sh save before
# ... 处置之后 ...
bash demo/scripts/baseline.sh diff before
```

diagnose.sh 的结论区长这样（锁竞争演示进行中实跑）：

```
命中 4 项异常信号，优先排查顺序如下（先看链条源头，再看最显眼的症状）：
  → 案例二  证据：Innodb_row_lock_current_waits=1
  → 案例四  证据：buffer pool 命中率 98.331% < 99%
  → 案例一  证据：digest 中 1 条 SQL 无索引访问/磁盘临时表
  → 案例二  证据：sys.innodb_lock_waits 有 1 组等待（同上，多一处的佐证）
```

再配一条"谁在跑"的按维度聚合（比 `SHOW PROCESSLIST` 好用得多）：

```sql
SELECT user, SUBSTRING_INDEX(host, ':', 1) AS ip, command, state, COUNT(*) AS conns
FROM information_schema.processlist
WHERE command <> 'Daemon'
GROUP BY user, ip, command, state
ORDER BY conns DESC;
```

案例三的实跑结果，一眼就能看出是"50 个空闲连接"：

```
user    ip               command  conns
user1   192.168.215.1    Sleep    50
root    192.168.215.1    Query    1
```

### 2.6 什么算"合理"，什么算"异常"

避免误判，先约定基线：

| 现象 | 合理 | 异常 |
|---|---|---|
| 备份/大促/批量导入期间 IO、CPU 升高 | ✅ 有明确任务窗口 | ❌ 无任务也高 |
| 重启后 buffer pool 预热，前几分钟慢 | ✅ 会自愈 | ❌ 一直不恢复 → 内存不足 |
| 主从延迟在批量写入时涨到几十秒 | ✅ 任务结束即回落 | ❌ 持续不降 → 大事务/无主键/单线程 |
| `Threads_connected` 高但 `Threads_running` 低 | ✅ 连接池空闲 | ❌ Sleep 只增不减 → 泄漏 |
| 单条 SQL 偶发 0.5s（冷数据） | ✅ 首次访问 | ❌ 同一条反复 0.5s → 索引/统计信息问题 |

判断口诀：**看趋势（是否与业务曲线同步）、看复现（同样的 SQL 能否稳定复现）、看影响（是否影响 SLO）**。

---

## 3. 通用底座：配置、日志、EXPLAIN

后面五个案例反复用到这三样东西，先集中讲清楚。

### 3.1 配置：先分清"能不能在线改"

```sql
-- 查一个参数
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
SELECT * FROM performance_schema.variables_info WHERE VARIABLE_NAME='max_connections'\G
```

`variables_info` 会告诉你这个值的来源（`COMPILED` 默认 / `GLOBAL` 配置文件 / `PERSISTED` / `DYNAMIC`），比 `SHOW VARIABLES` 信息量大：

```
VARIABLE_NAME: max_connections
VARIABLE_SOURCE: COMPILED
VARIABLE_PATH:
SET_TIME: 2026-10-20 ...
SET_USER: NULL
```

修改方式与生效范围：

| 方式 | 命令 | 生效范围 | 重启后 |
|---|---|---|---|
| 会话级 | `SET SESSION x=y` | 当前连接 | 丢失 |
| 全局级 | `SET GLOBAL x=y` | 新连接 | 丢失 |
| 持久化 | `SET PERSIST x=y` | 新连接 | **保留**（写 `mysqld-auto.cnf`） |
| 配置文件 | `my.cnf` + 重启 | 全部 | 保留 |

实测（案例五）：

```sql
SET PERSIST max_connections=50;
SELECT * FROM performance_schema.persisted_variables;
```

```
VARIABLE_NAME       VARIABLE_VALUE
max_connections     50
```

**动态 vs 静态**（改错会启动失败，务必先用 `SELECT @@x` 验证）：

| 动态可改（无需重启） | 静态（需重启） |
|---|---|
| `max_connections`、`long_query_time`、`slow_query_log`、`tmp_table_size`、`sort_buffer_size`、`innodb_buffer_pool_size`（8.0 支持在线扩缩）、`innodb_io_capacity`、`innodb_flush_log_at_trx_commit`、`sync_binlog` | `innodb_page_size`、`innodb_log_file_size`（8.0.30 前）、`character_set_server`、`server_id`、`gtid_mode`（需按步骤切换）、`lower_case_table_names` |

关键参数速查（默认值以 8.0 为准，生产建议按规格调整）：

| 参数 | 8.0 默认 | 作用 | 调优口径 |
|---|---|---|---|
| `innodb_buffer_pool_size` | 128M | 缓存数据页/索引页 | 独占实例给物理内存 50%~70%；本文 128M 对应 620MB 数据，命中率仅 98.4% |
| `max_connections` | 151 | 最大连接数 | `Σ(应用池大小) + 20%` 预留；不是越大越好 |
| `innodb_flush_log_at_trx_commit` | 1 | 每次提交刷 redo | 1 最安全；2 性能优先，宕机丢 1s |
| `sync_binlog` | 1 | 每次提交刷 binlog | 1 最安全；0/N 性能优先 |
| `tmp_table_size` / `max_heap_table_size` | 16M | 内存临时表上限 | 两者要一起调；太小会落盘 |
| `sort_buffer_size` | 256K | 每连接排序缓冲 | 按连接数 × 大小算内存，不要盲目调大 |
| `join_buffer_size` | 256K | 无索引 JOIN 缓冲 | 同上 |
| `table_open_cache` | 4000 | 表描述符缓存 | 表多、并发高时调大；看 `Opened_tables` 增速 |
| `innodb_io_capacity` | 200 | 后台刷脏能力 | SSD 可设 2000~8000 |
| `innodb_redo_log_capacity` | 100M | redo 容量（8.0.30+） | 写多时 1~4G，避免 checkpoint 抖动 |

> 配置类问题的典型特征：**重启后变快，跑一段时间又慢**（buffer pool 冷/热）、**所有 SQL 一起慢**（不是单条 SQL 的问题）、**换机器就好**（规格不够）。

### 3.2 日志：五种日志各有各的用途

#### 3.2.1 错误日志（error log）

位置：`SHOW VARIABLES LIKE 'log_error'`。最容易被忽略，但 OOM、崩溃、复制中断、磁盘满都只在这里。

```bash
docker logs mysql-demo 2>&1 | tail -50
```

本文环境里真实出现过的一条（512M 限流时容器被 OOM Kill）：

```
2026-10-20T09:23:48 [Warning] [MY-014084] [InnoDB] Threads are unable to reserve space
in redo log which can't be reclaimed due to the 'log_checkpointer' consumer still lagging behind
```

以及复制中断时的典型报错（案例五真实踩到）：

```
Worker 1 failed executing transaction '...:462' ... Error executing row event:
'Unknown database 'repltest''
```

#### 3.2.2 慢查询日志（slow log）

配置：

```ini
slow_query_log = ON
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 0.2
log_slow_extra = ON            # 8.0.14+，输出 Read_*/Sort_*/Created_tmp_* 等细节
log_queries_not_using_indexes = OFF   # 开了会刷屏，除非在排查期
log_slow_admin_statements = ON
```

一条完整的慢日志（本文实跑）：

```
# Time: 2026-10-20T09:29:18.312910Z
# User@Host: user1[user1] @  [192.168.215.1]  Id: 41
# Query_time: 0.898886  Lock_time: 0.000005  Rows_sent: 10  Rows_examined: 111122
  Thread_id: 41  Errno: 0  Killed: 0  Bytes_received: 232  Bytes_sent: 394
  Read_first: 1  Read_last: 0  Read_key: 111115  Read_next: 55556  Read_prev: 0
  Read_rnd: 0  Read_rnd_next: 22  Sort_merge_passes: 0  Sort_range_count: 0
  Sort_rows: 10  Sort_scan_count: 1  Created_tmp_disk_tables: 1  Created_tmp_tables: 1
  Start: 2026-10-20T09:29:17.414024Z  End: 2026-10-20T09:29:18.312910Z
SET timestamp=1792488557;
SELECT c.city, COUNT(*) cnt, ROUND(SUM(o.pay_amount),2) amt
    FROM orders o JOIN customers c ON c.id=o.customer_id
    WHERE o.created_at >= '2024-06-01' AND o.created_at < '2024-07-01'
    GROUP BY c.city ORDER BY amt DESC;
```

字段怎么读：

| 字段 | 含义 | 怎么用 |
|---|---|---|
| `Query_time` | 总耗时（不含网络） | 与 `Lock_time` 对比，判断是等锁还是真计算 |
| `Lock_time` | 等元数据锁/行锁的时间 | 占比高 → 转案例二 |
| `Rows_sent` | 返回行数 | 与 `Rows_examined` 比值，衡量索引效率 |
| `Rows_examined` | 扫描行数 | 远大于 `Rows_sent` → 索引差 |
| `Read_rnd_next` | 全表扫描读的下一行数 | ≈ 表行数 → 全表扫描实锤 |
| `Sort_rows` / `Sort_merge_passes` | 排序行数 / 归并趟数 | `Sort_merge_passes > 0` → 排序溢出到磁盘 |
| `Created_tmp_disk_tables` | 磁盘临时表数 | > 0 → `tmp_table_size` 不够或 GROUP BY 设计问题 |

聚合分析：

```bash
mysqldumpslow -s t -t 10 /var/log/mysql/slow.log    # 按总耗时 Top10
mysqldumpslow -s c -t 10 /var/log/mysql/slow.log    # 按次数 Top10
pt-query-digest /var/log/mysql/slow.log             # 生产首选，输出更细（需另装 Percona Toolkit）
```

本文 `mysqldumpslow -s t` 的真实输出：

```
Count: 3  Time=0.54s (1s)  Lock=0.00s (0s)  Rows=10.0 (30), user1[user1]@[192.168.215.1]
  SELECT c.city, COUNT(*) cnt, ROUND(SUM(o.pay_amount),N) amt
  FROM orders o JOIN customers c ON c.id=o.customer_id ...
```

> `mysqldumpslow` 会把数字替换成 `N`、字符串替换成 `S`，所以看起来"不像原 SQL"，这是正常的归一化。

#### 3.2.3 general log

记录所有到达服务器的语句。**只用于抓现行，绝不要长期开**（IO 放大 10 倍以上）。

```sql
SET GLOBAL general_log_file='/var/log/mysql/general.log';
SET GLOBAL general_log=ON;   -- 抓 30 秒
SET GLOBAL general_log=OFF;
```

#### 3.2.4 binlog

`ROW` 格式 + GTID 是 8.0 的推荐配置。排查时常用：

```bash
# 看某个时间段的变更（需要 binlog 文件权限）
mysqlbinlog --base64-output=DECODE-ROWS -v mysql-bin.000003 | less
# 按 GTID 定位
mysqlbinlog --include-gtids='527b0319-cc68-11f1-98f3-466f5023dd2a:461-462' mysql-bin.000003
```

```sql
SHOW MASTER STATUS;                -- 当前位点
SHOW BINARY LOGS;                  -- 文件列表与大小
SELECT * FROM performance_schema.replication_group_members;  -- MGR 场景
```

#### 3.2.5 relay log（复制专用）

从库的 `SHOW REPLICA STATUS` 里看 `Relay_Log_File` / `Relay_Log_Pos` / `Relay_Log_Space`。`Relay_Log_Space` 持续增长说明 IO 线程拉取快于 SQL 线程回放。

#### 3.2.6 performance_schema 与 sys schema

这是 8.0 最值得投入的诊断资产，比慢日志更实时：

```sql
-- 按总耗时排的 SQL 指纹
SELECT DIGEST_TEXT, COUNT_STAR, ROUND(SUM_TIMER_WAIT/1e12,3) total_s,
       ROUND(AVG_TIMER_WAIT/1e12,4) avg_s, SUM_ROWS_EXAMINED, SUM_NO_INDEX_USED,
       SUM_CREATED_TMP_DISK_TABLES
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME='shopdb'
ORDER BY SUM_TIMER_WAIT DESC LIMIT 10;

-- 正在执行的语句（含等待事件）
SELECT * FROM sys.session WHERE conn_id IS NOT NULL\G
SELECT * FROM sys.innodb_lock_waits\G
SELECT * FROM sys.statement_analysis LIMIT 10;
```

### 3.3 EXPLAIN：从"看起来走了索引"到"真的走了索引"

#### 3.3.1 十二列逐列读

| 列 | 含义 | 危险信号 |
|---|---|---|
| `id` | 查询编号 | id 越大越先执行；相同 id 从上往下 |
| `select_type` | 查询类型 | `DEPENDENT SUBQUERY` 常意味着相关子查询逐行执行 |
| `table` | 表名 | `<derived2>` / `<union1,2>` 表示临时结果 |
| `partitions` | 命中分区 | 分区表全开 = 分区裁剪失效 |
| `type` | **访问方式** | `ALL`、`index` 要警惕 |
| `possible_keys` | 可能用的索引 | 有但 `key` 为 NULL → 优化器主动放弃，看统计信息/成本 |
| `key` | 实际用的索引 | NULL = 没走索引 |
| `key_len` | 索引使用长度 | 联合索引只用了一部分（对比完整长度） |
| `ref` | 与索引比较的列/常量 | `const` 最好；`func` 表示函数导致无法用索引 |
| `rows` | **预估**扫描行数 | 与真实行数差距大 → 统计信息过期 |
| `filtered` | 预估过滤后剩余比例 | 很低说明扫了很多才命中 |
| `Extra` | 附加信息 | 见下表 |

`type` 从好到差：

```
system > const > eq_ref > ref > fulltext > ref_or_null > index_merge
       > unique_subquery > index_subquery > range > index > ALL
```

经验：**OLTP 查询至少要到 `range`；出现 `index` 或 `ALL` 且 `rows` 很大，基本就是慢查询。**

`Extra` 常见值：

| Extra | 含义 | 判断 |
|---|---|---|
| `Using index` | 覆盖索引，不回表 | ✅ 最好 |
| `Using where` | 服务层过滤 | 中性，看 `rows` |
| `Using index condition` | 索引下推（ICP） | ✅ 一般更好 |
| `Using temporary` | 用了临时表（GROUP BY/UNION/DISTINCT） | ⚠️ 数据量大时落盘 |
| `Using filesort` | 需要额外排序 | ⚠️ 看 `Sort_merge_passes` |
| `Using join buffer (hash join)` | 被驱动表无索引 | ⚠️ 大表 JOIN 灾难 |
| `Using MRR` | 多范围读 | ✅ 通常更好 |
| `Impossible WHERE` | 条件恒假 | 检查 SQL 逻辑 |

#### 3.3.2 三种格式怎么选

```sql
EXPLAIN SELECT ...;                    -- 经典表格，日常首选
EXPLAIN FORMAT=TREE SELECT ...;        -- 8.0.16+，看清执行顺序和成本
EXPLAIN FORMAT=JSON SELECT ...;        -- 最全，含 cost_info、used_columns
EXPLAIN ANALYZE SELECT ...;            -- 8.0.18+，真实执行，带实际耗时/行数
```

`EXPLAIN ANALYZE` 是排查慢 SQL 的"终极武器"，因为它给的是**实际**数据而不是估算。本文案例一的实跑：

```
-> Limit/Offset: 20/900000 row(s)  (cost=101698 rows=20) (actual time=482..482 rows=20 loops=1)
    -> Sort: orders.created_at DESC, limit input to 900020 row(s) per chunk
       (cost=101698 rows=994865) (actual time=406..461 rows=900020 loops=1)
        -> Table scan on orders  (cost=101698 rows=994865) (actual time=0.0783..202 rows=1e+6 loops=1)
```

怎么读：

- `actual time=482..482`：第一行返回耗时 .. 最后一行返回耗时（毫秒）
- `rows=900020`：实际处理行数，对比 `cost` 里的估算值
- `loops=1`：该节点被执行几次；嵌套循环里 `loops` 很大要警惕
- **从最内层往外看**：`Table scan 202ms` → `Sort 461ms` → `Limit 482ms`，时间主要花在排序

#### 3.3.3 三个"假索引"陷阱

| 写法 | EXPLAIN 表现 | 为什么 |
|---|---|---|
| `WHERE DATE(created_at)='2024-06-01'` | `type=index`（全索引扫描） | 列被函数包裹，无法用索引定位 |
| `WHERE order_no LIKE '%123'` | `type=ALL` | 左模糊无法用 B+ 树 |
| `WHERE varchar_col = 123` | `type=ALL` + 隐式转换 | 字符串列与数字比较，索引失效 |
| `WHERE a=1 OR b=2`（b 无索引） | `type=ALL` | 优化器放弃 index_merge |

案例一里 `DATE()` 那条查询的实测最能说明问题：`type=index`、`Using index` 看起来"走了索引"，实际扫了 100 万条索引记录，耗时 92ms；改成范围查询后 `rows=1852`、耗时 0.5ms。

---

## 4. 案例一：慢查询 / SQL 效率低

### 4.1 企业场景

订单列表页支持"按创建时间排序 + 翻页"，运营后台支持"按 SKU 统计销量"，财务报表按天聚合。上线半年，订单表从 10 万涨到 100 万，接口 P99 从 80ms 涨到 1.2s。

**关键特征**：QPS 没有明显上涨，但慢查询数上涨；`Threads_running` 高；慢日志里都是同几条 SQL。

### 4.2 判断依据

| 信号 | 本案表现 | 说明 |
|---|---|---|
| `Slow_queries` | 持续增长 | 有语句超过阈值 |
| `Threads_running` | 高于 CPU 核数 | 语句在排队执行 |
| digest 表 | Top SQL 的 `SUM_NO_INDEX_USED > 0` | 有全表扫描 |
| CPU | 随 QPS 线性上升 | 计算型，不是 IO 型 |

如果同时出现"连接数打满"，先看慢 SQL，不要先调 `max_connections`。

### 4.3 复现

```bash
bash demo/scripts/10-case1-slow-sql.sh > demo/logs/case1.out 2>&1
cat demo/logs/case1.out
```

脚本会自动：清理旧索引 → 跑 5 条问题 SQL → 抓 EXPLAIN/慢日志 → 加索引 → 再跑一遍对比。

### 4.4 定位

#### ① 深分页：`LIMIT 900000, 20`

```sql
SELECT id, order_no, customer_id, total_amount, created_at
FROM orders ORDER BY created_at DESC LIMIT 900000, 20;
```

实测 **0.3446 s/次，每次扫描 190 万行**（100 万表 + 排序输入 90 万）：

```
执行 3 次 → 平均 0.3446 s/次 | 扫描行数 5700060 | 无索引访问 3 次 | 磁盘临时表 0
```

`EXPLAIN` 一眼看出问题：

```
type: ALL          ← 全表扫描
key: NULL
rows: 994865
Extra: Using filesort
```

`EXPLAIN ANALYZE` 告诉你时间花在哪：

```
-> Limit/Offset: 20/900000 row(s)   (actual time=482..482 rows=20)
    -> Sort: orders.created_at DESC  (actual time=406..461 rows=900020)
        -> Table scan on orders      (actual time=0.0783..202 rows=1e+6)
```

**根因**：`LIMIT offset, n` 必须先丢弃前 `offset` 行。翻到第 4.5 万页时，数据库要读出 90 万行再扔掉。`ORDER BY` 又因为要取非索引列而退化成全表扫描 + filesort。

#### ② 缺索引：`order_items.sku`

```sql
SELECT COUNT(*) AS cnt, SUM(amount) AS amt FROM order_items WHERE sku='SKU001234';
```

实测 **0.3295 s/次，每次扫 200 万行**，`type: ALL`、`rows: 1991822`。

`Handler` 统计是最硬的证据：

```
Handler_read_rnd_next   2000001     ← 顺序扫了 200 万行
Handler_read_key        1           ← 只用了 1 次索引
```

> `Handler_read_rnd_next` ≈ 表行数，就是"全表扫描"的同义词。

#### ③ 函数包裹索引列：`DATE(created_at)`

```sql
SELECT COUNT(*) FROM orders WHERE DATE(created_at)='2024-06-01';
```

实测 **0.0921 s，扫 100 万行**。注意 EXPLAIN 很有迷惑性：

```
type: index
key: idx_created_at
Extra: Using where; Using index
```

看起来用了索引，但 `type: index` 是**全索引扫描**——把整棵索引树读完再逐行算 `DATE()`。digest 表里 `SUM_NO_INDEX_USED=0`，更容易让人误判"没有全表扫描"。

#### ④ 左模糊：`LIKE '%0000012345'`

```sql
SELECT id, order_no, total_amount FROM orders WHERE order_no LIKE '%0000012345';
```

实测 **0.2339 s，扫 100 万行**，`type: ALL`。B+ 树只能做前缀匹配，左边有 `%` 就只能扫。

#### ⑤ 报表查询：JOIN + GROUP BY + 排序

```sql
SELECT c.city, COUNT(*) cnt, ROUND(SUM(o.pay_amount),2) amt
FROM orders o JOIN customers c ON c.id=o.customer_id
WHERE o.created_at >= '2024-06-01' AND o.created_at < '2024-07-01'
GROUP BY c.city ORDER BY amt DESC;
```

实测 **0.5377 s/次**，但只看 `Rows_examined` 会误判：

```
Rows_examined: 111122      ← 只扫了 11 万行
Created_tmp_disk_tables: 1 ← 但用了磁盘临时表
```

`EXPLAIN ANALYZE` 揭示真正的瓶颈：

```
-> Sort: amt DESC                        (actual time=395..395 rows=10)
    -> Table scan on <temporary>         (actual time=395..395 rows=10)
        -> Aggregate using temporary table (actual time=395..395 rows=10)
            -> Nested loop inner join    (actual time=0.8..338 rows=55556)
```

**根因**：扫描只用了 241ms，剩下 150ms 全在"临时表聚合 + 排序"。`GROUP BY c.city` 的 `city` 来自被驱动表，无法利用 `orders` 的索引顺序。

#### ⑥ 隐式类型转换：`varchar 列 = 数字`

```sql
-- 正确：字符串常量
SELECT id, order_no, total_amount FROM orders WHERE order_no = 'SO0000001234';
-- 错误：数字常量
SELECT id, order_no, total_amount FROM orders WHERE order_no = 1234;
```

实测对比（case1.out §11）：

```
正确：type: const  key: uk_order_no  rows: 1      → 0.0003 s/次
错误：type: ALL    key: NULL         rows: 995835 → 0.3442 s/次，扫 100 万行
```

差 **1100 倍**。原因：字符串列与数字比较时，MySQL 把**列**转成数字（而不是把常量转成字符串），`order_no` 上的索引彻底用不上。`SHOW WARNINGS` 里优化器说得明明白白：

```
Warning 1739: Cannot use ref access on index 'uk_order_no' due to type or
              collation conversion on field 'order_no'
```

更隐蔽的是**正确性**：`'SO0000001234'` 转数字 = 0，这条查询一行都查不到——不但慢，还悄悄查错了。定位口诀：**EXPLAIN 里 `possible_keys` 有、`key` 为 NULL 时，先跑一次 `EXPLAIN; SHOW WARNINGS;`**。

#### ⑦ 统计信息过期：优化器拿着旧地图走路

场景：批量导入/归档之后没人执行 `ANALYZE TABLE`，字典统计停留在旧值。实测（case1.out §12，专用表 `STATS_AUTO_RECALC=0`）：

```
阶段一：插 200 行 + ANALYZE        → mysql.innodb_table_stats.n_rows = 200
阶段二：再灌 50 万行，不 ANALYZE   → n_rows 仍 = 200（统计确实过期了）
                                    实际行数 500200
```

但接下来有个反直觉的发现——**EXPLAIN 的 rows 居然是准的**：

```
EXPLAIN SELECT * FROM demo_stats          → rows: 500200   ← 不是 200！
```

因为 8.0 对等值/范围条件（甚至全扫估算）会做 **index dive**：优化器现场潜入 B+ 树数一遍，不依赖字典统计。那过期的统计到底喂给谁？——**JOIN 的基数估算**：JOIN 没有具体值可下探，只能用 `innodb_index_stats` 里的 `n_diff`（平均每值多少行）来估算内表探测成本。字典统计过期时，JOIN 顺序与 NLJ/Hash 的选择就建立在旧数据上。

生产上"大变更之后 JOIN 突然变慢、`ANALYZE TABLE` 一下就好"，根因就在这里。治理：

- 大批量导入/归档后**必须 `ANALYZE TABLE`**（或建表时就设 `STATS_AUTO_RECALC=1`）；
- 数据倾斜严重的列加**直方图**（`ANALYZE TABLE t UPDATE HISTOGRAM ON col`），让 `filtered` 估算有据可依；
- 排查时直接查证据：`SELECT * FROM mysql.innodb_table_stats WHERE table_name='t';`

### 4.5 慢日志与 digest 联动

慢日志（阈值 0.2s）里能直接看到这条报表 SQL 的完整画像（冷缓存时的一次采样，热缓存约 0.54s）：

```
# Query_time: 0.898886  Lock_time: 0.000005  Rows_sent: 10  Rows_examined: 111122
  Read_key: 111115  Read_next: 55556  Sort_rows: 10
  Created_tmp_disk_tables: 1  Created_tmp_tables: 1
```

`mysqldumpslow -s t` 聚合后：

```
Count: 3  Time=0.54s (1s)  Rows=10.0 (30), user1[user1]@[192.168.215.1]
  SELECT c.city, COUNT(*) cnt, ROUND(SUM(o.pay_amount),N) amt ...
Count: 4  Time=0.33s (1s)  Rows=1.0 (4),  2users@[192.168.215.1]
  SELECT COUNT(*) AS cnt, SUM(amount) AS amt FROM order_items WHERE sku='S'
Count: 3  Time=0.34s (1s)  Rows=20.0 (60), user1[user1]@[192.168.215.1]
  SELECT ... FROM orders ORDER BY created_at DESC LIMIT N, N
```

`performance_schema` digest 排行榜（更实时，不需要等慢日志落盘）：

```
sql_digest: SELECT `c` . `city` , COUNT ( * ) `cnt` , ...
    次数: 3   总耗时s: 0.86   平均s: 0.2867
扫描行数: 333366   无索引: 0   磁盘临时表: 3
```

### 4.6 优化与验证

| 场景 | 优化前 | 优化手段 | 优化后 | 提升 |
|---|---|---|---|---|
| 深分页 | 0.3446 s / 190 万行 | 游标分页（Keyset） | 0.0009 s / 20 行 | ~380× |
| SKU 聚合 | 0.3295 s / 200 万行 | `ADD INDEX idx_sku(sku)` | 0.0019 s / 400 行 | ~170× |
| `DATE()` | 0.0921 s / 100 万行 | 改写为范围查询 | 0.0005 s / 1852 行 | ~180× |
| 左模糊 | 0.2339 s / 100 万行 | 无法索引，改设计 | — | 需换方案 |
| 报表 | 0.5377 s / 磁盘临时表 | 覆盖索引 `(created_at, customer_id, pay_amount)` | 0.0951 s / 索引覆盖 | ~5.6× |
| 隐式转换 | 0.3442 s / 100 万行 | 常量写成字符串（§4.4⑥） | 0.0003 s / 1 行 | ~1100× |
| 统计过期 | JOIN 成本误估 | `ANALYZE TABLE` / 直方图（§4.4⑦） | 估算恢复准确 | 预防性 |

#### 优化后的执行计划对比

游标分页（不再有 offset，直接定位起点）：

```sql
SELECT id, order_no, customer_id, total_amount, created_at
FROM orders
WHERE created_at < '2024-02-23 23:42:41'
ORDER BY created_at DESC LIMIT 20;
```

```
-> Limit: 20 row(s)  (actual time=0.345..0.348 rows=20 loops=1)
    -> Index range scan on orders using idx_created_at (reverse)
       (actual time=0.345..0.347 rows=20 loops=1)
```

耗时从 482ms 降到 **0.345ms**。

加索引后：

```
type: ref
key: idx_sku
key_len: 130
rows: 400
Extra: NULL
```

覆盖索引后：

```
key: idx_created_cust_amount
rows: 101098
Extra: Using where; Using index; Using temporary; Using filesort
```

注意：**`Using temporary; Using filesort` 还在**。覆盖索引只是消除了 5.5 万次回表，`GROUP BY city` 的排序依然存在。要彻底消除，需要把报表结果预聚合（物化视图/汇总表/OLAP），这是架构问题，不是索引能解决的。

### 4.7 深分页的三种解法

| 方案 | 写法 | 适用 |
|---|---|---|
| 游标分页 | `WHERE created_at < 上一页最后值 ORDER BY created_at DESC LIMIT 20` | 推荐，无限滚动 |
| 延迟关联 | `JOIN (SELECT id FROM orders ORDER BY created_at LIMIT 900000,20) t USING(id)` | 必须保留页码时 |
| 预计算总数 | 缓存 `COUNT(*)`，只允许前 N 页 | 产品可接受时 |

`LIMIT 900000, 20` 这种写法本身就应该在代码评审里被拦下来。

### 4.8 避坑清单

- 索引列上不要有函数、运算、隐式类型转换
- 联合索引注意最左前缀；`key_len` 能看出用了几列
- `LIKE '%x'` 无法走索引；需要全文检索请上 ES 或 `FULLTEXT`
- `SELECT *` 会破坏覆盖索引
- 小表驱动大表；被驱动表的关联列必须有索引
- `ORDER BY` 尽量与 `WHERE` 用同一个索引，避免 filesort
- 分页参数要有上限（`LIMIT` 最大 1000 之类）
- 统计信息过期会导致选错索引：`ANALYZE TABLE`、关注 `innodb_stats_auto_recalc`

---

## 5. 案例二：锁竞争与长事务

### 5.1 企业场景

秒杀扣库存、账户余额变更、订单状态流转。表现为：**RT 抖动（不是一直慢）**、库存接口偶发超时、监控上 `Innodb_row_lock_waits` 飙升、应用日志出现 `1205 Lock wait timeout` 或 `1213 Deadlock`。

### 5.2 判断依据

| 信号 | 本案表现 | 说明 |
|---|---|---|
| `Innodb_row_lock_waits` / `Innodb_row_lock_time` | 持续增长 | 有行锁等待 |
| `Threads_running` | 高，但 CPU 不高 | 线程在"等"，不是"算" |
| `SHOW PROCESSLIST` 的 `state` | `Waiting for ... lock` | 直接指向锁 |
| 慢日志 | `Lock_time` 占比高 | 区别于计算型慢查询 |
| `information_schema.innodb_trx` | 有长事务（age 很大） | 长事务是锁等待的放大器 |

关键区分：**等锁的 SQL 本身可能很快**，所以只看"慢 SQL 排行榜"会漏掉它。

### 5.3 复现与定位

**一键复现（输出写入 `demo/logs/case2.out`，同名文件会被覆盖）**

```bash
bash demo/scripts/20-case2-lock.sh > demo/logs/case2.out 2>&1
cat demo/logs/case2.out
```

下面按场景拆开，说明每一步在验证什么。

#### 场景 A：热点行锁等待

会话 A 开启事务扣库存但不提交：

```sql
BEGIN;
UPDATE inventory SET stock=stock-1 WHERE product_id=1;
SELECT SLEEP(15);   -- 模拟事务里调外部接口
COMMIT;
```

会话 B 扣同一行：

```sql
SET SESSION innodb_lock_wait_timeout=8;
UPDATE inventory SET stock=stock-1 WHERE product_id=1;
```

**① 谁在等谁**（`sys.innodb_lock_waits`，最直观）：

```sql
SELECT wait_age, waiting_pid, waiting_query, blocking_pid, blocking_query,
       locked_table, locked_index, locked_type
FROM sys.innodb_lock_waits\G
```

```
      wait_age: 00:00:03
   waiting_pid: 75
 waiting_query: UPDATE inventory SET stock=stock-1 WHERE product_id=1
  blocking_pid: 74
blocking_query: SELECT SLEEP(15)      ← 持锁者居然在 sleep
  locked_table: `shopdb`.`inventory`
 locked_index: PRIMARY
   locked_type: RECORD
```

这一条就定位了：**74 号会话开了事务不提交，75 号在等它。**

**② 锁的粒度与模式**（`performance_schema.data_locks`）：

```sql
SELECT ENGINE_TRANSACTION_ID trx, OBJECT_NAME tbl, INDEX_NAME idx,
       LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
FROM performance_schema.data_locks\G
```

```
trx: 2613  tbl: inventory  LOCK_TYPE: TABLE   LOCK_MODE: IX          GRANTED
trx: 2614  tbl: inventory  LOCK_TYPE: TABLE   LOCK_MODE: IX          GRANTED
trx: 2613  tbl: inventory  INDEX: PRIMARY     LOCK_MODE: X,REC_NOT_GAP  GRANTED  LOCK_DATA: 1
trx: 2614  tbl: inventory  INDEX: PRIMARY     LOCK_MODE: X,REC_NOT_GAP  WAITING  LOCK_DATA: 1
```

`LOCK_MODE` 读法：

| 值 | 含义 |
|---|---|
| `X,REC_NOT_GAP` | 行锁（不含间隙），唯一索引等值命中 |
| `X` | next-key lock（行 + 间隙），RR 下范围查询默认 |
| `X,GAP` | 纯间隙锁，锁"不存在的行" |
| `S` / `S,REC_NOT_GAP` | 共享锁 |
| `IX` / `IS` | 表级意向锁，正常现象 |

**③ 事务画像**（`information_schema.innodb_trx`）：

```sql
SELECT trx_id, trx_state, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_s,
       trx_rows_locked, trx_rows_modified, trx_isolation_level, LEFT(trx_query,60)
FROM information_schema.innodb_trx ORDER BY trx_started\G
```

```
trx_id: 2613   trx_state: RUNNING    age_s: 5   trx_rows_locked: 1
trx_id: 2614   trx_state: LOCK WAIT  age_s: 3   trx_rows_locked: 1
```

`age_s` 是判断长事务的核心指标：**超过 60s 的事务就要问一句"为什么不提交"**。

**④ `SHOW ENGINE INNODB STATUS`**：

```
---TRANSACTION 2614, ACTIVE 3 sec starting index read
LOCK WAIT 2 lock struct(s), heap size 1128, 1 row lock(s)
------- TRX HAS BEEN WAITING 3 SEC FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS ... index PRIMARY of table `shopdb`.`inventory` trx id 2614
lock_mode X locks rec but not gap waiting
```

会话 B 最终报错：`ERROR 1205 (HY000): Lock wait timeout exceeded`。

#### 场景 B：无索引更新 → 锁全表

这是最容易被忽视的锁放大：

```sql
BEGIN;
UPDATE inventory_log SET change_qty=0 WHERE biz_no='BIZ00000001';  -- biz_no 无索引
```

实测**这次事务持有 100341 个锁**（表 10 万行）：

```sql
SELECT COUNT(*) FROM performance_schema.data_locks;   -- 100341
SELECT trx_rows_locked FROM information_schema.innodb_trx;  -- 100340
```

**根因**：没有索引，InnoDB 只能全表扫描加锁，每一行都加 next-key lock。此时任何对该表的写入都会被阻塞，并发直接归零。

修复：`ALTER TABLE inventory_log ADD INDEX idx_biz_no(biz_no);` —— 同样的 SQL 只锁 1 行。

> 生产经验：**所有 `UPDATE/DELETE` 的 `WHERE` 条件列都必须有索引**，这不是性能优化，是正确性要求。

#### 场景 C：长事务——先拖住 purge，再阻塞 DDL

长事务的第一重危害是 **purge 停摆**。演示（case2.out §3，长事务持 read view 期间，写入方每秒提交一次 UPDATE）：

```
t      trx_id_counter  purge_done  gap（gap=被拖住、无法清理 undo 的事务数）
t+1s  2163  2159   4
t+5s  2175  2159  16
t+10s 2190  2159  31      ← 写入方明明都已提交，purge 却一步没走
```

长事务提交后，purge 一口气追上来：

```
t+1s  2215 2206  9
t+2s  2216 2215  1       ← gap 塌缩
```

后果：purge 停摆期间 undo 持续累积（History list length 只涨不跌）、回滚段膨胀、磁盘空间不释放——**长事务是生产上的头号空间杀手**。

一个实测才看得到的细节：**必须先做过一致性读（SELECT）的事务才真正挡住 purge**。只做 UPDATE 不 SELECT 的事务没有 read view，其他已提交事务的 undo 照样能被清理。所以"事务里先 SELECT 再干活"的写法，锁窗口和 purge 影响都比纯写事务更重。

长事务的第二重危害才是 **MDL 雪崩**：

```sql
-- 会话 A：开事务查一行，不提交
BEGIN; SELECT * FROM orders WHERE id=1;
-- 会话 B：加字段（等 MDL）
ALTER TABLE orders ADD COLUMN tmp_demo_col INT;
-- 会话 C：普通查询（排在 ALTER 后面）
SELECT id FROM orders WHERE id=1;
```

实测 `information_schema.processlist`：

```
id=88 user1  state: Waiting for table metadata lock   info: SELECT id FROM orders WHERE id=1
id=87 root   state: Waiting for table metadata lock   info: ALTER TABLE shopdb.orders ADD COLUMN ...
id=84 user1  state: User sleep                        info: SELECT SLEEP(20)
```

**这就是线上"加个字段导致全站不可用"的完整链路**：长事务持 MDL → DDL 排队 → 后续所有访问该表的请求排在 DDL 后面 → 连接池耗尽。

处置顺序：先 `KILL` 长事务（或等它结束），DDL 立刻通过；绝不要先 `KILL` DDL。

#### 场景 D：死锁

两个事务交叉更新：

```
A: BEGIN; UPDATE inventory SET stock=stock+1 WHERE product_id=1; ... WHERE product_id=2;
B: BEGIN; UPDATE inventory SET stock=stock+1 WHERE product_id=2; ... WHERE product_id=1;
```

应用侧收到：

```
ERROR 1213 (40001): Deadlock found when trying to get lock; try restarting transaction
```

`SHOW ENGINE INNODB STATUS` 的 `LATEST DETECTED DEADLOCK` 会完整记录两个事务持有什么、等什么：

```
*** (1) TRANSACTION:
TRANSACTION 2646, ACTIVE 4 sec starting index read
LOCK WAIT 3 lock struct(s), 2 row lock(s)
UPDATE inventory SET stock=stock+1 WHERE product_id=2
*** (1) HOLDS THE LOCK(S):   ... lock_mode X ... (product_id=1)
*** (1) WAITING FOR THIS LOCK TO BE GRANTED: ... (product_id=2)
*** (2) TRANSACTION:
TRANSACTION 2647 ... UPDATE ... WHERE product_id=1
*** (2) HOLDS THE LOCK(S):   ... (product_id=2)
```

**死锁是正常现象**，InnoDB 会自动回滚代价小的事务。要做的是：
1. 应用必须捕获 1213 并重试（带随机退避）；
2. 统一加锁顺序（比如按 `product_id` 升序更新）；
3. 开 `innodb_print_all_deadlocks=ON`，把死锁写进错误日志，便于复盘。

#### 场景 E：间隙锁（RR 隔离级别）

`promo_code` 的 id 是稀疏的（1000、1010、1020…），1005 并不存在：

```sql
-- 会话 A
BEGIN;
SELECT id FROM promo_code WHERE id BETWEEN 1000 AND 1010 FOR UPDATE;
```

`data_locks` 显示：

```
LOCK_MODE: X             LOCK_DATA: 1010     ← next-key lock（含间隙）
LOCK_MODE: X,REC_NOT_GAP LOCK_DATA: 1000     ← 行锁
```

此时插入 1005（一个不存在的 id）会被阻塞：

```
ERROR 1205 (HY000): Lock wait timeout exceeded
```

**根因**：RR 隔离级别下，范围查询会锁住区间内的"间隙"，防止幻读。这就是为什么"我明明只查了 10 行，却把别人的插入挡住了"。

三种解法：

| 方案 | 做法 | 代价 |
|---|---|---|
| 降隔离级别 | `SET SESSION transaction_isolation='READ-COMMITTED'` | 需要确认业务能接受不可重复读 |
| 改等值查询 | 用主键/唯一索引精确定位，避免范围 `FOR UPDATE` | 需要改 SQL |
| 缩短事务 | 把 `SELECT ... FOR UPDATE` 放到事务最后 | 需要改代码结构 |

### 5.4 治理要点

```sql
SHOW VARIABLES WHERE Variable_name IN
  ('innodb_lock_wait_timeout','innodb_deadlock_detect',
   'innodb_print_all_deadlocks','innodb_rollback_on_timeout','transaction_isolation');
```

本环境实测值：

```
innodb_deadlock_detect          ON          ← 死锁检测，高并发下可考虑关掉换超时
innodb_lock_wait_timeout        10          ← 等锁超时（秒）
innodb_print_all_deadlocks      OFF         ← 建议开，死锁全量落日志
innodb_rollback_on_timeout      OFF         ← 超时只回滚语句，不回滚事务
transaction_isolation           REPEATABLE-READ
```

五条硬规矩：

1. **事务里不做 RPC/HTTP/文件 IO**，事务只包 DB 操作；
2. **`UPDATE/DELETE` 的 `WHERE` 必须有索引**；
3. **统一加锁顺序**，避免交叉等待；
4. **应用必须处理 1213/1205**，重试 + 退避；
5. **监控长事务**：`SELECT * FROM information_schema.innodb_trx WHERE TIMESTAMPDIFF(SECOND,trx_started,NOW()) > 60;`，超过阈值告警。


---

## 6. 案例三：连接数 / 连接池耗尽

### 6.1 两种完全不同的"连接问题"

很多人把这两个混为一谈，处置方式相反：

| 类型 | 现象 | 本质 | 处置 |
|---|---|---|---|
| **A. 线程被占满** | `Threads_running` 高，`Threads_connected` 未必高 | 慢 SQL/锁占住工作线程 | 优化 SQL、加索引、限流 |
| **B. 连接被占满** | `Threads_connected` 到上限，大量 `Sleep` | 连接池配置过大/泄漏/未释放 | 调小池、修泄漏、加超时 |

调大 `max_connections` 对 A 无效（甚至更糟），对 B 只是把问题推迟。

### 6.2 复现 A：慢 SQL 占满工作线程

**一键复现（输出写入 `demo/logs/case3.out`，同名文件会被覆盖）**

```bash
bash demo/scripts/30-case3-connections.sh > demo/logs/case3.out 2>&1
cat demo/logs/case3.out
```

下面是拆开的分步命令。

```bash
# 20 并发跑报表 SQL（单条约 0.5s）
mysqlslap -h127.0.0.1 -P13306 -uuser1 -ppasswd1 --create-schema=shopdb \
  -c 20 -i 1 --number-of-queries=240 \
  --query="SELECT c.city, COUNT(*) cnt, SUM(o.pay_amount) amt FROM orders o JOIN customers c ON c.id=o.customer_id WHERE o.created_at >= '2024-06-01' AND o.created_at < '2024-07-01' GROUP BY c.city ORDER BY amt DESC"
```

压测中实测：

```
Threads_connected   22
Threads_running     22
```

```
command   state        c
Query     executing    21
Sleep                  1
```

**判断**：连接数只有 22（上限 50），远没到瓶颈，但 20 个线程全在 `executing`。这是典型的"线程不够用"，不是"连接不够用"。

### 6.3 复现 B：连接池打满

用 50 个空闲连接模拟"应用池配置过大 + 连接不释放"：

```bash
for i in $(seq 1 60); do
  mysql -h127.0.0.1 -P13306 -uuser1 -ppasswd1 shopdb < /tmp/idle_fifo &
done
```

实测第 51 个连接开始报错：

```
ERROR 1040 (08004): Too many connections
```

```
Threads_connected                51     ← 50 + root 保留连接
Max_used_connections             51
Aborted_connects                 3
Connection_errors_max_connections 10    ← 被拒绝的次数
```

按维度聚合，问题一目了然：

```sql
SELECT user, SUBSTRING_INDEX(host, ':', 1) AS ip, command, COUNT(*) AS conns
FROM information_schema.processlist
GROUP BY user, ip, command ORDER BY conns DESC;
```

```
user    ip               command  conns
user1   192.168.215.1    Sleep    50      ← 全是空闲连接
root    192.168.215.1    Query    1
```

### 6.4 定位

```sql
-- 1. 总量与上限
SHOW STATUS WHERE Variable_name IN
  ('Threads_connected','Threads_running','Max_used_connections',
   'Aborted_connects','Connection_errors_max_connections');
SHOW VARIABLES LIKE 'max_connections';

-- 2. 按 IP/用户/状态聚合（比 SHOW PROCESSLIST 好用）
SELECT user, SUBSTRING_INDEX(host,':',1) ip, command, state, COUNT(*) c
FROM information_schema.processlist
WHERE command <> 'Daemon'
GROUP BY user, ip, command, state ORDER BY c DESC;

-- 3. 谁占着最久
SELECT id, user, SUBSTRING_INDEX(host,':',1) ip, db, command, time, state, LEFT(info,50)
FROM information_schema.processlist
WHERE command <> 'Daemon' ORDER BY time DESC LIMIT 10;

-- 4. 连接与 OS 线程
SELECT TYPE, PROCESSLIST_COMMAND, COUNT(*) c
FROM performance_schema.threads
WHERE TYPE='FOREGROUND' GROUP BY TYPE, PROCESSLIST_COMMAND;

-- 5. 线程池/等待
SELECT * FROM sys.session WHERE conn_id IS NOT NULL\G
```

**关键认知**：`root` 始终保留一个连接（`max_connections + 1`）。所以连接打满时，root 还能登录救火——这是设计，不是 bug。

### 6.5 处置

**止血**（先恢复业务）：

```sql
-- 找出空闲超过 5 秒的连接
SELECT id, user, host, time FROM information_schema.processlist
WHERE command='Sleep' AND user='user1' AND time > 5;

-- 生成 KILL 语句
SELECT CONCAT('KILL ', id, ';') FROM information_schema.processlist
WHERE command='Sleep' AND user='user1' AND time > 5;
```

实测：清理 50 个空闲连接后，`Threads_connected` 从 51 回到 1。

**治本**：

| 问题 | 修复 |
|---|---|
| 池太大 | `maxPoolSize` 按 DB 容量反推，不是拍脑袋 |
| 连接泄漏 | 确保 `try-with-resources`；开 `leakDetectionThreshold` |
| 没有超时 | `connectionTimeout` 3s、`validationTimeout` 1s、`idleTimeout` 10min |
| `wait_timeout` 太大 | 服务端 300~600s；必须小于中间件/防火墙的空闲断连时间 |
| 突发流量 | 加限流/排队，不要让流量直接打到连接池 |

容量公式：

```
应用最大连接数 = Pod 数 × maxPoolSize × (1 + 突发冗余)
DB max_connections ≥ Σ(各应用最大连接数) + 运维/备份/监控预留 20%
```

本文环境：3 Pod × 20 = 60 > 50 → 必然打满。要么把池降到 15，要么把 `max_connections` 提到 100。

### 6.6 常见误区

| 误区 | 事实 |
|---|---|
| "连接越多吞吐越高" | 吞吐由 `Threads_running`（CPU/IO 并发能力）决定，连接多了只是排队 |
| "`max_connections` 调到 1000 就好了" | 每连接 0.3~1MB 基础内存，1000 连接先 OOM；且会掩盖真正的慢 SQL |
| "`Sleep` 连接不用管" | 每个 Sleep 连接占内存、占 fd；`wait_timeout` 默认 8 小时，泄漏会累积 |
| "连接池越大越好" | 池大小应 ≈ DB 能并行处理的线程数，超出部分只会增加 RT |

---

## 7. 案例四：服务器资源瓶颈

### 7.1 判断：先分清是哪种资源

| 资源 | 症状 | 关键指标 |
|---|---|---|
| CPU | 所有查询一起慢，`Threads_running` 高 | CPU 使用率、`Threads_running`、慢日志 |
| 内存 | 命中率下降，物理读上升，偶发 OOM | buffer pool 命中率、`Innodb_buffer_pool_reads`、`dmesg` |
| 磁盘 IO | 写入/排序慢，iowait 高 | `iostat`、`Innodb_data_reads`、`Sort_merge_passes` |
| 网络 | 大结果集查询慢，跨机房更明显 | `Bytes_sent`、RTT、带宽 |

**一键复现（输出写入 `demo/logs/case4.out`，同名文件会被覆盖）**

```bash
bash demo/scripts/40-case4-resources.sh > demo/logs/case4.out 2>&1
cat demo/logs/case4.out
```

### 7.2 CPU 瓶颈

**计算密集型 SQL**（每行一次 `MD5`）：

```sql
SELECT COUNT(*) FROM orders WHERE MD5(order_no) LIKE '%abc%';
```

实测 **0.6725 s，扫 100 万行**，`type: index`（全索引扫描）。

**并发把 CPU 打满**：16 并发，实测容器 CPU 到 **198.87%**（2 核跑满）：

```
压测中 CPU=198.87% 内存=553.8MiB / 1GiB
Threads_running 17
```

这里有一个必须说清楚的细节。压测用的 SQL 看起来是主键点查：

```sql
SELECT id, order_no FROM orders WHERE id = FLOOR(1 + RAND()*1000000);
```

但它**并不是点查**——`RAND()` 是每行求值的非确定性函数，优化器无法把它当常量，只能全表扫描。digest 表留下了铁证：

```
sql_digest: SELECT `id`,`order_no` FROM `orders` WHERE `id` = `FLOOR`(? + `RAND`()*?)
次数: 128   平均: 1.526 s   扫描行数: 128000000     ← 128 次 × 100 万行
```

**这是"看起来像点查、实际全表扫描"的典型代表**，比 `LIKE '%x'` 更隐蔽。判断方法：点查的 `Rows_examined` 必须约等于 `Rows_sent`；一旦接近表行数，立刻去看 `EXPLAIN`。

判断 CPU 问题的两条经验：

- CPU 高且 `Threads_running` ≈ 核数 × 2 → 满负荷计算，先看是不是全表扫描/函数计算；
- CPU 高但 `Threads_running` 不高 → 单条 SQL 在做大计算（MD5、正则、复杂 JSON 解析），或后台线程（purge、page cleaner）在忙。

### 7.3 内存瓶颈

本环境 buffer pool 只有 128M（8192 页），而数据量约 620MB：

```sql
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';   -- 134217728
SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_pages%';
```

```
Innodb_buffer_pool_pages_data    5804
Innodb_buffer_pool_pages_free    2305
```

`SHOW ENGINE INNODB STATUS` 的 `BUFFER POOL AND MEMORY`：

```
Buffer pool size   8192
Free buffers       2299
Database pages     5810
Buffer pool hit rate 984 / 1000, young-making rate 0 / 1000 not 950 / 1000
```

**命中率 98.4%**（生产要求 > 99.9%）。全局累计命中率看起来是 99.99%，因为大部分时间是空闲的——**要看当前值，不要只看累计值**。

内存分布（`sys.memory_global_total` + `memory_summary_global_by_event_name`）：

```
total_allocated  478.59 MiB

130.88 MB  memory/innodb/buf_buf_pool
 40.28 MB  memory/performance_schema/events_statements_summary_by_digest
 24.00 MB  memory/innodb/ut0link_buf
 22.22 MB  memory/innodb/lock0lock
 16.00 MB  memory/innodb/log_buffer_memory
```

**注意**：`performance_schema` 自己就吃了 40MB。小规格实例上，可以按需关闭部分 consumer。

### 7.4 磁盘 IO 瓶颈

执行一次覆盖 200 万行的 `LIKE` 扫描，`Innodb_data_read` 从 **92MB 涨到 318MB**（+226MB）：

```
执行前：Innodb_data_read 92604928   Innodb_data_reads 5696
执行后：Innodb_data_read 318573056  Innodb_data_reads 19488
```

host 侧 `iostat -d -w 1 -c 3`：

```
              disk0
    KB/t  tps  MB/s
   16.06   94  1.47
    6.53  136  0.86
    6.23  171  1.04
```

判断 IO 瓶颈的三个信号：

1. `Innodb_data_reads` 增速远超 `Innodb_buffer_pool_read_requests` → 缓存不够；
2. `Sort_merge_passes` 持续增长 → 排序溢出到磁盘；
3. `Innodb_buffer_pool_wait_free > 0` → 刷脏跟不上，写被阻塞。

### 7.5 临时表 / 排序瓶颈

`tmp_table_size=2M`、`max_heap_table_size=2M` 的小配置下，报表 SQL 实测：

```
Created_tmp_tables        1
Created_tmp_disk_tables   1     ← 临时表落盘
Sort_rows                 10
```

`Created_tmp_disk_tables > 0` 意味着 MySQL 把中间结果写到了磁盘（`#innodb_temp` 或 `tmpdir`），延迟是内存的几十倍。

处置：

```ini
tmp_table_size      = 64M
max_heap_table_size = 64M    # 必须与 tmp_table_size 一起调
internal_tmp_mem_storage_engine = TempTable   # 8.0 默认，比 MEMORY 引擎高效
```

但注意：**临时表膨胀往往是 SQL 写法问题**（`GROUP BY` 非索引列、`DISTINCT` 大结果、`UNION`），调参数只能缓解。

### 7.6 网络瓶颈

```sql
SELECT * FROM orders LIMIT 300000;   -- 约 25MB 结果集
```

实测耗时 0.69s，`Bytes_sent` 增加 **25MB**。

```
本次结果集传输：25 MB
```

网络问题的特征：

- 同一条 SQL 在本机 0.1s，跨机房 1.5s；
- `Bytes_sent` 远大于业务实际需要；
- 大量 `SELECT *`、N+1 查询、大字段（`TEXT/BLOB`）随行返回。

处置：只查需要的列、分页、大字段拆表、压缩传输、就近部署只读副本。

### 7.7 buffer pool 预热：重启后为什么前几分钟慢

`docker restart` 之后 buffer pool 清空，前几次查询全是物理读。实测（case4.out §6，重启后连跑同一条报表 SQL）：

```
重启前（热）：0.1437 s
冷启动第 1 遍：0.1404 s   命中率 98.71%
冷启动第 2 遍：0.1280 s   命中率 99.31%
冷启动第 3 遍：0.1294 s   命中率 99.53%
冷启动第 4 遍：0.1272 s   命中率 99.65%   ← 热点页被逐批载入，逼近热态
```

两点解读：

- **命中率的单调爬升就是预热机制的直接证据**。这是"重启后短时间慢、会自愈"的原理，也是云数据库"预热/内存保障"功能的卖点。
- 本例耗时差异偏小（140ms→127ms），是因为 **macOS 宿主机的文件缓存把物理读也兜住了**——冷读命中的是 host page cache 而不是真磁盘。生产云盘上冷热差会大得多。判断"内存不足 vs 正常预热"：预热几分钟内自愈 → 正常；长时间命中率上不去（对照 §2.5）→ buffer pool 确实不够（回到 §7.3）。

故障切换/重启后的正确姿势：切流量前先跑一遍热点查询预热（云厂商称为"预热窗口"），或接受前几分钟的 RT 抖动并把它从告警里摘出来。

### 7.8 资源类问题的排查顺序

```
1. 看 CPU：docker stats / top / mpstat
2. 看内存：buffer pool 命中率、sys.memory_global_total、dmesg 有无 OOM
3. 看磁盘：iostat 的 tps/MB/s、Innodb_data_reads 增速、Sort_merge_passes
4. 看网络：Bytes_sent、RTT、带宽监控
5. 对照：资源上升是否与业务曲线/任务窗口同步（合理 vs 异常）
```

---

## 8. 案例五：配置、架构与复制

### 8.1 配置：默认值是给"能跑"设计的，不是给"跑得好"设计的

**一键复现（输出写入 `demo/logs/case5.out`，含主从搭建，耗时约 1 分钟）**

```bash
bash demo/scripts/50-case5-config-repl.sh > demo/logs/case5.out 2>&1
cat demo/logs/case5.out
```

本环境的关键参数实测值：

```
innodb_buffer_pool_size        134217728     (128M)
innodb_buffer_pool_instances   1
innodb_flush_log_at_trx_commit 1
innodb_flush_method            fsync
innodb_io_capacity             200
innodb_log_buffer_size         16777216
max_connections                50
table_open_cache               2000
sync_binlog                    1
tmp_table_size                 2097152       (2M)
sort_buffer_size               1048576
join_buffer_size               262144
```

> 注：`open_files_limit` 这类参数 mysqld 启动时会按 `max_connections`、`table_open_cache` 自动上调，实际生效值可能大于 my.cnf 里的设定；要看真实值用 `SHOW VARIABLES`，不要拿配置文件对照。

#### 实测：双 1 刷盘的代价

200 次单行提交（每次 `COMMIT`）：

| 配置 | 耗时 | 说明 |
|---|---|---|
| `sync_binlog=1` + `flush_log_at_trx_commit=1` | **1226.3 ms** | 每次提交 2 次 fsync |
| `sync_binlog=0` + `flush_log_at_trx_commit=2` | **18.7 ms** | 每秒刷一次 |

**差 65 倍**。这就是"金融级配置"和"性能优先配置"的真实差距。选哪个取决于业务能接受丢多少数据：

- 订单/支付：必须双 1；
- 日志/埋点/点赞：可以双 0 或 `2`；
- 混合负载：分实例，不要用一个配置扛所有业务。

#### 在线调整与持久化

```sql
-- 8.0 支持在线扩缩 buffer pool（5.7 需要重启）
SET GLOBAL innodb_buffer_pool_size=256*1024*1024;
SHOW VARIABLES LIKE 'innodb_buffer_pool_size';   -- 268435456

-- 持久化，重启也生效（写入 mysqld-auto.cnf）
SET PERSIST max_connections=50;
SELECT * FROM performance_schema.persisted_variables;
```

```
VARIABLE_NAME       VARIABLE_VALUE
max_connections     50
```

#### 配置类问题的典型症状

| 症状 | 可能原因 |
|---|---|
| 重启后快，跑一阵又慢 | buffer pool 太小 / 表统计信息过期 |
| 所有 SQL 一起慢，换机器就好 | 规格不够（CPU/内存/IOPS） |
| 写入周期性卡顿 | redo/checkpoint 抖动、`innodb_io_capacity` 太低 |
| 大查询把实例拖垮 | `tmp_table_size`/`sort_buffer_size` 配置不当 + 无并发限制 |
| 连接数总是不够 | `max_connections` 与池大小不匹配 |
| **删了一半数据，查询没变快、磁盘没释放** | **表膨胀/碎片，见下** |

#### 表膨胀与碎片：删了数据为什么没变快

实测（case5.out §3，专用表 10 万行、每行约 200 字节）：

```
                    行数     .ibd 物理文件
① 插入 10 万行      100000    32M
② DELETE 80%         20000    32M   ← 行数掉到 1/5，文件一分不小
③ OPTIMIZE TABLE     20000    11M   ← 重建表，空间还给操作系统
```

**根因**：InnoDB 的 DELETE 只把行标记为删除、页放入空闲链表，**从不把空间还给操作系统**。后果有三层：磁盘占用不降；buffer pool 里装着大量半空的页（有效密度低）；全表扫描仍要走过带空洞的页。监控口径：`information_schema.tables` 的 `DATA_FREE` 与实际行数/数据量的比值，以及 `.ibd` 文件物理大小。

处置与代价：

| 手段 | 说明 | 代价 |
|---|---|---|
| `OPTIMIZE TABLE`（= `ALTER ... ENGINE=InnoDB`） | 重建表，空间回收 | 8.0 支持在线重建但 DML 受限，大表期间主从延迟 |
| `gh-ost` / `pt-online-schema-change` | 线上大表标准做法 | 需要额外磁盘与双写开销 |
| 分区表 + `DROP PARTITION` | 按时间归档场景的最优解 | 需要提前按归档键分区 |
| **避免起膨胀** | 大删除改分批 + 及时归档 | 治本 |

### 8.2 架构：读写分离的延迟陷阱

读写分离后，"写后读"读到旧数据是经典问题：

```
用户下单 → 主库写入 → 立刻查订单列表（走从库）→ 查不到 → 用户重复下单
```

解法：

1. 写后读强制走主库（同一事务/短窗口内）；
2. 用 GTID 判断从库是否已回放到该事务（`WAIT_FOR_EXECUTED_GTID_SET`）；
3. 关键路径不做读写分离。

```sql
-- 等待从库追上指定 GTID（超时 1s）
SELECT WAIT_FOR_EXECUTED_GTID_SET('527b0319-...:461', 1);
```

### 8.3 复制：从库为什么慢

#### 搭建（本文实测）

主库：

```sql
CREATE USER 'repl'@'%' IDENTIFIED WITH mysql_native_password BY 'repl123';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
```

从库：

```sql
CREATE DATABASE IF NOT EXISTS repltest;   -- 注意：这步必须手工做，见下方"老坑"
SET GLOBAL gtid_purged='<主库 gtid_executed>';
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='host.docker.internal', SOURCE_PORT=13306,
  SOURCE_USER='repl', SOURCE_PASSWORD='repl123',
  SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
```

实测状态：

```
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
Seconds_Behind_Source: 0
Replica_SQL_Running_State: Replica has read all relay log; waiting for more updates
```

#### 真实踩到的坑：`replicate-do-db` 过滤掉了建库语句

第一次启动复制直接中断：

```
Worker 1 failed executing transaction '...:462' ... Error executing row event:
'Unknown database 'repltest''
```

原因：`replicate-do-db=repltest` 是按**默认库**过滤的。`CREATE DATABASE repltest` 执行时默认库是 NULL，被过滤掉了；`CREATE TABLE repltest.big_order` 同理。从库既没有库也没有表，回放 row 事件必然失败。

**结论**：用 `replicate-do-db` 时，从库要预先建好库；主库的 DDL 必须 `USE db` 后再执行，或者改用 `replicate-wild-do-table`。

#### 第二个坑：`gtid_purged` 会把位点之前的建表 DDL 一起跳过

复现本次演示脚本重跑时踩到（报错同样在从库）：

```
Last_SQL_Errno: 1146
Worker 1 failed executing transaction '...:904' ... Error executing row event:
'table repltest.big_order doesn't exist'
```

链路：`SET GLOBAL gtid_purged='<主库位点>'` 的语义是"这些事务从库已经应用过了"——**位点之前的所有事务（包括建表 DDL）都会被跳过**。从库上库是手工建的、表却从未存在，回放第一个 INSERT 就报 1146。

**结论**：手工对齐位点时，从库不仅要**预建库，还要预建表**（schema 与主库对齐）；或者把位点选在 DDL 之前、让建表语句自然回放。这也解释了为什么克隆快照（clone plugin / 物理备份）比手工 GTID 对齐可靠得多。

#### 关键字段怎么读

```sql
SHOW REPLICA STATUS\G
```

| 字段 | 含义 | 异常处理 |
|---|---|---|
| `Replica_IO_Running` | IO 线程拉 binlog | `No` → 网络/账号/`server_id` 冲突 |
| `Replica_SQL_Running` | SQL 线程回放 | `No` → 看 `Last_Error`，多数是数据冲突/对象缺失 |
| `Seconds_Behind_Source` | 延迟秒数 | **有盲区，见下** |
| `Relay_Log_Space` | relay log 占用 | 持续增长 → 回放跟不上 |
| `Retrieved_Gtid_Set` / `Executed_Gtid_Set` | 已拉取/已执行 | 差值就是待回放事务 |
| `Last_Error` | 最后一次错误 | 复制中断的第一现场 |

#### 盲区：大事务期间 `Seconds_Behind_Source` 可能一直是 0

实测：主库一次提交 30 万行，从库回放期间每 0.5s 采样：

```
t+0.5s lag=0s
t+1.0s lag=0s
...
t+6.0s lag=0s
```

同时从库确实在回放，最终数据一致（160 万行对 160 万行）。

原因：`Seconds_Behind_Source` 基于**事件时间戳**计算，单个大事务在提交前不更新 `last_master_timestamp`，所以看起来"没延迟"，实际 SQL 线程已经卡了很久。

**更可靠的延迟监控**：

```bash
pt-heartbeat --host=master --update --interval=1
pt-heartbeat --host=replica --monitor --interval=1
```

或看 `performance_schema.replication_applier_status_by_worker` 的 `SERVICE_STATE`、`LAST_ERROR_MESSAGE`，以及 `Relay_Log_Space` 的增速。

#### 并行回放

```sql
SHOW VARIABLES WHERE Variable_name IN
  ('replica_parallel_workers','replica_parallel_type',
   'replica_preserve_commit_order','replica_pending_jobs_size_max');
```

本环境：

```
replica_parallel_type        LOGICAL_CLOCK
replica_parallel_workers     4
replica_preserve_commit_order ON
```

`LOGICAL_CLOCK` 能按组提交并行回放；但**单个大事务无法被拆分**，这是大事务导致延迟的根本原因。

#### 复制延迟的六个常见原因

| 原因 | 判断 | 处置 |
|---|---|---|
| 大事务 | 单事务几十万行 | 拆小批（每批 1000~5000 行） |
| 无主键表 | ROW 格式回放要全表扫 | 加主键 |
| 从库规格低 | 从库 CPU/IO 打满 | 升配 / 加并行 |
| 单线程回放 | `replica_parallel_workers=0` | 开 `LOGICAL_CLOCK` |
| 大 DDL | `ALTER` 在从库串行执行 | 用 gh-ost/pt-osc，或先在从库执行 |
| 从库承担读流量 | 慢查询占满从库 | 读流量隔离 / 加只读副本 |

### 8.4 架构类问题的判断

| 现象 | 可能架构问题 |
|---|---|
| 写后读不一致 | 读写分离延迟 |
| 单表过亿，查询越来越慢 | 需要分库分表/归档 |
| 热点商品/热点账户 | 单行锁竞争，需要拆分热点 |
| 跨库 JOIN 变多 | 分库分表粒度设计问题 |
| 从库数量增加但读性能不涨 | 读流量分配不均 / 从库延迟 |

---

## 9. 附录

### 9.1 五类问题速查表

| 类别 | 一句话判断 | 第一命令 | 典型修复 |
|---|---|---|---|
| 慢查询 | digest 里 `SUM_NO_INDEX_USED>0`，`type=ALL/index` | `EXPLAIN ANALYZE` | 加索引/改写 SQL |
| 锁 | `Innodb_row_lock_waits` 涨，state 含 lock | `sys.innodb_lock_waits` | 缩短事务/加索引/统一顺序 |
| 连接 | 1040 或 `Threads_connected` 到顶 | `processlist` 聚合 | 调池/修泄漏/限流 |
| 资源 | CPU/IO/内存饱和，SQL 本身不差 | `docker stats` + `iostat` | 升配/加缓存/限流 |
| 配置复制 | 重启后变快 / 从库慢 | `SHOW VARIABLES` + `SHOW REPLICA STATUS` | 调参/拆事务/并行回放 |

### 9.2 参数速查

| 参数 | 默认 | 建议 | 动态 |
|---|---|---|---|
| `innodb_buffer_pool_size` | 128M | 物理内存 50%~70% | ✅（8.0） |
| `max_connections` | 151 | 按池大小反推 | ✅ |
| `innodb_flush_log_at_trx_commit` | 1 | 支付 1，日志 2 | ✅ |
| `sync_binlog` | 1 | 支付 1，日志 0 | ✅ |
| `tmp_table_size` / `max_heap_table_size` | 16M | 64M，两者同步 | ✅ |
| `sort_buffer_size` | 256K | 1~4M（乘连接数算内存） | ✅ |
| `innodb_io_capacity` | 200 | SSD 2000~8000 | ✅ |
| `innodb_redo_log_capacity` | 100M | 1~4G | ✅（8.0.30+） |
| `long_query_time` | 10 | 0.1~1 | ✅ |
| `innodb_lock_wait_timeout` | 50 | 5~10 | ✅ |
| `innodb_print_all_deadlocks` | OFF | ON | ✅ |
| `replica_parallel_workers` | 4 | 4~16 | ✅（需重启复制） |

### 9.3 演示脚本清单

| 脚本 | 作用 | 运行命令 |
|---|---|---|
| `00-up.sh` | 启动容器、建表、造数 | `bash demo/scripts/00-up.sh` |
| `lib.sh` | 公共函数（计时、慢日志重置、digest 排行）；首次 source 自动生成凭据文件 `.my-*.cnf`（600 权限，不入库） | 被其他脚本 source |
| `10-case1-slow-sql.sh` | 案例一：7 条慢 SQL + 优化对比（含隐式转换、统计过期） | `bash demo/scripts/10-case1-slow-sql.sh > demo/logs/case1.out 2>&1` |
| `20-case2-lock.sh` | 案例二：行锁/锁全表/长事务+purge 量化/MDL/死锁/间隙锁 | `bash demo/scripts/20-case2-lock.sh > demo/logs/case2.out 2>&1` |
| `30-case3-connections.sh` | 案例三：线程打满 + 连接打满 | `bash demo/scripts/30-case3-connections.sh > demo/logs/case3.out 2>&1` |
| `40-case4-resources.sh` | 案例四：CPU/内存/IO/临时表/网络/重启预热 | `bash demo/scripts/40-case4-resources.sh > demo/logs/case4.out 2>&1` |
| `50-case5-config-repl.sh` | 案例五：配置实测 + 表膨胀碎片 + 主从复制 | `bash demo/scripts/50-case5-config-repl.sh > demo/logs/case5.out 2>&1` |
| `diagnose.sh` | 自动分流诊断：信号采集→阈值判定→决策树归类 | `bash demo/scripts/diagnose.sh > demo/logs/diagnose.out 2>&1` |
| `baseline.sh` | 基线快照与趋势对比 | `bash demo/scripts/baseline.sh save <tag>` / `diff <t1> [t2]` / `list` |
| `99-down.sh` | 结束清理：轻量清演示残留（默认）/ `--all` 彻底回收 | `bash demo/scripts/99-down.sh` 或 `bash demo/scripts/99-down.sh --all` |
| `99-health-check.sql` | 一键巡检（含判定列） | `mysql ... < demo/sql/99-health-check.sql > demo/logs/health.out 2>&1` |
| `01-schema.sql` / `02-seed.sql` | 表结构与造数 | 由 `00-up.sh` 自动执行 |

> 脚本只往标准输出打印，**不会自己创建 `.out` 文件**；上面的 `>` 由你决定写到哪，同名文件会被覆盖。
> 演示结束后跑 `99-down.sh` 回收脏数据（演示表/索引/复制通道/被改动的业务行/慢日志），`--all` 连容器与数据卷一起删。

### 9.4 排障 Checklist（可直接贴到工单）

```
□ 1. 现象：哪些接口慢？从什么时候开始？是否与发布/大促/数据量相关？
□ 2. 范围：单条 SQL / 单表 / 整库 / 整个实例？
□ 3. 分段：连接池等待 / 网络 / DB 执行 / 结果集传输，各占多少？
□ 4. 连接：Threads_running 与 Threads_connected 各是多少？Sleep 占比？
□ 5. 慢查：最近 10 分钟 Top5 SQL 是什么？Rows_examined / Rows_sent 比值？
□ 6. 执行计划：type 是什么？有没有 filesort/temporary？key 用对了吗？
□ 7. 锁：innodb_trx 有无超过 60s 的事务？innodb_lock_waits 有无等待？
□ 8. 资源：CPU、内存命中率、iowait、网络带宽，哪一项先到瓶颈？
□ 9. 复制：从库 IO/SQL 线程状态？Seconds_Behind_Source？Last_Error？
□ 10. 变更：最近有没有改 SQL、加字段、调参数、升级版本？
□ 11. 止血方案是什么？回滚方案是什么？
□ 12. 根因是什么？如何防止复发（索引规范/慢查门禁/容量评估）？
```

### 9.5 三条经验

1. **先判断，再动手。** 五类问题里，只有一类是真的"数据库不行"，其余四类都能通过改 SQL、改代码、改配置解决。
2. **指标要看趋势和分布，不要看瞬时值。** 累计命中率 99.99% 不代表当前没问题（案例四里当前值是 98.4%）。
3. **每一个"慢"都要落到一条具体的 SQL、一个具体的锁、一个具体的参数上。** 落不到，就说明还没定位完。

---

> 文档中的所有实验数据来自 `demo/logs/case1.out` ~ `case5.out`，可用 `demo/scripts/` 下的脚本复现。
