#!/usr/bin/env bash
# Container-side build of the native arm64 Luckfox cross-toolchain.
#
# Restores the vendor crosstool-NG config from the SDK, builds into the
# case-sensitive work volume (the macOS /out bind mount is case-insensitive,
# which crosstool-NG rejects), then packages the result as a tarball into /out.
# crosstool-NG refuses to run as root, so this re-execs itself as the
# unprivileged `builder` user after fixing mount ownership.
set -euo pipefail

TUPLE="${TUPLE:-arm-rockchip830-linux-uclibcgnueabihf}"
CTNG_CONFIG="/repo/external/sdk/tools/linux/toolchain/$TUPLE/bin/$TUPLE-ct-ng.config"

# crosstool-NG refuses to build as root. Hand the writable mounts to `builder`
# and re-exec as that user.
if [ "$(id -u)" = 0 ]; then
    chown -R builder:builder /workspace /out
    exec runuser -u builder -- env TUPLE="$TUPLE" bash "$0" "$@"
fi

[ -f "$CTNG_CONFIG" ] || {
    echo "[toolchain] vendor ct-ng config not found: $CTNG_CONFIG" >&2
    echo "[toolchain] is the SDK submodule checked out? (git submodule update --init external/sdk)" >&2
    exit 1
}

cd /workspace

# crosstool-NG insists on a case-sensitive filesystem for the work dir and the
# install prefix. /workspace is a Docker volume (case-sensitive); /out is a macOS bind
# mount (case-insensitive), so install into the volume and ship a tarball to /out.
mkdir -p /workspace/src /workspace/x-tools
PREFIX="/workspace/x-tools/$TUPLE"

echo "[toolchain] restoring vendor crosstool-NG config ..."
# The vendor file is a self-extracting bzip2 stream (tail +5 | bzcat).
tail -n +5 "$CTNG_CONFIG" | bzcat >.config

# The vendor config roots its install prefix and source paths at "${build}", a
# variable that is empty in this container. Pin every source/install path to
# the volume.
sed -i "s|^CT_PREFIX_DIR=.*|CT_PREFIX_DIR=\"$PREFIX\"|" .config
sed -i "s|^CT_LOCAL_TARBALLS_DIR=.*|CT_LOCAL_TARBALLS_DIR=\"/workspace/src\"|" .config
sed -i "s|^CT_LINUX_CUSTOM_LOCATION=.*|CT_LINUX_CUSTOM_LOCATION=\"/workspace/src/linux-5.10.66.tar.xz\"|" .config
sed -i "s|^CT_ISL_CUSTOM_LOCATION=.*|CT_ISL_CUSTOM_LOCATION=\"/workspace/src/isl-0.24.tar.xz\"|" .config

# binutils 2.32's gold linker fails to compile under host gcc 11 (gold/errors.h
# lacks #include <string>). The SDK only uses the default ld.bfd, so drop gold
# rather than patch it; oldconfig recomputes the dependent symbols.
sed -i 's|^CT_BINUTILS_LINKER_LD_GOLD=y|# CT_BINUTILS_LINKER_LD_GOLD is not set|' .config
sed -i 's|^# CT_BINUTILS_LINKER_LD is not set|CT_BINUTILS_LINKER_LD=y|' .config

echo "[toolchain] crosstool-NG $(ct-ng version 2>/dev/null | head -1)"
echo "[toolchain] migrating vendor config to the installed crosstool-NG ..."
ct-ng oldconfig

# Link the image's pre-staged sources into /workspace/src. ct-ng won't fetch
# these three on its own — linux/isl are custom-location and expat's vendor URL
# is dead — so the Dockerfile bakes them into /opt/ctng-dl with sha256 (see
# there for the full rationale). /workspace is a runtime volume that shadows the
# image — hence the symlinks rather than baking directly under it.
seed() { ln -sf "/opt/ctng-dl/$1" "/workspace/src/$1"; }
seed expat-2.2.6.tar.bz2
seed linux-5.10.66.tar.xz
seed isl-0.24.tar.xz

echo "[toolchain] building — this takes a while (downloads + compiles gcc/uClibc) ..."
ct-ng build

# A tarball is immune to the case-insensitive macOS filesystem and easy to ship.
echo "[toolchain] packaging -> /out/$TUPLE.tar.gz"
rm -f "/out/$TUPLE.tar.gz"
tar -C /workspace/x-tools -czf "/out/$TUPLE.tar.gz" "$TUPLE"

echo "[toolchain] done. Toolchain at volume /workspace/x-tools/$TUPLE, packaged to /out/$TUPLE.tar.gz"
