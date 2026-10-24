#!/usr/bin/env bash
# 启动演示用 MySQL 8.0：1C1G 限流，命名卷持久化
# 用法：
#   bash demo/scripts/00-up.sh          # 启动 + 建表 + 造数
#   RESET=1 bash demo/scripts/00-up.sh  # 删库重来
#   CPUS=1 MEM=2g bash demo/scripts/00-up.sh
#                                       # 自定义容器资源规格（默认 2核 / 1G）。
#                                       # 容器已存在时自动 docker update 热改限制，
#                                       # 无需重建；数据不受影响
#   MYSQL_ARGS="--max_connections=100 --innodb_buffer_pool_size=256M" \
#     bash demo/scripts/00-up.sh        # 追加自定义 mysqld 参数（命令行级，
#                                       # 优先级高于 conf/my.cnf；仅容器创建时
#                                       # 生效，改参数需 RESET=1 重建）
set -eu
cd "$(dirname "$0")/../.."
source demo/scripts/lib.sh

NAME=mysql-demo
VOL=mysql-demo-data
PORT=13306

# 容器资源规格：刻意模拟"小规格云数据库"，可按需覆盖
CPUS_SET=${CPUS+x}; MEM_SET=${MEM+x}
CPUS=${CPUS:-2}
MEM=${MEM:-1g}

reset() {
  echo ">> 清理旧容器/卷"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
}

if [ "${RESET:-0}" = "1" ]; then reset; fi
if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  echo ">> 容器已存在，直接启动"
  [ -n "${MYSQL_ARGS:-}" ] && echo "!! 注意：MYSQL_ARGS 只在容器创建时生效，本次未应用。要生效请：RESET=1 bash demo/scripts/00-up.sh"
  docker start "$NAME" >/dev/null
  if [ -n "$CPUS_SET$MEM_SET" ]; then
    echo ">> 热改资源限制：--cpus=${CPUS} --memory=${MEM}（docker update，无需重建）"
    docker update --cpus "$CPUS" --memory "$MEM" --memory-swap "$MEM" "$NAME" >/dev/null \
      || echo "!! docker update 失败：目标内存可能低于当前实际占用，或容器已删除"
  fi
else
  docker volume create "$VOL" >/dev/null
  echo ">> 启动容器：--cpus=${CPUS} --memory=${MEM}"
  [ -n "${MYSQL_ARGS:-}" ] && echo ">> 追加自定义参数：${MYSQL_ARGS}（优先级高于 conf/my.cnf）"
  docker run -d --name "$NAME" \
    --memory=${MEM} --memory-swap=${MEM} --cpus=${CPUS} \
    -p ${PORT}:3306 \
    -e MYSQL_ROOT_PASSWORD=root123 \
    -e MYSQL_DATABASE=shopdb \
    -e MYSQL_USER=user1 \
    -e MYSQL_PASSWORD=passwd1 \
    -v "$PWD/demo/conf/my.cnf:/etc/mysql/conf.d/demo.cnf:ro" \
    -v "$PWD/demo/logs:/var/log/mysql" \
    -v "$VOL":/var/lib/mysql \
    mysql:8.0 --character-set-server=utf8mb4 --collation-server=utf8mb4_0900_ai_ci ${MYSQL_ARGS:-} >/dev/null
fi

echo ">> 等待就绪"
for i in $(seq 1 80); do
  if docker exec "$NAME" mysqladmin ping -uroot -proot123 --silent >/dev/null 2>&1; then
    echo "   ready (${i}x2s)"; break
  fi
  sleep 2
done

M="$ROOT"

if ! $M -N -e "SELECT 1 FROM information_schema.tables WHERE table_schema='shopdb' AND table_name='orders'" 2>/dev/null | grep -q 1; then
  echo ">> 建表"
  $M < demo/sql/01-schema.sql
  echo ">> 造数（约 1 分钟）"
  $M < demo/sql/02-seed.sql
else
  echo ">> 数据已存在，跳过建表造数"
fi

$M -e "SET GLOBAL slow_query_log=OFF;" 2>/dev/null || true
: > demo/logs/slow.log
$M -e "SET GLOBAL slow_query_log=ON;" 2>/dev/null || true

echo ">> 连接信息：mysql -h127.0.0.1 -P${PORT} -uuser1 -ppasswd1 shopdb"
$M -e "SELECT VERSION() ver, @@max_connections max_conn,
       @@innodb_buffer_pool_size/1024/1024 bp_mb, @@slow_query_log slow_log,
       @@long_query_time lqt, @@gtid_mode gtid;" 2>/dev/null
