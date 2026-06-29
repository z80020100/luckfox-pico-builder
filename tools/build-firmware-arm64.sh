#!/usr/bin/env bash
# arm64 firmware build backend for the Luckfox Pico Pro Max.
#
# Normally invoked via tools/build-firmware.sh (the host-arch dispatcher); can also
# be run directly. Builds natively on arm64 (zero Rosetta) with the rebuilt arm64
# cross-toolchain -- if the toolchain tarball is missing it is built first
# automatically. The in-container steps live in docker/arm64/builder/firmware-build.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ARCH=arm64
VOLUME="${LUCKFOX_SDK_ARM64_VOLUME:-luckfox-pico-sdk-arm64}"
TUPLE="arm-rockchip830-linux-uclibcgnueabihf"
TOOLCHAIN_TARBALL="$REPO_ROOT/dist/toolchain/arm64/$TUPLE.tar.gz"
BUILD_DESC="Build the Luckfox Pico Pro Max firmware natively on arm64 and copy the images to
dist/firmware/<board>/."
RESET_SDK_HELP="Wipe and re-prepare the SDK in the build volume (re-injects the
                 toolchain and re-swaps the host tools)."
TOOLCHAIN_DESC="rebuilt aarch64 crosstool-NG 1.24.0 ($TUPLE)"

LOG_PREFIX="build-fw-arm64"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/build-info.sh
source "$SCRIPT_DIR/lib/build-info.sh"
# shellcheck source=lib/firmware-build.sh
source "$SCRIPT_DIR/lib/firmware-build.sh"

# arm64 builds natively, so it needs the rebuilt cross-toolchain; build it on first run.
preflight() {
    [ -f "$TOOLCHAIN_TARBALL" ] && return 0
    log "arm64 toolchain not found; building it first (one-time, ~15 min) ..."
    bash "$SCRIPT_DIR/build-toolchain-arm64.sh"
    [ -f "$TOOLCHAIN_TARBALL" ] || die "toolchain build did not produce $TOOLCHAIN_TARBALL"
}

run_firmware_build "$@"
