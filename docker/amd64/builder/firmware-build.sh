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

# Stub out the SDK's buildroot mirror probe (sysdrv/Makefile runs it right after
# it regenerates buildroot's .config). The probe re-picks a mirror via a 1.5s curl
# connect test and on a total miss blanks the defconfig's BR2_PRIMARY_SITE -- which
# this build hit (observed BR2_PRIMARY_SITE="" in the volume; its CN mirror is also
# unreachable from here). A blank primary sends every Buildroot package to its slow
# upstream site first (e.g. zip via info-zip's FTP). The stub keeps the defconfig's
# fast mirror (sources.buildroot.net). Idempotent.
printf '#!/bin/sh\nexit 0\n' >sysdrv/tools/board/mirror_select/buildroot_mirror_select.sh
./build.sh

if [ ! -d output/image ] || [ -z "$(ls -A output/image)" ]; then
    echo "[amd64] ERROR: no images produced in output/image" >&2
    exit 1
fi
find /out -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -a output/image/. /out/
# Native Linux docker runs the container as root, so the copied images land
# root-owned and the host-side build-info step can't write BUILD-INFO.txt beside
# them. Hand the bind-mounted /out back to the invoking user.
chown -R "${HOST_UID:?}:${HOST_GID:?}" /out
echo "[amd64] images copied to /out"
