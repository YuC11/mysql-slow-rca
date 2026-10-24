# 状态

已完成：环境、五个案例脚本与实跑输出（demo/logs/case1~5.out）、主文档、工具化三层（diagnose / baseline / 99-down）。

- 主文档：`../MySQL变慢五类问题-诊断演示手册.md`
- 环境重建：`RESET=1 bash demo/scripts/00-up.sh`；结束清理：`bash demo/scripts/99-down.sh`（`--all` 彻底删）
- 诊断工具：`diagnose.sh`（自动分流）→ `baseline.sh save/diff`（趋势对比）
- 从库：`mysql-replica`（13307），由 `50-case5-config-repl.sh` 自建；从库需预建库+表（gtid_purged 坑，见手册 §8.3）
- 实跑产物：`demo/logs/case1~5.out`、`diagnose.out`、`diagnose-replica.out`、`health.out`、`down.out`、`demo/baselines/post-clean.txt`
