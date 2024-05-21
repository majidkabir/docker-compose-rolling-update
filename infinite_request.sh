#!/bin/bash

DELAY=0.1

while true; do
    response=$(curl -m 1 -s -w "%{http_code}" -o - "http://localhost:8182/Hi")
    HTTP_STATUS=$(echo "$response" | tail -n1)
    RESPONSE_CONTENT=$(echo "$response" | sed '$d')

    if [ "$HTTP_STATUS" -ne 200 ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - API call failed with status code $HTTP_STATUS"
    else
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Response: $RESPONSE_CONTENT"
    fi

    sleep $DELAY
done
