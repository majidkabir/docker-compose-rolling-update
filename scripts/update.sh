#!/usr/bin/env bash
#
# update.sh — zero-downtime rolling update for Docker Compose services.
#
# For each service, in order:
#   1. Start N new containers next to the N running ones (--scale 2N --no-recreate)
#   2. Wait until every new container reports "healthy"
#   3. Stop and remove the N old containers
# If the new containers fail (unhealthy, crash, timeout, no healthcheck), they
# are removed again and the old containers keep serving traffic.
#
# Can also be installed as a Docker CLI plugin ("docker rollingupdate"),
# see scripts/install-plugin.sh.

set -euo pipefail

VERSION="1.0.0"
PLUGIN_NAME="rollingupdate"

# --- Docker CLI plugin support ------------------------------------------------
if [ "${1:-}" = "docker-cli-plugin-metadata" ]; then
    cat <<EOF
{"SchemaVersion":"0.1.0","Vendor":"majidkabir","Version":"${VERSION}","ShortDescription":"Zero-downtime rolling updates for Docker Compose services","URL":"https://github.com/majidkabir/docker-compose-rolling-update"}
EOF
    exit 0
fi
# Docker passes the plugin's subcommand name as the first argument.
PROG="$(basename "$0")"
if [ "$PROG" = "docker-${PLUGIN_NAME}" ]; then
    PROG="docker ${PLUGIN_NAME}"
    if [ "${1:-}" = "${PLUGIN_NAME}" ]; then
        shift
    fi
fi

# Resolve symlinks (plugin install) so check_status.sh is found next to the
# real script, whatever directory or path this was started from.
SELF="${BASH_SOURCE[0]}"
if resolved=$(readlink -f "$SELF" 2>/dev/null); then
    SELF="$resolved"
fi
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
CHECK_STATUS="${SCRIPT_DIR}/check_status.sh"

# --- Settings -----------------------------------------------------------------
TIMEOUT="${HEALTHCHECK_TIMEOUT:-120}"
STOP_TIMEOUT="${STOP_TIMEOUT:-}"
PULL=""
COMPOSE=(docker compose)
SERVICES=()

usage() {
    cat <<EOF
Usage: ${PROG} [OPTIONS] <service> [service...]

Zero-downtime rolling update of Docker Compose services. Each service must
have a healthcheck and be running.

Options:
  -f, --file FILE              Compose file (repeatable, like docker compose -f)
  -p, --project-name NAME      Compose project name
      --project-directory DIR  Compose project directory
  -t, --timeout SECONDS        Max wait for new containers to become healthy
                               (default: ${TIMEOUT}, env HEALTHCHECK_TIMEOUT)
      --stop-timeout SECONDS   Grace period when stopping old containers
                               (default: the service's stop_grace_period)
      --pull POLICY            Pull policy for new containers: always, missing,
                               never (default: the service's pull_policy)
  -h, --help                   Show this help
  -v, --version                Show version

COMPOSE_FILE, COMPOSE_PROJECT_NAME and other docker compose environment
variables are respected as usual.

Examples:
  ${PROG} api worker
  ${PROG} -f docker-compose.prod.yaml -p shop -t 300 api
EOF
}

log()  { echo "$*"; }
err()  { echo "✗ $*" >&2; }

need_value() {
    if [ "$2" -lt 2 ]; then
        err "$1 needs a value"
        usage >&2
        exit 64
    fi
}

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

# --- Argument parsing ---------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--file)            need_value "$1" $#; COMPOSE+=(-f "$2"); shift 2 ;;
        --file=*)             COMPOSE+=(-f "${1#*=}"); shift ;;
        -p|--project-name)    need_value "$1" $#; COMPOSE+=(-p "$2"); shift 2 ;;
        --project-name=*)     COMPOSE+=(-p "${1#*=}"); shift ;;
        --project-directory)  need_value "$1" $#; COMPOSE+=(--project-directory "$2"); shift 2 ;;
        --project-directory=*) COMPOSE+=(--project-directory "${1#*=}"); shift ;;
        -t|--timeout)         need_value "$1" $#; TIMEOUT="$2"; shift 2 ;;
        --timeout=*)          TIMEOUT="${1#*=}"; shift ;;
        --stop-timeout)       need_value "$1" $#; STOP_TIMEOUT="$2"; shift 2 ;;
        --stop-timeout=*)     STOP_TIMEOUT="${1#*=}"; shift ;;
        --pull)               need_value "$1" $#; PULL="$2"; shift 2 ;;
        --pull=*)             PULL="${1#*=}"; shift ;;
        -h|--help)            usage; exit 0 ;;
        -v|--version)         echo "docker-compose-rolling-update ${VERSION}"; exit 0 ;;
        --)                   shift; while [ $# -gt 0 ]; do SERVICES+=("$1"); shift; done ;;
        -*)                   err "Unknown option: $1"; usage >&2; exit 64 ;;
        *)                    SERVICES+=("$1"); shift ;;
    esac
done

if [ ${#SERVICES[@]} -eq 0 ]; then
    err "No services given."
    usage >&2
    exit 64
fi
if ! is_number "$TIMEOUT"; then
    err "--timeout must be a whole number of seconds, got: $TIMEOUT"
    exit 64
fi
if [ -n "$STOP_TIMEOUT" ] && ! is_number "$STOP_TIMEOUT"; then
    err "--stop-timeout must be a whole number of seconds, got: $STOP_TIMEOUT"
    exit 64
fi
case "$PULL" in
    ""|always|missing|never) ;;
    *) err "--pull must be always, missing or never, got: $PULL"; exit 64 ;;
esac
if [ ! -x "$CHECK_STATUS" ]; then
    err "Cannot find executable check_status.sh next to this script ($CHECK_STATUS)"
    exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
    err "Docker Compose v2 ('docker compose') is required."
    exit 1
fi

# --- Helpers ------------------------------------------------------------------

# Container IDs of a service in this project, one per line.
# Pass "-a" first to include stopped containers.
service_ids() {
    if [ "$1" = "-a" ]; then
        "${COMPOSE[@]}" ps -a -q "$2"
    else
        "${COMPOSE[@]}" ps -q --status running "$1"
    fi
}

contains() {
    local needle=$1 item
    shift
    for item in "$@"; do
        if [ "$item" = "$needle" ]; then return 0; fi
    done
    return 1
}

remove_container() {
    local id=$1
    log "      Stopping ${id:0:12}..."
    if [ -n "$STOP_TIMEOUT" ]; then
        docker stop -t "$STOP_TIMEOUT" "$id" >/dev/null || return 1
    else
        docker stop "$id" >/dev/null || return 1
    fi
    docker rm "$id" >/dev/null || return 1
}

# New containers started for the service currently being updated; removed
# again if the update fails or is interrupted.
NEW_IDS=()
CHECK_PID=""

rollback() {
    if [ ${#NEW_IDS[@]} -eq 0 ]; then return 0; fi
    log "   Rolling back: removing new container(s), old ones keep running..."
    local id
    for id in "${NEW_IDS[@]}"; do
        if docker rm -f "$id" >/dev/null 2>&1; then
            log "      Removed ${id:0:12}"
        else
            err "Could not remove ${id:0:12}; remove it manually: docker rm -f ${id:0:12}"
        fi
    done
    NEW_IDS=()
}

on_interrupt() {
    local code=$1
    echo "" >&2
    err "Interrupted."
    if [ -n "$CHECK_PID" ]; then
        kill "$CHECK_PID" 2>/dev/null || true
    fi
    rollback
    exit "$code"
}
trap 'on_interrupt 130' INT
trap 'on_interrupt 143' TERM

# Lines on stdin -> words, ignoring empty lines.
read_ids() {
    local line
    while IFS= read -r line; do
        if [ -n "$line" ]; then echo "$line"; fi
    done
}

rollout() {
    local service=$1
    local out id

    # Running containers (to replace) and all containers (to spot new ones).
    local old_ids=() all_before=()
    if ! out=$(service_ids "$service" | read_ids); then
        err "Could not list containers for $service"; return 1
    fi
    for id in $out; do old_ids+=("$id"); done
    if ! out=$(service_ids -a "$service" | read_ids); then
        err "Could not list containers for $service"; return 1
    fi
    for id in $out; do all_before+=("$id"); done

    local count=${#old_ids[@]}
    if [ "$count" -eq 0 ]; then
        err "$service has no running containers. Start it first: docker compose up -d $service"
        return 1
    fi
    if [ ${#all_before[@]} -ne "$count" ]; then
        err "$service has stopped containers that 'up' would restart."
        err "Remove them first: docker compose rm -f $service   (running ones are kept)"
        return 1
    fi

    local target=$((count * 2))
    log "   [1/3] Starting $count new container(s) next to $count running (scale $count → $target)..."
    local up_args=(up -d --no-deps --no-recreate --scale "${service}=${target}")
    if [ -n "$PULL" ]; then
        up_args+=(--pull "$PULL")
    fi
    if ! "${COMPOSE[@]}" "${up_args[@]}" "$service"; then
        err "docker compose up failed for $service"
        # Still clean up anything that did get created.
    fi

    if ! out=$(service_ids -a "$service" | read_ids); then
        err "Could not list containers for $service"; return 1
    fi
    NEW_IDS=()
    for id in $out; do
        if [ ${#all_before[@]} -eq 0 ] || ! contains "$id" "${all_before[@]}"; then
            NEW_IDS+=("$id")
        fi
    done

    if [ ${#NEW_IDS[@]} -ne "$count" ]; then
        err "Expected $count new container(s) for $service, found ${#NEW_IDS[@]}."
        rollback
        return 1
    fi

    log "   [2/3] Waiting for new container(s) to become healthy (timeout ${TIMEOUT}s)..."
    # Run in the background and 'wait' so INT/TERM traps fire immediately
    # instead of after the health check returns.
    "$CHECK_STATUS" --timeout "$TIMEOUT" "${NEW_IDS[@]}" &
    CHECK_PID=$!
    if ! wait "$CHECK_PID"; then
        CHECK_PID=""
        rollback
        return 1
    fi
    CHECK_PID=""
    log "      ✓ New container(s) healthy"
    NEW_IDS=()   # From here on the new containers are the ones to keep.

    log "   [3/3] Removing $count old container(s)..."
    for id in "${old_ids[@]}"; do
        if ! remove_container "$id"; then
            err "Failed to remove old container ${id:0:12}. The new version is running;"
            err "remove the old container manually: docker rm -f ${id:0:12}"
            return 1
        fi
    done
}

# --- Main ---------------------------------------------------------------------
# Validate service names against the compose file before touching anything.
if ! known_services=$("${COMPOSE[@]}" config --services); then
    err "Could not read the compose configuration."
    exit 1
fi
for service in "${SERVICES[@]}"; do
    if ! grep -qxF -- "$service" <<<"$known_services"; then
        err "Unknown service '$service'. Services in this project: $(echo "$known_services" | tr '\n' ' ')"
        exit 64
    fi
done

log "================================"
log "Starting rolling update"
log "Services: ${SERVICES[*]}"
log "================================"

updated=()
for service in "${SERVICES[@]}"; do
    log ""
    log ">>> Updating service: $service"
    if ! rollout "$service"; then
        log ""
        err "Failed to update $service. Its previous containers are still running."
        if [ ${#updated[@]} -gt 0 ]; then
            err "Already updated in this run: ${updated[*]}"
        fi
        exit 1
    fi
    log "✓ Successfully updated $service"
    updated+=("$service")
done

log ""
log "================================"
log "✓ Rolling update completed successfully!"
log "================================"
