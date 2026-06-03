# OpenWrt Multi-VPN Manager

A production-oriented OpenWrt package for managing multiple WireGuard profiles, device-based policy routing, network isolation, and resilient VPN recovery.

## Highlights

- Multiple WireGuard profiles (import/create/edit/delete/enable/disable)
- Per-device routing target: WAN or any VPN profile
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

## Quick Install (on OpenWrt)

1. Copy this repository to router or build host.
2. Run scripts/bootstrap-openwrt.sh.
3. Open LuCI > Services > VPN Manager.

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
