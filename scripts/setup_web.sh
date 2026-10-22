#!/usr/bin/env bash
# One-time bootstrap for the WEB SERVER (Amazon Linux 2023).
# Installs Docker and nginx; the app itself arrives as a container from Docker Hub
# when the pipeline first deploys.
# Usage:  sudo bash setup_web.sh        (prompts for the RDS settings)
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo bash $0" >&2
  exit 1
fi

check() {  # check <label> <value> <allowed-regex> <allowed-description>
  if [[ ! "$2" =~ $3 ]]; then
    echo "Invalid $1: only $4 are allowed." >&2
    exit 1
  fi
}

read -r -p "RDS endpoint (e.g. proj5-mysql.xxxx.ap-south-1.rds.amazonaws.com): " DB_HOST
read -r -p "DB username [admin]: " DB_USER
read -r -p "DB name [appdb]: " DB_NAME
read -r -s -p "DB password: " DB_PASSWORD
echo
DB_USER="${DB_USER:-admin}"
DB_NAME="${DB_NAME:-appdb}"

check "DB endpoint" "$DB_HOST" '^[A-Za-z0-9._-]+$' "letters, digits and . _ -"
check "DB username" "$DB_USER" '^[A-Za-z0-9_]+$' "letters, digits and underscore"
check "DB name" "$DB_NAME" '^[A-Za-z0-9_]+$' "letters, digits and underscore"
check "DB password" "$DB_PASSWORD" '^[A-Za-z0-9_]+$' "letters, digits and underscore"

dnf install -y docker nginx
systemctl enable --now docker

# Settings passed to the container with --env-file. Docker reads KEY=VALUE lines
# literally (no quotes). Only root can read it; deploy.sh uses sudo.
cat > /etc/webapp.env <<EOF
DB_HOST=$DB_HOST
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME
EOF
chown root:root /etc/webapp.env
chmod 600 /etc/webapp.env

# Minimal nginx config: reverse proxy everything to the container on 127.0.0.1:8000.
cat > /etc/nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    access_log /var/log/nginx/access.log;

    server {
        listen 80 default_server;
        server_name _;

        location / {
            proxy_pass http://127.0.0.1:8000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
EOF

systemctl enable --now nginx

echo
echo "Web server ready (Docker $(docker --version | cut -d' ' -f3 | tr -d ,) + nginx)."
echo "nginx returns 502 until the first pipeline deploy starts the container - that is expected."
