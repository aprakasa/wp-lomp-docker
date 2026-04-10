#!/bin/sh
set -eu

DOMAIN="${DOMAIN:-localhost}"
SSL="${SSL:-0}"
SSL_STAGING="${SSL_STAGING:-0}"
EMAIL="${EMAIL:-}"
OLS_CONTAINER="${OLS_CONTAINER:-wp-ols}"
SSL_DIR="/ssl"
WEBROOT="/webroot"

if [ "${SSL}" != "1" ]; then
    echo "[acme-sh] SSL is disabled, sleeping."
    exec sleep infinity
fi

if [ -z "${DOMAIN}" ] || [ "${DOMAIN}" = "localhost" ]; then
    echo "[acme-sh] ERROR: DOMAIN must be set to a real domain name (not localhost)"
    exit 1
fi

if [ -z "${EMAIL}" ]; then
    echo "[acme-sh] ERROR: EMAIL must be set for Let's Encrypt registration"
    exit 1
fi

mkdir -p "${SSL_DIR}"

if [ -f "${SSL_DIR}/ssl.crt" ]; then
    if ! openssl x509 -in "${SSL_DIR}/ssl.crt" -noout -subject 2>/dev/null | grep -q "CN.*=.*localhost"; then
        echo "[acme-sh] Certificate already exists for ${DOMAIN}"
        echo "[acme-sh] Starting acme.sh daemon for auto-renewal..."
        exec /entry.sh daemon
    fi
fi

echo "[acme-sh] Obtaining SSL certificate for ${DOMAIN}..."

ACME_ARGS="--webroot ${WEBROOT} -d ${DOMAIN} --keylength ec-256"

if [ "${SSL_STAGING}" = "1" ]; then
    ACME_ARGS="${ACME_ARGS} --staging"
fi

acme.sh --register-account -m "${EMAIL}"
acme.sh --set-default-ca --server letsencrypt

if ! acme.sh --issue ${ACME_ARGS}; then
    echo "[acme-sh] Failed to obtain certificate, cleaning up and sleeping 1h before retry"
    acme.sh --remove -d "${DOMAIN}" --ecc 2>/dev/null || true
    rm -rf "/acme.sh/${DOMAIN}_ecc" 2>/dev/null || true
    exec sleep 3600
fi

acme.sh --install-cert -d "${DOMAIN}" --ecc \
    --fullchain-file "${SSL_DIR}/ssl.crt" \
    --key-file "${SSL_DIR}/ssl.key" \
    --reloadcmd "docker exec ${OLS_CONTAINER} /usr/local/lsws/bin/lswsctrl restart 2>/dev/null || true"

chmod 640 "${SSL_DIR}/ssl.key" 2>/dev/null || true
chmod 644 "${SSL_DIR}/ssl.crt" 2>/dev/null || true

echo "[acme-sh] Certificate obtained successfully"
echo "[acme-sh] Starting acme.sh daemon for auto-renewal..."
exec /entry.sh daemon
