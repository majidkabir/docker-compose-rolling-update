#!/usr/bin/env bash
#
# install-plugin.sh — install update.sh as the Docker CLI plugin
# "docker rollingupdate".
#
#   ./scripts/install-plugin.sh            copy into ~/.docker/cli-plugins
#   ./scripts/install-plugin.sh --link     symlink instead (follows this checkout)
#   ./scripts/install-plugin.sh DIR        install into DIR
#
# For a system-wide install use /usr/local/lib/docker/cli-plugins (needs sudo).

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
if resolved=$(readlink -f "$SELF" 2>/dev/null); then
    SELF="$resolved"
fi
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"

MODE="copy"
DEST="${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins"

while [ $# -gt 0 ]; do
    case "$1" in
        --link) MODE="link"; shift ;;
        -h|--help) sed -n '3,10p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 64 ;;
        *) DEST="$1"; shift ;;
    esac
done

mkdir -p "$DEST"
target="$DEST/docker-rollingupdate"

if [ "$MODE" = "link" ]; then
    ln -sfn "$SCRIPT_DIR/update.sh" "$target"
else
    # update.sh looks for check_status.sh next to itself; Docker ignores files
    # in cli-plugins that don't start with "docker-".
    rm -f "$target"
    cp "$SCRIPT_DIR/update.sh" "$target"
    cp "$SCRIPT_DIR/check_status.sh" "$DEST/check_status.sh"
    chmod +x "$target" "$DEST/check_status.sh"
fi

echo "Installed ($MODE): $target"
if docker rollingupdate --version 2>/dev/null | grep -q "docker-compose-rolling-update"; then
    echo "Try it: docker rollingupdate --help"
else
    echo "Note: 'docker rollingupdate' is not picked up yet. Docker looks for plugins in"
    echo "\${DOCKER_CONFIG:-~/.docker}/cli-plugins and /usr/local/lib/docker/cli-plugins."
fi
