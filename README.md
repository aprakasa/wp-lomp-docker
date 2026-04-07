# WP-LOMP-Docker

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg?style=flat)](LICENSE)
[![Docker Compose](https://img.shields.io/badge/docker--compose-blue.svg?style=flat&logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![PHP](https://img.shields.io/badge/PHP-8.x-777BB4.svg?style=flat&logo=php&logoColor=white)](https://php.net/)
[![OpenLiteSpeed](https://img.shields.io/badge/OpenLiteSpeed-latest-009639.svg?style=flat&logo=openliterspeed&logoColor=white)](https://openlitespeed.org/)
[![MariaDB](https://img.shields.io/badge/MariaDB-12-003545.svg?style=flat&logo=mariadb&logoColor=white)](https://mariadb.org/)
[![Redis](https://img.shields.io/badge/Redis-7-DC382D.svg?style=flat&logo=redis&logoColor=white)](https://redis.io/)

WordPress LOMP stack (Linux + OpenLiteSpeed + MariaDB + PHP) deployed via Docker Compose. Uses LSCache plugin with built-in Redis object cache. All inter-service communication uses Unix sockets for maximum performance.

## Features

- **LSCache Plugin** — Full-page cache served by OpenLiteSpeed (bypasses PHP entirely)
- **Redis Object Cache** — Via Unix socket for minimal latency (`/var/run/redis/redis.sock`)
- **Unix Sockets** — All inter-service communication uses Unix sockets for maximum performance
- **Zero Configuration** — Auto-installs WordPress, WP-CLI, and LSCache on first startup
- **SSL Support** — acme.sh + Let's Encrypt with HTTP-01 webroot validation
- **Direct File Access** — WordPress files in `./wordpress/` on the host

## Architecture

```
flowchart TB
    Client(["🌐 Client"])

    subgraph Frontend
        OLS["OpenLiteSpeed<br/>LSCache · SSL · :80/:443/:7080"]
    end

    subgraph Application
        PHP["PHP 8.x<br/>WordPress · LSAPI · PhpRedis"]
    end

    subgraph Data
        MariaDB["MariaDB 12<br/>Database"]
        Redis["Redis 7<br/>Object Cache"]
    end

    Client -->|"HTTP/HTTPS"| OLS
    OLS <-->|"LSAPI Unix socket"| PHP
    PHP -->|"Unix socket"| MariaDB
    PHP <-->|"Unix socket"| Redis
```

## What's Inside

| Component | Version | Notes |
|-----------|---------|-------|
| OpenLiteSpeed | latest | Web server with built-in LSCache |
| PHP | 8.x (bundled with OLS) | LSAPI, PhpRedis 6.3.0 |
| MariaDB | 12 | InnoDB tuned, socket-only |
| Redis | 7 (Alpine) | Unix socket, maxmemory with allkeys-lru eviction |
| WordPress | latest | Auto-installed via WP-CLI |
| WP-CLI | latest | Auto-installed in entrypoint |
| LSCache | latest | Full-page cache + Redis object cache |
| acme.sh | latest | Let's Encrypt SSL via HTTP-01 webroot validation |

## Quick Start

1. Clone the repository:

```bash
git clone git@github.com:aprakasa/wp-lomp-docker.git
cd wp-lomp-docker
cp .env.example .env
```

2. Edit `.env` with your domain, database credentials, and WordPress admin settings:

```bash
nano .env
```

3. Start the stack:

```bash
docker compose up -d
```

4. Access WordPress at `http://your-domain`

WordPress will be automatically installed on first startup.

## SSL Setup (Production)

After DNS is pointing to your server:

```bash
./scripts/setup-ssl.sh your-domain.com admin@your-domain.com
```

Or set `DOMAIN` and `EMAIL` in `.env` and run:

```bash
./scripts/setup-ssl.sh
```

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
| `REDIS_MAXMEMORY` | `64mb` | Redis max memory |
| `WP_ADMIN_USER` | `admin` | WordPress admin username |
| `WP_ADMIN_PASSWORD` | - | WordPress admin password |
| `WP_ADMIN_EMAIL` | - | WordPress admin email |
| `WP_SITE_TITLE` | `WordPress` | Site title |
| `WORDPRESS_TABLE_PREFIX` | `wp_` | Database table prefix |
| `OLS_WORKERS` | `4` | PHP LSAPI children (worker processes) |
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

## Common Commands

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
docker compose exec openlitespeed wp --path=/var/www/vhosts/localhost/html --allow-root <command>
```

## Requirements

- Docker Engine 20.10+
- Docker Compose V2
- 1GB RAM minimum (2GB recommended)

## License

MIT
