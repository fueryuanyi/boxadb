# box.fueryuanyi.com —— 盒子助手（本 fork 自托管的前端）
#
# 纯静态站点，零后端：页面在自己浏览器里跑 ADB 协议，经本机
# 127.0.0.1:8765 的桥接程序转发到局域网盒子。所以这里只负责把文件发出去。
#
# 形态：http 回环源站（不走本机证书）。TLS 由 Cloudflare 边缘终止
#       （Universal SSL 已覆盖 *.fueryuanyi.com），流量路径
#       CF 边缘 → cloudflared 隧道 → 127.0.0.1:8081。
#       为什么不给这个站单独发 LE 证书：CF 代理下 http-01 会落到 HTTPS vhost 上 404、
#       tls-alpn-01 的 443 又被 xray 占着，历史上 rss/wallabag 就这么续期失败的。
#       回环 http 源站是这套基础设施里最省事、最不会哪天悄悄过期的形态。
#
# 部署位置：追加到 VPS 的 /etc/caddy/Caddyfile；内容目录 /var/www/boxadb
http://:8081 {
	# 只绑回环。注意别写成 127.0.0.1:8081 —— Caddy 会把它当 Host 匹配器，
	# cloudflared 送来的 Host: box.fueryuanyi.com 匹配不上，结果是一个空的 200。
	bind 127.0.0.1
	root * /var/www/boxadb
	encode zstd gzip
	file_server

	@assets path /assets/*
	header @assets Cache-Control "public, max-age=604800"
	header {
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
	}
}
