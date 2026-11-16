# box.fueryuanyi.com —— 盒子助手（本 fork 自托管的前端）
#
# 纯静态站点，不需要任何后端：页面在本机浏览器里跑 ADB 协议，
# 通过本机 127.0.0.1:8765 的桥接程序（boxadb-bridge）转发到局域网盒子。
# 所以这里只要把静态文件发出去，https 是硬要求（crypto.subtle 只在安全上下文可用）。
#
# 部署位置：VPS 上追加到 /etc/caddy/Caddyfile，内容目录 /var/www/boxadb
box.fueryuanyi.com {
	root * /var/www/boxadb
	encode zstd gzip
	file_server

	# 页面与 JS 常改，给弱缓存；assets 长期不变，可长缓存
	@assets path /assets/*
	header @assets Cache-Control "public, max-age=604800"
	header / Cache-Control "public, max-age=300"

	header {
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
	}
}
