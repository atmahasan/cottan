FROM python:3.11-slim

WORKDIR /app

# نصب کتابخانه تخصصی پردازش بسته‌های DNS
RUN pip install --no-cache-dir dnslib

# ۱. ساخت فایل کانفیگ آماده WhiteDNS / CottenDNS
RUN cat << 'EOF' > /app/whitedns_config.json
{
  "listen_port": 10000,
  "upstream_dns": [
    "1.1.1.1",
    "8.8.8.8",
    "9.9.9.9"
  ],
  "default_sni_proxy": "50.7.85.220",
  "rules": {
    "custom_records": {
      "openai.com": "50.7.85.220",
      "chatgpt.com": "50.7.85.220",
      "oaistatic.com": "50.7.85.220",
      "oaiusercontent.com": "50.7.85.220",
      "anthropic.com": "50.7.85.220",
      "claude.ai": "50.7.85.220",
      "gemini.google.com": "50.7.85.220",
      "bard.google.com": "50.7.85.220",
      "ai.google.dev": "50.7.85.220",
      "makersuite.google.com": "50.7.85.220",
      "generativelanguage.googleapis.com": "50.7.85.220",
      "alkalimakersuite-pa.clients6.google.com": "50.7.85.220",
      "copilot.microsoft.com": "50.7.85.220",
      "github.com": "140.82.121.4",
      "api.github.com": "140.82.121.6",
      "docker.com": "50.7.85.220",
      "registry-1.docker.io": "50.7.85.220",
      "auth.docker.io": "50.7.85.220",
      "production.cloudflare.docker.com": "50.7.85.220",
      "pkg.dev": "50.7.85.220",
      "dl.google.com": "50.7.85.220",
      "developer.android.com": "50.7.85.220",
      "gradle.org": "50.7.85.220",
      "maven.org": "50.7.85.220",
      "npmjs.org": "104.16.25.34",
      "pypi.org": "151.101.128.223",
      "epicgames.com": "50.7.85.220",
      "ea.com": "50.7.85.220",
      "origin.com": "50.7.85.220",
      "riotgames.com": "50.7.85.220",
      "leagueoflegends.com": "50.7.85.220",
      "valorant.com": "50.7.85.220",
      "brawlhallagame.com": "50.7.85.220",
      "supercell.com": "50.7.85.220",
      "spotify.com": "50.7.85.220",
      "twitch.tv": "50.7.85.220"
    },
    "blocked_domains": [
      "doubleclick.net",
      "googlesyndication.com",
      "googleadservices.com",
      "adservice.google.com",
      "app-measurement.com"
    ]
  }
}
EOF

# ۲. ساخت هسته اصلی سرور WhiteDNS / CottenDNS سازگار با Render
RUN cat << 'EOF' > /app/render_gateway.py
import os
import json
import socket
import base64
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs
from dnslib import DNSRecord, DNSHeader, RR, A, QTYPE, RCODE

CONFIG_PATH = "/app/whitedns_config.json"
with open(CONFIG_PATH, "r") as f:
    CONFIG = json.load(f)

RENDER_PORT = int(os.environ.get("PORT", CONFIG.get("listen_port", 10000)))
UPSTREAMS = CONFIG.get("upstream_dns", ["1.1.1.1", "8.8.8.8"])
CUSTOM_RECORDS = CONFIG.get("rules", {}).get("custom_records", {})
BLOCKED_DOMAINS = set(CONFIG.get("rules", {}).get("blocked_domains", []))

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

def match_domain(qname: str, domain_map: dict):
    qname = qname.rstrip(".").lower()
    if qname in domain_map:
        return domain_map[qname]
    for dom, ip in domain_map.items():
        if qname.endswith("." + dom):
            return ip
    return None

def is_blocked(qname: str) -> bool:
    qname = qname.rstrip(".").lower()
    for b in BLOCKED_DOMAINS:
        if qname == b or qname.endswith("." + b):
            return True
    return False

def resolve_dns(raw_query: bytes) -> bytes:
    try:
        request = DNSRecord.parse(raw_query)
        qname = str(request.q.qname)
        qtype = request.q.qtype

        # ۱. بررسی لیست سیاه (AdBlock)
        if is_blocked(qname):
            reply = request.reply()
            reply.header.rcode = RCODE.NXDOMAIN
            return reply.pack()

        # ۲. بررسی قوانین کاستوم و ضدتحریم WhiteDNS (فقط برای رکوردهای IPv4 / A)
        if qtype == QTYPE.A:
            spoof_ip = match_domain(qname, CUSTOM_RECORDS)
            if spoof_ip:
                reply = request.reply()
                reply.add_answer(RR(request.q.qname, QTYPE.A, rdata=A(spoof_ip), ttl=120))
                return reply.pack()
        elif qtype == QTYPE.AAAA:
            # اگر دامنه در لیست ضدتحریم بود، IPv6 را خالی برگردان تا کلاینت مجبور به استفاده از IPv4 شود
            if match_domain(qname, CUSTOM_RECORDS):
                reply = request.reply()
                return reply.pack()

    except Exception:
        pass

    # ۳. ارسال بقیه درخواست‌ها به DNS بالادستی (Cloudflare / Google)
    for upstream in UPSTREAMS:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(2.5)
        try:
            sock.sendto(raw_query, (upstream, 53))
            data, _ = sock.recvfrom(4096)
            return data
        except Exception:
            continue
        finally:
            sock.close()
    return b""

class WhiteDNSHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path in ["/", "/health"]:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            status = {
                "status": "online",
                "service": "WhiteDNS - CottenDNS",
                "loaded_rules": len(CUSTOM_RECORDS),
                "doh_endpoint": "/dns-query"
            }
            self.wfile.write(json.dumps(status).encode())
            return

        if parsed.path == "/dns-query":
            params = parse_qs(parsed.query)
            if "dns" in params:
                try:
                    b64_dns = params["dns"][0]
                    b64_dns += "=" * ((4 - len(b64_dns) % 4) % 4)
                    raw_query = base64.urlsafe_b64decode(b64_dns)
                    response = resolve_dns(raw_query)

                    self.send_response(200)
                    self.send_header("Content-Type", "application/dns-message")
                    self.send_header("Cache-Control", "max-age=120")
                    self.end_headers()
                    self.wfile.write(response)
                    return
                except Exception as e:
                    self.send_error(400, str(e))
                    return

        self.send_error(404, "Not Found")

    def do_POST(self):
        if self.path == "/dns-query":
            length = int(self.headers.get("Content-Length", 0))
            if length > 0:
                raw_query = self.rfile.read(length)
                response = resolve_dns(raw_query)

                self.send_response(200)
                self.send_header("Content-Type", "application/dns-message")
                self.end_headers()
                self.wfile.write(response)
                return
        self.send_error(404, "Not Found")

if __name__ == "__main__":
    print(f"[*] WhiteDNS / CottenDNS running on 0.0.0.0:{RENDER_PORT}", flush=True)
    server = ThreadingHTTPServer(("0.0.0.0", RENDER_PORT), WhiteDNSHandler)
    server.serve_forever()
EOF

# ایجاد لینک بدون پسوند برای جلوگیری از خطای Start Command در پنل Render
RUN ln -sf /app/render_gateway.py /app/render_gateway && chmod +x /app/render_gateway.py

EXPOSE 10000
CMD ["python3", "/app/render_gateway.py"]
