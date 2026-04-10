#!/bin/bash
set -e

WP_ROOT="/var/www/vhosts/localhost/html"
WP_CLI="wp --path=${WP_ROOT} --allow-root"

log() {
    echo "[entrypoint] $*"
}

validate_passwords() {
    # Reject weak default passwords
    if [[ "${WP_ADMIN_PASSWORD}" == "changeme" ]]; then
        log "ERROR: WP_ADMIN_PASSWORD uses default value 'changeme'. Please set a strong password in .env"
        exit 1
    fi
    if [[ "${MYSQL_PASSWORD}" == "secure_password_change_me" ]]; then
        log "ERROR: MYSQL_PASSWORD uses default value. Please set a strong password in .env"
        exit 1
    fi
    if [[ "${MYSQL_ROOT_PASSWORD}" == "root_secure_password_change_me" ]]; then
        log "ERROR: MYSQL_ROOT_PASSWORD uses default value. Please set a strong password in .env"
        exit 1
    fi
}

wait_for_mysql() {
    local max_attempts=30
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        if mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -S /var/run/mysqld/mysqld.sock -e "SELECT 1" &>/dev/null; then
            log "MariaDB is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        log "Waiting for MariaDB... (attempt $attempt/$max_attempts)"
        sleep 2
    done
    log "ERROR: MariaDB did not become ready in time"
    return 1
}

wait_for_redis() {
    local max_attempts=30
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        if [ -S /var/run/redis/redis.sock ]; then
            log "Redis is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        log "Waiting for Redis... (attempt $attempt/$max_attempts)"
        sleep 2
    done
    log "ERROR: Redis did not become ready in time"
    return 1
}

install_wp_cli() {
    if [ ! -f /usr/local/bin/wp ]; then
        log "Installing wp-cli..."
        curl -sS https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /tmp/wp-cli.phar
        EXPECTED_HASH=$(curl -sS https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512)
        ACTUAL_HASH=$(sha512sum /tmp/wp-cli.phar | awk '{print $1}')
        if [ "${ACTUAL_HASH}" = "${EXPECTED_HASH}" ]; then
            mv /tmp/wp-cli.phar /usr/local/bin/wp
            chmod +x /usr/local/bin/wp
            log "wp-cli installed and verified"
        else
            log "ERROR: wp-cli checksum verification failed"
            log "  Expected: ${EXPECTED_HASH}"
            log "  Actual:   ${ACTUAL_HASH}"
            exit 1
        fi
    fi
}

download_wordpress() {
    if [ ! -f "${WP_ROOT}/wp-load.php" ]; then
        log "Downloading WordPress..."
        mkdir -p "${WP_ROOT}"
        ${WP_CLI} core download --locale=en_US
        chown -R nobody:nogroup "${WP_ROOT}"
    fi
}

generate_wp_config() {
    if [ ! -f "${WP_ROOT}/wp-config.php" ]; then
        log "Generating wp-config.php..."
        ${WP_CLI} config create \
            --dbname="${MYSQL_DATABASE}" \
            --dbuser="${MYSQL_USER}" \
            --dbpass="${MYSQL_PASSWORD}" \
            --dbhost="localhost:/var/run/mysqld/mysqld.sock" \
            --dbprefix="${WORDPRESS_TABLE_PREFIX}" \
            --extra-php <<'EXTRA'
define('WP_DEBUG', false);
define('WP_DEBUG_LOG', false);
define('WP_MEMORY_LIMIT', '256M');
define('WP_MAX_MEMORY_LIMIT', '512M');
define('DISALLOW_FILE_EDIT', true);
define('DISABLE_WP_CRON', true);
if (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on') {
    define('FORCE_SSL_ADMIN', true);
}
EXTRA
        chown nobody:nogroup "${WP_ROOT}/wp-config.php"
    fi
}

install_wordpress() {
    if ! ${WP_CLI} core is-installed 2>/dev/null; then
        log "Installing WordPress..."
        local wp_scheme="http"
        if [ "${SSL}" = "1" ]; then
            wp_scheme="https"
        fi
        ${WP_CLI} core install \
            --url="${wp_scheme}://${DOMAIN}" \
            --title="${WP_SITE_TITLE}" \
            --admin_user="${WP_ADMIN_USER}" \
            --admin_password="${WP_ADMIN_PASSWORD}" \
            --admin_email="${WP_ADMIN_EMAIL}"
        log "WordPress installed successfully"
    fi
}

setup_lscache() {
    if ${WP_CLI} core is-installed 2>/dev/null; then
        if ! ${WP_CLI} plugin is-installed litespeed-cache 2>/dev/null; then
            log "Installing LSCache plugin..."
            ${WP_CLI} plugin install litespeed-cache --activate
        fi
        ${WP_CLI} plugin activate litespeed-cache 2>/dev/null || true
        log "Configuring LSCache Redis object cache..."
        ${WP_CLI} litespeed-option set object-kind 1 || true
        ${WP_CLI} litespeed-option set object-host '/var/run/redis/redis.sock' || true
        ${WP_CLI} litespeed-option set object-port '' || true
        ${WP_CLI} litespeed-option set object-life 360 || true
        ${WP_CLI} litespeed-option set object-persistent 1 || true
        ${WP_CLI} litespeed-option set object-admin 1 || true
        ${WP_CLI} litespeed-option set object 1 || true
        log "LSCache Redis object cache configured"
    fi
}

fix_permissions() {
    log "Fixing WordPress file permissions..."
    find "${WP_ROOT}" -not -user nobody -exec chown nobody:nogroup {} +
}

update_wp_urls_https() {
    if [ "${SSL}" = "1" ] && ${WP_CLI} core is-installed 2>/dev/null; then
        log "Updating WordPress URLs to HTTPS..."
        ${WP_CLI} option update siteurl "https://${DOMAIN}" --allow-root 2>/dev/null || true
        ${WP_CLI} option update home "https://${DOMAIN}" --allow-root 2>/dev/null || true
        ${WP_CLI} search-replace "http://${DOMAIN}" "https://${DOMAIN}" --all-tables --precise --allow-root 2>/dev/null || true
        ${WP_CLI} cache flush --allow-root 2>/dev/null || true
    fi
}

generate_self_signed_cert() {
    local ssl_dir="/usr/local/lsws/conf/vhosts/localhost/ssl"
    if [ ! -s "${ssl_dir}/ssl.key" ] || [ ! -s "${ssl_dir}/ssl.crt" ]; then
        log "Generating self-signed SSL certificate..."
        mkdir -p "${ssl_dir}"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "${ssl_dir}/ssl.key" \
            -out "${ssl_dir}/ssl.crt" \
            -subj "/CN=localhost" 2>/dev/null
        chmod 640 "${ssl_dir}/ssl.key"
        chmod 644 "${ssl_dir}/ssl.crt"
    fi
}

configure_ols_workers() {
    local workers="${OLS_WORKERS:-4}"
    local config_file="/usr/local/lsws/conf/httpd_config.conf"
    if [ -f "${config_file}" ]; then
        log "Configuring OLS workers to ${workers}..."
        local tmp_file="/tmp/httpd_config.tmp"
        sed -e "s/PHP_LSAPI_CHILDREN=[0-9]*/PHP_LSAPI_CHILDREN=${workers}/" \
            -e "s/maxConns\s*35/maxConns                       ${workers}/" \
            "${config_file}" > "${tmp_file}"
        cat "${tmp_file}" > "${config_file}"
        rm -f "${tmp_file}"
    fi
}

log "Starting entrypoint for domain: ${DOMAIN}"
validate_passwords

install_wp_cli
wait_for_mysql
wait_for_redis
download_wordpress
generate_wp_config
install_wordpress
setup_lscache
fix_permissions
update_wp_urls_https
generate_self_signed_cert
configure_ols_workers

setup_wp_cron() {
    if ! command -v cron &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq cron >/dev/null 2>&1 || true
    fi
    if command -v cron &>/dev/null; then
        echo "*/5 * * * * root wp --path=${WP_ROOT} --allow-root cron event run --due-now 2>/dev/null" > /etc/cron.d/wp-cron
        chmod 0644 /etc/cron.d/wp-cron
        cron
        log "WP-Cron scheduled (every 5 min via cron)"
    else
        log "WARNING: cron not available, WP-Cron will not run"
    fi
}

log "Starting OpenLiteSpeed..."
setup_wp_cron
/usr/local/lsws/bin/lswsctrl start

shutdown() {
    log "Caught signal, stopping OpenLiteSpeed..."
    /usr/local/lsws/bin/lswsctrl stop
    exit 0
}
trap shutdown SIGTERM SIGINT

sleep 1
OLS_PID=""
if [ -f /usr/local/lsws/logs/httpd.pid ]; then
    OLS_PID="$(cat /usr/local/lsws/logs/httpd.pid 2>/dev/null || echo "")"
fi
if [ -n "${OLS_PID}" ]; then
    while kill -0 "${OLS_PID}" 2>/dev/null; do
        sleep 5
    done
    log "OpenLiteSpeed process exited"
else
    while true; do
        if ! /usr/local/lsws/bin/lswsctrl status 2>/dev/null | grep -q 'litespeed is running'; then
            log "OpenLiteSpeed is not running, exiting"
            break
        fi
        sleep 5
    done
fi
