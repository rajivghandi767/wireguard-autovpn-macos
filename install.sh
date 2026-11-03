#!/usr/bin/env bash
# ==============================================================================
# wireguard-autovpn-macos Installer (Supports Apple Silicon & Intel Macs)
# ==============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Elevating privileges with sudo..."
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect Homebrew prefix (Apple Silicon /opt/homebrew vs Intel /usr/local)
if [[ -d "/opt/homebrew" ]]; then
    BREW_PREFIX="/opt/homebrew"
else
    BREW_PREFIX="/usr/local"
fi

echo "==> Detected Homebrew prefix: $BREW_PREFIX"

# Verify prerequisites
for tool in bash wg wg-quick wireguard-go; do
    if [[ ! -x "${BREW_PREFIX}/bin/${tool}" ]]; then
        echo "Error: Required binary '${BREW_PREFIX}/bin/${tool}' not found." >&2
        echo "Please run: brew install bash wireguard-tools" >&2
        exit 1
    fi
done

WG_DIR="${BREW_PREFIX}/etc/wireguard"
BIN_DEST="${BREW_PREFIX}/bin/wireguard-auto"
CONF_DEST="${WG_DIR}/autovpn.conf"
PLIST_DEST="/Library/LaunchDaemons/com.wireguard.autovpn.plist"

mkdir -p "${WG_DIR}"
mkdir -p "${BREW_PREFIX}/bin"

# 1. Install executable with root:wheel ownership
echo "==> Installing executable to ${BIN_DEST}..."
cp "${SCRIPT_DIR}/bin/wireguard-auto" "${BIN_DEST}"
chown root:wheel "${BIN_DEST}"
chmod 755 "${BIN_DEST}"

# 2. Install configuration file if not already present (idempotent)
if [[ ! -f "${CONF_DEST}" ]]; then
    echo "==> Creating default configuration at ${CONF_DEST}..."
    cp "${SCRIPT_DIR}/config/autovpn.conf.example" "${CONF_DEST}"
    chmod 644 "${CONF_DEST}"
else
    echo "==> Existing configuration found at ${CONF_DEST} (preserved)."
fi

# 3. Render and install LaunchDaemon plist
echo "==> Installing LaunchDaemon to ${PLIST_DEST}..."
sed "s|__BREW_PREFIX__|${BREW_PREFIX}|g" "${SCRIPT_DIR}/config/com.wireguard.autovpn.plist" > "${PLIST_DEST}"
chown root:wheel "${PLIST_DEST}"
chmod 644 "${PLIST_DEST}"

# Validate plist syntax
plutil -lint "${PLIST_DEST}"

# 4. Reload LaunchDaemon
echo "==> Loading com.wireguard.autovpn daemon..."
launchctl unload "${PLIST_DEST}" 2>/dev/null || true
launchctl load -w "${PLIST_DEST}"

echo ""
echo "==> Installation complete!"
echo "    Run 'wireguard-auto status' to verify."
