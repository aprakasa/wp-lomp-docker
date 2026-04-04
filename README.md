# WP-LOMP-Docker

WordPress LOMP stack (Linux + OpenLiteSpeed + MariaDB + PHP) with Redis object caching, deployed via Docker Compose. All inter-service communication uses Unix sockets for maximum performance.

## Quick Start

```bash
git clone <repo-url> wp-lomp-docker
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

### Production Domain Setup

For production, update `DOMAIN` in `.env` and also update the domain references in `ols/httpd.conf`:

1. Replace all `localhost` occurrences with your domain name in the `virtualHost`, `listener HTTP`, and `listener HTTPS` blocks
2. The `ols/vhost.conf` uses template variables (`$VH_ROOT`, `$VH_NAME`) and doesn't need changes

## WordPress Files

WordPress files are in `./wordpress/` on the host, giving you direct filesystem access. This directory is created and populated automatically on first startup.

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
