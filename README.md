# wireguard-autovpn-macos

Lightweight, zero-polling, event-driven WireGuard automation for macOS (`x86_64` Intel & `arm64` Apple Silicon) powered by `launchd` and `wireguard-tools`.

Automatically brings up your split-tunnel WireGuard interface when away from your trusted home Wi-Fi network(s) and tears it down when you return home—with zero background CPU wakeups and native coexistence alongside full-tunnel commercial VPNs (such as NordVPN).

---

## Key Features

- **Zero Background Polling (Battery Friendly):** Uses macOS `launchd` `WatchPaths` on `/Library/Preferences/SystemConfiguration/` to react only when physical network state changes occur.
- **Universal Architecture (`arm64` & `x86_64`):** Dynamically detects Homebrew prefixes (`/opt/homebrew` on Apple Silicon vs. `/usr/local` on Intel).
- **Modern macOS SSID & ARP Fallback:** Supports SSID matching via `networksetup` / `ipconfig getsummary` and optional gateway ARP MAC matching (for macOS Sequoia/Tahoe when Location Services redacts SSIDs for background daemons).
- **Commercial VPN Coexistence:** Includes a DNS & default-route readiness preflight loop so split-tunnel homelab routes (`10.100.x.x`) initialize cleanly alongside auto-connecting commercial VPNs without race conditions.
- **Captive Portal Override CLI:** Built-in `wireguard-auto pause` and `wireguard-auto resume` commands for hotel and airplane Wi-Fi login portals.

---

## Prerequisites

Install `wireguard-tools` via Homebrew (which automatically pulls in `wireguard-go` and `bash` 5+ as dependencies):

```bash
brew install wireguard-tools
```

Ensure your WireGuard tunnel profile (e.g., `homevpn.conf`) is placed in Homebrew's WireGuard directory:
- **Apple Silicon:** `/opt/homebrew/etc/wireguard/homevpn.conf`
- **Intel:** `/usr/local/etc/wireguard/homevpn.conf`

---

## Quick Start / Installation

1. Clone this repository:
   ```bash
   git clone <repo-url> wireguard-autovpn-macos
   cd wireguard-autovpn-macos
   ```
2. Run the automated installer:
   ```bash
   sudo ./install.sh
   ```
3. Edit your trusted SSIDs in `<BREW_PREFIX>/etc/wireguard/autovpn.conf`:
   ```bash
   WG_INTERFACE="homevpn"

   TRUSTED_SSIDS=(
       "Your-Home-WiFi-SSID"
   )
   ```

---

## CLI Usage

```text
Usage: wireguard-auto [command]

Commands:
  check     Evaluate network and activate/deactivate WireGuard (called by launchd)
  status    Show current Wi-Fi network, WireGuard state, and auto-connect mode
  pause     Temporarily disable auto-connect and bring down WireGuard (ideal for captive portals)
  resume    Re-enable auto-connect and evaluate current network
  disable   Persistently disable auto-connect across reboots
  enable    Same as resume
  help      Display this help message
```

---

## Uninstallation

```bash
sudo ./uninstall.sh
```
*(Unloads the `launchd` daemon and removes the binary while preserving your `.conf` files).*
