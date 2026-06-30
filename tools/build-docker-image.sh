#!/usr/bin/env bash
# Build (or rebuild) a Luckfox Docker image.
#
# The images are the per-host-arch build environments and the toolchain builder:
#   builder-amd64             amd64 build env (firmware, apps) -- official image
#   builder-arm64             native arm64 build env (no Rosetta)
#   toolchain-builder-arm64   crosstool-NG image that rebuilds the arm64 cross-toolchain
#
# The build-firmware / build-toolchain orchestrators auto-invoke this when their
# image is missing, so a normal build never needs it directly. Run it yourself to
# rebuild after editing a Dockerfile:  tools/build-docker-image.sh builder-arm64
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_PREFIX="docker-image"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ALL_TARGETS="builder-amd64 builder-arm64 toolchain-builder-arm64"

usage() {
    cat <<EOF
Usage: tools/build-docker-image.sh [--force] <target|all>

Targets:
  builder-amd64             amd64 build environment (official Luckfox image)
  builder-arm64             native arm64 build environment (no Rosetta)
  toolchain-builder-arm64   crosstool-NG image for the arm64 cross-toolchain
  all                       all of the above

Options:
  --force        rebuild even if the image already exists
  -h, --help     show this help
EOF
}

FORCE=0
REQUESTED=""
while [ $# -gt 0 ]; do
    case "$1" in
    --force) FORCE=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*) die "Unknown option: $1 (try --help)" ;;
    *)
        [ -z "$REQUESTED" ] || die "build one target at a time (or 'all')"
        REQUESTED="$1"
        ;;
    esac
    shift
done
[ -n "$REQUESTED" ] || {
    usage
    exit 1
}

require_docker

build_one() {
    local target="$1" platform dir tag
    case "$target" in
    builder-amd64) platform="linux/amd64" dir="docker/amd64/builder" ;;
    builder-arm64) platform="linux/arm64" dir="docker/arm64/builder" ;;
    toolchain-builder-arm64) platform="linux/arm64" dir="docker/arm64/toolchain" ;;
    *) die "unknown target: $target (try --help)" ;;
    esac
    tag="luckfox-pico-$target"
    if [ "$FORCE" = 0 ] && docker image inspect "$tag" >/dev/null 2>&1; then
        log "image present: $tag (use --force to rebuild)"
        return 0
    fi
    [ -f "$REPO_ROOT/$dir/Dockerfile" ] || die "Dockerfile not found: $dir/Dockerfile"
    log "building $tag ($platform) from $dir ..."
    docker build --platform "$platform" -t "$tag" "$REPO_ROOT/$dir"
    log "built: $tag"
}

if [ "$REQUESTED" = all ]; then
    for t in $ALL_TARGETS; do build_one "$t"; done
else
    build_one "$REQUESTED"
fi
