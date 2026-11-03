#!/usr/bin/env bash
# ==============================================================================
# wireguard-autovpn-macos Installer (Supports Apple Silicon M-Series & Intel Macs)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/bin/wireguard-auto" install-daemon "$@"
