# OpenWrt Multi-VPN Manager

A production-oriented OpenWrt package for managing multiple WireGuard profiles, device-based policy routing, network isolation, and resilient VPN recovery.

## Highlights

- Multiple WireGuard profiles (import/create/edit/delete/enable/disable)
- Per-device routing target: WAN or any VPN profile
- Dedicated WiFi over VPN: create a separate SSID and force its whole subnet through one VPN profile
- Exit IP visibility for WAN and VPN profiles, including country information/flags in the dashboard
- Atomic apply flow with validation and rollback
- Optional kill-switch per VPN profile
- Health-check and watchdog auto-reconnect
- IPv4 + IPv6 support
- nftables-first policy and firewall control
- LuCI web UI and ubus/rpcd backend
- Audit logging with private-key redaction

## Project Layout

- docs/: architecture, API, wireframes, deployment, operations, tests
- openwrt-package/: package files for OpenWrt build system
- src/: LuCI frontend, rpcd backend, shell core libraries
- scripts/: installer and operational scripts
- tests/: unit and integration tests

## API Documentation

- OpenAPI spec: docs/api-spec.yaml
- Usage guide: docs/api-usage.md
- LuCI web docs page: Services -> VPN Manager -> API Docs

## Quick Install (on OpenWrt)

This section is written for beginners and assumes you want to install directly on a running OpenWrt router.

### 0) What you need

- A router running OpenWrt with internet access
- Router admin account (usually `root`)
- A PC on the same network
- SSH client:
	- Windows: PowerShell has `ssh` built in
	- macOS/Linux: Terminal has `ssh` built in

### 1) Connect to the router by SSH

From your PC, run:

```sh
ssh root@192.168.1.1
```

If your router uses another LAN IP, replace `192.168.1.1`.

When asked for confirmation, type `yes`. Then enter your router password.

### 2) Download this project on the router

Run these commands on the router shell:

```sh
cd /root
rm -rf /root/openwrt-vpn-manager /tmp/openwrt-vpn-manager.tar.gz /tmp/openwrt-vpn-manager-main
wget -O /tmp/openwrt-vpn-manager.tar.gz https://codeload.github.com/roremi/openwrt-vpn-manager/tar.gz/refs/heads/main
tar -xzf /tmp/openwrt-vpn-manager.tar.gz -C /tmp
mv /tmp/openwrt-vpn-manager-main /root/openwrt-vpn-manager
```

### 3) Run the bootstrap installer

```sh
sh /root/openwrt-vpn-manager/scripts/bootstrap-openwrt.sh
```

What this script does:

- Detects package manager (`opkg` or `apk`)
- Installs required packages (WireGuard, nftables, rpcd, LuCI dependencies)
- Runs `scripts/install.sh`
- Enables and restarts `vpn-manager` service

### 4) Verify service status

```sh
/etc/init.d/vpn-manager status
```

If your OpenWrt build does not show status text, use:

```sh
ps | grep vpn-manager
```

### 5) Open the web interface

- Open LuCI in browser: `http://192.168.1.1`
- Go to: `Services -> VPN Manager`

### 6) First-time setup flow

1. Create or import a WireGuard profile.
2. Click apply/reconcile.
3. In devices list, choose target for each device:
	 - `wan` for normal internet
	 - your VPN profile for tunneled traffic
4. Apply policy changes.
5. Confirm active routing from the dashboard.

## What Is New In The Latest Version

### 1) MultiEbay quick import

- Save your MultiEbay API key on the router once
- Paste proxy in `ip:port:user:pass` or full proxy URL format
- The router creates the gateway, creates a WireGuard client, imports it, and applies it

### 2) WiFi routing

- WiFi Manager supports a dedicated SSID with its own subnet, DHCP scope, and firewall zone
- Each dedicated SSID can be bound to exactly one VPN profile
- Device-based routing rules remain separate and are not overwritten by dedicated WiFi bindings

### 3) Exit IP and country visibility

- Dashboard shows public IP information for WAN and VPN profiles
- Devices display the active exit IP based on the selected route target
- Country information is included so you can confirm the tunnel location quickly

## Updated Usage Guide

### A) Route one device through one VPN

1. Open `Services -> VPN Manager`
2. Go to `Devices Routing`
3. Find the device by hostname, IP, or MAC
4. Change `1-Tap Override` to the VPN profile you want

### B) WiFi setup

1. Open `Services -> VPN Manager`
2. Go to `WiFi Manager`
3. Configure the base WiFi radio if needed
4. In `Dedicated WiFi Over VPN`, enter:
	- `Binding ID`
	- `SSID`
	- `Password`
	- `Security`
	- `Target VPN`
	- `Enabled`
5. Save the dedicated WiFi binding
6. Connect devices to that SSID
7. Apply changes and verify the exit IP in the dashboard

### C) Import VPN from proxy using MultiEbay

1. Open `Services -> VPN Manager`
2. Go to `MultiEbay Import`
3. Save your API key if not already saved on the router
4. Paste proxy string
5. Click `Generate & Apply`
6. Wait for the profile to appear in `VPN Profiles`

## Notes For WiFi Routing

- Each dedicated WiFi binding creates its own OpenWrt interface, bridge, DHCP scope, and firewall zone
- Traffic from that SSID is routed by subnet, so existing per-device rules on the main LAN are unaffected
- DNS for that SSID is handed out from the target VPN profile when available

## One-liner Install

If you are already connected by SSH, run one command:

```sh
set -e; cd /root; rm -rf openwrt-vpn-manager /tmp/openwrt-vpn-manager.tar.gz /tmp/openwrt-vpn-manager-main; wget -O /tmp/openwrt-vpn-manager.tar.gz https://codeload.github.com/roremi/openwrt-vpn-manager/tar.gz/refs/heads/main; tar -xzf /tmp/openwrt-vpn-manager.tar.gz -C /tmp; mv /tmp/openwrt-vpn-manager-main /root/openwrt-vpn-manager; sh /root/openwrt-vpn-manager/scripts/bootstrap-openwrt.sh; /etc/init.d/vpn-manager enable; /etc/init.d/vpn-manager restart
```

## Troubleshooting (Common Beginner Issues)

### TLS or certificate error when running wget

If download fails with SSL/TLS/certificate errors:

For `opkg` routers:

```sh
opkg update
opkg install ca-bundle wget-ssl
```

For `apk` routers:

```sh
apk update
apk add ca-certificates wget
```

Then retry step 2.

### Wrong system time breaks HTTPS downloads

Check time:

```sh
date
```

If time is wrong, set timezone/NTP in LuCI (`System -> System`) and retry.

### Service installed but menu not visible in LuCI

Run:

```sh
/etc/init.d/uhttpd restart
```

Then refresh browser (Ctrl+F5).

### Reinstall cleanly

```sh
/etc/init.d/vpn-manager stop || true
rm -rf /root/openwrt-vpn-manager
rm -f /etc/config/vpn-manager
```

Then run install steps again.

## Build As OpenWrt Package

1. Place openwrt-package/vpn-manager into package/ directory of OpenWrt buildroot.
2. Add project files into package payload (see openwrt-package/vpn-manager/Makefile install section).
3. Run make menuconfig and select LuCI app VPN Manager.
4. Build and install resulting ipk.

## Safety Model

- All config changes go to UCI staging sections first.
- Validation occurs before reload.
- Transaction checkpoint saved before commit.
- Auto rollback if health probes fail after apply.

## License

MIT
