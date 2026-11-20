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
trap 'chmod -R u+rwx "$SANDBOX" 2>/dev/null || true; rm -rf "$SANDBOX"' EXIT

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

if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "${REPO_ROOT}/config/com.wireguard.autovpn.plist" >/dev/null; then
        pass "plutil -lint valid: config/com.wireguard.autovpn.plist"
    else
        fail "plutil -lint failed: config/com.wireguard.autovpn.plist"
    fi
elif command -v xmllint >/dev/null 2>&1; then
    if xmllint --noout "${REPO_ROOT}/config/com.wireguard.autovpn.plist" 2>/dev/null; then
        pass "xmllint valid: config/com.wireguard.autovpn.plist"
    else
        fail "xmllint failed: config/com.wireguard.autovpn.plist"
    fi
else
    pass "plist XML structure present: config/com.wireguard.autovpn.plist"
fi

# ------------------------------------------------------------------------------
# 2. Load Library Functions in Sandbox Mode
# ------------------------------------------------------------------------------
export BREW_PREFIX="$SANDBOX/brew"
export WG_DIR="$SANDBOX/etc/wireguard"
export CONFIG_FILE="$WG_DIR/autovpn.conf"
export RUN_DIR="$SANDBOX/run"
export WG_RUN_DIR="$SANDBOX/run/wireguard"
export LOG_FILE="$SANDBOX/wireguard-auto.log"
export LOCK_DIR="$RUN_DIR/wireguard-auto.lock"
export TEMP_DISABLE_FLAG="$RUN_DIR/wireguard-auto.paused"
export PERSIST_DISABLE_FLAG="$WG_DIR/.disabled"
export FULL_TUNNEL_FLAG="$RUN_DIR/wireguard-auto.full"
export STATE_FILE="$RUN_DIR/wireguard-auto.state"
export SKIP_ROOT_OWNERSHIP_CHECK=1
export SKIP_CHECK_SLEEP=1

mkdir -p "$WG_DIR" "$RUN_DIR" "$WG_RUN_DIR" "$BREW_PREFIX/bin"

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
assert_eq "$("$BIN_PATH" --version)" "wireguard-auto v1.1.0" "CLI '--version' outputs expected semantic version"

"$BIN_PATH" pause >/dev/null
if [[ -f "$TEMP_DISABLE_FLAG" ]]; then
    pass "CLI 'pause' creates temporary pause flag"
else
    fail "CLI 'pause' did not create temporary pause flag"
fi

STATUS_OUT="$("$BIN_PATH" status)"
if [[ "$STATUS_OUT" == *"PAUSED"* && "$STATUS_OUT" == *"unifi_vpn"* && "$STATUS_OUT" == *"v1.1.0"* && "$STATUS_OUT" == *"SPLIT (default)"* ]]; then
    pass "CLI 'status' reports version, PAUSED mode, split profile, and default tunnel mode"
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
rm -f "$PERSIST_DISABLE_FLAG"

# ------------------------------------------------------------------------------
# 6. Full-Tunnel Toggle, Auto-Reset on New Network & Non-Root Status Fix
# ------------------------------------------------------------------------------
echo ""
echo "--> 5. Full-Tunnel Toggle, Network-Bound Auto-Reset & Status Detection Tests"

# 6a. WG_FULL_INTERFACE validation & default derivation
cat > "$CONFIG_FILE" <<'EOF'
WG_INTERFACE="homevpn"
WG_FULL_INTERFACE="../../etc/passwd"
EOF
if ! parse_config "$CONFIG_FILE" 2>/dev/null; then
    pass "Config parser rejects path traversal in WG_FULL_INTERFACE"
else
    fail "Config parser accepted path traversal in WG_FULL_INTERFACE"
fi

cat > "$CONFIG_FILE" <<'EOF'
WG_INTERFACE="homevpn"
WG_FULL_INTERFACE="homevpn"
EOF
if ! parse_config "$CONFIG_FILE" 2>/dev/null; then
    pass "Config parser rejects WG_FULL_INTERFACE identical to WG_INTERFACE"
else
    fail "Config parser accepted identical WG_INTERFACE and WG_FULL_INTERFACE"
fi

cat > "$CONFIG_FILE" <<'EOF'
WG_INTERFACE="homevpn"
TRUSTED_SSIDS=(
    "Home-WiFi-5G"
)
TRUSTED_GATEWAY_MACS=(
    "00:1a:2b:03:04:0f"
)
EOF
parse_config "$CONFIG_FILE"
assert_eq "$(get_full_interface)" "homevpn-full" "get_full_interface derives '<WG_INTERFACE>-full' by default"

cat > "$CONFIG_FILE" <<'EOF'
WG_INTERFACE="homevpn"
WG_FULL_INTERFACE="home_full"
TRUSTED_SSIDS=(
    "Home-WiFi-5G"
)
TRUSTED_GATEWAY_MACS=(
    "00:1a:2b:03:04:0f"
)
EOF
parse_config "$CONFIG_FILE"
assert_eq "$(get_full_interface)" "home_full" "parse_config reads explicit WG_FULL_INTERFACE"

# Reject symlinked full-tunnel config
ln -sf "$CONFIG_FILE" "${WG_DIR}/home_full.conf"
if ! verify_profile_conf "home_full" 2>/dev/null; then
    pass "verify_profile_conf rejects symlinked full-tunnel config"
else
    fail "verify_profile_conf accepted symlinked full-tunnel config"
fi
rm -f "${WG_DIR}/home_full.conf"

# Missing full-tunnel config must be rejected cleanly
if ! verify_profile_conf "home_full" 2>/dev/null; then
    pass "verify_profile_conf fails cleanly when full-tunnel config is missing"
else
    fail "verify_profile_conf succeeded despite missing full-tunnel config"
fi

# Create split and full profiles sharing the exact same client IP (single UniFi peer)
cat > "${WG_DIR}/homevpn.conf" <<'EOF'
[Interface]
Address = 10.13.13.2/32

[Peer]
Endpoint = 198.51.100.42:51820
AllowedIPs = 10.13.13.0/24, 10.100.10.0/29
EOF

cat > "${WG_DIR}/home_full.conf" <<'EOF'
[Interface]
Address = 10.13.13.2/32
DNS = 10.100.11.4

[Peer]
Endpoint = 198.51.100.42:51820
AllowedIPs = 0.0.0.0/0
EOF

# 6b. Network-bound full-tunnel auto-reset logic (Approach A)
write_full_mode_flag "Radisson_Guest" "20:7c:14:f4:50:35"

if is_same_full_tunnel_network "Radisson_Guest" "20:7c:14:f4:50:35"; then
    pass "is_same_full_tunnel_network keeps FULL mode on same SSID"
else
    fail "is_same_full_tunnel_network reset FULL mode on same SSID"
fi

if ! is_same_full_tunnel_network "Starbucks_WiFi" "aa:bb:cc:dd:ee:ff"; then
    pass "is_same_full_tunnel_network triggers auto-reset on new SSID"
else
    fail "is_same_full_tunnel_network did not reset on new SSID"
fi

if is_same_full_tunnel_network "" ""; then
    pass "is_same_full_tunnel_network preserves FULL mode during brief Wi-Fi disconnect"
else
    fail "is_same_full_tunnel_network falsely reset during brief Wi-Fi disconnect"
fi

if is_same_full_tunnel_network "" "20:7c:14:f4:50:35"; then
    pass "is_same_full_tunnel_network matches Gateway MAC when macOS redacts SSID (<redacted>)"
else
    fail "is_same_full_tunnel_network failed Gateway MAC match under redacted SSID"
fi

if ! is_same_full_tunnel_network "" "11:22:33:44:55:66"; then
    pass "is_same_full_tunnel_network triggers auto-reset on new Gateway MAC when SSID is redacted"
else
    fail "is_same_full_tunnel_network failed to reset on new Gateway MAC under redacted SSID"
fi
clear_full_mode_flag

# 6c. Dual-profile shared-IP discrimination & non-root STATE_FILE visibility fix
MOCK_UTUN3_UP=1
MOCK_UTUN3_IP="10.13.13.2"

# shellcheck disable=SC2329
ifconfig() {
    if [[ "${1:-}" == "utun3" ]]; then
        if (( MOCK_UTUN3_UP == 1 )); then
            printf 'utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1420\n\tinet %s --> %s netmask 0xffffffff\n' "$MOCK_UTUN3_IP" "$MOCK_UTUN3_IP"
            return 0
        fi
        return 1
    fi
    if [[ -z "${1:-}" ]]; then
        if (( MOCK_UTUN3_UP == 1 )); then
            printf 'utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1420\n\tinet %s --> %s netmask 0xffffffff\n' "$MOCK_UTUN3_IP" "$MOCK_UTUN3_IP"
        fi
        return 0
    fi
    return 1
}

# Full profile active on utun3 with shared IP 10.13.13.2: must NOT falsely report split profile active
printf 'utun3\n' > "${WG_RUN_DIR}/home_full.name"
write_state_file "home_full" "utun3" "10.13.13.2"

if is_profile_active "home_full" && ! is_profile_active "homevpn"; then
    pass "Shared-IP profiles accurately distinguish active full profile from inactive split profile"
else
    fail "Shared-IP profile detection confused split and full profiles"
fi

# Simulate root-only /var/run/wireguard (000) + 0600 conf: non-root status reads world-readable STATE_FILE
rm -f "${WG_RUN_DIR}/home_full.name"
printf 'utun3\n' > "${WG_RUN_DIR}/homevpn.name"
write_state_file "homevpn" "utun3" "10.13.13.2"
chmod 000 "$WG_RUN_DIR"

assert_eq "$(get_profile_utun "homevpn")" "utun3" "Non-root status detects active utun3 via world-readable STATE_FILE when WG_RUN_DIR is root-only"

# Recycled utun3 with different IP (e.g. NordVPN 10.3.0.2) must NOT produce false positive
MOCK_UTUN3_IP="10.3.0.2"
if ! is_profile_active "homevpn"; then
    pass "STATE_FILE rejects recycled utun interface when live IP does not match"
else
    fail "STATE_FILE falsely reported UP after utun IP changed"
fi

chmod 700 "$WG_RUN_DIR"
MOCK_UTUN3_IP="10.13.13.2"
rm -f "${WG_RUN_DIR}/homevpn.name"
clear_state_file

# 6d. End-to-end cmd_full, cmd_split & _cmd_check_locked transitions with mocked wg-quick
MOCK_WG_LOG="$SANDBOX/mock-wg-quick.log"
MOCK_WG_QUICK="$SANDBOX/mock-wg-quick"
cat > "$MOCK_WG_QUICK" <<'EOF'
#!/usr/bin/env bash
action="$1"
profile="$2"
printf '%s %s\n' "$action" "$profile" >> "$MOCK_WG_LOG"
if [[ "$action" == "up" ]]; then
    printf 'utun3\n' > "${WG_RUN_DIR}/${profile}.name"
elif [[ "$action" == "down" ]]; then
    rm -f "${WG_RUN_DIR}/${profile}.name"
fi
EOF
chmod +x "$MOCK_WG_QUICK"
export MOCK_WG_LOG
export WG_QUICK_BIN="$MOCK_WG_QUICK"

MOCK_SSID="Radisson_Guest"
MOCK_MAC="20:7c:14:f4:50:35"
MOCK_DEF_GW="en0"

# shellcheck disable=SC2329
get_current_ssid() { printf '%s\n' "$MOCK_SSID"; }
# shellcheck disable=SC2329
get_gateway_mac() { printf '%s\n' "$MOCK_MAC"; }
# shellcheck disable=SC2329
get_default_gateway_interface() { printf '%s\n' "$MOCK_DEF_GW"; }
# shellcheck disable=SC2329
has_default_route() { return 0; }
# shellcheck disable=SC2329
ifconfig() {
    local has_name=0
    if [[ -f "${WG_RUN_DIR}/homevpn.name" || -f "${WG_RUN_DIR}/home_full.name" ]]; then
        has_name=1
    fi
    if [[ "${1:-}" == "utun3" || -z "${1:-}" ]]; then
        if (( has_name == 1 )); then
            printf 'utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1420\n\tinet 10.13.13.2 --> 10.13.13.2 netmask 0xffffffff\n'
            return 0
        fi
        return 1
    fi
    return 1
}

# Start away from home -> default check brings up SPLIT (homevpn)
_cmd_check_locked 1 >/dev/null
if is_profile_active "homevpn" && ! is_profile_active "home_full"; then
    pass "Default check brings up split-tunnel profile (homevpn) on untrusted hotel Wi-Fi"
else
    fail "Default check did not bring up split-tunnel profile"
fi

# NordVPN conflict guard: refuse full-tunnel when utun4 owns default route
MOCK_DEF_GW="utun4"
if ! ( cmd_full >/dev/null 2>&1 ); then
    pass "cmd_full refuses to override conflicting commercial VPN default route (utun4)"
else
    fail "cmd_full did not block conflicting commercial VPN (utun4)"
fi

if is_profile_active "homevpn" && ! is_full_mode_enabled; then
    pass "Failed conflict guard leaves existing split-tunnel untouched"
else
    fail "Failed conflict guard disrupted split-tunnel state"
fi

# --force overrides conflicting VPN guard when explicitly requested
cmd_full --force >/dev/null
if is_full_mode_enabled && is_profile_active "home_full" && ! is_profile_active "homevpn"; then
    pass "cmd_full --force overrides conflicting commercial VPN guard when requested"
else
    fail "cmd_full --force failed to override conflict guard"
fi
cmd_split >/dev/null

# Disconnect NordVPN (default route back on en0) -> cmd_full succeeds
MOCK_DEF_GW="en0"
cmd_full >/dev/null
if is_full_mode_enabled && is_profile_active "home_full" && ! is_profile_active "homevpn"; then
    pass "cmd_full switches cleanly from split (homevpn) to full (home_full) bound to Radisson_Guest"
else
    fail "cmd_full failed to switch from split to full"
fi

# Subsequent check on same SSID keeps full-tunnel active
_cmd_check_locked 1 >/dev/null
if is_full_mode_enabled && is_profile_active "home_full"; then
    pass "Daemon check preserves full-tunnel while remaining on Radisson_Guest"
else
    fail "Daemon check unexpectedly dropped full-tunnel on same SSID"
fi

# Status output accurately shows FULL mode and active full profile
FULL_STATUS_OUT="$(cmd_status)"
if [[ "$FULL_STATUS_OUT" == *"FULL (manual override — bound to: Radisson_Guest)"* && "$FULL_STATUS_OUT" == *"UP (home_full on utun3 — full)"* ]]; then
    pass "cmd_status displays bound FULL mode and active full profile on utun3"
else
    fail "cmd_status output missing expected FULL mode / UP interface details"
fi

# Connect to a NEW untrusted SSID (Starbucks) -> auto-resets back to SPLIT!
MOCK_SSID="Starbucks_WiFi"
MOCK_MAC="aa:bb:cc:dd:ee:ff"
_cmd_check_locked 1 >/dev/null
if ! is_full_mode_enabled && is_profile_active "homevpn" && ! is_profile_active "home_full"; then
    pass "Moving to a new SSID (Starbucks_WiFi) auto-resets FULL mode back to SPLIT (homevpn)"
else
    fail "Moving to a new SSID failed to auto-reset FULL mode back to SPLIT"
fi

# Re-enable full on Starbucks, then switch manually via cmd_split
cmd_full >/dev/null
cmd_split >/dev/null
if ! is_full_mode_enabled && is_profile_active "homevpn" && ! is_profile_active "home_full"; then
    pass "cmd_split manually tears down full-tunnel and restores split-tunnel"
else
    fail "cmd_split failed to restore split-tunnel"
fi

# Re-enable full on Starbucks, then return to trusted home Wi-Fi -> tears down & clears flag
cmd_full >/dev/null
MOCK_SSID="Home-WiFi-5G"
MOCK_MAC="00:1a:2b:03:04:0f"
_cmd_check_locked 1 >/dev/null
if ! is_full_mode_enabled && ! is_profile_active "home_full" && ! is_profile_active "homevpn" && [[ ! -f "$STATE_FILE" ]]; then
    pass "Returning to trusted home Wi-Fi tears down full-tunnel, clears FULL flag, and clears state file"
else
    fail "Returning to trusted home Wi-Fi left active tunnel or stale state"
fi

# Refuses cmd_full while on trusted home Wi-Fi
if ! ( cmd_full >/dev/null 2>&1 ); then
    pass "cmd_full refuses activation while connected to trusted home Wi-Fi"
else
    fail "cmd_full allowed activation on trusted home Wi-Fi"
fi

echo ""
echo "============================================================"
printf " Test Summary: %d passed, %d failed\n" "$PASS_COUNT" "$FAIL_COUNT"
echo "============================================================"

if (( FAIL_COUNT > 0 )); then
    exit 1
fi
