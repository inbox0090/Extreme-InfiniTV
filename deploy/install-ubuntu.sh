#!/usr/bin/env bash
# Extreme InfiniTV — Ubuntu Server installer
#
# Hosts the existing Astro production build with Nginx. It does not modify
# provider credentials, API calls, playback code, routes, or application data.
# Usage: sudo bash deploy/install-ubuntu.sh [domain-or-_]

set -Eeuo pipefail

APP_NAME="extreme-infinitv"
APP_ROOT="/opt/${APP_NAME}"
WEB_ROOT="/var/www/${APP_NAME}"
NGINX_SITE="/etc/nginx/sites-available/${APP_NAME}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${APP_NAME}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DOMAIN="${1:-_}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash deploy/install-ubuntu.sh [domain-or-_]" >&2
  exit 1
fi

if [[ ! "${DOMAIN}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid domain. Use a hostname such as tv.example.com or _." >&2
  exit 1
fi

if [[ ! -d "${SOURCE_DIR}/dist" ]] || [[ -z "$(find "${SOURCE_DIR}/dist" -maxdepth 1 -name 'index.html' -print -quit)" ]]; then
  cat >&2 <<'EOF'
No production build was found in dist/.

Build the project before installing:
  corepack enable
  pnpm install --frozen-lockfile
  pnpm run build
EOF
  exit 1
fi

echo "[1/6] Installing Nginx…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx

echo "[2/6] Copying this release to ${APP_ROOT}…"
rm -rf "${APP_ROOT}"
install -d -m 0755 "${APP_ROOT}"
# Archive-friendly copy: keeps deployment scripts and the source for inspection.
cp -a "${SOURCE_DIR}/." "${APP_ROOT}/"
rm -rf "${APP_ROOT}/node_modules" "${APP_ROOT}/.git"

echo "[3/6] Publishing the existing static production build…"
rm -rf "${WEB_ROOT}"
install -d -m 0755 "${WEB_ROOT}"
cp -a "${APP_ROOT}/dist/." "${WEB_ROOT}/"
chown -R root:root "${WEB_ROOT}"
find "${WEB_ROOT}" -type d -exec chmod 0755 {} \;
find "${WEB_ROOT}" -type f -exec chmod 0644 {} \;

echo "[4/6] Writing the Nginx site configuration…"
cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WEB_ROOT};
    index index.html;
    charset utf-8;

    # Keeps client-side paths compatible with the existing app routes.
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Fingerprinted production assets are safe to cache aggressively.
    location ~* \.(?:css|js|mjs|map|woff2?|ttf|otf|svg|png|jpe?g|webp|avif|ico|mp4|webm)$ {
        expires 30d;
        add_header Cache-Control "public, max-age=2592000, immutable";
        try_files \$uri =404;
    }

    # HTML should refresh promptly after a release update.
    location ~* \.(?:html|json|xml)$ {
        add_header Cache-Control "no-cache";
        try_files \$uri =404;
    }

    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
}
EOF

ln -sfn "${NGINX_SITE}" "${NGINX_ENABLED}"
rm -f /etc/nginx/sites-enabled/default

echo "[5/6] Validating and starting the systemd-managed web service…"
nginx -t
systemctl enable nginx
systemctl restart nginx

echo "[6/6] Done."
echo
printf 'Extreme InfiniTV is now served by Nginx at: http://%s/\n' "${DOMAIN}"
echo "Release files: ${APP_ROOT}"
echo "Web root:      ${WEB_ROOT}"
echo
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  echo "UFW is active. If port 80 is not already allowed, run:"
  echo "  sudo ufw allow 'Nginx HTTP'"
fi
if [[ "${DOMAIN}" != "_" ]]; then
  echo "For HTTPS after DNS points to this server, install Certbot and run:"
  echo "  sudo apt-get install -y certbot python3-certbot-nginx"
  echo "  sudo certbot --nginx -d ${DOMAIN}"
fi
