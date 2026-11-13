#!/usr/bin/env bash
# Installs the AIC8800D80 WiFi + Bluetooth setup described in README.md.
# Run as a normal user: privileged steps go through sudo.

set -euo pipefail

readonly ASANRIVAS_URL="https://github.com/asanrivas/aic8800-linux-driver.git"
readonly ASANRIVAS_COMMIT="4125bcc0d3fadc40ab3194c80389284dd54b872e"
readonly RADXA_URL="https://github.com/radxa-pkg/aic8800.git"
readonly RADXA_COMMIT="516e3b087763d80c44f5e3b6d2dd63e0d925c91d"
readonly DKMS_NAME="aic8800"
readonly DKMS_VERSION="1.2.1"
readonly DKMS_SRC="/usr/src/${DKMS_NAME}-${DKMS_VERSION}"
readonly FW_DIR="/lib/firmware/aic8800D80"
readonly MODPROBE_CONF="/etc/modprobe.d/aic8800-bt.conf"
readonly MODULES_CONF="/etc/modules-load.d/aic8800.conf"
readonly UDEV_RULE="/etc/udev/rules.d/aic.rules"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PATCHES="${SCRIPT_DIR}/patches"
readonly WORK="${AIC8800_WORK:-${HOME}/aic8800-build}"
readonly DRIVER_DIR="${WORK}/aic8800-linux-driver"
readonly RADXA_DIR="${WORK}/radxa-aic8800"
readonly RADXA_DRV="${RADXA_DIR}/src/USB/driver_fw"
KVER="$(uname -r)"
readonly KVER

DRY_RUN=0
ALLOW_UNSUPPORTED=0

usage() {
    cat <<EOF
Usage: ./install.sh [command] [options]

Commands:
  install      Full installation (default)
  rebuild-bt   Rebuild aic_btusb for the running kernel, after a kernel update
  verify       Check that the modules and interfaces are present
  uninstall    Remove everything this script installed

Options:
  --dry-run                  Print the commands without changing anything
  --allow-unsupported-kernel Continue on kernel 7.4+ (untested, the WiFi build may fail)
  -h, --help                 Show this help

Sources are kept in ${WORK} (override with AIC8800_WORK).
EOF
}

log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

run() {
    if ((DRY_RUN)); then
        printf '+ %s\n' "$*"
    else
        "$@"
    fi
}

# For cleanup commands that may legitimately fail, such as removing something
# that was never installed.
run_ignore_errors() {
    if ((DRY_RUN)); then
        printf '+ %s\n' "$*"
    else
        "$@" >/dev/null 2>&1 || true
    fi
}

write_root_file() {
    local path="$1" content="$2"
    if ((DRY_RUN)); then
        printf '+ write %s: %s\n' "$path" "${content//$'\n'/ }"
    else
        printf '%s\n' "$content" | sudo tee "$path" >/dev/null
    fi
}

check_not_root() {
    if ((EUID == 0)); then
        die "run this as a normal user, without sudo"
    fi
}

check_fedora() {
    command -v dnf >/dev/null || die "dnf not found: this script targets Fedora"
}

check_kernel() {
    local major minor
    IFS=. read -r major minor _ <<<"$KVER"
    if ((major > 7 || (major == 7 && minor >= 4))); then
        if ((ALLOW_UNSUPPORTED)); then
            warn "kernel $KVER is untested: the aic8800_fdrv build may fail"
        else
            die "kernel $KVER is untested: patches cover up to 7.3. Boot a 7.3 kernel or pass --allow-unsupported-kernel (see README.md)"
        fi
    fi
}

check_headers() {
    if [[ -e "/lib/modules/${KVER}/build" ]]; then
        return 0
    fi
    if ((DRY_RUN)); then
        warn "headers for $KVER are not installed yet"
    else
        die "headers for $KVER not found. Reboot into the newest kernel and run this again"
    fi
}

check_secure_boot() {
    if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
        warn "Secure Boot is enabled: unsigned modules may be rejected (see README.md)"
    fi
}

# Resets a clone owned by this script to its pinned commit. Refuses to touch a
# directory that is not a clone of the expected repository.
fetch_repo() {
    local url="$1" commit="$2" dir="$3" origin
    if [[ -e "$dir" ]]; then
        origin="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)"
        [[ "$origin" == "$url" ]] || die "$dir exists but is not a clone of $url"
        run git -C "$dir" fetch --quiet origin
    else
        run git clone --quiet "$url" "$dir"
    fi
    run git -C "$dir" reset --quiet --hard
    run git -C "$dir" clean --quiet -fdx
    run git -C "$dir" checkout --quiet "$commit"
}

install_dependencies() {
    log "Installing build dependencies"
    run sudo dnf install -y dkms kernel-devel kernel-headers gcc make git python3 sg3_utils usbutils
}

fetch_sources() {
    log "Fetching sources into $WORK"
    run mkdir -p "$WORK"
    fetch_repo "$ASANRIVAS_URL" "$ASANRIVAS_COMMIT" "$DRIVER_DIR"
    fetch_repo "$RADXA_URL" "$RADXA_COMMIT" "$RADXA_DIR"
}

assemble_tree() {
    log "Applying patches and replacing aic_load_fw"
    run git -C "$DRIVER_DIR" apply "${PATCHES}/0001-kernel-7.2-compat.patch"
    run git -C "$DRIVER_DIR" apply "${PATCHES}/0003-kernel-7.3-compat.patch"
    run rm -rf "${DRIVER_DIR}/drivers/aic8800/aic_load_fw"
    run cp -r "${RADXA_DRV}/drivers/aic8800/aic_load_fw" "${DRIVER_DIR}/drivers/aic8800/aic_load_fw"
    run chmod +x "${DRIVER_DIR}/scripts/dkms-pre-build.sh"
}

install_wifi() {
    log "Building WiFi modules with DKMS"
    run_ignore_errors sudo dkms remove "${DKMS_NAME}/${DKMS_VERSION}" --all
    run sudo rm -rf "$DKMS_SRC"
    run sudo cp -r "$DRIVER_DIR" "$DKMS_SRC"
    run sudo dkms add -m "$DKMS_NAME" -v "$DKMS_VERSION"
    run sudo dkms build -m "$DKMS_NAME" -v "$DKMS_VERSION"
    run sudo dkms install -m "$DKMS_NAME" -v "$DKMS_VERSION" --force
}

install_firmware() {
    log "Installing firmware"
    run sudo mkdir -p "$FW_DIR"
    run sudo cp -r "${RADXA_DRV}/fw/aic8800D80/." "${FW_DIR}/"
}

install_bluetooth() {
    log "Building and installing aic_btusb for $KVER"
    # bluez mode (hci device) instead of the android char device; same as radxa's debian patch
    run sed -i 's/^\(#define CONFIG_BLUEDROID[[:space:]]\+\)1/\10/' "${RADXA_DRV}/drivers/aic_btusb/aic_btusb.h"
    run make -C "${RADXA_DRV}/drivers/aic_btusb" clean
    run make -C "${RADXA_DRV}/drivers/aic_btusb"
    run sudo install -p -m 644 "${RADXA_DRV}/drivers/aic_btusb/aic_btusb.ko" \
        "/lib/modules/${KVER}/kernel/drivers/bluetooth/"
    run sudo depmod -a "$KVER"
}

install_system_config() {
    log "Writing modprobe, module load and udev configuration"
    write_root_file "$MODPROBE_CONF" "install btusb /bin/false"
    write_root_file "$MODULES_CONF" $'aic_load_fw\naic8800_fdrv'
    run sudo cp "${DRIVER_DIR}/tools/aic.rules" "$UDEV_RULE"
    run sudo udevadm control --reload
    run sudo udevadm trigger
}

cmd_install() {
    check_not_root
    check_fedora
    check_kernel
    check_secure_boot
    if ((!DRY_RUN)); then
        sudo -v
    fi
    install_dependencies
    check_headers
    fetch_sources
    assemble_tree
    install_wifi
    install_firmware
    install_bluetooth
    install_system_config
    log "Done"
    if ((!DRY_RUN)); then
        echo "Reboot with the adapter plugged in, then run: ./install.sh verify"
    fi
}

cmd_rebuild_bt() {
    check_not_root
    check_headers
    if [[ ! -d "$RADXA_DRV" ]] && ((!DRY_RUN)); then
        run mkdir -p "$WORK"
        fetch_repo "$RADXA_URL" "$RADXA_COMMIT" "$RADXA_DIR"
    fi
    install_bluetooth
    run sudo modprobe aic_btusb
}

cmd_verify() {
    local failed=0

    check() {
        local label="$1"
        shift
        if "$@" >/dev/null 2>&1; then
            printf 'ok    %s\n' "$label"
        else
            printf 'FAIL  %s\n' "$label"
            failed=1
        fi
    }
    dkms_installed() { dkms status "${DKMS_NAME}/${DKMS_VERSION}" -k "$KVER" | grep -q installed; }
    module_loaded() { [[ -d "/sys/module/$1" ]]; }
    module_absent() { [[ ! -d "/sys/module/$1" ]]; }
    wifi_present() { nmcli -t -f TYPE device | grep -qx wifi; }
    controller_present() { bluetoothctl show | grep -q 'Controller'; }

    check "dkms: ${DKMS_NAME}/${DKMS_VERSION} installed for ${KVER}" dkms_installed
    check "module loaded: aic_load_fw" module_loaded aic_load_fw
    check "module loaded: aic8800_fdrv" module_loaded aic8800_fdrv
    check "module loaded: aic_btusb" module_loaded aic_btusb
    check "module not loaded: btusb" module_absent btusb
    check "network: WiFi interface present" wifi_present
    check "bluetooth: controller present" controller_present

    if ((failed)); then
        echo
        echo "Some checks failed. Kernel log: sudo dmesg | grep -iE 'aic|firmware' | tail -40"
        return 1
    fi
    echo
    echo "All checks passed. Now use WiFi and Bluetooth at the same time to confirm they coexist."
}

cmd_uninstall() {
    check_not_root
    log "Removing the driver and its configuration"
    run_ignore_errors sudo dkms remove "${DKMS_NAME}/${DKMS_VERSION}" --all
    run sudo rm -rf "$DKMS_SRC" "$FW_DIR"
    run sudo rm -f "$MODPROBE_CONF" "$MODULES_CONF" "$UDEV_RULE"
    local module
    for module in /lib/modules/*/kernel/drivers/bluetooth/aic_btusb.ko; do
        if [[ -e "$module" ]]; then
            run sudo rm -f "$module"
        fi
    done
    run sudo depmod -a
    run sudo udevadm control --reload
    log "Done. Reboot to unload the modules. Sources remain in $WORK"
}

COMMAND="install"
while (($#)); do
    case "$1" in
    install | rebuild-bt | verify | uninstall) COMMAND="$1" ;;
    --dry-run) DRY_RUN=1 ;;
    --allow-unsupported-kernel) ALLOW_UNSUPPORTED=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        die "unknown argument: $1"
        ;;
    esac
    shift
done

case "$COMMAND" in
install) cmd_install ;;
rebuild-bt) cmd_rebuild_bt ;;
verify) cmd_verify ;;
uninstall) cmd_uninstall ;;
esac
