#!/usr/bin/env bash
# ==============================================================================
# wireguard-autovpn-macos Installer (Supports Apple Silicon M-Series & Intel Macs)
# ==============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Elevating privileges with sudo..."
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect Homebrew prefix (Apple Silicon /opt/homebrew vs Intel /usr/local)
if [[ -x "/opt/homebrew/bin/wg-quick" || -x "/opt/homebrew/bin/brew" || -d "/opt/homebrew/bin" ]]; then
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
DAEMON_DIR="/Library/Application Support/wireguard-auto/bin"
DAEMON_BIN="${DAEMON_DIR}/wireguard-auto"
CLI_SYMLINK="${BREW_PREFIX}/bin/wireguard-auto"
CONF_DEST="${WG_DIR}/autovpn.conf"
PLIST_DEST="/Library/LaunchDaemons/com.wireguard.autovpn.plist"

mkdir -p "${WG_DIR}"
mkdir -p "${BREW_PREFIX}/bin"
mkdir -p "${DAEMON_DIR}"

# Harden directory ownership so unprivileged users cannot replace root-executed files
chown root:wheel "/Library/Application Support/wireguard-auto" "${DAEMON_DIR}"
chmod 755 "/Library/Application Support/wireguard-auto" "${DAEMON_DIR}"
chown root:wheel "${WG_DIR}"
chmod 755 "${WG_DIR}"

# Ensure any existing WireGuard tunnel configs (*.conf except autovpn.conf) remain 0600 root:wheel
for wg_conf in "${WG_DIR}"/*.conf; do
    [[ -e "$wg_conf" ]] || continue
    if [[ "$(basename "$wg_conf")" != "autovpn.conf" ]]; then
        chown root:wheel "$wg_conf"
        chmod 600 "$wg_conf"
    fi
done

# 1. Install daemon executable into root-protected /Library/Application Support/wireguard-auto/bin
echo "==> Installing root daemon executable to ${DAEMON_BIN}..."
cp "${SCRIPT_DIR}/bin/wireguard-auto" "${DAEMON_BIN}"
chown root:wheel "${DAEMON_BIN}"
chmod 755 "${DAEMON_BIN}"

# Create CLI symlink in Homebrew bin for convenient terminal usage
echo "==> Linking CLI binary at ${CLI_SYMLINK}..."
ln -sf "${DAEMON_BIN}" "${CLI_SYMLINK}"

# 2. Install configuration file if not already present (idempotent) and enforce root ownership
if [[ ! -f "${CONF_DEST}" ]]; then
    echo "==> Creating default configuration at ${CONF_DEST}..."
    cp "${SCRIPT_DIR}/config/autovpn.conf.example" "${CONF_DEST}"
else
    echo "==> Existing configuration found at ${CONF_DEST} (preserved)."
fi
chown root:wheel "${CONF_DEST}"
chmod 644 "${CONF_DEST}"

# 3. Install and validate LaunchDaemon plist
echo "==> Installing LaunchDaemon to ${PLIST_DEST}..."
cp "${SCRIPT_DIR}/config/com.wireguard.autovpn.plist" "${PLIST_DEST}"
chown root:wheel "${PLIST_DEST}"
chmod 644 "${PLIST_DEST}"

plutil -lint "${PLIST_DEST}"

# 4. Reload LaunchDaemon (modern bootstrap with legacy load fallback)
echo "==> Loading com.wireguard.autovpn daemon..."
launchctl bootout system "${PLIST_DEST}" 2>/dev/null || launchctl unload "${PLIST_DEST}" 2>/dev/null || true
if ! launchctl bootstrap system "${PLIST_DEST}" 2>/dev/null; then
    launchctl load -w "${PLIST_DEST}"
fi

echo ""
echo "==> Installation complete!"
echo "    Config file : ${CONF_DEST}"
echo "    Run 'wireguard-auto status' to verify your current network and gateway MAC."
