#!/bin/bash

# Health Check and Cleanup Script
# This script:
# 1. Waits for new containers to be healthy
# 2. Removes unhealthy containers
# 3. Removes the oldest container (after new one is verified)

get_containers_in_state() {
    local service=$1
    local state=$2
    docker ps --filter "label=com.docker.compose.service=${service}" --filter "health=${state}" -q
}

get_all_containers_sorted_by_age() {
    local service=$1
    docker ps --filter "label=com.docker.compose.service=${service}" -q \
        | xargs -r docker inspect --format '{{.Created}} {{.Id}}' \
        | sort \
        | awk '{print $2}'
}

stop_and_remove_container() {
    local container=$1
    local container_short=$(echo "$container" | cut -c1-12)
    echo "   Removing container: $container_short"
    docker stop "${container}" > /dev/null 2>&1
    docker rm "${container}" > /dev/null 2>&1
}

SERVICE_NAME=$1

if [ -z "${SERVICE_NAME}" ]; then
    echo "Usage: $0 <service_name>"
    exit 1
fi

# Wait for containers to exit "starting" state
HEALTHCHECK_TIMEOUT=30
ELAPSED=0

echo "   Waiting for containers to stabilize (max ${HEALTHCHECK_TIMEOUT}s)..."

while [ $ELAPSED -lt $HEALTHCHECK_TIMEOUT ]; do
    STARTING=$(get_containers_in_state "${SERVICE_NAME}" "starting")
    
    if [ -z "${STARTING}" ]; then
        break
    fi
    
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

# Check for unhealthy containers and remove them
UNHEALTHY=$(get_containers_in_state "${SERVICE_NAME}" "unhealthy")

if [ -n "${UNHEALTHY}" ]; then
    echo "   Found unhealthy containers, removing them..."
    for container in ${UNHEALTHY}; do
        stop_and_remove_container "${container}"
    done
    exit 1
fi

# All containers are healthy - remove the oldest one
ALL_CONTAINERS=$(get_all_containers_sorted_by_age "${SERVICE_NAME}")
CONTAINER_COUNT=$(echo "${ALL_CONTAINERS}" | wc -l | xargs)

if [ "${CONTAINER_COUNT}" -gt 1 ]; then
    OLDEST=$(echo "${ALL_CONTAINERS}" | head -n 1)
    echo "   Removing oldest container..."
    stop_and_remove_container "${OLDEST}"
fi

exit 0
