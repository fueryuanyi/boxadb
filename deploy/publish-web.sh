#!/usr/bin/env bash
# ============================================================
# publish-web —— 把仓库里的静态前端发布到 VPS（box.fueryuanyi.com）
#
# 只发页面需要的四样东西：index.html / css / js / assets。
# bridge.go、workflow 之类不上线（桥接是跑在本机的二进制）。
#
# 用法：
#   ./deploy/publish-web.sh            # 真发布
#   ./deploy/publish-web.sh --dry-run  # 演练（rsync -n）
#
# 前置：SSH 别名 vps 可用（~/.ssh/config），远端目录 /var/www/boxadb 归 root。
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE_HOST="${REMOTE_HOST:-vps}"
REMOTE_DIR="${REMOTE_DIR:-/var/www/boxadb}"
DRY=""
[ "${1:-}" = "--dry-run" ] && DRY="-n"

echo "→ rsync → ${REMOTE_HOST}:${REMOTE_DIR}"
rsync -az --delete ${DRY} \
  -e "ssh -o StrictHostKeyChecking=accept-new" \
  index.html css js assets \
  "${REMOTE_HOST}:${REMOTE_DIR}/"

if [ -z "$DRY" ]; then
  echo "→ 校验证书与响应"
  curl -fsS -o /dev/null -w '   https 状态 %{http_code}  用时 %{time_total}s\n' https://box.fueryuanyi.com/
fi
