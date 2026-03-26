# Zero-Downtime Rolling Update Example

This directory contains a complete, working example of zero-downtime rolling updates with Docker Compose.

## What This Example Shows

- **Node.js Server**: Simple HTTP server that responds with its version
- **Nginx**: Acts as load balancer routing to both services
- **Health Checks**: Both services report their health status
- **Monitoring**: Script to watch requests during updates

## Files

- `docker-compose.yaml` - Service definitions with health checks
- `Dockerfile` - Node.js server with curl for health checks
- `server.js` - Simple version-aware HTTP server
- `nginx/nginx.conf` - Nginx configuration with upstream load balancing
- `monitor.sh` - Real-time monitoring of requests

## Prerequisites

- Docker & Docker Compose
- curl (for monitoring)

## Step 1: Build the Docker Images

```bash
# Build version 1
VERSION=v1 docker build -t service:v1 .

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

Change both services to use the new image:

```yaml
services:
  service1:
    image: service:v2  # Changed from v1
  service2:
    image: service:v2  # Changed from v1
```

### Run the Rolling Update Script

```bash
# From the example directory
../scripts/update.sh service1 service2

# Watch the monitor.sh output for zero-downtime behavior
```

Expected behavior:
- ✓ All requests continue to succeed
- ✓ Responses might alternate between v1 and v2 (both alive temporarily)
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

### Load Balancing

Nginx upstream block distributes requests:

```nginx
upstream backend {
    server service1:3000;
    server service2:3000;
}
```

This ensures both services receive traffic.

### Service Scaling

During updates, services are temporarily scaled to 2:

```bash
docker compose up -d --scale service1=2 --no-recreate
# Now running: (old service1) + (new service1)
# After health check passes: old service1 is removed
```

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
