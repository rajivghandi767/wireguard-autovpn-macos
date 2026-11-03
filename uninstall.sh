#!/usr/bin/env bash
# ==============================================================================
# wireguard-autovpn-macos Uninstaller
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/bin/wireguard-auto" uninstall-daemon "$@"
