#!/usr/bin/env bash
# LibreTV 本地构建部署脚本（服务器端使用）
#
# 用途：把当前目录的源码构建成 Docker 镜像并重启容器。
# 与 `docker compose pull` 的区别：pull 拿的是上游官方镜像，本脚本构建的是
# 本仓库当前代码（含我们改过的移动端适配）。
#
# 用法：
#   ./deploy-local.sh            # 构建 + 启动
#   ./deploy-local.sh logs       # 构建 + 启动后跟踪日志
#   ./deploy-local.sh down       # 停止并移除容器（不动镜像）
#
# 前置条件：
#   - 已安装 Docker 与 docker compose v2（docker compose version 能执行）
#   - 仓库根目录存在 .env，且其中有 PASSWORD=...
#   - 建议至少 2GB 可用内存（Next.js 构建较吃内存）
set -euo pipefail

cd "$(dirname "$0")"

COMPOSE_BASE=docker-compose.yml
COMPOSE_LOCAL=docker-compose.local.yml
COMPOSE="docker compose -f ${COMPOSE_BASE} -f ${COMPOSE_LOCAL}"

if ! docker compose version >/dev/null 2>&1; then
  echo "❌ 未检测到 docker compose v2，请先安装 Docker Compose 插件" >&2
  exit 1
fi

if [ ! -f .env ]; then
  echo "❌ 缺少 .env 文件。请先创建，至少包含：" >&2
  echo "   PASSWORD=你的访问密码" >&2
  exit 1
fi

if ! grep -qE '^\s*PASSWORD=.+' .env; then
  echo "❌ .env 中缺少 PASSWORD=...，compose 启动会直接报错。" >&2
  exit 1
fi

case "${1:-up}" in
  down)
    $COMPOSE down
    exit 0
    ;;
  logs)
    shift || true
    ;;
  up)
    shift || true
    ;;
  *)
    ;;
esac

echo "==> 构建镜像（源码：$(pwd)）"
$COMPOSE build

echo "==> 启动/更新容器"
$COMPOSE up -d --remove-orphans

echo "==> 当前状态"
$COMPOSE ps

echo "==> 健康检查：等待 http://127.0.0.1:8080/api/status 就绪"
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8080/api/status >/dev/null 2>&1; then
    echo "✅ 服务已就绪"
    curl -fsS --max-time 2 http://127.0.0.1:8080/api/status || true
    echo
    break
  fi
  sleep 1
  if [ "$i" -eq 30 ]; then
    echo "⚠️  30 秒内未通过健康检查，请查看日志：$COMPOSE logs --tail=100" >&2
  fi
done

if [ "${1:-}" = "logs" ]; then
  $COMPOSE logs -f --tail=100
fi
