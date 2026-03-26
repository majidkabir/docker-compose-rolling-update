# Docker Compose Rolling Update — Zero-Downtime Deployments

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Shell Script](https://img.shields.io/badge/shell-bash-green.svg)
![Docker Compose](https://img.shields.io/badge/docker--compose-v3.8%2B-blue.svg)

**Zero-downtime rolling updates for Docker Compose** — deploy new versions of your services without dropping a single request. No Docker Swarm, no Kubernetes required.

## Why This Exists

Docker Compose does not have a built-in rolling update command. Running `docker compose up` recreates containers one by one with a brief downtime gap. `docker compose pull && docker compose up -d` replaces all containers simultaneously, causing a full restart.

This project fills that gap with a simple bash script approach:

- **No orchestrator required** — works with plain Docker Compose on any machine or VM
- **No external dependencies** — pure bash + Docker CLI
- **Production-tested** — handles graceful shutdown, Nginx DNS staleness, and health-check gating
- **Drop-in** — copy two scripts into any existing Docker Compose project

## How It Works

For each service, the update follows three steps:

1. **Scale Up** — start a new container alongside the existing one (`--no-recreate` keeps the old one alive)
2. **Health Check** — wait until the new container passes Docker's health check
3. **Remove Old** — stop and remove the old container only after the new one is confirmed healthy

At no point is the service fully down. Traffic flows to the old container until the new one is ready.

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

### 1. Copy the Scripts

```bash
mkdir -p scripts
cp scripts/update.sh scripts/check_status.sh ./scripts/
chmod +x ./scripts/*.sh
```

### 2. Configure Your docker-compose.yaml

Services must have a `healthcheck` so the script knows when the new container is ready:

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

```bash
# Update multiple services in sequence
./scripts/update.sh api worker

# Update a single service
./scripts/update.sh api
```

## Project Structure

```
.
├── scripts/
│   ├── update.sh          # Main orchestration script
│   └── check_status.sh    # Health check and cleanup
│
├── example/               # Complete working example: Node.js + Nginx
│   ├── docker-compose.yaml
│   ├── Dockerfile
│   ├── server.js
│   ├── nginx/
│   │   └── nginx.conf
│   ├── monitor.sh         # Real-time request monitoring
│   └── README.md
│
└── README.md              # This file
```

## Requirements

- Docker Engine 20.10+ and Docker Compose v3.8+
- Services must define a `healthcheck`
- The health check command must be available inside the container (e.g., `curl`, `wget`)
- Applications must handle `SIGTERM` gracefully

## Important Notes

- **Health Checks**: Must be configured both in `Dockerfile` and `docker-compose.yaml`
- **Startup Time**: Adjust `start_period` for slower-starting services to avoid false unhealthy reports during boot
- **Graceful Shutdown**: Services must handle `SIGTERM` and drain in-flight requests before exiting. `docker stop` sends SIGTERM and waits 10 seconds before force-killing with SIGKILL.
- **Nginx DNS**: Use Docker's embedded resolver (`127.0.0.11`) with a variable in `proxy_pass`. Do **not** use `docker network disconnect` before stopping — it makes the container's IP silently unreachable (packets dropped), causing Nginx to hang on connection rather than fail fast and retry.

## Scripts Reference

### `update.sh`

Orchestrates the rolling update for one or more services.

```
Usage: ./scripts/update.sh <service1> [service2] [...]
```

- Scales each service to 2 replicas with `--no-recreate`
- Calls `check_status.sh` to wait for health and clean up
- Exits with code 1 on first failure, leaving the stack in a safe state

### `check_status.sh`

Waits for new containers to become healthy, then removes the old one.

```
Usage: ./scripts/check_status.sh <service_name>
```

- Waits up to 30 seconds for containers to leave the `starting` state
- Removes any `unhealthy` containers and returns exit code 1
- Removes the oldest container once all remaining containers are healthy

## Troubleshooting

**Health check fails immediately**
- Confirm the health check binary exists: `docker exec <id> which curl`
- Try the check manually: `docker exec <id> curl -f http://localhost:3000/`
- Increase `start_period` if the app takes time to boot

**Old container is not removed**
- Confirm containers have Docker Compose labels: `docker inspect <id> | grep com.docker.compose`
- Check Docker socket permissions

**Requests fail during update (HTTP 000 or 502)**
- Ensure Nginx uses `resolver 127.0.0.11 valid=1s` and a variable in `proxy_pass`
- Add `proxy_next_upstream error timeout` so Nginx retries on the healthy container
- Confirm the application handles SIGTERM and does not exit while a request is in flight

## Example

See [`example/`](example/) for a complete, runnable demonstration with a Node.js server, Nginx, and a monitoring script that verifies zero-downtime behavior in real time.

## License

[MIT](LICENSE)
