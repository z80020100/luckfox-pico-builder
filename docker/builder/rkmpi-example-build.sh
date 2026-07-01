#!/usr/bin/env bash
# Cross-compile one or more luckfox_pico_rkmpi_example demos for the RV1106, inside
# the builder container. Runs on either builder arch and picks the host-matching
# cross-toolchain by container arch:
#   aarch64 container -> the rebuilt aarch64 toolchain tarball, staged under a stub
#   x86_64  container -> the x86-64 toolchain bundled in the SDK (read-only mount)
# The examples resolve their compiler from LUCKFOX_SDK_PATH/tools/linux/toolchain/
# <tuple> (CMakeLists.txt); every link library and model a demo needs is bundled in
# the example itself.
set -euo pipefail

TUPLE=arm-rockchip830-linux-uclibcgnueabihf
DEMOS="${DEMOS:?DEMOS not set}"
LIBC="${LIBC:-uclibc}"

# Supply the host-matching cross-toolchain and point LUCKFOX_SDK_PATH at it.
case "$(uname -m)" in
aarch64)
    tarball="/repo/dist/toolchain/arm64/$TUPLE.tar.gz"
    [ -f "$tarball" ] || {
        echo "[rkmpi] ERROR: missing $tarball (run tools/build-toolchain-arm64.sh first)" >&2
        exit 1
    }
    sdk_stub=/tmp/sdk
    rm -rf "$sdk_stub"
    mkdir -p "$sdk_stub/tools/linux/toolchain"
    tar -xzf "$tarball" -C "$sdk_stub/tools/linux/toolchain/"
    export LUCKFOX_SDK_PATH="$sdk_stub"
    expected_host=aarch64
    ;;
x86_64)
    # The SDK's own x86-64 toolchain is already host-native; use it in place.
    export LUCKFOX_SDK_PATH=/repo/external/sdk
    expected_host=x86-64
    ;;
*)
    echo "[rkmpi] ERROR: unsupported container arch: $(uname -m)" >&2
    exit 1
    ;;
esac

gcc="$LUCKFOX_SDK_PATH/tools/linux/toolchain/$TUPLE/bin/$TUPLE-gcc"
[ -x "$gcc" ] || {
    echo "[rkmpi] ERROR: cross-compiler not found at $gcc" >&2
    exit 1
}
file -b "$gcc" | grep -q "$expected_host" || {
    echo "[rkmpi] ERROR: cross-compiler is not $expected_host-hosted" >&2
    exit 1
}

# Copy the examples to a writable dir: the submodule mount is read-only and CMake
# writes build/ and install/ inside the source tree.
work=/tmp/rkmpi
rm -rf "$work"
cp -a /repo/external/rkmpi "$work"
cd "$work"

echo "[rkmpi] cmake $(cmake --version | head -1)"
for demo in $DEMOS; do
    echo "[rkmpi] building $demo ($LIBC) ..."
    rm -rf build && mkdir build
    (cd build && cmake .. -DEXAMPLE_DIR="example/$demo" -DEXAMPLE_NAME="$demo" -DLIBC_TYPE="$LIBC" && make install "-j$(nproc)")

    demo_out="$work/install/$LIBC/${demo}_demo"
    [ -d "$demo_out" ] || {
        echo "[rkmpi] ERROR: build produced no $demo_out" >&2
        exit 1
    }

    # Refresh only this demo's output dir; leave other demos' prior output intact.
    dst="/out/${demo}_demo"
    rm -rf "$dst"
    mkdir -p "$dst"
    cp -a "$demo_out/." "$dst/"
    echo "[rkmpi] $demo copied to $dst"
done
# Native Linux docker runs the container as root, so the copied files land
# root-owned; hand the bind-mounted /out back to the invoking host user.
chown -R "${HOST_UID:?}:${HOST_GID:?}" /out
