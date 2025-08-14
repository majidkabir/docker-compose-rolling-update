#!/bin/bash

 # Function to get container IDs for a service in a specific state
 get_containers_in_state() {
     local service=$1
     local state=$2
     docker ps --filter "label=com.docker.compose.service=${service}" --filter "health=${state}" -q
 }

 # Function to get all container IDs for a service sorted by creation time (oldest first)
 get_all_containers_sorted_by_age() {
     local service=$1
    docker ps --filter "label=com.docker.compose.service=${service}" -q \
        | xargs -r docker inspect --format '{{.Created}} {{.Id}}' \
        | sort \
        | awk '{print $2}'
    }
stop_and_remove_container() {
    local container=$1
    docker stop "${container}"
    docker rm "${container}"
    docker exec nginx nginx -s reload
}

 # Main script
 service_name=$1

 if [ -z "${service_name}" ]; then
     echo "Usage: $0 <service_name>"
     exit 1
 fi

 # Wait until no containers are in the "starting" state
 timeout=5  # Set the timeout duration in seconds
 elapsed=0
 echo "Waiting for containers of service '${service_name}' to be in a stable state..."
 while true; do
     starting_containers=$(get_containers_in_state "${service_name}" "starting")
     if [ -z "${starting_containers}" ]; then
         break
     fi

     if [ ${elapsed} -ge ${timeout} ]; then
         echo "Timeout reached. Stopping the container."
         for container in ${starting_containers}; do
             stop_and_remove_container "${container}"
         done
         exit 0
     fi

     sleep 1
     elapsed=$((elapsed + 1))
 done

 # Check for unhealthy containers
 unhealthy_containers=$(get_containers_in_state "${service_name}" "unhealthy")

 if [ -n "${unhealthy_containers}" ]; then
     echo "Stopping unhealthy container(s): ${unhealthy_containers}"
     for container in ${unhealthy_containers}; do
         stop_and_remove_container "${container}"
     done
 else
     # Get the oldest container for the service
     all_containers=$(get_all_containers_sorted_by_age "${service_name}")
     container_count=$(echo "${all_containers}" | wc -l)

     if [ "${container_count}" -gt 1 ]; then
         oldest_container=$(echo "${all_containers}" | head -n 1)
         echo "Stopping the oldest container: ${oldest_container}"
         docker exec nginx nginx -s reload
         stop_and_remove_container "${oldest_container}"
     else
         echo "No containers found for service '${service_name}'."
     fi
 fi
