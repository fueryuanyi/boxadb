// 盒子助手 · 桌面桥（MIT License. Copyright (c) 2026 wukongdaily）
//
// 职责：在"GitHub Pages 上的网页(https)"与"局域网里的电视盒子(TCP)"之间
// 建一条字节管道。浏览器端因 https 混合内容限制不能直连 ws://，
// 所以由本程序在本机 127.0.0.1 起一个小服务代为转发。
//
// 本程序不解析 ADB 协议——ADB 全部由浏览器端的 MIT 引擎（Tango）完成，
// 这里只做两件事：
//   1) GET /health       —— 探活；
//   2) GET /adb?host=&port= —— 升级为 WebSocket(RFC 6455, IETF 公开规范)，
//      并与目标 TCP 地址互搬字节。
package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ── 配置 ──

const listenHost = "127.0.0.1"
const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

func listenPort() string {
	if p := os.Getenv("BRIDGE_PORT"); p != "" {
		return p
	}
	return "8765"
}

// ── WebSocket 帧（按 RFC 6455；服务端发出的帧不加掩码）──

const (
	opCont  = 0x0
	opText  = 0x1
	opBin   = 0x2
	opClose = 0x8
	opPing  = 0x9
	opPong  = 0xa
)

func putFrame(w io.Writer, opcode byte, data []byte) error {
	var head []byte
	n := len(data)
	switch {
	case n < 126:
		head = []byte{0x80 | opcode, byte(n)}
	case n <= 0xffff:
		head = []byte{0x80 | opcode, 126, byte(n >> 8), byte(n)}
	default:
		head = make([]byte, 10)
		head[0] = 0x80 | opcode
		head[1] = 127
		for i := 0; i < 8; i++ {
			head[2+i] = byte(uint64(n) >> uint(8*(7-i)))
		}
	}
	if _, err := w.Write(head); err != nil {
		return err
	}
	if n > 0 {
		if _, err := w.Write(data); err != nil {
			return err
		}
	}
	return nil
}

func putClose(w io.Writer, code uint16, text string) error {
	body := []byte(text)
	if len(body) > 120 {
		body = body[:120]
	}
	payload := make([]byte, 2+len(body))
	payload[0] = byte(code >> 8)
	payload[1] = byte(code)
	copy(payload[2:], body)
	return putFrame(w, opClose, payload)
}

// grabFrame 读取并解开一个客户端帧（客户端帧必须带掩码）。
// 返回 opcode、载荷，以及该帧之后留在缓冲里的剩余字节。
func grabFrame(br *bufio.Reader) (byte, []byte, error) {
	var hdr [2]byte
	if _, err := io.ReadFull(br, hdr[:]); err != nil {
		return 0, nil, err
	}
	opcode := hdr[0] & 0x0f
	masked := hdr[1]&0x80 != 0
	length := uint64(hdr[1] & 0x7f)
	switch hdr[1] & 0x7f {
	case 126:
		var ext [2]byte
		if _, err := io.ReadFull(br, ext[:]); err != nil {
			return 0, nil, err
		}
		length = uint64(ext[0])<<8 | uint64(ext[1])
	case 127:
		var ext [8]byte
		if _, err := io.ReadFull(br, ext[:]); err != nil {
			return 0, nil, err
		}
		for _, b := range ext {
			length = length<<8 | uint64(b)
		}
	}
	if length > 64<<20 {
		return 0, nil, fmt.Errorf("frame too large: %d", length)
	}
	var mask [4]byte
	if masked {
		if _, err := io.ReadFull(br, mask[:]); err != nil {
			return 0, nil, err
		}
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(br, payload); err != nil {
		return 0, nil, err
	}
	if masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	return opcode, payload, nil
}

// ── 隧道 ──

func pumpBoth(browser net.Conn, box net.Conn) {
	// 盒子 → 浏览器：每个 TCP 分片包成一个 binary 帧
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := box.Read(buf)
			if n > 0 {
				if e := putFrame(browser, opBin, buf[:n]); e != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}
		putClose(browser, 1000, "upstream closed")
		browser.Close()
	}()

	// 浏览器 → 盒子：解帧；收到 close 则双向关闭
	br := bufio.NewReader(browser)
	for {
		op, payload, err := grabFrame(br)
		if err != nil {
			break
		}
		switch op {
		case opBin, opText, opCont:
			if _, e := box.Write(payload); e != nil {
				putClose(browser, 1000, "upstream error")
				box.Close()
				browser.Close()
				return
			}
		case opPing:
			putFrame(browser, opPong, payload)
		case opPong:
			// 忽略
		case opClose:
			putClose(browser, 1000, "")
			box.Close()
			browser.Close()
			return
		}
	}
	box.Close()
	browser.Close()
}

func handleTunnel(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	host := q.Get("host")
	port, err := strconv.Atoi(q.Get("port"))
	if err != nil || port < 1 || port > 65535 || !isIPv4(host) {
		http.Error(w, "bad host/port", http.StatusBadRequest)
		return
	}
	if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") || r.Header.Get("Sec-WebSocket-Key") == "" {
		http.Error(w, "websocket upgrade required", http.StatusBadRequest)
		return
	}

	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijack unsupported", http.StatusInternalServerError)
		return
	}
	box, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), 3*time.Second)
	if err != nil {
		http.Error(w, "cannot reach "+host+":"+q.Get("port"), http.StatusBadGateway)
		return
	}
	box.(*net.TCPConn).SetNoDelay(true)

	browser, rw, err := hijacker.Hijack()
	if err != nil {
		box.Close()
		return
	}
	accept := sha1.Sum([]byte(r.Header.Get("Sec-WebSocket-Key") + wsGUID))
	browser.Write([]byte(
		"HTTP/1.1 101 Switching Protocols\r\n" +
			"Upgrade: websocket\r\nConnection: Upgrade\r\n" +
			"Sec-WebSocket-Accept: " + base64.StdEncoding.EncodeToString(accept[:]) + "\r\n\r\n"))
	_ = rw.Flush()
	log.Printf("tunnel open %s:%d", host, port)
	pumpBoth(browser, box)
	log.Printf("tunnel close %s:%d", host, port)
}

// ── HTTP 入口 ──

func allowCross(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "*")
	// GitHub Pages(https) 调 ws://127.0.0.1 的 PNA 预检
	w.Header().Set("Access-Control-Allow-Private-Network", "true")
}

func router(w http.ResponseWriter, r *http.Request) {
	allowCross(w)
	switch {
	case r.Method == http.MethodOptions:
		w.WriteHeader(http.StatusNoContent)
	case r.URL.Path == "/health":
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte("boxadb bridge ok\n"))
	case r.URL.Path == "/adb":
		handleTunnel(w, r)
	default:
		http.NotFound(w, r)
	}
}

func isIPv4(s string) bool {
	ip := net.ParseIP(s)
	return ip != nil && ip.To4() != nil && strings.Count(s, ".") == 3
}

// ── 启动 ──

func main() {
	addr := net.JoinHostPort(listenHost, listenPort())

	// 幂等保护：已有一个桥在监听时直接退出（重复双击图标无害）
	if c, err := net.DialTimeout("tcp", addr, 300*time.Millisecond); err == nil {
		c.Close()
		log.Printf("boxadb bridge already running at %s", addr)
		return
	}

	srv := &http.Server{Addr: addr, Handler: http.HandlerFunc(router)}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("listen %s: %v", addr, err)
	}
	log.Printf("boxadb bridge listening on http://%s (health: /health, tunnel: /adb)", addr)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		log.Println("shutting down")
		ln.Close()
		srv.Close()
	}()
	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		log.Fatalf("serve: %v", err)
	}
}
