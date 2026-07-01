#!/usr/bin/env bash
# One-command firmware build for the Luckfox Pico Pro Max.
#
# Picks the build environment by host architecture and delegates to the matching
# backend, so you do not need to know which Docker image to use:
#   arm64 host -> build-firmware-arm64.sh  (native arm64)
#   amd64 host -> build-firmware-amd64.sh  (native x86-64)
# Emulated cross-arch builds are unsupported, so the arch is always the host's and
# every argument passes through to the backend.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG_PREFIX="build-firmware"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<EOF
Usage: tools/build-firmware.sh [BOARD_CONFIG] [--reset-sdk]

Builds the firmware natively in a Docker build environment chosen by host
architecture and copies the images to dist/firmware/host-<arch>/<board>/ (with a
BUILD-INFO.txt provenance file). Emulated cross-arch builds are unsupported.

Options:
  --reset-sdk    wipe and re-prepare the SDK in the build volume.
  -h, --help     show this help.

All arguments are passed through to build-firmware-<arch>.sh.
EOF
}

PASS=()
while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
    *) PASS+=("$1") ;;
    esac
    shift
done

ARCH="$(host_arch)"
BACKEND="$SCRIPT_DIR/build-firmware-$ARCH.sh"
[ -f "$BACKEND" ] || die "backend not found: $BACKEND"
log "host arch $ARCH -> ${BACKEND##*/}"
exec bash "$BACKEND" ${PASS[@]+"${PASS[@]}"}
