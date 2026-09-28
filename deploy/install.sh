#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Harbor Desk ERP — install / update ONE site on this server.
#
# Called by the "Live / Update" .bat like this (from the just-unzipped release
# folder, so $PWD is that folder — server.js, package.json, deploy/, public/):
#
#   sudo HD_SITE=<site> bash deploy/install.sh <domain> <email>
#
# What it does, every single time it runs (first install AND every update):
#   1. Copies the new code into /opt/harbor-desk-<site>/app — NEVER touching
#      an existing harbor-desk.db there, so all data survives every update.
#   2. Installs node dependencies.
#   3. Picks a port for this site the FIRST time only (reused forever after),
#      so it can never collide with another site already running here.
#   4. Creates/updates an independent systemd service named
#      harbor-desk-<site> and (re)starts it.
#   5. If a domain was given: sets up an nginx reverse proxy for it, and if
#      an email was also given, requests a free HTTPS certificate (certbot).
#
# Every site gets its own systemd service, its own port, and its own nginx
# server block — installing/updating one site never touches any other site
# already running on this server.
# ---------------------------------------------------------------------------
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/site-paths.sh"

# Best-effort server IP for the messages below — local first (always works, no internet needed),
# falling back to an external lookup only if that comes up empty. Never lets a lookup failure show
# ugly proxy/network error text — anything unexpected just becomes "<server-ip>".
server_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [ -z "$ip" ]; then ip="$(curl -s -4 --max-time 3 ifconfig.me 2>/dev/null)"; fi
  case "$ip" in ""|*[!0-9.]*) echo "<server-ip>" ;; *) echo "$ip" ;; esac
}

DOMAIN="$1"
EMAIL="$2"
RELEASE_DIR="$PWD"

if [ ! -f "$RELEASE_DIR/server.js" ]; then
  echo "[X] server.js nahi mila is folder mein ($RELEASE_DIR) — galat jagah se chalaya gaya lagta hai." >&2
  exit 1
fi

echo "=============================================================="
echo "  Site: $SITE        App folder: $APP"
echo "=============================================================="

mkdir -p "$APP" "$DIR"

echo "[1/5] Naya code copy ho raha hai (database ko haath nahi lagaya jaata)..."
rsync -a --delete \
  --exclude 'node_modules' \
  --exclude '*.db' --exclude '*.db-*' \
  --exclude 'deploy' \
  --exclude 'startup-error.log' \
  "$RELEASE_DIR"/ "$APP"/

# Keep a permanent copy of deploy/ at $BASE/deploy (outside the throwaway /tmp extraction) — this is
# the stable path Backup / Data-Clean .bat files reference on future runs, so they keep working even
# though the /tmp extraction they were part of is deleted right after install finishes.
mkdir -p "$BASE/deploy"
cp -f "$RELEASE_DIR"/deploy/*.sh "$BASE/deploy/" 2>/dev/null || true

echo "[2/5] Dependencies install ho rahi hain (npm install)..."
cd "$APP"
npm install --omit=dev --no-audit --no-fund

echo "[3/5] Port check ho raha hai..."
if [ ! -f "$PORT_FILE" ]; then
  PORT=4000
  while ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${PORT}\$"; do PORT=$((PORT+1)); done
  echo "$PORT" > "$PORT_FILE"
  echo "      Naya port assign hua: $PORT (yeh hamesha isi site ke liye reserve rahega)"
else
  PORT="$(cat "$PORT_FILE")"
  echo "      Pehle se assign shuda port: $PORT"
fi

echo "[4/5] systemd service ($SERVICE) (re)start ho raha hai..."
cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=Harbor Desk ERP - $SITE
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP
Environment=PORT=$PORT
Environment=NODE_ENV=production
ExecStart=/usr/bin/env node $APP/server.js
Restart=always
RestartSec=3
User=root
StandardOutput=append:$BASE/service.log
StandardError=append:$BASE/service.log

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1 || true
systemctl restart "$SERVICE"
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then
  echo "[X] Service start nahi hui — log dekhein: journalctl -u $SERVICE -n 50" >&2
  systemctl --no-pager status "$SERVICE" || true
  exit 1
fi
echo "      [OK] $SERVICE chal raha hai (port $PORT)"

if [ -n "$DOMAIN" ]; then
  echo "[5/5] nginx + HTTPS set ho raha hai ($DOMAIN)..."
  command -v nginx >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y nginx)
  NGX="/etc/nginx/sites-available/$SITE"
  cat > "$NGX" <<EOF
server {
  listen 80;
  server_name $DOMAIN;
  client_max_body_size 20m;
  location / {
    proxy_pass http://127.0.0.1:$PORT;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
  ln -sf "$NGX" "/etc/nginx/sites-enabled/$SITE"
  if nginx -t 2>/tmp/nginx-test.log; then
    systemctl reload nginx
  else
    echo "[!] nginx config mein masla — details:"; cat /tmp/nginx-test.log
  fi

  if [ -n "$EMAIL" ]; then
    command -v certbot >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y certbot python3-certbot-nginx)
    certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect \
      || echo "[!] HTTPS certificate abhi nahi laga — DNS ka 'A' record shayad abhi is server ($(server_ip)) par point nahi ho raha. DNS theek hone ke baad yehi Live-Update file dobara chalayein."
  fi
else
  echo "[5/5] Domain nahi diya gaya — sirf http://<server-ip>:$PORT par chal raha hai."
fi

echo "=============================================================="
echo "  [OK] Site '$SITE' live hai."
[ -n "$DOMAIN" ] && echo "  https://$DOMAIN  (ya HTTPS na laga ho to http://$DOMAIN)"
echo "  Direct (bina domain ke): http://$(server_ip):$PORT"
echo "=============================================================="
