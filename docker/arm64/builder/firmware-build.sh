#!/usr/bin/env bash
# Prepare the SDK with the native arm64 toolchain and arm64 host tools, then build.
# Runs inside the build container.
#
#  1. Clone the SDK into the case-sensitive volume (macOS bind mounts collapse
#     the kernel's case-twin files).
#  2. Replace the x86-64 cross-toolchain with the native arm64 one.
#  3. Swap each x86-64 prebuilt host tool under sysdrv/tools/pc for the same-named
#     arm64 system tool; tools with no arm64 counterpart are left as-is.
#  4. Build the firmware.
set -euo pipefail

TUPLE=arm-rockchip830-linux-uclibcgnueabihf
BOARD_CONFIG="${BOARD_CONFIG:?BOARD_CONFIG not set}"
BOARD_CFG_SUBDIR="${BOARD_CFG_SUBDIR:?BOARD_CFG_SUBDIR not set}"
TC_TARBALL="/repo/dist/toolchain/arm64/$TUPLE.tar.gz"

git config --global --add safe.directory "*"

if [ "${RESET_SDK:-0}" = 1 ]; then
    echo "[arm64] --reset-sdk: wiping volume ..."
    find /sdk -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi

if [ ! -e /sdk/.arm64-ready ]; then
    find /sdk -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    echo "[arm64] cloning SDK from host git objects ..."
    git clone --no-hardlinks /repo/external/sdk /sdk

    echo "[arm64] injecting native arm64 toolchain ..."
    [ -f "$TC_TARBALL" ] || {
        echo "[arm64] ERROR: missing $TC_TARBALL (run tools/build-toolchain-arm64.sh first)" >&2
        exit 1
    }
    tcdir="/sdk/tools/linux/toolchain/$TUPLE"
    # Preserve vendor extras the rebuilt toolchain lacks. runtime_lib/ holds the
    # target uClibc libs the rootfs build unpacks — target-side, host-independent,
    # and the same uClibc-ng version we rebuilt, so the vendor copy is correct.
    rm -rf /tmp/tc-extras && mkdir -p /tmp/tc-extras
    [ -d "$tcdir/runtime_lib" ] && mv "$tcdir/runtime_lib" /tmp/tc-extras/
    rm -rf "$tcdir"
    tar -xzf "$TC_TARBALL" -C "/sdk/tools/linux/toolchain/"
    [ -d /tmp/tc-extras/runtime_lib ] && mv /tmp/tc-extras/runtime_lib "$tcdir/runtime_lib"
    file -b "$tcdir/bin/$TUPLE-gcc" | grep -q aarch64 || {
        echo "[arm64] ERROR: injected toolchain is not aarch64" >&2
        exit 1
    }

    echo "[arm64] swapping x86 pc host tools for same-named arm64 system tools ..."
    find /sdk/sysdrv/tools/pc -type f | while read -r f; do
        file -b "$f" 2>/dev/null | grep -q x86-64 || continue
        base=$(basename "$f")
        sys=$(command -v "$base" 2>/dev/null || true)
        # -L follows symlinks (e.g. mkfs.ext4 -> mke2fs); cp -f then copies the
        # real arm64 binary, which dispatches on argv[0] just like the original.
        if [ -n "$sys" ] && file -bL "$sys" 2>/dev/null | grep -q aarch64; then
            cp -f "$sys" "$f"
            echo "  + $base -> arm64"
        else
            echo "  - $base (no arm64 system tool; off-path for this board, left as-is)"
        fi
    done

    # Apply arm64-native packaging patches onto the SDK clone (the submodule
    # stays pinned; patches are overlaid only here, in the case-sensitive
    # volume). The patch overlays u-boot's natively-built mkimage/loaderimage/
    # trust_merger over the rkbin x86-64 prebuilts so u-boot's own packaging
    # steps run native.
    echo "[arm64] applying arm64-native packaging patches ..."
    for p in /repo/docker/arm64/builder/patches/*.patch; do
        [ -f "$p" ] || continue
        echo "  + $(basename "$p")"
        git -C /sdk apply "$p"
    done

    # Native arm64 host tools overlaid over the x86-64 rkbin/SDK prebuilts so
    # packaging runs native (no Rosetta):
    #   boot_merger  -> rkbin/tools/: the RV1106 NEWIDB loader packer u-boot's
    #                   spl.sh runs (the one closed tool with no open counterpart);
    #                   emits download.bin + idblock.img byte-identical to the
    #                   prebuilt (only the build timestamp differs).
    #   afptool,     -> Linux_Pack_Firmware/: update.img packing, replacing the
    #   rkImageMaker    mk-update_pack.sh prebuilts (RKAF byte-identical; RKFW
    #                   differs only by timestamp).
    echo "[arm64] building native arm64 boot_merger + afptool + rkImageMaker ..."
    pf_src=/repo/docker/arm64/builder/src
    g++ -O2 -std=gnu++11 -o /tmp/boot_merger "$pf_src/boot_merger.cpp" -lcrypto
    g++ -O2 -std=gnu++11 -o /tmp/afptool "$pf_src/afptool.cpp"
    g++ -O2 -std=gnu++11 -o /tmp/rkImageMaker "$pf_src/rkImageMaker.cpp" -lcrypto
    for _t in boot_merger afptool rkImageMaker; do
        file -b "/tmp/$_t" | grep -q aarch64 || {
            echo "[arm64] ERROR: built $_t is not aarch64" >&2
            exit 1
        }
    done
    cp -f /tmp/afptool /tmp/rkImageMaker /sdk/tools/linux/Linux_Pack_Firmware/
    cp -f /tmp/boot_merger /sdk/sysdrv/source/uboot/rkbin/tools/boot_merger
    echo "[arm64] native tools overlaid (boot_merger->rkbin/tools; afptool,rkImageMaker->Linux_Pack_Firmware)"

    touch /sdk/.arm64-ready
else
    echo "[arm64] reusing prepared SDK (pass --reset-sdk to refresh)"
fi

cd /sdk
ln -rfs "$BOARD_CFG_SUBDIR/$BOARD_CONFIG" .BoardConfig.mk
echo "[arm64] board: $(readlink -f .BoardConfig.mk)"

echo "[arm64] starting build.sh ..."
./build.sh

if [ ! -d output/image ] || [ -z "$(ls -A output/image)" ]; then
    echo "[arm64] ERROR: no images produced in output/image" >&2
    exit 1
fi
find /out -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -a output/image/. /out/
echo "[arm64] images copied to /out"
