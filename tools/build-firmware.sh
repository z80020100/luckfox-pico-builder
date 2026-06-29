#!/usr/bin/env bash
# One-command firmware build for the Luckfox Pico Pro Max.
#
# Picks the build environment by host architecture and delegates to the matching
# backend, so you do not need to know which Docker image to use:
#   arm64 host -> build-firmware-arm64.sh  (native arm64, zero Rosetta)
#   amd64 host -> build-firmware-amd64.sh  (official image; Rosetta on Apple Silicon)
# Override the choice with --arch. Everything else passes through to the backend.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG_PREFIX="build-firmware"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

host_arch() {
    case "$(uname -m)" in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) die "unsupported host arch: $(uname -m) (expected x86_64/amd64 or aarch64/arm64)" ;;
    esac
}

usage() {
    cat <<EOF
Usage: tools/build-firmware.sh [--arch auto|amd64|arm64] [BOARD_CONFIG] [--reset-sdk]

Builds the firmware in a Docker build environment chosen by host architecture and
copies the images to dist/firmware/<board>/ (with a BUILD-INFO.txt provenance file).

Options:
  --arch <a>     auto (default) picks the host arch so the build runs natively.
                 Forcing the other arch runs under emulation and is slow
                 (amd64-on-arm64 = Rosetta; arm64-on-amd64 = QEMU).
  --reset-sdk    wipe and re-prepare the SDK in the build volume.
  -h, --help     show this help.

Everything except --arch is passed through to build-firmware-<arch>.sh.
EOF
}

ARCH=auto
PASS=()
while [ $# -gt 0 ]; do
    case "$1" in
    --arch)
        shift
        [ $# -gt 0 ] || die "--arch requires a value (auto|amd64|arm64)"
        ARCH="$1"
        ;;
    --arch=*) ARCH="${1#*=}" ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) PASS+=("$1") ;;
    esac
    shift
done

HOST="$(host_arch)"
case "$ARCH" in
auto) ARCH="$HOST" ;;
amd64 | arm64) ;;
*) die "invalid --arch: '$ARCH' (use auto, amd64 or arm64)" ;;
esac

if [ "$ARCH" = "$HOST" ]; then
    export LUCKFOX_FORCED_ARCH=native
else
    export LUCKFOX_FORCED_ARCH=forced
    if [ "$ARCH" = amd64 ]; then
        warn "forcing amd64 on an $HOST host: runs under Rosetta emulation (slow)."
    else
        warn "forcing arm64 on an $HOST host: runs under QEMU emulation (slow)."
    fi
fi

BACKEND="$SCRIPT_DIR/build-firmware-$ARCH.sh"
[ -f "$BACKEND" ] || die "backend not found: $BACKEND"
log "host=$HOST arch=$ARCH ($LUCKFOX_FORCED_ARCH) -> ${BACKEND##*/}"
exec bash "$BACKEND" ${PASS[@]+"${PASS[@]}"}
