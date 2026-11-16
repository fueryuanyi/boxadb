#!/usr/bin/env bash
# ============================================================
# purge-cache —— 清 Cloudflare 上 box.fueryuanyi.com 的缓存
#
# 为什么要这个脚本：CF 对 .js / .css / .png 这类静态扩展默认缓存 4 小时
# （响应头 cache-control: max-age=14400），源站改了它不跟着改。
# 更坑的是源站曾返回过「200 + 空 body」，CF 把空响应当正经内容缓存了，
# 前端就成了白板页面 —— 见到 cf-cache-status: HIT 且 content-length: 0，
# 先来清缓存，别去怀疑 Caddy。
#
# 权限要求：CF API Token 需要 **Zone → Cache Purge → Purge** 权限。
#   ~/.cloudflare-api-token 或环境变量 CF_API_TOKEN 均可，但必须是带
#   Cache Purge 的那把 —— 只有 Edit zone DNS 的 token 会返回
#   「Authentication error」。
#   没有的话就去面板手动点：Caching → Configuration → Purge Everything。
#
# 用法：
#   ./deploy/purge-cache.sh                 # 清整站（purge_everything）
#   ./deploy/purge-cache.sh https://box.fueryuanyi.com/js/app.js [...]   # 只清指定 URL
# ============================================================
set -euo pipefail

ZONE_NAME="${CF_ZONE_NAME:-fueryuanyi.com}"
TOKEN="${CF_API_TOKEN:-$(cat "$HOME/.cloudflare-api-token" 2>/dev/null || true)}"
[ -n "$TOKEN" ] || { echo "!! 没有 CF token（~/.cloudflare-api-token 或 CF_API_TOKEN）" >&2; exit 1; }

API="https://api.cloudflare.com/client/v4"

zone_id=$(curl -s "$API/zones?name=$ZONE_NAME" -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"][0]["id"] if d.get("result") else "")')
[ -n "$zone_id" ] || { echo "!! 查不到 zone $ZONE_NAME（token 权限？）" >&2; exit 1; }
echo "zone $ZONE_NAME = $zone_id"

if [ $# -gt 0 ]; then
  body=$(python3 -c 'import json,sys; print(json.dumps({"files": sys.argv[1:]}))' "$@")
  echo "→ 按 URL 清：$*"
else
  body='{"purge_everything":true}'
  echo "→ 清整站（purge_everything）"
fi

resp=$(curl -s -X POST "$API/zones/$zone_id/purge_cache" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data "$body")

python3 - "$resp" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
if d.get("success"):
    print("✅ 已提交清理")
else:
    print("❌ 失败：", d.get("errors"))
    print("   提示：只有 Edit zone DNS 权限的 token 会报 Authentication error，"
          "需要 Cache Purge 权限；或者去面板 Caching → Configuration → Purge Everything。")
    sys.exit(1)
PY
