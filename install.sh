#!/usr/bin/env bash
set -euo pipefail

REPO="wukongdaily/boxadb"
ARCH_RAW="$(uname -m)"

case "$ARCH_RAW" in
  arm64)
    BIN_NAME="boxadb-bridge-darwin-arm64"
    ;;
  x86_64)
    echo "当前方案只提供 Apple Silicon（arm64）版二进制。"
    exit 1
    ;;
  *)
    echo "不支持的 CPU 架构：$ARCH_RAW"
    exit 1
    ;;
esac

APP_DIR="$HOME/Applications/BoxADB Bridge"
BIN_PATH="$APP_DIR/boxadb-bridge"
LAUNCH_PATH="$APP_DIR/启动桥接.command"
DESKTOP_LINK="$HOME/Desktop/BoxADB 桥接.command"

mkdir -p "$APP_DIR"

URL="https://github.com/${REPO}/releases/latest/download/${BIN_NAME}"
echo "下载 $URL"
if ! curl -fL -o "$BIN_PATH" "$URL"; then
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
echo "   2) 打开 https://wukongdaily.github.io/boxadb/ 输盒子 IP → 点连接"
echo "   3) 用完关掉 Terminal 窗口，端口自动释放"
