#!/usr/bin/env bash
# ==============================================================================
# wireguard-autovpn-macos Automated Security & Unit Test Suite
# ==============================================================================

set -euo pipefail

# Prefer Homebrew Bash 4+ if installed, while supporting macOS /bin/bash 3.2+
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$candidate" ]]; then
            exec "$candidate" "$0" "$@"
        fi
    done
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_PATH="${REPO_ROOT}/bin/wireguard-auto"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/wg-autovpn-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf '  [PASS] %s\n' "$1"
}

fail() {
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf '  [FAIL] %s\n' "$1" >&2
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local msg="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$msg"
    else
        fail "$msg (expected '$expected', got '$actual')"
    fi
}

echo "============================================================"
echo " Running wireguard-autovpn-macos Security & Unit Test Suite "
echo "============================================================"

# ------------------------------------------------------------------------------
# 1. Syntax & Manifest Validation
# ------------------------------------------------------------------------------
echo ""
echo "--> 1. Syntax & LaunchDaemon Plist Validation"

for script in "bin/wireguard-auto" "install.sh" "uninstall.sh" "config/autovpn.conf.example"; do
    if bash -n "${REPO_ROOT}/${script}"; then
        pass "bash -n syntax valid: ${script}"
    else
        fail "bash -n syntax failed: ${script}"
    fi
done

if plutil -lint "${REPO_ROOT}/config/com.wireguard.autovpn.plist" >/dev/null; then
    pass "plutil -lint valid: config/com.wireguard.autovpn.plist"
else
    fail "plutil -lint failed: config/com.wireguard.autovpn.plist"
fi

# ------------------------------------------------------------------------------
# 2. Load Library Functions in Sandbox Mode
# ------------------------------------------------------------------------------
export BREW_PREFIX="$SANDBOX/brew"
export WG_DIR="$SANDBOX/etc/wireguard"
export CONFIG_FILE="$WG_DIR/autovpn.conf"
export RUN_DIR="$SANDBOX/run"
export LOG_FILE="$SANDBOX/wireguard-auto.log"
export LOCK_DIR="$RUN_DIR/wireguard-auto.lock"
export TEMP_DISABLE_FLAG="$RUN_DIR/wireguard-auto.paused"
export PERSIST_DISABLE_FLAG="$WG_DIR/.disabled"
export SKIP_ROOT_OWNERSHIP_CHECK=1
export SKIP_CHECK_SLEEP=1

mkdir -p "$WG_DIR" "$RUN_DIR" "$BREW_PREFIX/bin"

# shellcheck disable=SC1090
WIREGUARD_AUTO_SOURCE_ONLY=1 source "$BIN_PATH"

# ------------------------------------------------------------------------------
# 3. Security Audit Tests (Injection, Traversal, Symlink, OPSEC)
# ------------------------------------------------------------------------------
echo ""
echo "--> 2. Security & Vulnerability Regression Tests"

# 3a. Command injection in autovpn.conf must NOT execute
PWN_FILE="$SANDBOX/pwned"
# shellcheck disable=SC2016
{
    printf 'WG_INTERFACE="homevpn"\n'
    printf '$(touch "%s")\n' "$PWN_FILE"
    printf 'TRUSTED_SSIDS=(\n'
    printf '    "$(touch "%s")"\n' "$PWN_FILE"
    printf '    "`touch "%s"`"\n' "$PWN_FILE"
    printf ')\n'
} > "$CONFIG_FILE"
parse_config "$CONFIG_FILE"
if [[ ! -e "$PWN_FILE" ]]; then
    pass "Config parser blocks arbitrary command execution (no source/eval)"
else
    fail "Config parser executed command substitution inside autovpn.conf!"
fi

# 3b. Path traversal in WG_INTERFACE must be rejected
cat > "$CONFIG_FILE" <<'EOF'
WG_INTERFACE="../../etc/passwd"
EOF
if ! parse_config "$CONFIG_FILE" 2>/dev/null; then
    pass "Config parser rejects path traversal in WG_INTERFACE (../../etc/passwd)"
else
    fail "Config parser accepted path traversal in WG_INTERFACE"
fi

# 3c. Symlinked CONFIG_FILE must be rejected
ln -sf "$CONFIG_FILE" "$SANDBOX/symlink.conf"
if ! verify_config_security "$SANDBOX/symlink.conf" 2>/dev/null; then
    pass "verify_config_security rejects symlinked configuration file"
else
    fail "verify_config_security accepted symlinked configuration file"
fi

# 3d. LaunchDaemon ProgramArguments must not point to user-writable Homebrew bin
if grep -q "/Library/Application Support/wireguard-auto/bin/wireguard-auto" "${REPO_ROOT}/config/com.wireguard.autovpn.plist"; then
    pass "LaunchDaemon executes binary from root-owned /Library/Application Support"
else
    fail "LaunchDaemon does not use root-owned binary path"
fi

# ------------------------------------------------------------------------------
# 4. M-Series & macOS Sonoma/Sequoia/Tahoe Compatibility Tests
# ------------------------------------------------------------------------------
echo ""
echo "--> 3. Apple Silicon (M-Series) & Modern macOS Compatibility Tests"

# 4a. BSD arp zero-stripped MAC normalization
assert_eq "$(normalize_mac "0:1a:2b:3:4:f")" "00:1a:2b:03:04:0f" "normalize_mac pads BSD arp single-digit hex octets"
assert_eq "$(normalize_mac "AA:BB:CC:0D:0E:FF")" "aa:bb:cc:0d:0e:ff" "normalize_mac converts uppercase MACs to canonical lowercase"
assert_eq "$(normalize_mac "00-11-22-33-44-55")" "00:11:22:33:44:55" "normalize_mac supports dash-delimited MACs"

if ! normalize_mac "not-a-mac" 2>/dev/null; then
    pass "normalize_mac rejects malformed MAC strings"
else
    fail "normalize_mac accepted malformed MAC string"
fi

# 4b. Trusted SSID & Gateway ARP MAC Fallback (when SSID is redacted by macOS)
cat > "$CONFIG_FILE" <<'EOF'
WG_INTERFACE="unifi_vpn"
TRUSTED_SSIDS=(
    "Home-WiFi-5G"
    "My Lab Network"
)
TRUSTED_GATEWAY_MACS=(
    "00:1a:2b:03:04:0f"
)
EOF
parse_config "$CONFIG_FILE"

assert_eq "$WG_INTERFACE" "unifi_vpn" "parse_config reads WG_INTERFACE"
assert_eq "${#TRUSTED_SSIDS[@]}" "2" "parse_config reads 2 TRUSTED_SSIDS entries"
assert_eq "${TRUSTED_SSIDS[1]}" "My Lab Network" "parse_config preserves spaces inside quoted SSID"
assert_eq "${TRUSTED_GATEWAY_MACS[0]}" "00:1a:2b:03:04:0f" "parse_config reads TRUSTED_GATEWAY_MACS"

# Mock get_gateway_mac returning BSD zero-stripped MAC normalized
# shellcheck disable=SC2329
get_gateway_mac() {
    normalize_mac "0:1a:2b:3:4:f"
}

if is_trusted_network "Home-WiFi-5G"; then
    pass "is_trusted_network matches configured home SSID"
else
    fail "is_trusted_network failed to match configured home SSID"
fi

if is_trusted_network ""; then
    pass "is_trusted_network falls back to Gateway MAC when macOS redacts SSID (<redacted>)"
else
    fail "is_trusted_network failed Gateway MAC fallback when SSID is empty/redacted"
fi

# shellcheck disable=SC2329
get_gateway_mac() {
    normalize_mac "de:ad:be:ef:00:01"
}

if ! is_trusted_network "CoffeeShop-Free-WiFi"; then
    pass "is_trusted_network rejects untrusted SSID and untrusted Gateway MAC"
else
    fail "is_trusted_network trusted an untrusted network"
fi

# 4c. Endpoint host extraction (IPv4, Hostname, IPv6)
cat > "${WG_DIR}/unifi_vpn.conf" <<'EOF'
[Interface]
Address = 10.100.0.2/32

[Peer]
Endpoint = 198.51.100.42:51820
EOF
assert_eq "$(get_endpoint_host)" "198.51.100.42" "get_endpoint_host extracts IPv4 endpoint"

cat > "${WG_DIR}/unifi_vpn.conf" <<'EOF'
[Peer]
Endpoint = [2001:db8::1]:51820
EOF
assert_eq "$(get_endpoint_host)" "2001:db8::1" "get_endpoint_host extracts IPv6 endpoint"

# ------------------------------------------------------------------------------
# 5. Lock Concurrency & CLI Subcommands
# ------------------------------------------------------------------------------
echo ""
echo "--> 4. Concurrency Locking & CLI Subcommands"

if acquire_lock; then
    pass "acquire_lock creates atomic lock directory"
else
    fail "acquire_lock failed on clean directory"
fi

release_lock
if [[ ! -d "$LOCK_DIR" ]]; then
    pass "release_lock cleanly removes lock directory"
else
    fail "release_lock left lock directory behind"
fi

# CLI version / pause / status / disable verification
assert_eq "$("$BIN_PATH" --version)" "wireguard-auto v1.0.0" "CLI '--version' outputs expected semantic version"

"$BIN_PATH" pause >/dev/null
if [[ -f "$TEMP_DISABLE_FLAG" ]]; then
    pass "CLI 'pause' creates temporary pause flag"
else
    fail "CLI 'pause' did not create temporary pause flag"
fi

STATUS_OUT="$("$BIN_PATH" status)"
if [[ "$STATUS_OUT" == *"PAUSED"* && "$STATUS_OUT" == *"unifi_vpn"* && "$STATUS_OUT" == *"v1.0.0"* ]]; then
    pass "CLI 'status' reports version, PAUSED mode, and configured profile"
else
    fail "CLI 'status' output unexpected"
fi

rm -f "$TEMP_DISABLE_FLAG"
"$BIN_PATH" disable >/dev/null
if [[ -f "$PERSIST_DISABLE_FLAG" ]]; then
    pass "CLI 'disable' creates persistent disable flag"
else
    fail "CLI 'disable' did not create persistent disable flag"
fi

echo ""
echo "============================================================"
printf " Test Summary: %d passed, %d failed\n" "$PASS_COUNT" "$FAIL_COUNT"
echo "============================================================"

if (( FAIL_COUNT > 0 )); then
    exit 1
fi
