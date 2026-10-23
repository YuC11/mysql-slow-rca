# MySQL 变慢：诊断与演示

主文档：**[MySQL变慢五类问题-诊断演示手册.md](MySQL变慢五类问题-诊断演示手册.md)**

## 快速开始

```bash
# 1. 拉起演示库（Docker，2核1G，MySQL 8.0）
bash demo/scripts/00-up.sh

# 2. 逐个案例跑（每个脚本都会打印定位命令的真实输出）
bash demo/scripts/10-case1-slow-sql.sh
bash demo/scripts/20-case2-lock.sh
bash demo/scripts/30-case3-connections.sh
bash demo/scripts/40-case4-resources.sh
bash demo/scripts/50-case5-config-repl.sh

# 3. 一键巡检
mysql -h127.0.0.1 -P13306 -uroot -proot123 < demo/sql/99-health-check.sql
```

- 连接：`user1 / passwd1`（业务）、`root / root123`（诊断）
- 端口：`13306`；从库：`13307`
- 数据：订单 100 万 / 明细 200 万 / 支付 90 万

## 目录

```
demo/
├── conf/my.cnf               # 演示实例配置（128M buffer pool / max_connections 50）
├── sql/
│   ├── 01-schema.sql         # 电商交易表结构
│   ├── 02-seed.sql           # 确定性造数
│   └── 99-health-check.sql   # 一键巡检
├── scripts/
│   ├── 00-up.sh              # 启动 + 建表 + 造数
│   ├── lib.sh                # 公共函数
│   ├── 10~50-case*.sh        # 五个案例
│   └── ...
└── logs/                     # 每轮实跑的输出 case1.out ~ case5.out
```

## 五类问题

| 类别 | 核心判断信号 | 章节 |
|---|---|---|
| 慢查询 / SQL 效率 | `type=ALL/index`、`Rows_examined >> Rows_sent` | §4 |
| 锁竞争 / 长事务 | `Innodb_row_lock_waits`、`innodb_trx.age` | §5 |
| 连接数 / 连接池 | `Threads_connected` 到顶、大量 `Sleep` | §6 |
| 服务器资源 | CPU / 命中率 / `iostat` / `Bytes_sent` | §7 |
| 配置 / 架构 / 复制 | 重启后变快、`SHOW REPLICA STATUS` | §8 |
