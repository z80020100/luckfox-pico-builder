#!/usr/bin/env bash
# Build luckfox_pico_rkmpi_example RTSP demos for the Luckfox Pico Pro Max (RV1106).
#
# Cross-compiles one or more demos from external/rkmpi natively on the host arch and
# copies each deployable demo folder to dist/rkmpi/host-<arch>/<demo>_demo/. With no
# demo argument it builds all of them. The examples build against the cross-compiler
# only (not a full SDK build), so the in-container step just supplies the toolchain:
#   arm64 -> the rebuilt aarch64 cross-toolchain tarball (built here on first run)
#   amd64 -> the x86-64 cross-toolchain bundled in the SDK
# Those steps live in docker/builder/rkmpi-example-build.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TUPLE="arm-rockchip830-linux-uclibcgnueabihf"
LIBC=uclibc
# Demos are named luckfox_pico_rtsp_<name>; the CLI takes the short <name>.
DEMO_PREFIX="luckfox_pico_rtsp_"
DEMOS="opencv opencv_capture retinaface retinaface_osd yolov5"

LOG_PREFIX="build-rkmpi"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ARCH="$(host_arch)"

usage() {
    cat <<EOF
Usage: tools/build-rkmpi-example.sh [DEMO...]

Cross-compiles luckfox_pico_rkmpi_example RTSP demos natively on the host arch
($ARCH) and copies each deployable demo to dist/rkmpi/host-$ARCH/<demo>_demo/.

Arguments:
  DEMO...   short demo names to build ($LIBC). With no argument, builds all.

Options:
  -h, --help   Show this help.

Available demos (short name):
$(for d in $DEMOS; do echo "  $d"; done)
EOF
}

selected=""
while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
    -*) die "Unknown option: $1 (try --help)" ;;
    *) selected="${selected:+$selected }$1" ;;
    esac
    shift
done
selected="${selected:-$DEMOS}"

rkmpi_dir="$REPO_ROOT/external/rkmpi"
[ -e "$rkmpi_dir/build.sh" ] || die "rkmpi submodule missing. Run: git submodule update --init external/rkmpi"

# Validate short names and expand to full example directory names.
demos=""
for name in $selected; do
    echo "$DEMOS" | grep -qw "$name" || die "unknown demo: $name (try --help)"
    full="$DEMO_PREFIX$name"
    [ -d "$rkmpi_dir/example/$full" ] || die "demo not found in submodule: example/$full"
    demos="${demos:+$demos }$full"
done

require_docker

# Each host arch builds natively with a host-matching cross-toolchain: arm64 needs
# the rebuilt tarball (built here on first run); amd64 uses the SDK's bundled x86-64
# toolchain, so the SDK submodule must be checked out.
if [ "$ARCH" = arm64 ]; then
    ensure_arm64_toolchain "$REPO_ROOT/dist/toolchain/arm64/$TUPLE.tar.gz" "$SCRIPT_DIR"
else
    [ -d "$REPO_ROOT/external/sdk/tools/linux/toolchain/$TUPLE" ] ||
        die "SDK toolchain missing (amd64 uses the SDK's bundled x86-64 toolchain). Run: git submodule update --init external/sdk"
fi

target="builder-$ARCH"
image="luckfox-pico-$target"
export DOCKER_DEFAULT_PLATFORM="linux/$ARCH"
bash "$SCRIPT_DIR/build-docker-image.sh" "$target"

output_base="$REPO_ROOT/dist/rkmpi/host-$ARCH"
mkdir -p "$output_base"

log "Building rkmpi demos ($LIBC, native $ARCH): $demos"
build_start=$SECONDS

docker run --rm \
    -e DEMOS="$demos" \
    -e LIBC="$LIBC" \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -v "$REPO_ROOT:/repo:ro" \
    -v "$output_base:/out" \
    "$image" bash "/repo/docker/builder/rkmpi-example-build.sh"

log "Demos written under: $output_base"
for d in $demos; do
    ls -lh "$output_base/${d}_demo"
done
log_build_time "$build_start"
log "Done. Deploy a demo with: adb push \"$output_base/<demo>_demo\" /root/"
