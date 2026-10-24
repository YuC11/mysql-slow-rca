# MySQL 变慢：诊断与演示

主文档：**[MySQL变慢五类问题-诊断演示手册.md](MySQL变慢五类问题-诊断演示手册.md)**

## 快速开始

```bash
# 1. 拉起演示库（Docker，2核1G，MySQL 8.0）
bash demo/scripts/00-up.sh

# 2. 逐个案例跑（每个脚本都会打印定位命令的真实输出）
bash demo/scripts/10-case1-slow-sql.sh  > demo/logs/case1.out 2>&1
bash demo/scripts/20-case2-lock.sh      > demo/logs/case2.out 2>&1
bash demo/scripts/30-case3-connections.sh > demo/logs/case3.out 2>&1
bash demo/scripts/40-case4-resources.sh > demo/logs/case4.out 2>&1
bash demo/scripts/50-case5-config-repl.sh > demo/logs/case5.out 2>&1

# 3. 一键巡检 + 自动分流诊断 + 基线快照
mysql --defaults-extra-file=demo/scripts/.my-root.cnf -h127.0.0.1 -P13306 \
  < demo/sql/99-health-check.sql > demo/logs/health.out 2>&1
bash demo/scripts/diagnose.sh > demo/logs/diagnose.out 2>&1
bash demo/scripts/baseline.sh save before

# 4. 结束清理：回收演示脏数据（保留容器与业务数据）
bash demo/scripts/99-down.sh
#    彻底清理（连容器/数据卷/日志一起删）：bash demo/scripts/99-down.sh --all
```

- 连接：`user1 / passwd1`（业务）、`root / root123`（诊断）；脚本凭据走 `demo/scripts/.my-*.cnf`（首次运行自动生成，600 权限，不入库）
- 端口：`13306`；从库：`13307`
- 数据：订单 100 万 / 明细 200 万 / 支付 90 万

## 目录

```
demo/
├── conf/my.cnf               # 演示实例配置（128M buffer pool / max_connections 50）
├── sql/
│   ├── 01-schema.sql         # 电商交易表结构
│   ├── 02-seed.sql           # 确定性造数
│   └── 99-health-check.sql   # 一键巡检（含 PASS/WARN/FAIL 判定列）
├── scripts/
│   ├── 00-up.sh              # 启动 + 建表 + 造数
│   ├── lib.sh                # 公共函数（bench/digest 排行/慢日志重置）
│   ├── 10~50-case*.sh        # 五个案例（7 类慢 SQL、锁+purge 量化、连接、资源+预热、配置+碎片+复制）
│   ├── diagnose.sh           # 自动分流诊断：五信号判定 → 决策树归类案例一~五
│   ├── baseline.sh           # 基线快照：save/diff 看趋势
│   └── 99-down.sh            # 结束清理（轻量 / --all 彻底）
├── logs/                     # 实跑输出：case1~5.out / diagnose.out / health.out / down.out / slow.log
└── baselines/                # 基线快照存放处
```

## 五类问题

| 类别 | 核心判断信号 | 章节 |
|---|---|---|
| 慢查询 / SQL 效率 | `type=ALL/index`、`Rows_examined >> Rows_sent` | §4 |
| 锁竞争 / 长事务 | `Innodb_row_lock_waits`、`innodb_trx.age`、purge gap | §5 |
| 连接数 / 连接池 | `Threads_connected` 到顶、大量 `Sleep` | §6 |
| 服务器资源 | CPU / 命中率 / `iostat` / `Bytes_sent` / 重启预热 | §7 |
| 配置 / 架构 / 复制 | 重启后变快、`SHOW REPLICA STATUS`、表膨胀 | §8 |

环境重建：`RESET=1 bash demo/scripts/00-up.sh`；从库：`mysql-replica`（13307，由 case5 脚本自建）。
