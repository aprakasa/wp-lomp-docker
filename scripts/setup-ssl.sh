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

# Input validation to prevent command injection
validate_input() {
    local var="$1"
    local name="$2"
    # Only allow alphanumeric, dots, hyphens, and @ for email
    if [[ ! "$var" =~ ^[a-zA-Z0-9.@-]+$ ]]; then
        echo "ERROR: Invalid characters in ${name}. Only alphanumeric, ., -, and @ are allowed."
        exit 1
    fi
}

if [ -z "${DOMAIN}" ] || [ -z "${EMAIL}" ]; then
    echo "Usage: ./scripts/setup-ssl.sh [DOMAIN] [EMAIL]"
    echo "   Or set DOMAIN and EMAIL in .env"
    exit 1
fi

# Validate inputs to prevent command injection
validate_input "${DOMAIN}" "DOMAIN"
validate_input "${EMAIL}" "EMAIL"

if [ -z "${COMPOSE_PROJECT_NAME}" ]; then
    COMPOSE_PROJECT_NAME="wp"
fi

OLS_CONTAINER="${COMPOSE_PROJECT_NAME}-ols"
SSL_DIR="$(cd "$(dirname "$0")/.." && pwd)/ssl"
SSL_CONTAINER_DIR="/usr/local/lsws/conf/vhosts/localhost/ssl"

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

echo "[SSL] Verifying ACME challenge path is reachable..."
ACME_TEST_DIR="/var/www/vhosts/localhost/html/.well-known/acme-challenge"
docker exec "${OLS_CONTAINER}" bash -c "
    mkdir -p '${ACME_TEST_DIR}'
    echo 'test' > '${ACME_TEST_DIR}/test.txt'
    chown -R nobody:nogroup '${ACME_TEST_DIR}'
"

ACME_URL="http://${DOMAIN}/.well-known/acme-challenge/test.txt"
ACME_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${ACME_URL}" 2>/dev/null)
docker exec "${OLS_CONTAINER}" rm -f "${ACME_TEST_DIR}/test.txt"

if [ "${ACME_RESPONSE}" != "200" ]; then
    echo "WARNING: ACME challenge path returned HTTP ${ACME_RESPONSE} (expected 200)."
    echo "  Tested: ${ACME_URL}"
    echo "  SSL certificate request may fail. Ensure:"
    echo "    1. DNS for ${DOMAIN} points to this server"
    echo "    2. Port 80 is open and reachable from the internet"
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
    curl -sS https://get.acme.sh | sh -s email=\${EMAIL} --noprofile
fi

echo '[SSL] Requesting certificate for '\${DOMAIN}'...'
echo '[SSL] (this may take 30-60 seconds...)'
if ! /root/.acme.sh/acme.sh --issue -d \"\${DOMAIN}\" -w \"\${WEBROOT}\" --server letsencrypt 2>&1; then
    echo '[SSL] Initial issue failed.'
    echo '[SSL] Checking if rate-limited...'
    if /root/.acme.sh/acme.sh --list 2>/dev/null | grep -q \"\${DOMAIN}\"; then
        echo '[SSL] Existing cert found, retrying with --force...'
        /root/.acme.sh/acme.sh --issue -d \"\${DOMAIN}\" -w \"\${WEBROOT}\" --server letsencrypt --force 2>&1
    else
        echo '[SSL] ERROR: Certificate issue failed. Common causes:'
        echo '  - Rate limit exceeded (wait and retry later)'
        echo '  - DNS not pointing to this server'
        echo '  - Port 80 not accessible from internet'
        exit 1
    fi
fi

echo '[SSL] Installing certificate...'
/root/.acme.sh/acme.sh --install-cert -d \"\${DOMAIN}\" \
    --key-file ${SSL_CONTAINER_DIR}/ssl.key \
    --fullchain-file ${SSL_CONTAINER_DIR}/ssl.crt \
    --reloadcmd 'echo done'
chown nobody:nogroup ${SSL_CONTAINER_DIR}/ssl.key ${SSL_CONTAINER_DIR}/ssl.crt
chmod 640 ${SSL_CONTAINER_DIR}/ssl.key
chmod 644 ${SSL_CONTAINER_DIR}/ssl.crt
"

echo "[SSL] Restarting OLS to load new certificates..."
docker compose restart openlitespeed

echo "[SSL] Done! HTTPS should now be active for ${DOMAIN}"
echo "[SSL] NOTE: Auto-renewal is NOT configured (containers are ephemeral)."
echo "[SSL] Run this script again before the certificate expires (90 days), or set up a host cron job."
