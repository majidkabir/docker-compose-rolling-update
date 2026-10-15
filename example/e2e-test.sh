#!/usr/bin/env bash
#
# e2e-test.sh — automated version of the example walkthrough.
#
# Builds v1 and v2, starts the stack, keeps monitor.sh running, then:
#   1. rolls service1 and service2 from v1 to v2
#   2. tries a broken release (BROKEN=1), which must be rolled back
# Fails if any request fails, the broken release is accepted, or the final
# state is wrong. Used by CI; safe to run locally (cleans up after itself).

set -Eeuo pipefail

cd "$(dirname "$0")"
UPDATE=../scripts/update.sh
PROJECT="rolling-update-e2e"
export COMPOSE_PROJECT_NAME="$PROJECT"

LOG="$(mktemp)"
UPDATE_LOG="$(mktemp)"
MONITOR_PID=""

cleanup() {
    if [ -n "$MONITOR_PID" ]; then kill "$MONITOR_PID" 2>/dev/null || true; fi
    docker compose down --remove-orphans >/dev/null 2>&1 || true
    rm -f "$LOG" "$UPDATE_LOG"
}
trap cleanup EXIT

# In GitHub Actions, also emit an annotation so the reason shows on the PR.
annotate() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        local msg="$1"
        msg="${msg//'%'/'%25'}"; msg="${msg//$'\n'/'%0A'}"; msg="${msg//$'\r'/'%0D'}"
        echo "::error title=e2e-test::${msg}"
    fi
}

fail() {
    echo "✗ FAIL: $*" >&2
    echo "--- monitor log (last 30 lines) ---" >&2
    tail -n 30 "$LOG" >&2 || true
    annotate "$*"$'\n'"--- monitor log (failures) ---"$'\n'"$(grep -E '^[0-9]{4}-' "$LOG" | grep -v ' - OK: ' | head -n 15)"$'\n'"--- containers ---"$'\n'"$(docker compose ps -a 2>&1)"
    exit 1
}

on_error() {
    annotate "Command failed (exit $1) at line $2: $3"$'\n'"--- update.sh output ---"$'\n'"$(tail -n 25 "$UPDATE_LOG")"$'\n'"--- containers ---"$'\n'"$(docker compose ps -a 2>&1)"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

step() { echo ""; echo "=== $* ==="; }

# Runs update.sh, keeping its output for failure reports.
run_update() {
    "$UPDATE" "$@" 2>&1 | tee -a "$UPDATE_LOG"
}

running_count() {
    docker compose ps -q --status running "$1" | grep -c . || true
}

step "Building images"
docker build -q -t service:v1 . >/dev/null
docker build -q -t service:v2 . >/dev/null

step "Starting v1"
VERSION=1 docker compose up -d --wait

./monitor.sh > "$LOG" 2>&1 &
MONITOR_PID=$!
sleep 2
grep -q "OK: Hello World v1" "$LOG" || fail "v1 is not serving through nginx"

step "Rolling update to v2"
VERSION=2 run_update service1 service2

step "Broken release must be rolled back"
if BROKEN=1 VERSION=2 run_update service1; then rc=0; else rc=$?; fi
[ "$rc" -eq 1 ] || fail "broken release exited with $rc, expected 1"

sleep 2
kill "$MONITOR_PID"
MONITOR_PID=""

step "Checking results"
total=$(grep -cE '^[0-9]{4}-' "$LOG" || true)
errors=$(grep -E '^[0-9]{4}-' "$LOG" | grep -vc ' - OK: ' || true)
last=$(grep -E ' - OK: ' "$LOG" | tail -n 1)

echo "Requests: $total, failed: $errors"
[ "$total" -gt 20 ] || fail "too few requests recorded ($total)"
[ "$errors" -eq 0 ] || fail "$errors request(s) failed during the update"
[[ "$last" == *"Hello World v2!"* ]] || fail "last response was not v2: $last"
[ "$(running_count service1)" -eq 1 ] || fail "service1 should have 1 running container"
[ "$(running_count service2)" -eq 1 ] || fail "service2 should have 1 running container"

echo ""
echo "✓ Zero-downtime rolling update verified"
