#!/usr/bin/env bash
set -e

echo "=== Initializing CottenDNS for Render ==="
export INTERNAL_DNS_PORT=5353

# ۱. تغییر خودکار پورت 53 به 5353 در فایل‌های کانفیگ احتمالی برای جلوگیری از خطای Permission در Render
find . -maxdepth 2 -type f \( -name "*.json" -o -name "*.yaml" -o -name "*.yml" -o -name "*.conf" -o -name "*.py" -o -name "*.go" \) \
  ! -name "render_gateway.py" \
  -exec sed -i 's/:53\b/:5353/g; s/"port": *53/"port": 5353/g; s/PORT *= *53/PORT = 5353/g' {} + 2>/dev/null || true

# ۲. تشخیص و اجرای هسته اصلی CottenDNS در پس‌زمینه
if [ -f "./CottenDNS" ]; then
    echo "[+] Running compiled CottenDNS binary..."
    ./CottenDNS &
elif [ -f "main.py" ]; then
    echo "[+] Running Python main.py..."
    python3 main.py &
elif [ -f "app.py" ]; then
    echo "[+] Running Python app.py..."
    python3 app.py &
elif [ -f "server.py" ]; then
    echo "[+] Running Python server.py..."
    python3 server.py &
elif [ -f "index.js" ]; then
    echo "[+] Running Node.js index.js..."
    node index.js &
fi

# ۳. اجرای گیت‌وی اصلی روی پورت Render ($PORT)
exec python3 render_gateway
.py
