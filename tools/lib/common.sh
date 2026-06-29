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
