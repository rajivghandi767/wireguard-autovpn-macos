#!/usr/bin/env bash
# ==============================================================================
# wireguard-autovpn-macos Uninstaller
# ==============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Elevating privileges with sudo..."
    exec sudo "$0" "$@"
fi

if [[ -x "/opt/homebrew/bin/wg-quick" || -x "/opt/homebrew/bin/brew" || -d "/opt/homebrew/bin" ]]; then
    BREW_PREFIX="/opt/homebrew"
else
    BREW_PREFIX="/usr/local"
fi

PLIST_DEST="/Library/LaunchDaemons/com.wireguard.autovpn.plist"
DAEMON_ROOT="/Library/Application Support/wireguard-auto"
CLI_SYMLINK="${BREW_PREFIX}/bin/wireguard-auto"

if [[ -f "${PLIST_DEST}" ]]; then
    echo "==> Unloading and removing ${PLIST_DEST}..."
    launchctl bootout system "${PLIST_DEST}" 2>/dev/null || launchctl unload -w "${PLIST_DEST}" 2>/dev/null || true
    rm -f "${PLIST_DEST}"
fi

if [[ -e "${CLI_SYMLINK}" || -L "${CLI_SYMLINK}" ]]; then
    echo "==> Removing CLI link ${CLI_SYMLINK}..."
    rm -f "${CLI_SYMLINK}"
fi

if [[ -d "${DAEMON_ROOT}" ]]; then
    echo "==> Removing daemon directory ${DAEMON_ROOT}..."
    rm -f "${DAEMON_ROOT}/bin/wireguard-auto"
    rmdir "${DAEMON_ROOT}/bin" "${DAEMON_ROOT}" 2>/dev/null || true
fi

rm -f /var/run/wireguard-auto.lock/pid /var/run/wireguard-auto.paused
rmdir /var/run/wireguard-auto.lock 2>/dev/null || true

echo "==> Uninstalled wireguard-auto daemon and CLI."
echo "    Note: Your WireGuard configs in ${BREW_PREFIX}/etc/wireguard/ were preserved."
