#!/usr/bin/env bash
# Build a native arm64 Luckfox cross-toolchain inside Docker with crosstool-NG.
#
# The vendor toolchain ships only as x86-64 binaries. This rebuilds it from the
# vendor's crosstool-NG config on an arm64 host, producing a cross compiler that
# runs natively without emulation. Output lands in dist/toolchain/arm64/.
set -euo pipefail

# Run the arm64 image natively and silence the platform warning when the host
# default differs.
export DOCKER_DEFAULT_PLATFORM=linux/arm64

TARGET="toolchain-builder-arm64"
IMAGE="luckfox-pico-$TARGET"
VOLUME="${LUCKFOX_TOOLCHAIN_ARM64_VOLUME:-luckfox-pico-toolchain-arm64}"
TUPLE="arm-rockchip830-linux-uclibcgnueabihf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK_DIR="$REPO_ROOT/external/sdk"
CTNG_CONFIG="$SDK_DIR/tools/linux/toolchain/$TUPLE/bin/$TUPLE-ct-ng.config"
OUTPUT_DIR="$REPO_ROOT/dist/toolchain/arm64"

LOG_PREFIX="build-toolchain"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_docker
[ -f "$CTNG_CONFIG" ] || die "Vendor ct-ng config missing: $CTNG_CONFIG
Run: git submodule update --init external/sdk"

bash "$SCRIPT_DIR/build-docker-image.sh" "$TARGET"

ensure_volume "$VOLUME" "crosstool-NG work volume (caches build state)"

mkdir -p "$OUTPUT_DIR"
BUILD_HOSTNAME="$(build_hostname)"
log "Building native arm64 toolchain for: $TUPLE"
warn "First run is slow: crosstool-NG downloads and compiles gcc and uClibc."
build_start=$SECONDS

docker run --rm \
    --hostname "$BUILD_HOSTNAME" \
    -e TUPLE="$TUPLE" \
    -v "$REPO_ROOT:/repo:ro" \
    -v "$VOLUME:/workspace" \
    -v "$OUTPUT_DIR:/out" \
    "$IMAGE" bash /repo/docker/arm64/toolchain/build-toolchain.sh

[ -f "$OUTPUT_DIR/$TUPLE.tar.gz" ] || die "Build finished but tarball is missing: $OUTPUT_DIR/$TUPLE.tar.gz"
log "Toolchain packaged to: $OUTPUT_DIR/$TUPLE.tar.gz"
ls -lh "$OUTPUT_DIR/$TUPLE.tar.gz"
log "It is an aarch64-linux toolchain: run it inside an arm64 container, not directly on the host."
log_build_time "$build_start"
log "Done."
