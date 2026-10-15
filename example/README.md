# Zero-Downtime Rolling Update Example

This directory contains a complete, working example of zero-downtime rolling updates with Docker Compose.

## What This Example Shows

`service1` and `service2` are **two independent microservices** — they share the same Node.js image here for simplicity, but in a real system they would be completely different applications. Having two services in the example demonstrates that the update script can roll out a new version to **multiple independent services in one command**, updating each one sequentially with zero downtime.

- **Node.js Server**: Simple HTTP server; each service reports its own version
- **Nginx**: Reverse proxy in front of `service1` — `service2` represents an independent backend (internal API, worker, etc.) that is not exposed directly through nginx in this example
- **Health Checks**: Both services report their health status independently
- **Monitoring**: Script to watch requests to `service1` during updates

## Files

- `docker-compose.yaml` - Service definitions with health checks; `VERSION` selects the image tag
- `Dockerfile` - Node.js server running as the unprivileged `node` user
- `server.js` - Simple version-aware HTTP server with graceful shutdown
- `nginx/nginx.conf` - Nginx reverse proxy configuration for `service1`
- `monitor.sh` - Real-time monitoring of requests
- `e2e-test.sh` - Runs the whole walkthrough automatically and fails on any dropped request (used by CI)

## Prerequisites

- Docker & Docker Compose
- curl (for monitoring)

## Step 1: Build the Docker Images

```bash
# Build version 1
docker build -t service:v1 .

# Verify build
docker images | grep service
```

## Step 2: Start Services

```bash
cd example/
docker compose up -d --wait

# Check status
docker compose ps
```

Wait a few seconds for health checks to pass.

## Step 3: Monitor in Real-Time

In a new terminal, run:

```bash
./monitor.sh

# Output:
# 2024-03-18 10:15:20 - OK: Hello World v1!
# 2024-03-18 10:15:20 - OK: Hello World v1!
# 2024-03-18 10:15:20 - OK: Hello World v1!
```

The monitor script continuously sends requests and shows:
- ✓ Successful responses with version
- ✗ Failed requests (should not happen during rolling update)

## Step 4: Perform a Rolling Update

### Create Version 2 Image

```bash
docker build --build-arg VERSION=2 -t service:v2 .
```

The build arg is baked into the image, so `service:v2` reports v2. The compose file picks the image tag from the `VERSION` variable (`service:v${VERSION}`), so there is nothing to edit.

### Run the Rolling Update Script

```bash
# From the example directory — updates service1 first, then service2 independently
VERSION=2 ../scripts/update.sh service1 service2

# Watch the monitor.sh output for zero-downtime behavior
```

The script updates each service independently and sequentially:
1. `service1` is scaled to 2 containers (old + new), the new one must report `healthy`, then the old one is removed
2. `service2` goes through the same process

Expected behavior in `monitor.sh`:
- ✓ All requests continue to succeed throughout
- ✓ Responses may briefly alternate between v1 and v2 while both `service1` containers are alive
- ✓ Eventually all responses show v2

## Step 5: Test a Broken Release

`BROKEN=1` makes the new container crash on startup, like a bad release would:

```bash
BROKEN=1 VERSION=2 ../scripts/update.sh service1
```

The script will:
1. Detect that the new container is not running (an `unhealthy` one is caught the same way)
2. Roll back by removing it
3. Exit with code 1 — the old container never stopped, so `monitor.sh` shows no errors

Containers without a healthcheck, or that stay `starting` past `--timeout`, are rolled back too.

## Monitoring Output Explanation

```
2024-03-18 10:15:20 - OK: Hello World v1!         ← Request succeeded
2024-03-18 10:15:20 - HTTP 500                     ← Server error
2024-03-18 10:15:20 - Request failed               ← Connection timeout
```

During a successful rolling update, you should see **no failures**.

## Cleanup

```bash
docker compose down
docker rmi service:v1 service:v2 2>/dev/null
```

## Key Concepts

### Health Checks

The health check is defined once, in `docker-compose.yaml`. It uses `node` itself, so the image doesn't need `curl`:

```yaml
healthcheck:
  test:
    - CMD
    - node
    - -e
    - "require('http').get('http://localhost:3000/', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"
  interval: 5s
  timeout: 2s
  retries: 3
  start_period: 5s
```

A `HEALTHCHECK` in the Dockerfile works just as well — one of the two is enough.

### Load Balancing & Dynamic DNS

Nginx uses Docker's embedded DNS resolver so it picks up container changes within 1 second instead of caching IPs forever:

```nginx
resolver 127.0.0.11 valid=1s ipv6=off;

location / {
    # Variable forces per-request DNS re-resolution
    set $upstream service1:3000;
    proxy_pass http://$upstream;

    proxy_connect_timeout 500ms;
    proxy_next_upstream error timeout;
    proxy_next_upstream_tries 3;
    proxy_next_upstream_timeout 2s;
}
```

Key points:
- **`resolver 127.0.0.11`** — Docker's embedded DNS, always available inside containers
- **`valid=1s`** — Nginx re-queries DNS every second so a removed container is forgotten quickly
- **Variable in `proxy_pass`** — required to activate the resolver on each request; a static `upstream {}` block ignores the resolver and caches IPs at startup
- **`proxy_next_upstream error timeout`** — if the old container's port is gone, Nginx retries the next resolved IP immediately instead of returning an error to the client

### Graceful Shutdown

Services must handle `SIGTERM` to avoid dropping the request being processed at the moment `docker stop` runs. The example server closes idle keep-alive connections immediately (so Nginx's connection pool is cleared) and waits for any active request to finish before exiting:

```js
process.on('SIGTERM', () => {
  server.closeIdleConnections(); // clear Nginx's keep-alive pool instantly
  server.close(() => {           // wait for in-flight request to finish
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10000).unref(); // don't hang forever
});
```

Without `closeIdleConnections()`, Nginx may reuse a stale keep-alive connection to the stopping container and receive a TCP reset, which reaches the client as `HTTP 000`.

The forced-exit timer (10s) is shorter than the service's `stop_grace_period` (15s), so the app exits on its own terms before Docker sends SIGKILL.

### Service Scaling

Each independent service is temporarily scaled to 2 during its update window:

```bash
# Step 1: scale service1 to 2 (old instance stays alive)
docker compose up -d --no-deps --no-recreate --scale service1=2 service1
# Running: service1 (v1, old) + service1 (v2, new) + service2 (v1, untouched)

# Step 2: once service1's new container is healthy, old one is removed
# Running: service1 (v2) + service2 (v1, untouched)

# Step 3: repeat for service2
docker compose up -d --no-deps --no-recreate --scale service2=2 service2
# Running: service1 (v2) + service2 (v1, old) + service2 (v2, new)
# After health check: service1 (v2) + service2 (v2)
```

At no point is any service fully down — the old container keeps serving traffic until the new one is confirmed healthy.

## Troubleshooting

**Health check reports unhealthy**:
- The update script prints the last health-check output
- Check the server is listening: `docker compose logs service1`

**Nginx returns 502 Bad Gateway**:
- Check service DNS resolution: `docker exec nginx getent hosts service1`
- Verify services are on same network

**Old version still responding**:
- Check how many containers are running: `docker compose ps`
- Monitor with `docker stats` to see which containers have traffic

## Next Steps

- Customize this example for your own services
- Adjust health check parameters for your application
- Add additional monitoring or logging
- Integrate into your CI/CD pipeline

For the generic rolling update scripts, see [../README.md](../README.md)
