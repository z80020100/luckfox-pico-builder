#!/usr/bin/env bash
# Shared shell helpers for the tools/ scripts.
#
# Source it after resolving SCRIPT_DIR and (optionally) setting LOG_PREFIX:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   LOG_PREFIX="my-tool"
#   source "$SCRIPT_DIR/lib/common.sh"

# Tag prepended to every log line; defaults to the sourcing script's name.
: "${LOG_PREFIX:=${0##*/}}"

log() { printf '\033[0;32m[%s]\033[0m %s\n' "$LOG_PREFIX" "$*"; }
warn() { printf '\033[0;33m[%s]\033[0m %s\n' "$LOG_PREFIX" "$*" >&2; }
die() {
    printf '\033[0;31m[%s]\033[0m %s\n' "$LOG_PREFIX" "$*" >&2
    exit 1
}

# Abort with a friendly message unless a usable Docker daemon is available.
require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker."
    docker info >/dev/null 2>&1 || die "Docker daemon not responding. Start it and retry."
}

# Ensure a Docker volume exists, creating it (with a log line) on first use.
ensure_volume() {
    local name="$1" desc="${2:-build volume}"
    docker volume inspect "$name" >/dev/null 2>&1 || {
        log "Creating $desc: $name"
        docker volume create "$name" >/dev/null
    }
}

# List the Pro Max BoardConfig files under an SDK board-config dir.
# Usage: list_boards <sdk_dir> <board_cfg_subdir>
list_boards() {
    local sdk_dir="$1" subdir="$2" cfg found=0
    for cfg in "$sdk_dir/$subdir"/BoardConfig-*RV1106_Luckfox_Pico_Pro_Max*.mk; do
        [ -e "$cfg" ] || continue
        echo "  ${cfg##*/}"
        found=1
    done
    [ "$found" = 1 ] || echo "  (SDK submodule not checked out yet)"
}

build_hostname() {
    hostname
}

# Log wall-clock time since a $SECONDS snapshot as "Build time: Xm Ys".
log_build_time() {
    local elapsed=$((SECONDS - $1))
    log "Build time: $((elapsed / 60))m $((elapsed % 60))s"
}
