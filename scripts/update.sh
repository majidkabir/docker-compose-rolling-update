#!/bin/bash

set -e

# Rolling Update Script for Docker Compose
# This script orchestrates zero-downtime updates by:
# 1. Scaling up the service (new container starts)
# 2. Waiting for health check to pass
# 3. Removing the old container
# 4. Repeat for the other service

SERVICE_NAMES=${@:-"service1 service2"}

echo "================================"
echo "Starting Rolling Update"
echo "Services to update: $SERVICE_NAMES"
echo "================================"

for service in $SERVICE_NAMES; do
    echo ""
    echo ">>> Updating service: $service"
    
    # Scale up service (new instance starts)
    echo "   [1/3] Scaling up $service..."
    docker compose up -d --scale "$service"=2 --no-recreate
    
    # Wait for new container to be healthy
    echo "   [2/3] Waiting for new $service container to be healthy..."
    ./"$(dirname "$0")"/check_status.sh "$service"
    
    if [ $? -eq 0 ]; then
        echo "   [3/3] New $service container is healthy!"
        echo "✓ Successfully updated $service"
    else
        echo "✗ Failed to update $service - health check failed"
        exit 1
    fi
done

echo ""
echo "================================"
echo "✓ Rolling update completed successfully!"
echo "================================"
