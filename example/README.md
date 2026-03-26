# Zero-Downtime Rolling Update Example

This directory contains a complete, working example of zero-downtime rolling updates with Docker Compose.

## What This Example Shows

`service1` and `service2` are **two independent microservices** — they share the same Node.js image here for simplicity, but in a real system they would be completely different applications. Having two services in the example demonstrates that the update script can roll out a new version to **multiple independent services in one command**, updating each one sequentially with zero downtime.

- **Node.js Server**: Simple HTTP server; each service reports its own version
- **Nginx**: Reverse proxy in front of `service1` — `service2` represents an independent backend (internal API, worker, etc.) that is not exposed directly through nginx in this example
- **Health Checks**: Both services report their health status independently
- **Monitoring**: Script to watch requests to `service1` during updates

## Files

- `docker-compose.yaml` - Service definitions with health checks
- `Dockerfile` - Node.js server with curl for health checks
- `server.js` - Simple version-aware HTTP server
- `nginx/nginx.conf` - Nginx reverse proxy configuration for `service1`
- `monitor.sh` - Real-time monitoring of requests

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
docker compose up -d

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

Edit `server.js` to see the change, or just build a new image:

```bash
# Modify server.js if you want to see the version change
docker build -t service:v2 .
```

### Update docker-compose.yaml

Change both services to use the new image and bump the VERSION env var:

```yaml
services:
  service1:
    image: service:v2
    environment:
      - VERSION=2
  service2:
    image: service:v2
    environment:
      - VERSION=2
```

### Run the Rolling Update Script

```bash
# From the example directory — updates service1 first, then service2 independently
../scripts/update.sh service1 service2

# Watch the monitor.sh output for zero-downtime behavior
```

The script updates each service independently and sequentially:
1. `service1` is scaled to 2 containers (old + new), new one is health-checked, old one removed
2. `service2` goes through the same process

Expected behavior in `monitor.sh`:
- ✓ All requests continue to succeed throughout
- ✓ Responses may briefly alternate between v1 and v2 while both `service1` containers are alive
- ✓ Eventually all responses show v2

## Step 5: Test Unhealthy Container Handling

Update docker-compose.yaml with an unhealthy image:

```yaml
services:
  service1:
    image: service:unhealthy  # Some broken version
```

Run the update script:

```bash
../scripts/update.sh service1
```

The script will:
1. Detect the unhealthy container
2. Remove it
3. Report the failure

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
docker rmi service:v1 service:v2 service:unhealthy 2>/dev/null
```

## Key Concepts

### Health Checks

Health checks are defined in both places:

**docker-compose.yaml**:
```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:3000/"]
  interval: 5s
  timeout: 2s
  retries: 3
  start_period: 5s
```

**Dockerfile**:
```dockerfile
HEALTHCHECK --interval=5s --timeout=2s --retries=3 --start-period=5s \
    CMD curl -f http://localhost:3000/ || exit 1
```

Both must be defined for Docker to monitor container health.

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
});
```

Without `closeIdleConnections()`, Nginx may reuse a stale keep-alive connection to the stopping container and receive a TCP reset, which reaches the client as `HTTP 000`.

### Service Scaling

Each independent service is temporarily scaled to 2 during its update window:

```bash
# Step 1: scale service1 to 2 (old instance stays alive)
docker compose up -d --scale service1=2 --no-recreate
# Running: service1 (v1, old) + service1 (v2, new) + service2 (v1, untouched)

# Step 2: once service1's new container is healthy, old one is removed
# Running: service1 (v2) + service2 (v1, untouched)

# Step 3: repeat for service2
docker compose up -d --scale service2=2 --no-recreate
# Running: service1 (v2) + service2 (v1, old) + service2 (v2, new)
# After health check: service1 (v2) + service2 (v2)
```

At no point is any service fully down — the old container keeps serving traffic until the new one is confirmed healthy.

## Troubleshooting

**Health check reports unhealthy**:
- Ensure curl is installed: `docker exec <container> curl -f http://localhost:3000/`
- Check server is actually listening: `docker exec <container> netstat -tuln | grep 3000`

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
