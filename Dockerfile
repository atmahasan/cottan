FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

# ۱. نصب پیش‌نیازها
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    golang-go \
    nodejs \
    npm \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# ۲. کپی کردن فایل‌های پروژه شما
COPY . /app

# ۳. نصب وابستگی‌های احتمالی پروژه
RUN if [ -f "requirements.txt" ]; then pip3 install --no-cache-dir -r requirements.txt; fi && \
    if [ -f "go.mod" ]; then go build -o CottenDNS .; fi && \
    if [ -f "package.json" ]; then npm install --production; fi

# ۴. ساخت خودکار فایل /app/render_gateway.py مستقیماً داخل کانتینر
RUN cat << 'EOF' > /app/render_gateway.py
import os
import socket
import base64
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs

RENDER_PORT = int(os.environ.get("PORT", 10000))
INTERNAL_DNS_HOST = os.environ.get("INTERNAL_DNS_HOST", "127.0.0.1")
INTERNAL_DNS_PORT = int(os.environ.get("INTERNAL_DNS_PORT", 5353))
FALLBACK_DNS = ("1.1.1.1", 53)

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

def forward_dns_query(raw_query: bytes) -> bytes:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(3.0)
    try:
        sock.sendto(raw_query, (INTERNAL_DNS_HOST, INTERNAL_DNS_PORT))
        data, _ = sock.recvfrom(4096)
        return data
    except Exception:
        sock.sendto(raw_query, FALLBACK_DNS)
        data, _ = sock.recvfrom(4096)
        return data
    finally:
        sock.close()

class DoHHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path in ["/", "/health"]:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status": "online", "service": "CottenDNS-Render"}')
            return

        if parsed.path == "/dns-query":
            params = parse_qs(parsed.query)
            if "dns" in params:
                try:
                    b64_dns = params["dns"][0]
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
    print(f"[*] Starting CottenDNS DoH Gateway on 0.0.0.0:{RENDER_PORT}", flush=True)
    server = ThreadingHTTPServer(("0.0.0.0", RENDER_PORT), DoHHandler)
    server.serve_forever()
EOF

# ۵. ایجاد لینک بدون پسوند برای جلوگیری از خطای تایپی احتمالی در Start Command پنل Render
RUN ln -sf /app/render_gateway.py /app/render_gateway

# ۶. ساخت خودکار اسکریپت راه‌انداز (entrypoint.sh)
RUN cat << 'EOF' > /app/entrypoint.sh
#!/usr/bin/env bash
set -e

export INTERNAL_DNS_PORT=5353

find . -maxdepth 2 -type f \( -name "*.json" -o -name "*.yaml" -o -name "*.yml" -o -name "*.conf" -o -name "*.py" -o -name "*.go" \) \
  ! -name "render_gateway.py" \
  -exec sed -i 's/:53\b/:5353/g; s/"port": *53/"port": 5353/g; s/PORT *= *53/PORT = 5353/g' {} + 2>/dev/null || true

if [ -f "./CottenDNS" ]; then
    ./CottenDNS &
elif [ -f "main.py" ]; then
    python3 main.py &
elif [ -f "app.py" ]; then
    python3 app.py &
elif [ -f "server.py" ]; then
    python3 server.py &
elif [ -f "index.js" ]; then
    node index.js &
fi

exec python3 /app/render_gateway.py
EOF

RUN chmod +x /app/entrypoint.sh /app/render_gateway.py

EXPOSE 10000

CMD ["/app/entrypoint.sh"]
