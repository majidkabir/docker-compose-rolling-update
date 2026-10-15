# Zero-Downtime Rolling Update Example

A runnable demo: update two services from v1 to v2 while a monitor sends requests, and watch none of them fail. Then try a broken release and watch it get rolled back.

## What's Inside

```
:8182 → nginx → service1      (monitored by monitor.sh)
                service2      (independent backend, not behind nginx)
```

`service1` and `service2` stand for two independent microservices. They share one Node.js image here for simplicity; having two shows that one command can update several services, one after another.

| File | Purpose |
|---|---|
| `docker-compose.yaml` | Both services, healthchecks, nginx. `VERSION` picks the image tag |
| `Dockerfile` | Node.js server; `--build-arg VERSION=N` sets the version it reports |
| `server.js` | HTTP server with graceful shutdown; `BROKEN=1` makes it crash on start |
| `nginx/nginx.conf` | Proxy that re-resolves Docker DNS and retries on errors |
| `monitor.sh` | Sends a request every 0.1s and prints the result |
| `e2e-test.sh` | Runs this whole walkthrough automatically (used by CI) |

**You need:** Docker with Compose v2, `curl`, and port 8182 free. Run every command from this `example/` directory.

## 1. Start v1

```bash
cd example/
docker build -t service:v1 .
docker compose up -d --wait
```

`--wait` returns once the services are healthy.

## 2. Watch the traffic

In a second terminal (also in `example/`):

```bash
./monitor.sh
```

```
2026-10-15 10:15:20 - OK: Hello World v1!
2026-10-15 10:15:20 - OK: Hello World v1!
```

Failures show up as `HTTP 502` (or another status) or `Request failed (connection error)`. There shouldn't be any during the whole walkthrough.

## 3. Roll out v2

```bash
docker build --build-arg VERSION=2 -t service:v2 .
VERSION=2 ../scripts/update.sh service1 service2
```

`VERSION=2` makes the compose file resolve `service:v2`; nothing needs editing. The script updates `service1`, then `service2`. In the monitor, responses switch from v1 to v2 — briefly mixed while both `service1` containers run — with no failures.

## 4. Try a broken release

```bash
BROKEN=1 VERSION=2 ../scripts/update.sh service1
```

The new container crashes on startup, so the script removes it and exits with code `1`. The running container was never touched, so the monitor keeps showing `OK`. Unhealthy containers, containers without a healthcheck, and containers still starting after `--timeout` are rolled back the same way.

## 5. Clean up

```bash
docker compose down
docker rmi service:v1 service:v2
```

## Run It Automatically

```bash
./e2e-test.sh
```

Steps 1–4 in one go. It fails if any request fails, the broken release is accepted, or the end state isn't one running container per service serving v2. It cleans up after itself (the images stay). Stop a stack you started by hand first (`docker compose down`): the test needs port 8182 and the `nginx` container name.

## How the Pieces Fit

**Healthcheck** — defined once in `docker-compose.yaml`, using `node` so the image needs no `curl`. The script waits for `healthy` before removing anything.

**Nginx** — `resolver 127.0.0.11 valid=1s` plus a variable in `proxy_pass` makes it look up `service1` again every second, so it sees new containers and forgets removed ones. `proxy_next_upstream error timeout` retries the other container when one disappears mid-request, so the client never notices.

**Graceful shutdown** — on `SIGTERM`, `server.js` closes idle keep-alive connections right away (so Nginx doesn't reuse one and get a reset), lets active requests finish, and forces an exit after 10s. That's shorter than the 15s `stop_grace_period`, so Docker never has to kill it mid-request.

**nginx itself** — it publishes port 8182 and has a `container_name`, so it can't run two copies and isn't updated with the script. After changing `nginx.conf`, reload it with `docker exec nginx nginx -s reload`.

## Troubleshooting

**`No such image: service:v2`** — the image for that `VERSION` isn't built yet; run the matching `docker build` first.

**Port 8182 already in use** — change `"8182:80"` in `docker-compose.yaml` and pass the new URL to `./monitor.sh http://localhost:<port>`.

**Nginx returns 502** — check that Docker DNS sees the service: `docker exec nginx getent hosts service1`.

**Health check stays unhealthy** — the script prints the last health-check output; `docker compose logs service1` shows the server's own logs.

See the [main README](../README.md) for using the scripts in your own project.
