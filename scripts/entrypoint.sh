#!/bin/bash
set -e

WP_ROOT="/var/www/vhosts/${DOMAIN}/html"
WP_CLI="wp --path=${WP_ROOT} --allow-root"

log() {
    echo "[entrypoint] $*"
}

wait_for_mysql() {
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
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

install_wp_cli() {
    if [ ! -f /usr/local/bin/wp ]; then
        log "Installing wp-cli..."
        curl -sS https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
        chmod +x /usr/local/bin/wp
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
EXTRA
        chown nobody:nogroup "${WP_ROOT}/wp-config.php"
    fi
}

install_wordpress() {
    if ! ${WP_CLI} core is-installed 2>/dev/null; then
        log "Installing WordPress..."
        ${WP_CLI} core install \
            --url="http://${DOMAIN}" \
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
        log "Configuring LSCache Redis object cache..."
        ${WP_CLI} litespeed-option set object-kind 1
        ${WP_CLI} litespeed-option set object-host '/var/run/redis/redis.sock'
        ${WP_CLI} litespeed-option set object-port '' || true
        ${WP_CLI} litespeed-option set object-life 360
        ${WP_CLI} litespeed-option set object-persistent 1
        ${WP_CLI} litespeed-option set object-admin 1
        ${WP_CLI} litespeed-option set object 1 || true
        log "LSCache Redis object cache configured"
    fi
}

log "Starting entrypoint for domain: ${DOMAIN}"

install_wp_cli
wait_for_mysql
download_wordpress
generate_wp_config
install_wordpress
setup_lscache

log "Starting OpenLiteSpeed..."
/usr/local/lsws/bin/lswsctrl start

while true; do
    if ! /usr/local/lsws/bin/lswsctrl status 2>/dev/null | grep -q 'litespeed is running'; then
        log "OpenLiteSpeed is not running, exiting"
        break
    fi
    sleep 60
done
