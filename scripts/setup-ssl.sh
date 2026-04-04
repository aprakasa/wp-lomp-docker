#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [ -f "${ENV_FILE}" ]; then
    set -a
    source "${ENV_FILE}"
    set +a
fi

DOMAIN="${1:-$DOMAIN}"
EMAIL="${2:-$EMAIL}"

if [ -z "${DOMAIN}" ] || [ -z "${EMAIL}" ]; then
    echo "Usage: ./scripts/setup-ssl.sh [DOMAIN] [EMAIL]"
    echo "   Or set DOMAIN and EMAIL in .env"
    exit 1
fi

if [ -z "${COMPOSE_PROJECT_NAME}" ]; then
    COMPOSE_PROJECT_NAME="wp"
fi

OLS_CONTAINER="${COMPOSE_PROJECT_NAME}-ols"
SSL_DIR="$(cd "$(dirname "$0")/.." && pwd)/ssl"

echo "[SSL] Checking if OLS container is running..."
if ! docker ps --format '{{.Names}}' | grep -q "^${OLS_CONTAINER}$"; then
    echo "ERROR: OLS container '${OLS_CONTAINER}' is not running."
    echo "Start the stack first: docker compose up -d"
    exit 1
fi

echo "[SSL] Checking DNS resolution for ${DOMAIN}..."
SERVER_IP=$(curl -s -4 https://ifconfig.me 2>/dev/null || curl -s -4 https://api.ipify.org 2>/dev/null)
DOMAIN_IP=$(dig +short "${DOMAIN}" 2>/dev/null | tail -1)
if [ -z "${DOMAIN_IP}" ]; then
    DOMAIN_IP=$(getent hosts "${DOMAIN}" 2>/dev/null | awk '{print $1}')
fi
if [ -z "${DOMAIN_IP}" ]; then
    DOMAIN_IP=$(host "${DOMAIN}" 2>/dev/null | grep 'has address' | head -1 | awk '{print $4}')
fi
if [ -z "${DOMAIN_IP}" ]; then
    DOMAIN_IP=$(nslookup "${DOMAIN}" 2>/dev/null | grep 'Address' | tail -1 | awk '{print $2}')
fi

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
WEBROOT='/var/www/vhosts/localhost/html'

echo '[SSL] Installing acme.sh if needed...'
if [ ! -f /root/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh -s email=\${EMAIL}
fi

echo '[SSL] Requesting certificate for '\${DOMAIN}'...'
/root/.acme.sh/acme.sh --issue -d \"\${DOMAIN}\" -w \"\${WEBROOT}\" --server letsencrypt --force

echo '[SSL] Installing certificate to temp location...'
/root/.acme.sh/acme.sh --install-cert -d \"\${DOMAIN}\" \
    --key-file /tmp/ssl.key \
    --fullchain-file /tmp/ssl.crt \
    --reloadcmd 'echo done'
"

echo "[SSL] Copying certs to ${SSL_DIR}/..."
mkdir -p "${SSL_DIR}"
docker cp "${OLS_CONTAINER}:/tmp/ssl.key" "${SSL_DIR}/ssl.key"
docker cp "${OLS_CONTAINER}:/tmp/ssl.crt" "${SSL_DIR}/ssl.crt"
chmod 644 "${SSL_DIR}/ssl.key" "${SSL_DIR}/ssl.crt" 2>/dev/null || sudo chmod 644 "${SSL_DIR}/ssl.key" "${SSL_DIR}/ssl.crt"

echo "[SSL] Restarting OLS to load new certificates..."
docker compose restart openlitespeed

echo "[SSL] Done! HTTPS should now be active for ${DOMAIN}"
echo "[SSL] Certificate will auto-renew via acme.sh cron job inside the container."
