#!/usr/bin/env bash
# One-command firmware flashing for the Luckfox Pico Pro Max (RV1106, SPI NAND).
#
# Flashes the built firmware to a USB-attached board with the rkdeveloptool
# submodule, building the tool natively on first use. Flashing is host-native by
# design: Docker cannot pass the board's USB through on macOS, and flashing is a
# local action against a physically attached board -- the arm64-cloud reasons that
# drive the Docker build do not apply here.
#
# RV1106 is SPI NAND with no GPT, so the eMMC-style update.img / parameter.txt /
# gpt+wlx flow does NOT apply (that is what the submodule's flash.sh does, and it
# is scoped to RK356x). Instead each partition image is written directly to its raw
# sector offset via `wl <sector> <img>`, after loading the USB loader (download.bin)
# into RAM with `db`. Offsets come from the SDK's mtdparts in the build's .env.txt.
# A board in ADB mode is rebooted into MaskROM first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RKDEV_DIR="$REPO_ROOT/external/rkdeveloptool"
DEFAULT_BOARD_CONFIG="BoardConfig-SPI_NAND-Buildroot-RV1106_Luckfox_Pico_Pro_Max-IPC.mk"

LOG_PREFIX="flash-firmware"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Object-file format this host can execute, used to spot a binary built for another
# platform (e.g. a Mach-O binary carried onto a Linux host) and rebuild it.
host_objfmt() {
    case "$(uname -s)" in
    Darwin) echo "Mach-O" ;;
    Linux) echo "ELF" ;;
    *) echo "" ;;
    esac
}

# Convert an mtdparts size/offset token (e.g. 256K, 4M, 210M, or a raw number) to bytes.
size_to_bytes() {
    local v="$1" num suf
    num="${v%[KkMmGg]}"
    suf="${v##*[0-9]}"
    case "$suf" in
    K | k) echo "$((num * 1024))" ;;
    M | m) echo "$((num * 1024 * 1024))" ;;
    G | g) echo "$((num * 1024 * 1024 * 1024))" ;;
    "") echo "$num" ;;
    *) die "cannot parse size/offset token: $v" ;;
    esac
}

# Parse the `mtdparts=...` line in .env.txt into "<name> 0x<sector>" lines.
# mtdparts entries are `<size>[@<offset>](<name>)`; an omitted @offset means the
# partition starts where the previous one ended. Sector = byte offset / 512.
compute_parts() {
    local env_txt="$1" line list tok cursor=0 name so size off_b sz_b sec
    line="$(grep -m1 '^mtdparts=' "$env_txt")" || return 1
    list="${line#*:}" # strip "mtdparts=<device>:"
    printf '%s\n' "$list" | tr ',' '\n' | while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        name="${tok#*(}"
        name="${name%%)*}"
        so="${tok%%(*}"
        if [ "${so#*@}" != "$so" ]; then
            size="${so%%@*}"
            off_b="$(size_to_bytes "${so#*@}")"
        else
            size="$so"
            off_b="$cursor"
        fi
        sz_b="$(size_to_bytes "$size")"
        sec=$((off_b / 512))
        printf '%s 0x%x\n' "$name" "$sec"
        cursor=$((off_b + sz_b))
    done
}

# Run the submodule's rkdeveloptool from its own dir (so it finds config.ini).
run_rkdev() {
    (cd "$RKDEV_DIR" && ./rkdeveloptool "$@")
}

rkdev_device_present() {
    run_rkdev ld 2>/dev/null | grep -qiE 'maskrom|loader'
}

# Make sure a MaskROM/Loader device is visible, rebooting an ADB-mode board if needed.
ensure_device() {
    rkdev_device_present && return 0
    if command -v adb >/dev/null 2>&1 && adb devices | sed '1d' | grep -q 'device$'; then
        log "Board in ADB mode; rebooting into loader/MaskROM ..."
        adb reboot loader || true
        local i=0
        while [ "$i" -lt 30 ]; do
            sleep 1
            rkdev_device_present && return 0
            i=$((i + 1))
        done
    fi
    die "No MaskROM/Loader device found (and no ADB device to reboot).
Put the board in MaskROM (hold BOOT while connecting USB) and retry."
}

usage() {
    cat <<EOF
Usage: tools/flash-firmware.sh [--arch auto|amd64|arm64] [--detect] [BOARD_CONFIG] [-y]

Flashes the built firmware to a USB-attached Luckfox Pico Pro Max (RV1106, SPI NAND)
using the native rkdeveloptool (external/rkdeveloptool), building the tool on first
use. The board may be in ADB, Loader or MaskROM mode -- an ADB-mode board is rebooted
into MaskROM first.

RV1106 has no GPT: the USB loader (download.bin) is loaded with 'db', then each
partition image is written to its raw sector offset with 'wl'. Offsets are derived
from the SDK mtdparts recorded in the firmware's .env.txt.

Flashing is host-native by design: Docker cannot pass the board's USB through on
macOS, and flashing is a local action against a physically attached board.

Arguments:
  BOARD_CONFIG   selects the firmware dir dist/firmware/host-<arch>/<board>/.
                 Default: $DEFAULT_BOARD_CONFIG

Options:
  --arch <a>     auto (default) flashes the image built on the host arch, falling
                 back to the other arch if only it is present (the target firmware
                 is identical either way).
  --detect       show the firmware dir, the derived partition map and the attached
                 device(s), then exit -- no reboot, no writes.
  -y, --yes      skip the confirmation prompt (flashing erases the board).
  -h, --help     show this help.

First run only -- rkdeveloptool build prerequisites:
  macOS:  brew install autoconf automake pkg-config libusb openssl
  Debian: sudo apt-get install libudev-dev libusb-1.0-0-dev dh-autoreconf
EOF
}

ARCH=auto
BOARD_CONFIG=""
ASSUME_YES=0
DETECT=0
while [ $# -gt 0 ]; do
    case "$1" in
    --arch)
        shift
        [ $# -gt 0 ] || die "--arch requires a value (auto|amd64|arm64)"
        ARCH="$1"
        ;;
    --arch=*) ARCH="${1#*=}" ;;
    --detect) DETECT=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*) die "Unknown option: $1 (try --help)" ;;
    *)
        [ -z "$BOARD_CONFIG" ] || die "Unexpected extra argument: $1"
        BOARD_CONFIG="$1"
        ;;
    esac
    shift
done
BOARD_CONFIG="${BOARD_CONFIG:-$DEFAULT_BOARD_CONFIG}"

case "$ARCH" in
auto) ARCH="$(host_arch)" ;;
amd64 | arm64) ;;
*) die "invalid --arch: '$ARCH' (use auto, amd64 or arm64)" ;;
esac

BOARD_TAG="$(board_tag "$BOARD_CONFIG")"

# Resolve the firmware partition dir, preferring the requested arch then falling back
# to the other (same target firmware, just a different build host). A valid dir holds
# the USB loader download.bin.
resolve_dir() {
    local a dir
    for a in "$ARCH" amd64 arm64; do
        dir="$REPO_ROOT/dist/firmware/host-$a/$BOARD_TAG"
        [ -f "$dir/download.bin" ] && {
            echo "$dir"
            return 0
        }
    done
    return 1
}

IMG_DIR="$(resolve_dir)" || die "No firmware found for board '$BOARD_TAG'.
Build it first: tools/build-firmware.sh $BOARD_CONFIG
Looked for: dist/firmware/host-*/$BOARD_TAG/download.bin"

DOWNLOAD_BIN="$IMG_DIR/download.bin"
ENV_TXT="$IMG_DIR/.env.txt"
[ -f "$ENV_TXT" ] || die ".env.txt (partition layout) not found in $IMG_DIR"

[ -f "$RKDEV_DIR/build.sh" ] || die "rkdeveloptool submodule not checked out.
Run: git submodule update --init external/rkdeveloptool"

# Build rkdeveloptool natively on first use, or when the present binary was built for
# another platform.
RKDEV_BIN="$RKDEV_DIR/rkdeveloptool"
if [ -x "$RKDEV_BIN" ] && file -b "$RKDEV_BIN" 2>/dev/null | grep -q "$(host_objfmt)"; then
    log "Using rkdeveloptool: $RKDEV_BIN"
else
    log "Building rkdeveloptool natively (first run; needs libusb/openssl/autotools) ..."
    (cd "$RKDEV_DIR" && ./build.sh) || die "rkdeveloptool build failed (see prerequisites in --help)."
    [ -x "$RKDEV_BIN" ] || die "build finished but $RKDEV_BIN is missing."
fi

PARTS=()
while IFS= read -r _p; do
    [ -n "$_p" ] && PARTS+=("$_p")
done < <(compute_parts "$ENV_TXT")
[ "${#PARTS[@]}" -gt 0 ] || die "could not parse any partitions from $ENV_TXT"

log "Firmware dir: $IMG_DIR"
log "Partition map (sector <- image, derived from .env.txt):"
for _p in "${PARTS[@]}"; do
    log "  ${_p##* } <- ${_p%% *}.img"
done

if [ "$DETECT" -eq 1 ]; then
    log "Detect only -- no reboot, no flashing."
    if command -v adb >/dev/null 2>&1; then
        log "ADB-mode devices (rebooted to MaskROM at flash time):"
        adb devices | sed '1d;/^[[:space:]]*$/d' || true
    fi
    log "MaskROM/Loader devices seen by rkdeveloptool:"
    run_rkdev ld || true
    exit 0
fi

warn "Flashing ERASES and rewrites the board's SPI NAND -- make sure the right board is attached."
if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die "Not a TTY; re-run with -y to confirm flashing."
    printf 'Proceed with flashing? [y/N] '
    read -r reply
    case "$reply" in
    y | Y | yes | YES) ;;
    *) die "Aborted." ;;
    esac
fi

ensure_device
log "Downloading USB loader (download.bin) into RAM ..."
run_rkdev db "$DOWNLOAD_BIN"
sleep 2

for _p in "${PARTS[@]}"; do
    name="${_p%% *}"
    sec="${_p##* }"
    img="$IMG_DIR/$name.img"
    if [ ! -f "$img" ]; then
        warn "skip $name (no $name.img in firmware dir)"
        continue
    fi
    log "wl $sec <- $name.img"
    run_rkdev wl "$sec" "$img"
done

log "Resetting board ..."
run_rkdev rd || true
log "Done. Verify the board boots the new firmware."
