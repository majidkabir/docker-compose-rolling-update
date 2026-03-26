#!/bin/bash

# Monitoring Script
# This script continuously sends requests to the service to monitor uptime
# during rolling updates. Watch this to verify zero-downtime behavior.

DELAY=0.1
URL="${1:-http://localhost:8182}"

echo "Monitoring service at $URL"
echo "Press Ctrl+C to stop"
echo ""

while true; do
    # Send request and capture both status code and response
    RESPONSE=$(curl -m 1 -s -w "\n%{http_code}" "$URL" 2>&1)
    
    HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_CONTENT=$(echo "$RESPONSE" | sed '$d')
    
    if ! [[ "$HTTP_STATUS" =~ ^[0-9]+$ ]]; then
        # curl failed (timeout, connection refused, etc.)
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Request failed (connection error)"
    elif [ "$HTTP_STATUS" -ne 200 ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - HTTP $HTTP_STATUS"
    else
        echo "$(date +'%Y-%m-%d %H:%M:%S') - OK: $RESPONSE_CONTENT"
    fi
    
    sleep "$DELAY"
done
