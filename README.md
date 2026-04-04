# WP-LOMP-Docker

WordPress LOMP stack (Linux + OpenLiteSpeed + MariaDB + PHP) deployed via Docker Compose. Uses LSCache plugin with built-in Redis object cache. All inter-service communication uses Unix sockets for maximum performance.

## Quick Start

```bash
git clone git@github.com:aprakasa/wp-lomp-docker.git
cd wp-lomp-docker
cp .env.example .env
# Edit .env with your domain, database credentials, and WordPress admin settings
nano .env
docker compose up -d
```

WordPress will be automatically installed on first startup. Visit `http://your-domain` to see your site.

## SSL Setup (Production)

After DNS is pointing to your server:

```bash
./scripts/setup-ssl.sh your-domain.com admin@your-domain.com
```

Or set `DOMAIN` and `EMAIL` in `.env` and run:

```bash
./scripts/setup-ssl.sh
```

## What's Inside

| Component | Version | Notes |
|-----------|---------|-------|
| OpenLiteSpeed | latest | Web server with built-in LSCache |
| PHP | 8.x (bundled with OLS image) | LSAPI, PhpRedis 6.3.0 |
| MariaDB | 12 | InnoDB tuned, socket-only |
| Redis | 7 (Alpine) | Unix socket, maxmemory with allkeys-lru eviction |
| WordPress | latest | Auto-installed via WP-CLI |
| WP-CLI | latest | Auto-installed in entrypoint |
| LSCache | latest | Full-page cache + Redis object cache |
| acme.sh | latest | Let's Encrypt SSL via DNS validation |

## Architecture

| Service | Image | Port Exposure |
|---------|-------|---------------|
| OpenLiteSpeed | `litespeedtech/openlitespeed:latest` | 80, 443, 7080 (admin) |
| MariaDB | `mariadb:12` | None (socket only) |
| Redis | `redis:7-alpine` | None (socket only) |

All inter-service communication uses Unix sockets via shared Docker volumes:

- **PHP ↔ OLS**: LSAPI socket (`uds://tmp/lshttpd/lsphp.sock`)
- **MariaDB ↔ PHP**: MySQL socket (`/var/run/mysqld/mysqld.sock`)
- **Redis ↔ PHP**: Redis socket (`/var/run/redis/redis.sock`)

## Configuration

All configuration is done via `.env` (copy from `.env.example`):

| Variable | Default | Description |
|----------|---------|-------------|
| `DOMAIN` | `localhost` | Your domain name |
| `EMAIL` | `admin@example.com` | Admin email (used for SSL) |
| `MYSQL_ROOT_PASSWORD` | - | MariaDB root password |
| `MYSQL_DATABASE` | `wordpress` | Database name |
| `MYSQL_USER` | `wp_user` | Database user |
| `MYSQL_PASSWORD` | - | Database password |
| `INNODB_BUFFER_POOL_SIZE` | `256M` | MariaDB InnoDB buffer |
| `REDIS_MAXMEMORY` | `64mb` | Redis max memory |
| `WP_ADMIN_USER` | `admin` | WordPress admin username |
| `WP_ADMIN_PASSWORD` | - | WordPress admin password |
| `WP_ADMIN_EMAIL` | - | WordPress admin email |
| `WP_SITE_TITLE` | `WordPress` | Site title |
| `WORDPRESS_TABLE_PREFIX` | `wp_` | Database table prefix |
| `OLS_WORKERS` | `4` | OLS worker processes |
| `TZ` | `UTC` | Timezone |

### Production Domain Setup

Set `DOMAIN` in `.env` to your domain name. All internal paths use `localhost` — no config file edits needed. The OLS listener uses a catch-all (`*`) so it responds to any domain pointing to the server.

## WordPress Files

WordPress files are in `./wordpress/` on the host, giving you direct filesystem access. This directory is created and populated automatically on first startup.

## Caching

The **LSCache** plugin (`litespeed-cache`) is automatically installed and activated on first startup. It provides:

- **Full-page cache** served by OpenLiteSpeed (bypasses PHP entirely)
- **Redis object cache** using PhpRedis via Unix socket (`/var/run/redis/redis.sock`)

No additional cache plugins are needed. The Redis object cache connection is pre-configured via `wp litespeed-option set` during first startup.

## Logs

- **OLS logs**: `./logs/`
- **MariaDB logs**: `docker compose logs mariadb`
- **Redis logs**: `docker compose logs redis`

## OLS Admin Panel

Access the OpenLiteSpeed admin panel at `http://your-server:7080` with default credentials:
- Username: `admin`
- Password: (check `docker compose exec openlitespeed cat /usr/local/lsws/adminpasswd`)

## Commands

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# View logs
docker compose logs -f openlitespeed

# Restart OLS only
docker compose restart openlitespeed

# Access WordPress CLI
docker compose exec openlitespeed wp --path=/var/www/vhosts/$DOMAIN/html --allow-root <command>
```

## License

MIT
