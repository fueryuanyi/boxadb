# 部署说明（本 fork 的自托管方式）

上游把前端放在 GitHub Pages（`https://wukongdaily.github.io/boxadb/`），大陆访问不稳、
能不能开还取决于上游仓库；本 fork 改成自托管：**网页在自己的 VPS 上、二进制在自己的 release 里**。
ADB 逻辑零改动，只改地址与部署方式。

## 架构：前端在公网，桥接只在本机

```
浏览器（https://box.fueryuanyi.com）      ← Cloudflare 边缘终止 TLS
   │  纯静态页面，零后端
   ├── ws → 127.0.0.1:8765  ← 本机 boxadb-bridge（只监听回环）
   │                            │ TCP
   └── 页面里跑 ADB 协议（Tango） └──→ 局域网盒子 192.168.x.x:5555
```

- 桥接程序**必须跑在「你用来开网页的那台电脑」上**，它只监听 `127.0.0.1`，
  所以不需要也不该暴露到公网；每台电脑各装一份（装一次，双击启动器即跑）。
- 浏览器允许 https 页面调 `ws://127.0.0.1`（回环视为安全上下文），故页面放公网 https 没问题。
- 页面本身必须 https：ADB 密钥靠 `crypto.subtle` 生成，非安全上下文直接不可用。

## 线上拓扑（实测形态）

| 环节 | 值 |
|---|---|
| 浏览器入口 | `https://box.fueryuanyi.com`（CF 代理，CNAME → `dsh-backup` 隧道） |
| CF → 源站 | cloudflared 隧道 ingress：`box.fueryuanyi.com` → `http://127.0.0.1:8081` |
| 源站 | Caddy，`http://:8081` + `bind 127.0.0.1`，`root * /var/www/boxadb` |
| 证书 | 无。TLS 由 CF 边缘终止（Universal SSL 覆盖 `*.fueryuanyi.com`） |
| 明文文件 | VPS `/var/www/boxadb`（2.2 MB） |

**为什么不给这个站单独发 Let's Encrypt 证书**：CF 代理下 http-01 挑战会落到 HTTPS vhost
上返回 404、tls-alpn-01 要的 443 又被 xray REALITY 占着。这台机器上 `rss`/`wallabag`
的证书续期就是这样长期失败的（日志里 attempt 40+ 还在重试）。所以静态站走
「CF 终止 TLS + 回环 http 源站」，没有会悄悄过期的证书。

**为什么地址不能写成 `http://127.0.0.1:8081`**：Caddy 会把站点地址里的主机部分当 Host
匹配器用，cloudflared 送来的 `Host: box.fueryuanyi.com` 匹配不上，结果是 **200 + 空响应**
（这个坑踩过一次，症状极像缓存问题）。正确写法是 `http://:8081` + `bind 127.0.0.1`。

## 一次性部署（VPS）

1. 推静态文件（仓库根执行，需要 `ssh vps` 可用、远端是 root）：

   ```bash
   ssh vps 'mkdir -p /var/www/boxadb'
   ./deploy/publish-web.sh
   ```

2. 追加 Caddy vhost（内容见 `Caddyfile.box.fueryuanyi.com`）：

   ```bash
   scp deploy/Caddyfile.box.fueryuanyi.com vps:/tmp/
   ssh vps 'cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-pre-boxadb-$(date +%Y%m%d-%H%M%S) \
            && cat /tmp/Caddyfile.box.fueryuanyi.com >> /etc/caddy/Caddyfile \
            && caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile \
            && systemctl reload caddy'
   # 本机验一眼（带上 Host，才是 cloudflared 的视角）
   ssh vps 'curl -s -o /dev/null -w "%{http_code}/%{size_download}\n" -H "Host: box.fueryuanyi.com" http://127.0.0.1:8081/'
   ```

3. Cloudflare 隧道 ingress（`/etc/cloudflared/config.yml` 的 `ingress:` 内，
   放在最后那条 `service: http_status:404` **之前**）：

   ```yaml
   - hostname: box.fueryuanyi.com
     service: http://127.0.0.1:8081
   ```

   ```bash
   ssh vps 'cloudflared tunnel ingress validate && systemctl restart cloudflared'
   ```

4. DNS（只建隧道 CNAME，真实 IP 不进 DNS）：

   ```bash
   ~/code/.bin/cf-dns-apply.sh to-tunnel --host box --tunnel vps --apply
   ```

## 本机桥接

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/fueryuanyi/boxadb/main/install.sh | bash

# Windows（PowerShell）
iwr https://raw.githubusercontent.com/fueryuanyi/boxadb/main/install.bat -o $env:TEMP\install.bat; & $env:TEMP\install.bat
```

装完双击启动器跑桥（或终端直接 `boxadb-bridge`），浏览器开 <https://box.fueryuanyi.com/>，
填盒子 IP（端口 5555 自动补），点「连接」。

桥接自检（桥没跑时这里是连不上，跑起来才是 200）：

```bash
curl -s http://127.0.0.1:8765/health     # boxadb bridge ok
```

## 注意事项

- **CF 会缓存静态扩展**（.js/.css/.png）默认 4 小时（`cache-control: max-age=14400`）。
  发布新版本后如果页面还是旧的，去面板 Purge Cache，别怀疑 Caddy。
  源站返回过空响应时尤其会被缓存成「白板页面」——排查时先看 `cf-cache-status: HIT`。
- 隧道 ingress 改了要重启 cloudflared；Caddy 改了 `systemctl reload caddy` 即可。

## 发布新版本

```bash
git tag v0.1.5 && git push origin v0.1.5   # Actions 构建 5 个平台二进制并出 release
```

只改网页不用发版本，直接 `./deploy/publish-web.sh`。
