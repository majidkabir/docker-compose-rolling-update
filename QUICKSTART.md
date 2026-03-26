# Quick Reference Guide

## For Developers Using the Scripts

### Setup (one-time)
```bash
# Copy scripts to your project
cp scripts/update.sh scripts/check_status.sh ./your-project-scripts/
chmod +x ./your-project-scripts/*.sh
```

### Update Services
```bash
# Update service1, then service2
./scripts/update.sh service1 service2

# Update only one service
./scripts/update.sh service1
```

### What Happens During Update
1. New container starts (scale 2)
2. Health check runs every 5 seconds
3. Once healthy, old container is removed
4. Repeat for next service

## For Understanding the Project

### The Problem
Docker Compose doesn't have built-in rolling updates (unlike Docker Swarm/Kubernetes).
We need zero-downtime updates so users don't experience service interruptions.

### The Solution
Smart scaling + health checks + container removal:
- Scale service to 2 instances temporarily
- Health check ensures the new one is working
- Only then remove the old one
- Nginx load balances between them

### Key Requirements
1. ✓ Services must have `healthcheck` in Dockerfile
2. ✓ Services must have `healthcheck` in docker-compose.yaml
3. ✓ Health check command must work (curl, wget, etc.)
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
docker logs service1.1  # or service2.1, etc
docker logs nginx
```

### Manual health check
```bash
docker exec <container-id> curl -f http://localhost:3000/
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

# 2. Start services (docker-compose.yaml starts with service:v1, VERSION=1)
docker compose up -d

# 3. Monitor in another terminal
./monitor.sh
# Should see: OK: Hello World v1!

# 4. Build version 2 (make a visible change in server.js first, e.g. fix a typo)
docker build -t service:v2 .
# Edit docker-compose.yaml: set image to service:v2 and VERSION=2 for both services

# 5. Run rolling update
../scripts/update.sh service1 service2

# 6. Watch monitor.sh - responses transition from v1 → mix of v1+v2 → all v2
#    No HTTP errors or connection failures should appear

# 7. Cleanup
docker compose down
docker rmi service:v1 service:v2
```
