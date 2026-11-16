#!/usr/bin/env bash
# ============================================================
# boxadb-net —— 「人在哪儿跟哪儿同网」：把浏览器的 127.0.0.1:8765 指向不同地点的桥
#
# 痛点：盒子助手的前端写死了 BRIDGE_BASE=http://127.0.0.1:8765，一个浏览器只能
# 看到一个桥。但桥必须在目标盒子所在的局域网里 —— 想操作老家的电视，就得让
# 「本机回环 8765」这条线通到老家的桥上去。
#
# 做法（不暴露任何端口、不改前端）：
#   local  本机直接跑 boxadb-bridge（能碰当前所在网段的设备）
#   <site> ssh -N -L 127.0.0.1:8765:127.0.0.1:8765 到该地点常开主机
#           → 远端桥仍只绑它自己的回环，全靠 SSH 隧道搬过来
# 浏览器侧永远是 ws://127.0.0.1:8765（回环不受 https 混合内容限制），不用改页面。
#
# 配置：~/.config/boxadb/sites.conf，每行 <名字>\t<说明>\t<目标>
#   目标是 local（本机跑桥）或 ssh:user@host（该地点常开主机的 tailnet 地址/IP）
#
# 用法：
#   boxadb-net                  # 同 status
#   boxadb-net status           # 当前指向谁 + 各地点通不通
#   boxadb-net use <名字>       # 切换（local/home/...）
#   boxadb-net off              # 全关，端口释放（上游设计：不用就别常驻）
#   boxadb-net probe <ip> [端口]  # 用当前桥连一下 ip:port，看对端返回什么（验「同网」）
# ============================================================
set -uo pipefail

CONF="${BOXADB_NET_CONF:-$HOME/.config/boxadb/sites.conf}"
STATE_DIR="${BOXADB_NET_STATE:-$HOME/.local/state/boxadb}"
PIDFILE="$STATE_DIR/endpoint.pid"
NAMEFILE="$STATE_DIR/current"
LOG="$STATE_DIR/endpoint.log"
BRIDGE_BIN="${BOXADB_BRIDGE:-$HOME/Applications/BoxADB Bridge/boxadb-bridge}"
PORT="${BOXADB_PORT:-8765}"
BASE="http://127.0.0.1:$PORT"

mkdir -p "$STATE_DIR"
mkdir -p "$(dirname "$CONF")"

# 首次运行写一份默认配置（老家是当前唯一有常开主机的地点）
if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<EOF
# boxadb-net 地点表：<名字><TAB><说明><TAB><目标>
#   目标 = local          本机直接跑桥（只够到当前所在网段）
#   目标 = ssh:user@host  该地点的常开主机（tailnet 地址最稳，IP 变了才要改）
# 加地点只加一行，别改脚本。
local	本机（当前所在网段）	local
home	老家 192.168.8.0/24	ssh:root@100.123.156.12
travel	MT3000 随身网段 192.168.12.0/24	ssh:root@100.122.230.50
EOF
  echo "已生成配置：$CONF"
fi

say()  { printf '%s\n' "$*"; }
die()  { printf '!! %s\n' "$*" >&2; exit 1; }

health() { curl -s --max-time 2 "$BASE/health" 2>/dev/null | tr -d '\n'; }

# 当前 8765 是谁在听（PID）
listener_pid() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $2}'; }

site_names() { awk -F'\t' '!/^#/ && NF>=3 {print $1}' "$CONF"; }

site_row() { awk -F'\t' -v n="$1" '!/^#/ && $1==n {print; exit}' "$CONF"; }

# 停掉当前占用方（只停我们自己的：pidfile 里记的，或确认是 boxadb-bridge / 我们起的 ssh -L）
stop_current() {
  local pid
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null || break; sleep 0.3; done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
  fi
  # 兜底 1：还没绑上端口（或绑失败卡住）的隧道进程也要收掉
  for p in $(pgrep -f "ssh -N .*-L 127\.0\.0\.1:$PORT:127\.0\.0\.1:$PORT" 2>/dev/null); do
    kill "$p" 2>/dev/null || true
  done

  # 兜底 2：端口上如果还剩我们自己的进程，一并收掉
  pid=$(listener_pid)
  if [ -n "${pid:-}" ]; then
    local cmd
    cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
    case "$cmd" in
      *boxadb-bridge*|*"ssh -N"*"$PORT:127.0.0.1:$PORT"*) kill "$pid" 2>/dev/null || true; sleep 0.5 ;;
    esac
  fi
  rm -f "$NAMEFILE"
}

wait_health() { # $1=期望名字（空=只要有人应答）  $2=最长秒数
  local want="${1:-}" max="${2:-20}" i body
  for i in $(seq 1 $((max * 2))); do
    body=$(health)
    if [ -n "$body" ]; then
      if [ -z "$want" ] || printf '%s' "$body" | grep -q "($want)"; then printf '%s' "$body"; return 0; fi
    fi
    sleep 0.5
  done
  return 1
}

cmd_status() {
  printf '%-8s  %s\n' "地点" "说明"
  local cur="" body; body=$(health)
  printf '%s' "$body" | grep -q '(' && cur=$(printf '%s' "$body" | sed -n 's/.*(\(.*\))/\1/p')

  while IFS=$'\t' read -r name desc target; do
    case "$name" in ''|'#'*) continue ;; esac
    local st="待用"
    if [ "$cur" = "$name" ]; then
      st="◀ 当前（$body）"
    elif [ "$target" = "local" ]; then
      [ -x "$BRIDGE_BIN" ] && st="可用" || st="缺二进制：$BRIDGE_BIN"
    else
      local host="${target#ssh:}"
      if ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 "$host" 'true' 2>/dev/null; then st="可达"; else st="连不上"; fi
    fi
    printf '  %-8s %s\n           → %s\n' "$name" "$desc" "$st"
  done < "$CONF"

  local pid; pid=$(listener_pid)
  if [ -n "${pid:-}" ]; then
    printf '\n端口 %s 由 PID %s 持有：%s\n' "$PORT" "$pid" "$(ps -p "$pid" -o command= 2>/dev/null)"
  else
    printf '\n端口 %s 空闲（桥没跑，浏览器连设备会失败）\n' "$PORT"
  fi
}

cmd_use() {
  local name="${1:-}" row desc target
  [ -n "$name" ] || die "用法：boxadb-net use <名字>（可选：$(site_names | tr '\n' ' '))"
  row=$(site_row "$name"); [ -n "$row" ] || die "配置里没有地点：$name"
  desc=$(printf '%s' "$row" | cut -f2); target=$(printf '%s' "$row" | cut -f3)

  local body; body=$(health)
  if printf '%s' "$body" | grep -q "($name)"; then
    say "已经指向 $name（$body）—— 无需切换"; return 0
  fi

  stop_current

  if [ "$target" = "local" ]; then
    [ -x "$BRIDGE_BIN" ] || die "找不到本机桥：$BRIDGE_BIN（先跑 install.sh）"
    BRIDGE_NAME="$name" nohup "$BRIDGE_BIN" >>"$LOG" 2>&1 &
    echo $! > "$PIDFILE"
  else
    local host="${target#ssh:}"
    local hport="${host#*@}"; hport="${hport%%:*}"
    # 预检：SSH 端口都连不上就别等（笔记本合盖、tailnet 掉线都长这样）
    if ! nc -z -G 4 "$hport" 22 2>/dev/null; then
      die "连不上 $hport:22 —— 这地点现在不可达（设备关机/掉网/没上 tailnet？）"
    fi
    # -N 只做转发；ExitOnForwardFailure 保证端口没抢到就退出而不是假成功
    nohup ssh -N -o BatchMode=yes -o ConnectTimeout=8 -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      -o StrictHostKeyChecking=accept-new \
      -L "127.0.0.1:$PORT:127.0.0.1:$PORT" "$host" >>"$LOG" 2>&1 &
    echo $! > "$PIDFILE"
  fi

  if body=$(wait_health "$name" 25); then
    echo "$name" > "$NAMEFILE"
    say "✅ 已切到 $name：$desc"
    say "   $body"
  else
    say "❌ 切到 $name 失败（$target）。看日志：$LOG"
    tail -5 "$LOG" 2>/dev/null | sed 's/^/   /'
    stop_current
    exit 1
  fi
}

cmd_off() {
  stop_current
  say "已关闭；端口 $PORT 释放（要用时再 boxadb-net use <名字>）"
}

# 用当前桥连一下目标 ip:port，把对端前若干字节打出来 —— 判断「是不是真的在那个网里」
cmd_probe() {
  local host="${1:-}" port="${2:-80}"
  [ -n "$host" ] || die "用法：boxadb-net probe <ip> [端口]"
  python3 - "$host" "$port" "$PORT" <<'PY'
import base64, os, socket, struct, sys
host, port, bport = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
s = socket.create_connection(("127.0.0.1", bport), timeout=8)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET /adb?host={host}&port={port} HTTP/1.1\r\nHost: 127.0.0.1:{bport}\r\n"
           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf:
    d = s.recv(4096)
    if not d: break
    buf += d
status = buf.split(b"\r\n")[0].decode(errors="replace")
print("WS 握手:", status)
if "101" not in status:
    print("（握手没成功，说明桥没跑或目标不通）"); sys.exit(1)

def send(payload):
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    n = len(payload)
    hdr = bytes([0x82, 0x80 | n]) if n < 126 else bytes([0x82, 0x80 | 126]) + struct.pack(">H", n)
    s.sendall(hdr + mask + masked)

try:
    send(b"HEAD / HTTP/1.0\r\n\r\n")
    s.settimeout(6)
    h = s.recv(2)
    n = h[1] & 0x7f
    if n == 126: n = struct.unpack(">H", s.recv(2))[0]
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk: break
        data += chunk
    if not data:
        print("连接已建立但目标没回数据（端口通、协议不认得这条）")
    else:
        head = data.decode(errors="replace").split("\r\n")[0]
        print("目标回应:", head[:120])
except socket.timeout:
    print("目标没在 6 秒内回话（端口可能不通）")
PY
}

case "${1:-status}" in
  status|"") cmd_status ;;
  use)   cmd_use "${2:-}" ;;
  off)   cmd_off ;;
  probe) cmd_probe "${2:-}" "${3:-80}" ;;
  -h|--help|help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "未知子命令：$1（status / use <名字> / off / probe <ip> [端口]）" ;;
esac
