import os
import socket
import base64
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs

# پورت اختصاصی Render و پورت داخلی هسته CottenDNS
RENDER_PORT = int(os.environ.get("PORT", 10000))
INTERNAL_DNS_HOST = os.environ.get("INTERNAL_DNS_HOST", "127.0.0.1")
INTERNAL_DNS_PORT = int(os.environ.get("INTERNAL_DNS_PORT", 5353))
FALLBACK_DNS = ("1.1.1.1", 53)

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

def forward_dns_query(raw_query: bytes) -> bytes:
    """ارسال بسته خام DNS به هسته داخلی CottenDNS و در صورت عدم پاسخ، به کلودفلر"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(3.0)
    try:
        sock.sendto(raw_query, (INTERNAL_DNS_HOST, INTERNAL_DNS_PORT))
        data, _ = sock.recvfrom(4096)
        return data
    except Exception:
        # اگر هسته داخلی روی پورت 5353 بالا نیامده بود، مستقیم از Upstream بپرس
        sock.sendto(raw_query, FALLBACK_DNS)
        data, _ = sock.recvfrom(4096)
        return data
    finally:
        sock.close()

class DoHHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # غیرفعال کردن لاگ‌های اضافی برای سرعت بیشتر

    def do_GET(self):
        parsed = urlparse(self.path)
        
        # مسیر بررسی سلامت برای Render و Cron-job
        if parsed.path in ["/", "/health"]:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status": "online", "service": "CottenDNS-Render"}')
            return

        # مسیر استاندارد DNS over HTTPS (متد GET)
        if parsed.path == "/dns-query":
            params = parse_qs(parsed.query)
            if "dns" in params:
                try:
                    b64_dns = params["dns"][0]
                    # اصلاح Padding در Base64URL
                    b64_dns += "=" * ((4 - len(b64_dns) % 4) % 4)
                    raw_query = base64.urlsafe_b64decode(b64_dns)
                    response = forward_dns_query(raw_query)

                    self.send_response(200)
                    self.send_header("Content-Type", "application/dns-message")
                    self.send_header("Cache-Control", "max-age=60")
                    self.end_headers()
                    self.wfile.write(response)
                    return
                except Exception as e:
                    self.send_error(400, f"Bad DNS Query: {e}")
                    return

        self.send_error(404, "Not Found")

    def do_POST(self):
        # مسیر استاندارد DNS over HTTPS (متد POST)
        if self.path == "/dns-query":
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length > 0:
                raw_query = self.rfile.read(content_length)
                response = forward_dns_query(raw_query)

                self.send_response(200)
                self.send_header("Content-Type", "application/dns-message")
                self.end_headers()
                self.wfile.write(response)
                return

        self.send_error(404, "Not Found")

if __name__ == "__main__":
    print(f"[*] Starting CottenDNS DoH Gateway on 0.0.0.0:{RENDER_PORT}")
    print(f"[*] Forwarding queries to internal DNS at {INTERNAL_DNS_HOST}:{INTERNAL_DNS_PORT}")
    server = ThreadingHTTPServer(("0.0.0.0", RENDER_PORT), DoHHandler)
    server.serve_forever()
