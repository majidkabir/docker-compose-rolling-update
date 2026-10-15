# Docker Compose Rolling Update — Zero-Downtime Deployments

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Shell Script](https://img.shields.io/badge/shell-bash-green.svg)
![Docker Compose](https://img.shields.io/badge/docker%20compose-v2-blue.svg)
[![CI](https://github.com/majidkabir/docker-compose-rolling-update/actions/workflows/ci.yml/badge.svg)](https://github.com/majidkabir/docker-compose-rolling-update/actions/workflows/ci.yml)

**Zero-downtime rolling updates for Docker Compose** — deploy new versions of your services without dropping a single request. No Docker Swarm, no Kubernetes required.

## Why This Exists

Docker Compose does not have a built-in rolling update command. Running `docker compose up` recreates containers one by one with a brief downtime gap. `docker compose pull && docker compose up -d` replaces all containers simultaneously, causing a full restart.

This project fills that gap with a simple bash script approach:

- **No orchestrator required** — works with plain Docker Compose on any machine or VM
- **No external dependencies** — pure bash + Docker CLI
- **Safe by default** — health-check gating, automatic rollback on failure, scoped to your Compose project
- **Drop-in** — copy two scripts into any existing Docker Compose project, or install as `docker rolling-update`

## How It Works

For each service, the update follows three steps:

1. **Scale Up** — start new containers alongside the running ones (`--no-recreate` keeps the old ones alive). A service with N replicas temporarily runs 2N.
2. **Health Check** — wait until every new container reports `healthy`
3. **Remove Old** — stop and remove the old containers only after the new ones are confirmed healthy

If a new container turns unhealthy, crashes, has no healthcheck, or doesn't become healthy before the timeout, the script **rolls back**: it removes the new containers and the old ones keep serving. The same happens if you press Ctrl+C or the script receives SIGTERM.

At no point is the service fully down. Traffic flows to the old containers until the new ones are ready.

```
Initial State:
:8182 → nginx → service1 (v1)
                service2 (v1)    [independent service, not behind nginx]

Updating service1:
:8182 → nginx → service1 (v1, old) + service1 (v2, new)
                service2 (v1)
                ↓ (new container passes health check)
:8182 → nginx → service1 (v2)
                service2 (v1)

Updating service2:
:8182 → nginx → service1 (v2)
                service2 (v1, old) + service2 (v2, new)
                ↓ (new container passes health check)
:8182 → nginx → service1 (v2)
                service2 (v2)
```

## Comparison to Alternatives

| | This project | Docker Swarm | Kubernetes |
|---|---|---|---|
| Rolling updates | ✅ | ✅ native | ✅ native |
| Requires orchestrator | ❌ | ✅ Swarm mode | ✅ K8s cluster |
| Works with `docker-compose.yaml` | ✅ | ❌ needs stack file | ❌ needs manifests |
| Setup complexity | Low | Medium | High |
| Best for | Single host / small teams | Multi-host clusters | Large-scale infra |

If you are already on Docker Swarm or Kubernetes, use their native rolling update features. If you are on a single VM or a small setup using Docker Compose, this project is for you.

## Quick Start

### 1. Get the Scripts

Either copy both scripts into your project (they must stay in the same directory):

```bash
mkdir -p scripts
cp scripts/update.sh scripts/check_status.sh ./scripts/
chmod +x ./scripts/*.sh
```

Or install them once as a Docker CLI plugin, then use `docker rolling-update` anywhere:

```bash
./scripts/install-plugin.sh
docker rolling-update --help
```

### 2. Configure Your docker-compose.yaml

Services must have a healthcheck (in the compose file or as a `HEALTHCHECK` in the image) so the script knows when the new container is ready. The script refuses to remove old containers when it cannot verify the new ones. Set `stop_grace_period` to how long your app needs to drain requests:

```yaml
services:
  api:
    image: your-api:v1
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 5s
      timeout: 2s
      retries: 3
      start_period: 10s
    stop_grace_period: 15s

  worker:
    image: your-worker:v1
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 5s
      timeout: 2s
      retries: 3
      start_period: 10s
```

### 3. Handle SIGTERM in Your Application

`docker stop` sends `SIGTERM` before killing a container. Your application must finish in-flight requests before exiting — otherwise the one request being handled at the moment of shutdown is dropped.

Example for Node.js:

```js
process.on('SIGTERM', () => {
  server.closeIdleConnections(); // drop Nginx keep-alive pool immediately
  server.close(() => process.exit(0)); // wait for active request to finish
});
```

For other languages: Python (`signal.signal(signal.SIGTERM, ...)`), Go (`signal.NotifyContext`), Java (shutdown hooks).

### 4. Configure Nginx for Dynamic DNS (if using Nginx)

A static `upstream {}` block caches backend IPs at startup and never re-resolves, causing Nginx to keep routing to removed containers. Use Docker's embedded DNS resolver with a variable in `proxy_pass` instead:

```nginx
resolver 127.0.0.11 valid=1s ipv6=off;

location / {
    set $upstream your-service:3000;
    proxy_pass http://$upstream;

    proxy_connect_timeout 500ms;
    proxy_next_upstream error timeout;
    proxy_next_upstream_tries 3;
    proxy_next_upstream_timeout 2s;
}
```

See [`example/nginx/nginx.conf`](example/nginx/nginx.conf) for a complete, ready-to-use configuration.

### 5. Run the Rolling Update

Change the image tag (or build a new image), then:

```bash
# Update multiple services in sequence
./scripts/update.sh api worker

# Update a single service
./scripts/update.sh api

# Different compose file / project, longer timeout for slow-starting apps
./scripts/update.sh -f docker-compose.prod.yaml -p shop -t 300 api
```

Run it from your compose project directory, or point it there with `-f` / `--project-directory`. The scripts can be called from any path.

## Project Structure

```
.
├── scripts/
│   ├── update.sh          # Main orchestration script (also the CLI plugin)
│   ├── check_status.sh    # Waits for containers to become healthy
│   └── install-plugin.sh  # Installs `docker rolling-update`
│
├── example/               # Complete working example: Node.js + Nginx
│   ├── docker-compose.yaml
│   ├── Dockerfile
│   ├── server.js
│   ├── nginx/
│   │   └── nginx.conf
│   ├── monitor.sh         # Real-time request monitoring
│   ├── e2e-test.sh        # Automated zero-downtime test (used by CI)
│   └── README.md
│
├── .github/workflows/     # ShellCheck, end-to-end test, releases
├── CHANGELOG.md
└── README.md              # This file
```

## Requirements

- Bash 3.2+ (macOS default works), Docker Engine 20.10+, Docker Compose v2 (`docker compose`)
- Services must define a healthcheck, and its command must exist inside the container
- Services must be running before an update, with no stopped containers left over
- Applications must handle `SIGTERM` gracefully

## Important Notes

- **Health Checks**: Define one either in `docker-compose.yaml` or as a `HEALTHCHECK` in the image — one place is enough
- **Startup Time**: Adjust `start_period` for slower-starting services, and raise `--timeout` (default 120s) if the app needs longer to become healthy
- **Graceful Shutdown**: Services must handle `SIGTERM` and drain in-flight requests before exiting. `docker stop` sends SIGTERM and waits for `stop_grace_period` (default 10s) before force-killing with SIGKILL. Override per run with `--stop-timeout`.
- **Traffic before healthy**: Docker's DNS returns a new container's IP as soon as it is running, before it is healthy. Proxies that resolve via DNS (like the Nginx setup here) can send it requests during the health-check window, so the app should not accept connections until it can serve them.
- **Resources**: During an update a service briefly runs twice its replicas, so leave headroom for memory and ports. Services that publish a fixed host port (`ports: "8080:80"`) or set `container_name` cannot run two copies — put them behind a proxy instead.
- **Nginx DNS**: Use Docker's embedded resolver (`127.0.0.11`) with a variable in `proxy_pass`. Do **not** use `docker network disconnect` before stopping — it makes the container's IP silently unreachable (packets dropped), causing Nginx to hang on connection rather than fail fast and retry.

## Scripts Reference

### `update.sh`

Orchestrates the rolling update for one or more services.

```
Usage: update.sh [OPTIONS] <service> [service...]

  -f, --file FILE              Compose file (repeatable, like docker compose -f)
  -p, --project-name NAME      Compose project name
      --project-directory DIR  Compose project directory
  -t, --timeout SECONDS        Max wait for new containers to become healthy (default: 120)
      --stop-timeout SECONDS   Grace period when stopping old containers
                               (default: the service's stop_grace_period)
  -h, --help                   Show help
  -v, --version                Show version
```

- Only touches containers of the given service in the given Compose project
- Runs `docker compose up -d --no-deps --no-recreate --scale <svc>=2N <svc>`
- Calls `check_status.sh` on the new containers, then removes the old ones
- On failure or interrupt, removes the new containers and exits non-zero; services updated earlier in the same run stay updated
- Respects `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME`, and `HEALTHCHECK_TIMEOUT` / `STOP_TIMEOUT` environment variables

Exit codes: `0` success, `1` update failed (rolled back), `64` usage error, `130`/`143` interrupted (rolled back).

### `check_status.sh`

Waits until the given containers are running and healthy. Used by `update.sh`, but works on its own too.

```
Usage: check_status.sh [-t TIMEOUT] <container> [container...]
```

Exit codes: `0` all healthy, `1` unhealthy, not running, or timed out, `2` no healthcheck, `64` usage error.

### `install-plugin.sh`

Links `update.sh` into `~/.docker/cli-plugins/docker-rolling-update` so it runs as `docker rolling-update`. Pass a directory to install somewhere else.

## Troubleshooting

**Health check fails immediately**
- The script prints the last health-check output; also see `docker inspect --format '{{json .State.Health}}' <id>`
- Confirm the health check binary exists: `docker exec <id> which curl`
- Increase `start_period` if the app takes time to boot

**"Timed out ... still starting"**
- The app takes longer than `--timeout` to become healthy; raise it, e.g. `-t 300`

**"has stopped containers that 'up' would restart"**
- Remove the leftovers first: `docker compose rm -f <service>` (running containers are kept)

**"Unknown service" or no containers found**
- Run from the compose project directory, or pass `-f` / `-p` / `--project-directory` the same way you run `docker compose`

**Requests fail during update (HTTP 000 or 502)**
- Ensure Nginx uses `resolver 127.0.0.11 valid=1s` and a variable in `proxy_pass`
- Add `proxy_next_upstream error timeout` so Nginx retries on the healthy container
- Confirm the application handles SIGTERM and does not exit while a request is in flight

## Example

See [`example/`](example/) for a complete, runnable demonstration with a Node.js server, Nginx, and a monitoring script that verifies zero-downtime behavior in real time.

## License

[MIT](LICENSE)
