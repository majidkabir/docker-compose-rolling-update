# Quick Reference Guide

## For Developers Using the Scripts

### Setup (one-time)
```bash
# Copy scripts to your project (keep them in the same directory)
cp scripts/update.sh scripts/check_status.sh ./your-project-scripts/
chmod +x ./your-project-scripts/*.sh

# ...or install as a Docker CLI plugin: docker rollingupdate
./scripts/install-plugin.sh
```

### Update Services
```bash
# Update service1, then service2
./scripts/update.sh service1 service2

# Update only one service
./scripts/update.sh service1

# Other compose file / project, 5 min health timeout
./scripts/update.sh -f prod.yaml -p shop -t 300 service1
```

### What Happens During Update
1. New container(s) start next to the old ones (N replicas → 2N)
2. Script waits until every new container is `healthy` (default timeout 120s)
3. Once healthy, the old containers are stopped and removed
4. Repeat for the next service

If a new container is unhealthy, crashes, has no healthcheck, or times out,
the new containers are removed and the old ones keep running (rollback).

## For Understanding the Project

### The Problem
Docker Compose doesn't have built-in rolling updates (unlike Docker Swarm/Kubernetes).
We need zero-downtime updates so users don't experience service interruptions.

### The Solution
Smart scaling + health checks + container removal:
- Scale service to 2x its replicas temporarily
- Health check ensures the new one is working
- Only then remove the old one
- Nginx load balances between them

### Key Requirements
1. ✓ Services must have a healthcheck (docker-compose.yaml or Dockerfile — one is enough)
2. ✓ The health check command must exist in the container (curl, wget, node, etc.)
3. ✓ No fixed host `ports:` or `container_name` on updated services (two copies run briefly)
4. ✓ Load balancer must route to both service instances during transition
5. ✓ Services must handle `SIGTERM` gracefully — finish in-flight requests before exiting
6. ✓ Nginx must use Docker's DNS resolver (`127.0.0.11`) with a variable in `proxy_pass` — static upstream blocks cache IPs and won't pick up new containers

## For Troubleshooting

### Check container health
```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
docker inspect <container-id> | grep -A 20 '"Health"'
```

### Check logs
```bash
docker compose logs service1   # all containers of a service
docker logs nginx
```

### Manual health check
```bash
./scripts/check_status.sh -t 30 <container-id>   # waits for healthy, exit 0/1/2
```

### See what's happening
```bash
docker stats  # Real-time container stats
docker events  # Real-time events
```

## Example Workflow

```bash
cd example/

# 1. Build version 1
docker build -t service:v1 .

# 2. Start services (image tag and VERSION default to 1)
docker compose up -d --wait

# 3. Monitor in another terminal
./monitor.sh
# Should see: OK: Hello World v1!

# 4. Build version 2
docker build --build-arg VERSION=2 -t service:v2 .

# 5. Run rolling update (VERSION=2 selects service:v2)
VERSION=2 ../scripts/update.sh service1 service2

# 6. Watch monitor.sh - responses transition from v1 → mix of v1+v2 → all v2
#    No HTTP errors or connection failures should appear

# 7. Try a broken release: it is rolled back, v2 keeps serving
BROKEN=1 VERSION=2 ../scripts/update.sh service1

# 8. Cleanup
docker compose down
docker rmi service:v1 service:v2
```
