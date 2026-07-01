#!/usr/bin/env bash
# Shared helper sourced by the build-firmware-* backends.
# Relies on common.sh being sourced first (uses its build_hostname).
#
# Writes BUILD-INFO.txt into the firmware output dir to record full build
# provenance: which build host arch produced it, which toolchain, from which SDK
# commit and when. The output path separates builds by host (host-<arch>/) so both
# can coexist; the target firmware is always RV1106 ARMv7 regardless of build host.
#
# Usage: write_build_info <out_dir> <build_arch> <toolchain_desc> <board_config>

write_build_info() {
    local out="$1" build_arch="$2" toolchain="$3" board="$4"
    local sdk_dir sdk_commit build_host
    sdk_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/external/sdk"
    sdk_commit="$(git -C "$sdk_dir" rev-parse HEAD 2>/dev/null || echo unknown)"
    build_host="$(build_hostname)" # from common.sh; same value --hostname stamps into the kernel
    cat >"$out/BUILD-INFO.txt" <<EOF
build_host:    $build_host
build_arch:    $build_arch
host_machine:  $(uname -m)
host_os:       $(uname -s) $(uname -r)
toolchain:     $toolchain
board_config:  $board
sdk_commit:    $sdk_commit
built_at:      $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}
