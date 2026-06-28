#!/usr/bin/env bash
# Prepare the SDK in the build volume, then build the firmware.
# Runs inside the official Luckfox image: its bundled x86-64 toolchain and host
# tools need no injection or host-tool swap, unlike the arm64 builder.
#
#  1. Clone the SDK into the case-sensitive volume (macOS bind mounts collapse the
#     kernel's case-twin files).
#  2. Build the firmware and copy the images to /out.
set -euo pipefail

BOARD_CONFIG="${BOARD_CONFIG:?BOARD_CONFIG not set}"
BOARD_CFG_SUBDIR="${BOARD_CFG_SUBDIR:?BOARD_CFG_SUBDIR not set}"

git config --global --add safe.directory "*"

if [ "${RESET_SDK:-0}" = 1 ]; then
    echo "[amd64] --reset-sdk: wiping volume ..."
    find /sdk -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi

if [ ! -e /sdk/.sdk-ready ]; then
    find /sdk -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    echo "[amd64] cloning SDK from host git objects ..."
    git clone --no-hardlinks /repo/external/sdk /sdk
    touch /sdk/.sdk-ready
else
    echo "[amd64] reusing SDK in volume (pass --reset-sdk to refresh)"
fi

cd /sdk
ln -rfs "$BOARD_CFG_SUBDIR/$BOARD_CONFIG" .BoardConfig.mk
echo "[amd64] board: $(readlink -f .BoardConfig.mk)"
./build.sh

if [ ! -d output/image ] || [ -z "$(ls -A output/image)" ]; then
    echo "[amd64] ERROR: no images produced in output/image" >&2
    exit 1
fi
find /out -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -a output/image/. /out/
echo "[amd64] images copied to /out"
