#!/usr/bin/env bash
set -euo pipefail

REPO="fueryuanyi/boxadb"
OS="$(uname -s)"
ARCH="$(uname -m)"
URL_BASE="https://github.com/${REPO}/releases/latest/download"

if [ "$OS" = "Linux" ]; then
  # ── Linux：无 Gatekeeper / 无 quarantine / 无签名，下二进制 + chmod 即可 ──
  case "$ARCH" in
    x86_64|amd64)  BIN_NAME="boxadb-bridge-linux-amd64" ;;
    aarch64|arm64) BIN_NAME="boxadb-bridge-linux-arm64" ;;
    *) echo "不支持的 Linux 架构：$ARCH" >&2; exit 1 ;;
  esac

  BINDIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
  BIN_PATH="$BINDIR/boxadb-bridge"
  mkdir -p "$BINDIR"

  echo "下载 $URL_BASE/$BIN_NAME"
  if ! curl -fL -o "$BIN_PATH" "$URL_BASE/$BIN_NAME"; then
    echo "[错误] 下载失败。确认 GitHub Releases 已构建完成（首次需先跑 Actions）。" >&2
    exit 1
  fi
  chmod +x "$BIN_PATH"

  echo
  echo "✅ 已安装：$BIN_PATH"
  case ":$PATH:" in
    *":$BINDIR:"*) echo "   运行：boxadb-bridge" ;;
    *) echo "   运行：$BIN_PATH"
       echo "   （可选）加入 PATH：echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;;
  esac
  echo
  echo "用法："
  echo "   1) 终端运行 boxadb-bridge（前台跑桥；Ctrl+C 或关终端窗口即停）"
  echo "   2) 浏览器打开 https://box.fueryuanyi.com/ 输盒子 IP → 点连接"
  exit 0
fi

# ── macOS：按 CPU 选包，生成双击启动器 + 图标 + 去隔离 ──
case "$ARCH" in
  arm64)  BIN_NAME="boxadb-bridge-darwin-arm64" ;;
  x86_64) BIN_NAME="boxadb-bridge-darwin-amd64" ;;
  *) echo "不支持的 macOS 架构：$ARCH" >&2; exit 1 ;;
esac

APP_DIR="$HOME/Applications/BoxADB Bridge"
BIN_PATH="$APP_DIR/boxadb-bridge"
LAUNCH_PATH="$APP_DIR/启动桥接.command"
DESKTOP_LINK="$HOME/Desktop/BoxADB 桥接.command"

mkdir -p "$APP_DIR"

echo "下载 $URL_BASE/$BIN_NAME"
if ! curl -fL -o "$BIN_PATH" "$URL_BASE/$BIN_NAME"; then
  echo "[错误] 下载失败。检查 GitHub Releases 是否已经构建完成（首次要跑一下 Actions）。" >&2
  exit 1
fi
chmod +x "$BIN_PATH"

# 生成启动器 —— exec 让 Terminal 会话被 bridge 直接替换，关窗即 SIGHUP 终止
cat > "$LAUNCH_PATH" <<EOF
#!/bin/bash
# 由 install.sh 生成；双击后 Terminal 打开、关闭即断开
exec "$BIN_PATH" "\$@"
EOF
chmod +x "$LAUNCH_PATH"

# 去掉 quarantine 属性（Gatekeeper 首次不再拦）
xattr -d com.apple.quarantine "$BIN_PATH" 2>/dev/null || true
xattr -d com.apple.quarantine "$LAUNCH_PATH" 2>/dev/null || true

# 桌面软链接（可选，失败也不影响）
if [ -d "$HOME/Desktop" ]; then
  ln -sf "$LAUNCH_PATH" "$DESKTOP_LINK" || true
fi

# ---- 给启动器打自定义图标（Finder 里不再是通用 Terminal 图标）----
# 用 macOS 自带的 osascript 调 NSWorkspace.setIcon:forFile:options:，
# 图标写进文件自身的资源里，双击行为不变（仍开 Terminal、关窗即断）。
ICN_URL="https://raw.githubusercontent.com/${REPO}/main/assets/AppIcon.icns"
ICN_PATH="$APP_DIR/AppIcon.icns"
ICON_RESULT="skipped"
if curl -fL -o "$ICN_PATH" "$ICN_URL"; then
  xattr -d com.apple.quarantine "$ICN_PATH" 2>/dev/null || true
  ICON_RESULT="$(osascript -l JavaScript - "$ICN_PATH" "$LAUNCH_PATH" <<'JXA' || echo failed
ObjC.import('AppKit');
function run(argv){
  var icns = argv[0], file = argv[1];
  var img = $.NSImage.alloc.initWithContentsOfFile(icns);
  if (img.isNil()) return "unavailable";
  var ok = $.NSWorkspace.sharedWorkspace.setIconForFileOptions(img, file, 0);
  return ok ? "ok" : "failed";
}
JXA
)"
fi

echo
echo "✅ 已安装："
echo "   二进制：$BIN_PATH"
echo "   启动器：$LAUNCH_PATH"
echo "   图标：  $([ "$ICON_RESULT" = ok ] && echo "已应用" || echo "未应用（$ICON_RESULT，不影响功能）")"
[ -e "$DESKTOP_LINK" ] && echo "   桌面快捷方式：$DESKTOP_LINK"
echo
echo "用法："
echo "   1) 双击「BoxADB 桥接.command」（桌面或 App 目录）→ Terminal 打开跑桥"
echo "   2) 打开 https://box.fueryuanyi.com/ 输盒子 IP → 点连接"
echo "   3) 用完关掉 Terminal 窗口，端口自动释放"
