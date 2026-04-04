#!/bin/bash
set -e

DOMAIN="${DOMAIN:-$1}"
EMAIL="${EMAIL:-$2}"

if [ -z "${DOMAIN}" ] || [ -z "${EMAIL}" ]; then
    echo "Usage: ./scripts/setup-ssl.sh [DOMAIN] [EMAIL]"
    echo "   Or set DOMAIN and EMAIL in .env"
    exit 1
fi

if [ -z "${COMPOSE_PROJECT_NAME}" ]; then
    COMPOSE_PROJECT_NAME="wp"
fi

OLS_CONTAINER="${COMPOSE_PROJECT_NAME}-ols"

echo "[SSL] Checking if OLS container is running..."
if ! docker ps --format '{{.Names}}' | grep -q "^${OLS_CONTAINER}$"; then
    echo "ERROR: OLS container '${OLS_CONTAINER}' is not running."
    echo "Start the stack first: docker compose up -d"
    exit 1
fi

echo "[SSL] Checking DNS resolution for ${DOMAIN}..."
SERVER_IP=$(curl -s https://ifconfig.me 2>/dev/null || curl -s https://api.ipify.org 2>/dev/null)
DOMAIN_IP=$(dig +short "${DOMAIN}" | tail -1)

if [ -z "${DOMAIN_IP}" ]; then
    echo "ERROR: ${DOMAIN} does not resolve to any IP address."
    echo "Please configure DNS before running this script."
    exit 1
fi

if [ "${DOMAIN_IP}" != "${SERVER_IP}" ]; then
    echo "WARNING: ${DOMAIN} resolves to ${DOMAIN_IP}, but this server's IP is ${SERVER_IP}."
    echo "SSL certificate request may fail if DNS is not pointing to this server."
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "[SSL] Setting up SSL certificate for ${DOMAIN}..."
docker exec "${OLS_CONTAINER}" bash -c "
set -e

DOMAIN='${DOMAIN}'
EMAIL='${EMAIL}'
VHOST_DIR='/usr/local/lsws/conf/vhosts/${DOMAIN}'
SSL_DIR='/var/www/vhosts/${DOMAIN}'

mkdir -p \"\${VHOST_DIR}\"
mkdir -p \"\${SSL_DIR}\"

echo '[SSL] Installing acme.sh if needed...'
if [ ! -f /root/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh -s email=\${EMAIL}
fi

echo '[SSL] Requesting certificate for \${DOMAIN}...'
/root/.acme.sh/acme.sh --issue -d \"\${DOMAIN}\" -w \"\${SSL_DIR}\" --webroot \"\${SSL_DIR}\"

echo '[SSL] Installing certificate...'
mkdir -p \"\${VHOST_DIR}\"
/root/.acme.sh/acme.sh --install-cert -d \"\${DOMAIN}\" \
    --key-file \"\${VHOST_DIR}/ssl.key\" \
    --fullchain-file \"\${VHOST_DIR}/ssl.crt\" \
    --reloadcmd 'echo SSL cert installed'

echo '[SSL] Copying certs to host-mounted ssl/ directory...'
cp \"\${VHOST_DIR}/ssl.key\" /usr/local/lsws/conf/vhosts/${DOMAIN}/ssl.key
cp \"\${VHOST_DIR}/ssl.crt\" /usr/local/lsws/conf/vhosts/${DOMAIN}/ssl.crt

echo '[SSL] Restarting OpenLiteSpeed...'
/usr/local/lsws/bin/lswsctrl restart

echo '[SSL] SSL certificate installed successfully!'
"

echo "[SSL] Done! HTTPS should now be active for ${DOMAIN}"
echo "[SSL] Certificate will auto-renew via acme.sh cron job inside the container."
