FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

# نصب پیش‌نیازهای سیستم، پایتون، گولنگ و ابزارهای شبکه
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    golang-go \
    nodejs \
    npm \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# کپی کردن کل فایل‌های مخزن CottenDNS
COPY . /app

# نصب خودکار وابستگی‌ها بر اساس ساختار مخزن
RUN if [ -f "requirements.txt" ]; then pip3 install --no-cache-dir -r requirements.txt; fi && \
    if [ -f "go.mod" ]; then go build -o CottenDNS .; fi && \
    if [ -f "package.json" ]; then npm install --production; fi

# دادن دسترسی اجرا به اسکریپت راه‌انداز
RUN chmod +x /app/entrypoint.sh

EXPOSE 10000

CMD ["/app/entrypoint.sh"]
