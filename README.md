# 盒子助手网页版 [![bilibili](https://img.shields.io/badge/B站·教程-A0AABC?style=flat&logo=bilibili&logoColor=fff&labelColor=FB7299&color=3a3a44)](https://www.bilibili.com/video/BV1RwsG6dEd9)


网页版 ADB 助手，专为电视盒子 / Android TV 设计。
**一个网页 → 连上局域网里的盒子 → 装 APK / 终端 / 遥控器 / 截图 / 重启。**

## 快速开始
电脑打开桥接程序，再打开网页，就能用了<br>
### 桥接程序 https://github.com/wukongdaily/boxadb/releases
1. 双击桌面「BoxADB 桥接」快捷方式 → 弹窗口跑桥（保持别关）
2. 浏览器打开 https://wukongdaily.github.io/boxadb/ ，填盒子 IP（端口 5555 自动补）→ 点「连接设备」
3. 用完关掉那个窗口，端口立即释放，不留后台

## 支持的浏览器

| 浏览器 | 支持情况 |
|---|---|
| **Chrome / Edge** | ✅ 推荐（基于 Chromium 内核的浏览器均可） |
| **Firefox** | ⚠️ 理论上支持，暂未充分实测 |
| **Safari** | ❌ 暂不支持（后续开发支持） |

## 飞牛 NAS 版

有飞牛 fnOS 的话，盒子助手还有常驻 NAS 的原生版 [boxadb-fnos](https://github.com/wukongdaily/boxadb-fnos)：经统一网关同源，**手机在客厅也能开网页连盒子**，不必在每台电脑另开桥。

## 第三方组件致谢（均为 MIT）

本项目站在这些优秀开源项目的肩膀上：

- **[@yume-chan/ya-webadb (Tango)](https://github.com/yume-chan/ya-webadb)** —— ADB 协议引擎，感谢 [@yume-chan](https://github.com/yume-chan)（Simon Chan）
- **[@yume-chan/adb-daemon-webusb](https://github.com/yume-chan/ya-webadb)** —— USB 数据线直连（WebUSB）传输组件
- **[xterm.js](https://xtermjs.org/)** —— 浏览器终端
- **[fflate](https://github.com/101arrowz/fflate)** —— APK/XAPK 解包

以上均为 MIT 许可，版权声明与许可全文见 [`js/vendor/THIRD-PARTY-LICENSES.md`](js/vendor/THIRD-PARTY-LICENSES.md)。

## 许可

本项目以 [MIT](LICENSE) 许可开源。
