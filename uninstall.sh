#!/usr/bin/env bash
# ==============================================================================
# wireguard-autovpn-macos Uninstaller
# ==============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Elevating privileges with sudo..."
    exec sudo "$0" "$@"
fi

if [[ -d "/opt/homebrew" ]]; then
    BREW_PREFIX="/opt/homebrew"
else
    BREW_PREFIX="/usr/local"
fi

PLIST_DEST="/Library/LaunchDaemons/com.wireguard.autovpn.plist"
BIN_DEST="${BREW_PREFIX}/bin/wireguard-auto"

if [[ -f "${PLIST_DEST}" ]]; then
    echo "==> Unloading and removing ${PLIST_DEST}..."
    launchctl unload -w "${PLIST_DEST}" 2>/dev/null || true
    rm -f "${PLIST_DEST}"
fi

if [[ -f "${BIN_DEST}" ]]; then
    echo "==> Removing ${BIN_DEST}..."
    rm -f "${BIN_DEST}"
fi

rm -rf /tmp/wireguard-auto.lock /tmp/wireguard-auto.disabled

echo "==> Uninstalled wireguard-auto daemon and CLI."
echo "    Note: Your WireGuard configs in ${BREW_PREFIX}/etc/wireguard/ were preserved."
