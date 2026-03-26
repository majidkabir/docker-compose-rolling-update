# Docker Compose Zero-Downtime Rolling Updates

A production-ready solution for achieving zero-downtime deployments with Docker Compose by using service scaling and health checks.

## How It Works

The rolling update strategy works by:

1. **Scale Up**: Start a new instance of the service
2. **Health Check**: Wait for the new instance to pass health checks
3. **Remove Old**: Delete the old instance
4. **Repeat**: Do the same for the next service

This ensures there's always at least one healthy instance serving traffic during the entire update process.

```
Initial State:
service1 (v1) → nginx → :8182
service2 (v1) →

Updating service1:
service1 (v1) + service1 (v2-new) → nginx → :8182
service2 (v1) →
              ↓ (wait for health check)
service1 (v2) → nginx → :8182
service2 (v1) →

Updating service2:
service1 (v2) → nginx → :8182
service2 (v1) + service2 (v2-new) →
              ↓ (wait for health check)
service1 (v2) → nginx → :8182
service2 (v2) →
```

## Project Structure

```
.
├── scripts/
│   ├── update.sh          # Main orchestration script
│   └── check_status.sh    # Health check and cleanup
│
├── example/               # Complete example with Node.js + Nginx
│   ├── docker-compose.yaml
│   ├── Dockerfile
│   ├── server.js
│   ├── nginx/
│   │   └── nginx.conf
│   ├── monitor.sh         # Monitoring script
│   └── README.md          # Example-specific documentation
│
└── README.md              # This file
```

## Quick Start

### 1. Using the Scripts with Your Own Services

Copy the scripts to your project:

```bash
mkdir -p scripts
cp scripts/update.sh scripts/check_status.sh ./scripts/
chmod +x ./scripts/*.sh
```

### 2. Configure Your docker-compose.yaml

Ensure your services have health checks defined:

```yaml
services:
  service1:
    image: your-service:v1
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/"]
      interval: 5s
      timeout: 2s
      retries: 3
  
  service2:
    image: your-service:v1
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/"]
      interval: 5s
      timeout: 2s
      retries: 3
```

### 3. Run Rolling Updates

```bash
# Update both services
./scripts/update.sh service1 service2

# Or update specific service
./scripts/update.sh service1
```

## Requirements

- Docker & Docker Compose (v3.8+)
- Services must have proper `healthcheck` configuration
- Health check command must be available in the container (e.g., `curl`)

## Important Notes

- **Health Checks**: Must be configured in your Dockerfile and docker-compose.yaml
- **Startup Time**: Adjust `start_period` in health checks for slower-starting services
- **Load Balancing**: Configure your load balancer/proxy to route to both service instances
- **Nginx Configuration**: Use upstream blocks to distribute traffic

## Example

See the [example/](example/) directory for a complete working example with:
- Simple Node.js HTTP server
- Nginx as reverse proxy and load balancer
- Monitoring script to verify zero-downtime behavior

## Files in scripts/

### update.sh
Main orchestration script that:
- Scales up the service
- Waits for health checks
- Removes old containers
- Reports progress

**Usage**: `./scripts/update.sh service1 service2`

### check_status.sh
Health monitoring script that:
- Waits for containers to exit "starting" state
- Removes unhealthy containers
- Removes the oldest container (after new one is verified)

**Usage**: `./scripts/check_status.sh service_name`

## Troubleshooting

**Health check fails immediately**
- Ensure health check command exists in container (e.g., curl is installed)
- Check health check timeout is not too short
- Verify the health check endpoint is responding

**Old containers not removed**
- Check Docker permissions
- Ensure containers have proper labels
- Run with verbose output to debug

**Requests still go to old container**
- Verify load balancer/proxy is configured correctly
- Check container networking
- Ensure both services are accessible

## License

MIT
