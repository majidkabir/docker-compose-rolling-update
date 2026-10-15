# Docker Compose Rolling Update — Zero-Downtime Deployments

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Shell Script](https://img.shields.io/badge/shell-bash-green.svg)
![Docker Compose](https://img.shields.io/badge/docker%20compose-v2-blue.svg)
[![CI](https://github.com/majidkabir/docker-compose-rolling-update/actions/workflows/ci.yml/badge.svg)](https://github.com/majidkabir/docker-compose-rolling-update/actions/workflows/ci.yml)

**Zero-downtime rolling updates for Docker Compose** — deploy new versions of your services without dropping a single request. No Docker Swarm, no Kubernetes required.

```bash
./scripts/update.sh api worker      # or: docker rollingupdate api worker
```

## Why This Exists

Docker Compose has no rolling update command. When a service's image changes, `docker compose up -d` stops the old container before starting the new one, so the service is down until the new one is ready — and if the new version is broken, it stays down.

This project fills that gap with two small bash scripts:

- **No orchestrator** — plain Docker Compose on any machine or VM
- **No dependencies** — bash and the Docker CLI
- **Safe by default** — the old version keeps serving until the new one is healthy, and a failed update rolls back automatically
- **Drop-in** — copy the scripts into your project, or install them as `docker rollingupdate`

## How It Works

For each service, one after the other:

1. **Scale up** — start new containers next to the running ones (`up --no-recreate --scale`). A service with N replicas briefly runs 2N.
2. **Wait for healthy** — every new container must report `healthy`.
3. **Remove old** — only then are the old containers stopped and removed.

If a new container turns unhealthy, crashes, has no healthcheck, or isn't healthy before the timeout, the script **rolls back**: it removes the new containers, and the old ones never stopped serving. Ctrl+C or SIGTERM rolls back the same way.

```
Updating service1 (behind nginx):

  before        nginx → service1 v1
  during        nginx → service1 v1 + service1 v2 (starting → healthy)
  after         nginx → service1 v2

  on failure    nginx → service1 v1        (v2 removed, v1 never stopped)
```

## Quick Start

### 1. Get the scripts

Download both scripts into your project. They must stay in the same directory:

```bash
mkdir -p scripts && cd scripts
base=https://github.com/majidkabir/docker-compose-rolling-update/releases/latest/download
curl -fsSL -O "$base/update.sh" -O "$base/check_status.sh"
chmod +x update.sh check_status.sh
```

Or clone the repository and install them once as a Docker CLI plugin, so `docker rollingupdate` works in any project:

```bash
git clone https://github.com/majidkabir/docker-compose-rolling-update.git
./docker-compose-rolling-update/scripts/install-plugin.sh
docker rollingupdate --help
```

### 2. Prepare your compose file

Each service you update needs:

- a **healthcheck** (in the compose file, or a `HEALTHCHECK` in the image) — without one the script refuses to remove the old containers
- **no fixed host port and no `container_name`**, because two copies run during the update — publish ports on a proxy in front instead
- a **`stop_grace_period`** long enough to finish in-flight requests

```yaml
services:
  api:
    image: registry.example.com/api:${API_TAG:-1.4.0}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 5s
      timeout: 2s
      retries: 3
      start_period: 10s
    stop_grace_period: 15s
```

### 3. Handle SIGTERM in your application

`docker stop` sends `SIGTERM`, waits `stop_grace_period`, then kills the container. Stop accepting new connections, finish the requests in flight, then exit. In Node.js:

```js
process.on('SIGTERM', () => {
  server.closeIdleConnections();          // drop idle keep-alive connections now
  server.close(() => process.exit(0));    // exit once active requests finish
  setTimeout(() => process.exit(1), 10000).unref(); // never hang past the grace period
});
```

Other languages: Python `signal.signal(signal.SIGTERM, ...)`, Go `signal.NotifyContext`, Java shutdown hooks or Spring Boot's `server.shutdown=graceful`.

### 4. Route traffic with DNS re-resolution (Nginx)

Your proxy must notice new and removed containers. A static `upstream {}` block resolves names once at startup, so it keeps sending traffic to removed containers. Use Docker's DNS with a variable in `proxy_pass`, and retry on the next container when one disappears:

```nginx
resolver 127.0.0.11 valid=1s ipv6=off;

location / {
    set $upstream api:3000;
    proxy_pass http://$upstream;

    proxy_connect_timeout 500ms;
    proxy_next_upstream error timeout;
    proxy_next_upstream_tries 3;
    proxy_next_upstream_timeout 2s;
}
```

See [`example/nginx/nginx.conf`](example/nginx/nginx.conf) for a complete configuration. Traefik's Docker provider tracks containers on its own.

### 5. Deploy a new version

New containers start from whatever image the compose file resolves to **at that moment**, so point it at the new version first:

```bash
# New tag: change it in the compose file, or via a variable the file reads
API_TAG=1.5.0 ./scripts/update.sh api

# Same tag pushed again (e.g. :latest): pull it, or the old local image is reused
./scripts/update.sh --pull always api

# Image built locally under the same tag
docker compose build api && ./scripts/update.sh api

# Several services (one after another), another compose file, slow-starting apps
./scripts/update.sh -f docker-compose.prod.yaml -p shop -t 300 api worker
```

Run it from the compose project directory, or point it there with `-f` / `--project-directory`. A non-zero exit code means the update failed and was rolled back, so it drops straight into a deploy pipeline:

```bash
ssh deploy@server 'cd /srv/shop && API_TAG=1.5.0 ./scripts/update.sh api'
```

Make a tag change permanent (e.g. in `.env`); otherwise a later plain `docker compose up -d` brings the old version back.

## Requirements

- Docker Engine with Docker Compose v2 (`docker compose`); tested with Compose v2.38 and v5
- Bash. The scripts avoid Bash 4 features so they can run on macOS's default Bash 3.2, though CI only runs Linux
- The service must be running before the update, with no stopped containers left over

## Limitations

- **Single host.** It updates containers on the machine where it runs.
- **Stateless services only.** Don't use it for databases or anything that can't run two copies at once.
- **Traffic before healthy.** Docker's DNS returns a new container as soon as it runs, before it's healthy, so a DNS-based proxy can send it requests during the health-check window. Apps should only start listening once they can serve.
- **Twice the resources, briefly.** Each service runs 2N containers during its update.
- **Not for the proxy itself.** Services with `container_name` or fixed host ports (like the example's nginx) can't run two copies; update those with a normal `docker compose up -d`.

## Scripts Reference

### `update.sh`

```
Usage: update.sh [OPTIONS] <service> [service...]

  -f, --file FILE              Compose file (repeatable, like docker compose -f)
  -p, --project-name NAME      Compose project name
      --project-directory DIR  Compose project directory
  -t, --timeout SECONDS        Max wait for new containers to become healthy (default: 120)
      --stop-timeout SECONDS   Grace period when stopping old containers
                               (default: the service's stop_grace_period)
      --pull POLICY            always | missing | never (default: the service's pull_policy)
  -h, --help                   Show help
  -v, --version                Show version
```

- Only touches the named services in the current Compose project
- Runs `docker compose up -d --no-deps --no-recreate --scale <svc>=2N <svc>`, waits with `check_status.sh`, then removes the old containers
- Stops at the first failed service; services updated earlier in the same run stay updated
- Reads `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME`, `HEALTHCHECK_TIMEOUT` and `STOP_TIMEOUT` from the environment

Exit codes: `0` updated, `1` failed and rolled back, `64` usage error, `130` / `143` interrupted and rolled back.

### `check_status.sh`

Waits until the given containers are running and healthy. `update.sh` uses it, and it works on its own:

```
Usage: check_status.sh [-t TIMEOUT] <container> [container...]
```

Exit codes: `0` all healthy, `1` unhealthy, not running or timed out, `2` no healthcheck, `64` usage error.

### `install-plugin.sh`

Installs the scripts into `~/.docker/cli-plugins` so `update.sh` runs as `docker rollingupdate` (Docker plugin names can't contain dashes). `--link` symlinks instead of copying, so the plugin follows your clone; pass a directory to install elsewhere, e.g. `/usr/local/lib/docker/cli-plugins` for all users.

## Troubleshooting

**The new containers run the old version**
- The image didn't change. Use a new tag, pass `--pull always` when a tag was re-pushed, or rebuild before updating. `docker compose config --images` shows what Compose resolves.

**Health check fails**
- The script prints the last health-check output. More detail: `docker inspect --format '{{json .State.Health}}' <id>`
- Check the command exists in the image, e.g. `docker exec <id> which curl`
- Raise `start_period` if the app needs time to boot

**"Timed out ... still starting"**
- The app needs longer than `--timeout` (default 120s); raise it, e.g. `-t 300`

**"has stopped containers that 'up' would restart"**
- Remove the leftovers first: `docker compose rm -f <service>` (running containers are kept)

**"pull access denied" for an image you built locally**
- Compose can't find that tag locally. Check `docker compose config --images`; for local-only images set `pull_policy: never` or pass `--pull never`

**"Unknown service" or no containers found**
- Run from the compose project directory, or pass the same `-f` / `-p` / `--project-directory` you use with `docker compose`

**Requests fail during the update (HTTP 502 or connection errors)**
- Nginx needs `resolver 127.0.0.11 valid=1s`, a variable in `proxy_pass`, and `proxy_next_upstream error timeout`
- The app must finish in-flight requests on SIGTERM
- Don't `docker network disconnect` containers before stopping them: packets to them are silently dropped, so Nginx waits for a timeout instead of retrying immediately

## Example

[`example/`](example/) is a runnable demo — two Node.js services behind Nginx, plus a monitor that prints every request during the update. [`example/e2e-test.sh`](example/e2e-test.sh) runs the whole demo automatically; CI uses it to check for zero failed requests on every change. For a command cheat sheet, see [QUICKSTART.md](QUICKSTART.md).

## Project Structure

```
scripts/
  update.sh           Rolling update (also the Docker CLI plugin)
  check_status.sh     Waits for containers to become healthy
  install-plugin.sh   Installs `docker rollingupdate`
example/              Runnable demo: Node.js + Nginx, monitor, end-to-end test
.github/workflows/    ShellCheck, end-to-end test, releases
QUICKSTART.md         Command cheat sheet
CHANGELOG.md          Release notes
```

## License

[MIT](LICENSE)
