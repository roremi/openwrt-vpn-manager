# System Architecture

## 1. Components

1. LuCI Frontend (JS views)
- Dashboard, VPN list, devices, routing map, realtime logs, settings.

2. RPC Backend (rpcd + ucode)
- Exposes secure ubus methods for CRUD, tests, apply, rollback, status, metrics.

3. Core Engine (shell libs)
- UCI model management
- WireGuard lifecycle
- nftables + firewall zone orchestration
- policy-based routing tables/rules
- health-check and watchdog

4. Runtime Services
- procd init service: vpn-manager
- cron/procd timers for watchdog and health checks

5. Data Plane
- WAN direct path
- wg interfaces (wg_vpn_a, wg_vpn_b, ...)
- nft marks + ip rules for source-device based routing

## 2. Data Model (UCI-centric)

Config file: /etc/config/vpn-manager

- config global 'global'
  - option enabled '1'
  - option auto_rollback '1'
  - option rollback_timeout '45'
  - option health_interval '20'
  - option strict_validation '1'

- config profile 'name'
  - option enabled '1'
  - option name 'VPN A'
  - option iface 'wg_vpn_a'
  - option private_key '***'
  - option public_key '***'
  - option endpoint_host 'x.x.x.x'
  - option endpoint_port '51820'
  - list allowed_ips '0.0.0.0/0'
  - list allowed_ips '::/0'
  - option persistent_keepalive '25'
  - option metric '100'
  - option table_id '101'
  - option fwmark '0x101'
  - option kill_switch '0'
  - option dns_mode 'peer'

- config device_policy 'mac_or_id'
  - option mac 'AA:BB:CC:DD:EE:FF'
  - option ip '192.168.1.30'
  - option hostname 'tv-livingroom'
  - option target 'wan|profile_id'
  - option enabled '1'

- config zone_group 'group_name'
  - option zone 'iot'
  - list members 'AA:BB:...'
  - option client_isolation '1'
  - option allow_interzone '0'

## 3. Transaction and Rollback

1. Create checkpoint:
- uci export network/firewall/vpn-manager > /tmp/vpn-manager/checkpoint-<ts>.uci
- nft list ruleset > /tmp/vpn-manager/checkpoint-<ts>.nft

2. Validate candidate:
- wg syncconf dry parse
- nft -c for generated rules
- ip rule/table conflict checks

3. Apply candidate atomically:
- uci commit
- reload network/firewall
- reconcile pbr and nft marks

4. Post-apply health window:
- verify endpoint reachability and handshake
- verify egress IP through desired tunnel
- on failure rollback checkpoint

## 4. Recovery and Stability

- Per-profile watchdog restarts only affected interface.
- Reconnect backoff: 2s, 5s, 10s, 30s, then steady 60s.
- Fail-open or fail-closed based on kill-switch.
- Changes are profile-scoped to avoid disrupting other profiles.

## 5. Security Controls

- rpcd ACL based permission sets.
- CSRF from LuCI framework token handling.
- Input validation for keys, endpoint, CIDR, ports, MAC, hostnames.
- Audit log with key redaction.
- Role profiles:
  - admin: full access
  - operator: manage profiles/device policy, no RBAC changes
  - viewer: read-only

## 6. Network Isolation

- Optional VLAN-per-group or zone-only segregation.
- nftables forward chain denies inter-zone by default.
- mDNS/broadcast suppression toggle by zone rules.
- Guest zone internet-only template.

## 7. IPv6

- Separate fwmarks and rules for ip -6 rule.
- AllowedIPs and default route split for v4/v6.
- Health check probes both 1.1.1.1 and 2606:4700:4700::1111.
