#!/opt/homebrew/bin/python3
# -*- coding: utf-8 -*-
"""
SwiftBar 插件：盒子助手桥（人在哪儿跟哪儿同网）

回答一个问题：这台机器上 127.0.0.1:8765 现在指向哪个地点的网？
  local  本机桥 —— 能碰当前所在网段的设备
  home   老家 MT6000 上的桥（SSH 隧道搬过来的）
  关     桥没跑，浏览器点「连接」会失败

切换逻辑全在 /opt/homebrew/bin/boxadb-net（见 boxadb 仓库 deploy/），
本插件只做展示 + 触发，不重复实现，避免两处口径分叉。

装法：本文件放进 ~/Library/Application Support/xbar/plugins/，chmod +x，
SwiftBar 认文件名里的间隔（.1m. = 每分钟；切换动作会带 refresh=true 立即刷新）。
"""

import sys
sys.dont_write_bytecode = True  # 跟本目录其它插件一致：别在 plugins 里留 __pycache__

import os
import shutil
import subprocess

HOME = os.path.expanduser("~")
CONF = os.path.join(HOME, ".config/boxadb/sites.conf")
STATE = os.path.join(HOME, ".local/state/boxadb")
NET = "/opt/homebrew/bin/boxadb-net"
PORT = os.environ.get("BOXADB_PORT", "8765")
WEB = "https://box.fueryuanyi.com/"

GREEN = "#2e9e5b"
GRAY = "#8a8a8a"
RED = "#d03b3b"


def run(cmd, timeout=3):
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        ).stdout.strip()
    except Exception:
        return ""


def health():
    return run(["curl", "-s", "--max-time", "1", "http://127.0.0.1:%s/health" % PORT])


def load_sites():
    """读地点表：返回 [(名字, 说明, 目标)]"""
    out = []
    try:
        with open(CONF, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line.strip() or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) >= 3:
                    out.append((parts[0].strip(), parts[1].strip(), parts[2].strip()))
    except FileNotFoundError:
        pass
    return out


def port_owner():
    """返回 (命令名, PID)；没人监听时返回 ("", "")。用 -F 稳定解析，别切空格列。"""
    if not shutil.which("lsof"):
        return "", ""
    try:
        r = subprocess.run(
            ["lsof", "-nP", "-iTCP:%s" % PORT, "-sTCP:LISTEN", "-F", "pc"],
            capture_output=True, text=True, timeout=3,
        )
        cmd, pid = "", ""
        for line in r.stdout.splitlines():
            if line.startswith("c"):
                cmd = line[1:]
            elif line.startswith("p"):
                pid = line[1:]
        return cmd, pid
    except Exception:
        return "", ""


def main():
    sites = load_sites()
    body = health()
    cmd, pid = port_owner()

    # 当前地点：靠 /health 回显括号里的名字（BRIDGE_NAME）
    current = ""
    if body.startswith("boxadb bridge ok ("):
        current = body[len("boxadb bridge ok ("):].rstrip(")")
    elif body.startswith("boxadb bridge ok"):
        current = "?"

    desc_of = {n: d for n, d, _ in sites}

    if not body:
        print("📺 关 | color=%s" % GRAY)
        print("---")
        print("桥没在跑，浏览器点「连接」会失败 | color=%s size=12" % GRAY)
    elif current == "?":
        print("📺 无名桥 | color=%s" % GRAY)
        print("---")
        print("8765 上有桥但不是 boxadb-net 起的（旧二进制或手动双击的） | size=12")
    else:
        label = {"local": "本机", "home": "老家"}.get(current, current)
        color = GREEN if current == "local" else "#2f6fb2"
        print("📺 %s | color=%s" % (label, color))
        print("---")
        print("当前：%s（%s） | size=12" % (current, desc_of.get(current, "")))
        print("桥回显：%s | size=12 color=%s" % (body, GRAY))

    if pid:
        print("端口 %s：%s（PID %s） | size=12 color=%s" % (PORT, cmd or "?", pid, GRAY))

    # ── 切换地点 ──
    print("---")
    print("切换地点")
    for name, desc, _target in sites:
        mark = "✓ " if name == current else "　"
        print("%s%s | bash=%s use %s | terminal=false | refresh=true size=12"
              % (mark, desc, NET, name))
    if not sites:
        print("（没有地点表：%s） | size=12 color=%s" % (CONF, GRAY))

    print("---")
    print("打开盒子助手 | href=%s" % WEB)
    if body:
        print("关闭桥（释放 %s） | bash=%s off | terminal=false | refresh=true" % (PORT, NET))
    print("刷新 | refresh=true | size=12")


if __name__ == "__main__":
    main()
