#!/usr/bin/env bash
# ============================================================
# install-on-openwrt —— 把桥装到一台 OpenWrt 路由器上，让它成为「该地点的耳朵」
#
# 装完的状态：bridge 以 procd 服务常驻，只监听路由器自己的 127.0.0.1:8765，
# 不开防火墙端口、不做端口转发 —— 外部完全够不到，只能靠
#   ssh -N -L 127.0.0.1:8765:127.0.0.1:8765 root@<router>
# 把这条回环搬到你的电脑上（deploy/boxadb-net.sh 就是在干这个）。
#
# 用法：
#   ./deploy/openwrt/install-on-openwrt.sh root@192.168.8.1 home
#   ./deploy/openwrt/install-on-openwrt.sh root@100.123.156.12 home   # 走 tailnet
#
#   $1 = ssh 目标       $2 = 地点名（写进 BRIDGE_NAME，/health 会回显）
#
# 前置：本机 ssh 到该路由器免密可用；路由器能访问 GitHub（走代理或用本地二进制：
#       BOXADB_BIN=/path/to/boxadb-bridge-linux-arm64 可跳过下载）。
# ============================================================
set -euo pipefail

TARGET="${1:-}"; SITE="${2:-home}"
[ -n "$TARGET" ] || { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

REPO="fueryuanyi/boxadb"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOCAL_BIN="${BOXADB_BIN:-}"
INIT="$HERE/boxadb-bridge.init"

echo "→ 目标 $TARGET，地点名 $SITE"

# 1) 判断路由器架构，挑对应二进制
arch=$(ssh -o ConnectTimeout=8 "$TARGET" 'uname -m')
case "$arch" in
  aarch64|arm64) ART="boxadb-bridge-linux-arm64" ;;
  x86_64|amd64)  ART="boxadb-bridge-linux-amd64" ;;
  *) echo "!! 不支持的架构：$arch" >&2; exit 1 ;;
esac
echo "→ 架构 $arch → $ART"

# 2) 二进制就位（优先用本机已有文件，免去路由器翻墙下载）
if [ -z "$LOCAL_BIN" ]; then
  LOCAL_BIN="$(mktemp -t boxadb-bridge)"
  echo "→ 下载 $ART（release latest）"
  curl -fL --max-time 180 -o "$LOCAL_BIN" \
    "https://github.com/$REPO/releases/latest/download/$ART"
fi
ls -l "$LOCAL_BIN"

echo "→ 上传二进制与 init 脚本"
scp -q "$LOCAL_BIN" "$TARGET:/usr/bin/boxadb-bridge"
scp -q "$INIT"      "$TARGET:/etc/init.d/boxadb-bridge"

# 3) 重新签发地点名、起服务、开机自启
ssh "$TARGET" "
  set -e
  chmod +x /usr/bin/boxadb-bridge /etc/init.d/boxadb-bridge
  sed -i 's/^BRIDGE_NAME_VALUE=.*/BRIDGE_NAME_VALUE=$SITE/' /etc/init.d/boxadb-bridge
  /etc/init.d/boxadb-bridge enable
  /etc/init.d/boxadb-bridge restart
  sleep 2
  echo '--- /health ---'
  curl -s --max-time 3 http://127.0.0.1:8765/health || echo '(没应答)'
  echo '--- 监听 ---'
  netstat -ltn 2>/dev/null | grep 8765 || echo '(没有 8765 监听)'
"

echo
echo "✅ 装好了。用它："
echo "   boxadb-net use $SITE     # 浏览器 127.0.0.1:8765 会指向这台路由器所在的网段"
echo "   boxadb-net probe <该网段的某个IP> 80    # 验证是不是真的在那个网里"
