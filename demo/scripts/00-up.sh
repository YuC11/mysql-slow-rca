#!/usr/bin/env bash
# 启动演示用 MySQL 8.0：1C1G 限流，命名卷持久化
# 用法：
#   bash demo/scripts/00-up.sh          # 启动 + 建表 + 造数
#   RESET=1 bash demo/scripts/00-up.sh  # 删库重来
set -eu
cd "$(dirname "$0")/../.."

NAME=mysql-demo
VOL=mysql-demo-data
PORT=13306

reset() {
  echo ">> 清理旧容器/卷"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
}

if [ "${RESET:-0}" = "1" ]; then reset; fi
if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  echo ">> 容器已存在，直接启动"
  docker start "$NAME" >/dev/null
else
  docker volume create "$VOL" >/dev/null
  echo ">> 启动容器：--memory=1g --cpus=2"
  docker run -d --name "$NAME" \
    --memory=1g --memory-swap=1g --cpus=2 \
    -p ${PORT}:3306 \
    -e MYSQL_ROOT_PASSWORD=root123 \
    -e MYSQL_DATABASE=shopdb \
    -e MYSQL_USER=user1 \
    -e MYSQL_PASSWORD=passwd1 \
    -v "$PWD/demo/conf/my.cnf:/etc/mysql/conf.d/demo.cnf:ro" \
    -v "$PWD/demo/logs:/var/log/mysql" \
    -v "$VOL":/var/lib/mysql \
    mysql:8.0 --character-set-server=utf8mb4 --collation-server=utf8mb4_0900_ai_ci >/dev/null
fi

echo ">> 等待就绪"
for i in $(seq 1 80); do
  if docker exec "$NAME" mysqladmin ping -uroot -proot123 --silent >/dev/null 2>&1; then
    echo "   ready (${i}x2s)"; break
  fi
  sleep 2
done

M="mysql --defaults-extra-file=demo/scripts/.my-root.cnf -h127.0.0.1 -P${PORT}"

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
