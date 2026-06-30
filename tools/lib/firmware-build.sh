#!/usr/bin/env bash
# Shared driver for the per-arch firmware-build backends (build-firmware-amd64.sh
# and build-firmware-arm64.sh). Both build the same RV1106 ARMv7 firmware and copy
# the images to dist/firmware/host-<arch>/<board>/; they differ only by build environment
# (Docker image, toolchain, SDK volume). The backend sets a few config vars,
# optionally overrides preflight(), then calls: run_firmware_build "$@".
#
# Requires common.sh and build-info.sh sourced first, and SCRIPT_DIR / REPO_ROOT
# resolved by the backend.
#
# Config vars the backend must set before calling run_firmware_build:
#   ARCH             amd64 | arm64 -- selects the builder image, the SDK volume
#                    default, the docker run platform, the in-container script
#                    docker/<ARCH>/builder/firmware-build.sh, and the build_arch
#                    recorded in BUILD-INFO.txt.
#   VOLUME           SDK build volume name.
#   BUILD_DESC       one-line "what this builds" blurb shown in --help.
#   RESET_SDK_HELP   the --reset-sdk description shown in --help (differs per arch).
#   TOOLCHAIN_DESC   toolchain provenance string written to BUILD-INFO.txt.
# Optional:
#   preflight()      run after the preflight checks and before the build; arm64
#                    overrides it to build the cross-toolchain on first run.

# These config vars are set by the sourcing backend, not here.
# shellcheck disable=SC2154

DEFAULT_BOARD_CONFIG="BoardConfig-SPI_NAND-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk"
BOARD_CFG_SUBDIR="project/cfg/BoardConfig_IPC"

# No-op unless the backend overrides it.
preflight() { :; }

_firmware_usage() {
    cat <<EOF
Usage: tools/build-firmware-$ARCH.sh [BOARD_CONFIG] [--reset-sdk]

$BUILD_DESC

Arguments:
  BOARD_CONFIG   BoardConfig file under the SDK's $BOARD_CFG_SUBDIR/.
                 Default: $DEFAULT_BOARD_CONFIG

Options:
  --reset-sdk    $RESET_SDK_HELP
  -h, --help     Show this help.

Available Pro Max board configs:
$(list_boards "$REPO_ROOT/external/sdk" "$BOARD_CFG_SUBDIR")
EOF
}

run_firmware_build() {
    local sdk_dir="$REPO_ROOT/external/sdk"
    local target="builder-$ARCH"
    local image="luckfox-pico-$target"
    local reset_sdk=0 board_config=""

    while [ $# -gt 0 ]; do
        case "$1" in
        --reset-sdk) reset_sdk=1 ;;
        -h | --help)
            _firmware_usage
            exit 0
            ;;
        -*) die "Unknown option: $1 (try --help)" ;;
        *)
            [ -z "$board_config" ] || die "Unexpected extra argument: $1"
            board_config="$1"
            ;;
        esac
        shift
    done
    board_config="${board_config:-$DEFAULT_BOARD_CONFIG}"

    local tag
    tag="$(board_tag "$board_config")"
    local output_dir="$REPO_ROOT/dist/firmware/host-$ARCH/$tag"

    require_docker
    [ -e "$sdk_dir/build.sh" ] || die "SDK submodule missing. Run: git submodule update --init external/sdk"
    [ -f "$sdk_dir/$BOARD_CFG_SUBDIR/$board_config" ] || die "BoardConfig not found: $BOARD_CFG_SUBDIR/$board_config
Available Pro Max configs:
$(list_boards "$sdk_dir" "$BOARD_CFG_SUBDIR")"

    preflight

    export DOCKER_DEFAULT_PLATFORM="linux/$ARCH"
    bash "$SCRIPT_DIR/build-docker-image.sh" "$target"

    ensure_volume "$VOLUME" "SDK build volume"

    mkdir -p "$output_dir"
    local build_host
    build_host="$(build_hostname)"
    log "Building firmware for: $board_config"
    warn "First run is slow: full kernel and buildroot build."
    local build_start=$SECONDS

    docker run --rm \
        --hostname "$build_host" \
        -e BOARD_CONFIG="$board_config" \
        -e BOARD_CFG_SUBDIR="$BOARD_CFG_SUBDIR" \
        -e RESET_SDK="$reset_sdk" \
        -e HOST_UID="$(id -u)" \
        -e HOST_GID="$(id -g)" \
        -v "$REPO_ROOT:/repo:ro" \
        -v "$VOLUME:/sdk" \
        -v "$output_dir:/out" \
        "$image" bash "/repo/docker/$ARCH/builder/firmware-build.sh"

    write_build_info "$output_dir" "$ARCH" "$TOOLCHAIN_DESC" "$board_config"

    log "Firmware images written to: $output_dir"
    ls -lh "$output_dir"
    log_build_time "$build_start"
    log "Done."
}
