# boxadb

网页版 ADB 助手，专为电视盒子 / Android TV 设计。无需安装任何客户端：
**一个网页 → 连上局域网里的盒子 → 装 APK / 终端 / 遥控器 / 截图 / 重启。**

> 纯 WiFi（adb tcpip 5555），MIT 许可，业务代码全部原创。

## 快速开始（macOS Apple Silicon）

```bash
curl -fsSL https://raw.githubusercontent.com/wukongdaily/boxadb/main/install.sh | bash
```

安装后双击「BoxADB 桥接.command」启动本机桥，再打开网页连盒子即可。

Windows（10/11 64-bit）：从 [Releases](https://github.com/wukongdaily/boxadb/releases) 下载 `boxadb-windows.zip`，解压后双击 `install.bat`。

## 目录

| 文件 | 说明 |
|---|---|
| `bridge.go` | 本机桥：WebSocket(RFC 6455) ↔ TCP 字节管道，只转发不解析 ADB |
| `js/` | 前端业务代码（原创） |
| `js/vendor/` | 第三方引擎（见下方致谢与许可） |

## 第三方组件致谢（均为 MIT）

本项目站在这些优秀开源项目的肩膀上：

- **[@yume-chan/ya-webadb (Tango)](https://github.com/yume-chan/ya-webadb)** —— ADB 协议引擎，感谢 [@yume-chan](https://github.com/yume-chan)（Simon Chan）
- **[xterm.js](https://xtermjs.org/)** —— 浏览器终端
- **[fflate](https://github.com/101arrowz/fflate)** —— APK/XAPK 解包

以上均为 MIT 许可，版权声明与许可全文见 [`js/vendor/THIRD-PARTY-LICENSES.md`](js/vendor/THIRD-PARTY-LICENSES.md)。

## 许可

本项目以 [MIT](LICENSE) 许可开源。
