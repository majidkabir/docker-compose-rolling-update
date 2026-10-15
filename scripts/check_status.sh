#!/usr/bin/env bash
#
# check_status.sh — wait until one or more containers report "healthy".
#
# Used by update.sh to gate a rollout, but it also works on its own:
#
#   ./check_status.sh [-t TIMEOUT] <container> [container...]
#
# Exit codes:
#   0   every container is running and healthy
#   1   a container became unhealthy, stopped running, or the timeout expired
#   2   a container has no healthcheck, so its health cannot be verified
#   64  usage error
#
# Environment:
#   HEALTHCHECK_TIMEOUT        default timeout in seconds (default: 120)
#   HEALTHCHECK_POLL_INTERVAL  seconds between polls (default: 1)

set -euo pipefail

TIMEOUT="${HEALTHCHECK_TIMEOUT:-120}"
POLL_INTERVAL="${HEALTHCHECK_POLL_INTERVAL:-1}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-t TIMEOUT] <container> [container...]

Waits until every given container is running and its healthcheck reports
"healthy". Fails fast if a container turns unhealthy or exits.

Options:
  -t, --timeout SECONDS  Give up after SECONDS (default: ${TIMEOUT})
  -h, --help             Show this help
EOF
}

err() { echo "   ✗ $*" >&2; }

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

CONTAINERS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -t|--timeout)
            if [ $# -lt 2 ]; then err "$1 needs a value"; exit 64; fi
            TIMEOUT="$2"; shift 2 ;;
        --timeout=*) TIMEOUT="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do CONTAINERS+=("$1"); shift; done ;;
        -*) err "Unknown option: $1"; usage >&2; exit 64 ;;
        *) CONTAINERS+=("$1"); shift ;;
    esac
done

if [ ${#CONTAINERS[@]} -eq 0 ]; then
    usage >&2
    exit 64
fi
if ! is_number "$TIMEOUT"; then
    err "Timeout must be a whole number of seconds, got: $TIMEOUT"
    exit 64
fi

# Prints "<state> <health>", e.g. "running healthy" or "exited none".
container_status() {
    docker inspect --format \
        '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$1"
}

# Last healthcheck output, to explain why a container is unhealthy.
last_health_output() {
    docker inspect --format \
        '{{if .State.Health}}{{range .State.Health.Log}}{{.Output}}{{end}}{{end}}' \
        "$1" 2>/dev/null | tail -n 3
}

deadline=$((SECONDS + TIMEOUT))
pending=("${CONTAINERS[@]}")

while :; do
    still_starting=()

    for container in "${pending[@]}"; do
        short="${container:0:12}"

        if ! status=$(container_status "$container" 2>/dev/null); then
            err "Container $short no longer exists"
            exit 1
        fi
        read -r state health <<<"$status"

        if [ "$state" != "running" ]; then
            err "Container $short is '$state', not running. Check: docker logs $short"
            exit 1
        fi

        case "$health" in
            healthy)
                ;;
            none)
                err "Container $short has no healthcheck, so it cannot be verified."
                err "Add a healthcheck to the service (compose 'healthcheck:' or Dockerfile HEALTHCHECK)."
                exit 2
                ;;
            unhealthy)
                err "Container $short is unhealthy."
                output=$(last_health_output "$container")
                if [ -n "$output" ]; then
                    while IFS= read -r line; do
                        echo "     | $line" >&2
                    done <<<"$output"
                fi
                exit 1
                ;;
            *)  # "starting"
                still_starting+=("$container")
                ;;
        esac
    done

    if [ ${#still_starting[@]} -eq 0 ]; then
        exit 0
    fi

    if [ "$SECONDS" -ge "$deadline" ]; then
        names=""
        for container in "${still_starting[@]}"; do
            names="$names ${container:0:12}"
        done
        err "Timed out after ${TIMEOUT}s; still starting:${names}"
        exit 1
    fi

    pending=("${still_starting[@]}")
    sleep "$POLL_INTERVAL"
done
