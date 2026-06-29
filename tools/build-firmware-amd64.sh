#!/usr/bin/env bash
# amd64 firmware build backend for the Luckfox Pico Pro Max.
#
# Normally invoked via tools/build-firmware.sh (the host-arch dispatcher); can also
# be run directly. Builds in the official amd64 image -- native on an x86-64 host,
# Rosetta on Apple Silicon. The in-container steps live in
# docker/amd64/builder/firmware-build.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ARCH=amd64
VOLUME="${LUCKFOX_SDK_AMD64_VOLUME:-luckfox-pico-sdk-amd64}"
BUILD_DESC="Build the Luckfox Pico Pro Max firmware inside Docker and copy the images to
dist/firmware/<board>/."
RESET_SDK_HELP="Wipe and re-clone the SDK into the build volume. Use after a
                 submodule SHA bump or to force a clean source tree."
TOOLCHAIN_DESC="official x86-64 prebuilt (arm-rockchip830-linux-uclibcgnueabihf)"

LOG_PREFIX="build-fw-amd64"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/build-info.sh
source "$SCRIPT_DIR/lib/build-info.sh"
# shellcheck source=lib/firmware-build.sh
source "$SCRIPT_DIR/lib/firmware-build.sh"

run_firmware_build "$@"
