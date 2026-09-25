#!/usr/bin/env python3
"""本地 TCP 隧道：把 github.com 的 HTTPS 流量转发到可用的真实 IP。

背景：本机 DNS 把 github.com 解析到被阻断的 IP（20.27.177.113），
而真实可用 IP 是 20.205.243.166。git 不支持自定义 DNS，故起本地代理：
git → 127.0.0.1:8899 (CONNECT 隧道) → 20.205.243.166:443

用法：python3 gh_tunnel.py [port]，然后
     git -c http.proxy=http://127.0.0.1:8899 push origin main
"""
import socket
import socketserver
import sys
import threading

GOOD_IP = "20.205.243.166"        # github.com 可达 IP
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
FORCE_HOSTS = {"github.com", "www.github.com", "ssh.github.com"}


class Tunnel(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = self.request.recv(4096)
                if not chunk:
                    return
                head += chunk
            line = head.split(b"\r\n")[0].decode(errors="replace")
            parts = line.split()
            if len(parts) < 2 or parts[0] != "CONNECT":
                self.request.sendall(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n")
                return
            host, _, port = parts[1].partition(":")
            port = int(port or 443)
            target_ip = GOOD_IP if host in FORCE_HOSTS else socket.gethostbyname(host)
            print(f"[tunnel] {host}:{port} → {target_ip}:{port}", flush=True)
            upstream = socket.create_connection((target_ip, port), timeout=15)
            self.request.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            self._pipe(self.request, upstream)
        except Exception as e:
            print(f"[tunnel] 错误: {e}", flush=True)

    @staticmethod
    def _pipe(a, b):
        def copy(src, dst):
            try:
                while True:
                    data = src.recv(65536)
                    if not data:
                        break
                    dst.sendall(data)
            except OSError:
                pass
            finally:
                for s in (src, dst):
                    try:
                        s.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
        threading.Thread(target=copy, args=(a, b), daemon=True).start()
        copy(b, a)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with Server(("127.0.0.1", PORT), Tunnel) as srv:
        print(f"[tunnel] 监听 127.0.0.1:{PORT}（github.com → {GOOD_IP}）", flush=True)
        srv.serve_forever()
