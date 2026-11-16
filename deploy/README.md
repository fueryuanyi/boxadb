# 部署说明（本 fork 的自托管方式）

上游把前端放在 GitHub Pages（`https://wukongdaily.github.io/boxadb/`），大陆访问不稳且
页面能不能开取决于上游仓库；本 fork 改成自托管：**网页在自己的 VPS 上、二进制在自己的 release 里**。

## 架构：为什么前端放在公网、桥接放在本机

```
浏览器（https://box.fueryuanyi.com）
   │  静态页面，零后端
   ├── fetch/ws → 127.0.0.1:8765  ← 本机 boxadb-bridge（仅为本机可达）
   │                                 │ TCP
   └── 页面里跑 ADB 协议（Tango）      └──→ 局域网盒子 192.168.x.x:5555
```

- 桥接程序**必须跑在「你用来开网页的那台电脑」上**，它只监听 127.0.0.1（回环），
  所以不需要、也不该暴露到公网；每台电脑各装一份。
- 浏览器允许 https 页面调 `ws://127.0.0.1`（回环视为安全上下文），所以页面放在公网 https 上没问题。
- 页面本身必须 https：ADB 密钥靠 `crypto.subtle` 生成，非安全上下文直接不可用。

## 一次性部署（VPS）

前提：VPS 上 Caddy 已在跑（`https_port 8443`），Cloudflare 隧道 `dsh-backup` 的 ingress
指向 `127.0.0.1:8443`。

1. 建目录并把静态文件推上去（仓库根执行）：

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
   ```

3. Cloudflare 隧道 ingress 加一条（`/etc/cloudflared/config.yml` 的 `ingress:` 内，
   位置在最后的 `service: http_status:404` 之前）：

   ```yaml
   - hostname: box.fueryuanyi.com
     service: https://127.0.0.1:8443
     originRequest:
       originServerName: box.fueryuanyi.com
   ```

   改完 `cloudflared tunnel ingress validate && systemctl restart cloudflared`。

4. DNS：CNAME 指向隧道（不开通到 VPS 真实 IP 的 A 记录），

   ```bash
   ~/code/.bin/cf-dns-apply.sh to-tunnel --host box --tunnel vps --apply
   ```

   注意：DNS 里只有隧道 CNAME，真实 IP 不进 DNS；Caddy 侧的 vhost 仍会自己申请证书，
   容器内访问走 `originServerName` 指定的 vhost 名。

## 本机桥接

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/fueryuanyi/boxadb/main/install.sh | bash

# Windows（PowerShell）
iwr https://raw.githubusercontent.com/fueryuanyi/boxadb/main/install.bat -o $env:TEMP\install.bat; & $env:TEMP\install.bat
```

装完双击启动器跑桥（或终端 `boxadb-bridge`），浏览器开 <https://box.fueryuanyi.com/>，
填盒子 IP（端口 5555 自动补），点「连接」。

桥接可用性自检：

```bash
curl -s http://127.0.0.1:8765/health   # 期望 200
```

## 发布新版本

```bash
git tag v1.0.3 && git push origin v1.0.3   # 触发 Actions 构建 5 个平台的二进制并出 release
```

网页改动不需要版本号，直接 `./deploy/publish-web.sh`。
