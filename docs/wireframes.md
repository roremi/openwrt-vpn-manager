# Admin UI Wireframes

## 1. Dashboard

- Header: system status, role badge, dark mode toggle
- Cards:
  - Router Health (CPU/RAM/Uptime)
  - WAN state
  - VPN Active/Down count
  - Watchdog events
- Table: VPN summary
  - Name | Endpoint | Status | Handshake | RX | TX | Ping | Actions
- Chart: bandwidth by profile (last 5m/1h)
- Realtime log panel

## 2. VPN Profiles

- Left: profile list with status pill
- Right: profile editor tabs
  - General
  - Keys
  - Routing
  - Kill Switch
  - Health-check
- Top actions:
  - Import .conf
  - Add profile
  - Clone
  - Delete
  - Test latency
  - Enable/Disable

## 3. Devices

- Discovery table:
  - Hostname | IP | MAC | Vendor | Online | Current route
- Filters: online/offline, VLAN/zone, target route
- Bulk action:
  - Assign WAN / VPN A / VPN B / VPN C
- Side panel: device details + history

## 4. Routing Map

- Visual graph:
  - LAN/WiFi clients -> policy mark -> table -> WAN/VPN
- Conflict warnings:
  - duplicated fwmark/table, stale rule, missing interface

## 5. Isolation

- Zone matrix (source zone x destination zone) allow/deny toggles
- Guest wizard: one-click guest network with isolation
- Broadcast suppression toggles

## 6. Audit & Logs

- Timeline with actor, action, scope, result
- Redacted secrets
- Download log bundle

## 7. Theme

- Supports light/dark mode
- High contrast status colors for Up/Degraded/Down
