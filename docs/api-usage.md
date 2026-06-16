# VPN Manager API Usage Guide

This guide provides a detailed reference for full vpn-manager capability, including per-device VPN assignment, profile lifecycle, WiFi-over-VPN binding, MultiEbay automation, and safe apply or rollback.

## 1) Base Information

- Base path: /cgi-bin/luci/admin/services/vpnmanager
- Auth model: LuCI authenticated session
- Response format: application/json text body
- Read APIs: GET
- Write APIs: POST with application/x-www-form-urlencoded

### Alternative for software integration without LuCI login

Use token-protected public endpoints under:

- /cgi-bin/luci/vpnmanager/api/v1/*

These endpoints require header X-API-Key instead of LuCI session cookie.

Configure key on router:

uci -q set vpn-manager.global=vpn-manager
uci set vpn-manager.global.software_api_key='YOUR_STRONG_KEY'
uci commit vpn-manager
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

Example (no login session needed):

curl -s -H "Authorization: Bearer YOUR_STRONG_KEY" "http://192.168.1.1/cgi-bin/luci/vpnmanager/api/v1/devices"

If your OpenWrt/uhttpd path does not forward custom headers, use query fallback:

curl -s "http://192.168.1.1/cgi-bin/luci/vpnmanager/api/v1/devices?api_key=YOUR_STRONG_KEY"

## 2) Endpoint Index

### Profiles

- GET /profiles
- POST /profile
- POST /profile_delete
- POST /toggle
- POST /test
- POST /import

### Devices and Policies

- GET /devices
- GET /policies
- POST /policy
- POST /policy_delete

### WiFi and Dedicated WiFi Over VPN

- GET /wifi
- POST /wifi_set
- GET /wifi_bindings
- POST /wifi_binding
- POST /wifi_binding_delete

### MultiEbay Integration

- GET /multiebay_settings
- POST /multiebay_settings_save
- POST /multiebay_settings_clear
- POST /multiebay_import

### Operations

- GET /status
- GET /route_status
- GET /audit
- POST /apply
- POST /rollback

## 3) Common Response Patterns

### Success pattern

{
  "ok": true
}

### Error pattern

{
  "ok": false,
  "error": "message"
}

### Generic unsupported route or method

{
  "error": "unsupported method"
}

## 4) Detailed API Reference

### 4.1 GET /profiles

Purpose:
- Return all VPN profiles with runtime status and handshake age.

Sample response:

{
  "profiles": [
    {
      "id": "vpn_sg_01",
      "name": "Singapore 01",
      "iface": "wg_vpnsg01",
      "endpoint": "1.2.3.4:51820",
      "enabled": "1",
      "status": "healthy",
      "handshake_age": "22",
      "address": "10.9.0.2/32",
      "dns": "1.1.1.1",
      "allowed_ips": "0.0.0.0/0,::/0",
      "mtu": "1420",
      "persistent_keepalive": "25",
      "public_key": "base64_public_key"
    }
  ]
}

### 4.2 POST /profile

Purpose:
- Create new profile or update existing profile by id.

Required fields:
- id

Optional fields:
- name
- endpoint_host
- endpoint_port
- public_key
- private_key
- address
- dns
- allowed_ips (comma-separated)
- mtu
- persistent_keepalive
- enabled (0 or 1)
- preshared_key

Sample request:

curl -s -X POST "http://192.168.1.1/cgi-bin/luci/admin/services/vpnmanager/profile" \
  --data-urlencode "id=vpn_sg_01" \
  --data-urlencode "name=Singapore 01" \
  --data-urlencode "endpoint_host=1.2.3.4" \
  --data-urlencode "endpoint_port=51820" \
  --data-urlencode "public_key=base64_pub" \
  --data-urlencode "private_key=base64_priv" \
  --data-urlencode "address=10.9.0.2/32" \
  --data-urlencode "dns=1.1.1.1" \
  --data-urlencode "allowed_ips=0.0.0.0/0,::/0" \
  --data-urlencode "enabled=1"

Success response:

{
  "ok": true
}

Common error:

{
  "ok": false,
  "error": "missing profile id"
}

### 4.3 POST /import

Purpose:
- Import profile from local file path or raw WireGuard conf content.

Required fields:
- id

One of:
- path
- content

Sample request using content:

curl -s -X POST "http://192.168.1.1/cgi-bin/luci/admin/services/vpnmanager/import" \
  --data-urlencode "id=vpn_sg_01" \
  --data-urlencode "content=[Interface]\nPrivateKey=...\nAddress=10.0.0.2/32\nDNS=1.1.1.1\n[Peer]\nPublicKey=...\nAllowedIPs=0.0.0.0/0,::/0\nEndpoint=1.2.3.4:51820"

Success response:

{
  "ok": true
}

Common errors:

{
  "ok": false,
  "error": "conf file not found"
}

### 4.4 POST /test

Purpose:
- Validate profile state and estimate latency via interface-scoped probe.

Required fields:
- id

Sample success response:

{
  "ok": true,
  "state": "healthy",
  "latency": "n/a"
}

Sample failure response:

{
  "ok": false,
  "error": "profile not found"
}

### 4.5 POST /toggle

Purpose:
- Enable or disable profile.

Required fields:
- id
- enabled (0 or 1)

Success response:

{
  "ok": true
}

### 4.6 POST /profile_delete

Purpose:
- Delete profile and corresponding network interface entries.

Required fields:
- id

Common errors:

{
  "ok": false,
  "error": "profile not found"
}

### 4.7 GET /devices

Purpose:
- Return normalized device list merged from DHCP leases and ARP neighbor state.

Sample response:

{
  "devices": [
    {
      "ip": "192.168.1.195",
      "mac": "1e:95:1c:4d:d5:ac",
      "hostname": "SM-S911B",
      "state": "reachable",
      "connected": true
    }
  ]
}

### 4.8 GET /policies

Purpose:
- List configured per-device routing policies.

Sample response:

{
  "policies": [
    {
      "section": "policy_sm_s911b",
      "hostname": "SM-S911B",
      "mac": "1e:95:1c:4d:d5:ac",
      "ip": "192.168.1.195",
      "target": "vpn_sg_01"
    }
  ]
}

### 4.9 POST /policy

Purpose:
- Assign device route target to WAN or one VPN profile.

Required fields:
- section
- mac
- target

Recommended fields:
- ip
- hostname

Sample request:

curl -s -X POST "http://192.168.1.1/cgi-bin/luci/admin/services/vpnmanager/policy" \
  --data-urlencode "section=policy_sm_s911b" \
  --data-urlencode "hostname=SM-S911B" \
  --data-urlencode "mac=1e:95:1c:4d:d5:ac" \
  --data-urlencode "ip=192.168.1.195" \
  --data-urlencode "target=vpn_sg_01"

Success response:

{
  "ok": true
}

Typical errors:

{
  "ok": false,
  "error": "missing args"
}

{
  "ok": false,
  "error": "target profile not found: vpn_x"
}

{
  "ok": false,
  "error": "apply failed"
}

### 4.10 POST /policy_delete

Purpose:
- Remove one policy by section.

Required fields:
- section

### 4.11 GET /route_status

Purpose:
- Return route and egress IP map for WAN and profile targets.

Sample response (shape may vary by runtime):

{
  "wan": {
    "public_ip": "203.0.113.10",
    "country": "US",
    "ok": true
  },
  "vpn_sg_01": {
    "public_ip": "64.29.86.94",
    "country": "SG",
    "ok": true
  }
}

### 4.12 GET /status

Sample response:

{
  "up": 3,
  "down": 1,
  "timestamp": "2026-06-16T15:45:00Z"
}

### 4.13 GET /audit

Sample response:

{
  "lines": [
    "2026-06-16T15:30:10Z [INFO] reconcile started",
    "2026-06-16T15:30:11Z [INFO] reconcile success"
  ]
}

### 4.14 WiFi APIs

#### GET /wifi
- Read base WiFi configuration.

#### POST /wifi_set
- Update base SSID, key, encryption, channel, enabled.

Sample request:

curl -s -X POST "http://192.168.1.1/cgi-bin/luci/admin/services/vpnmanager/wifi_set" \
  --data-urlencode "ssid=MainWiFi" \
  --data-urlencode "key=Password123" \
  --data-urlencode "encryption=sae-mixed" \
  --data-urlencode "channel=6" \
  --data-urlencode "enabled=1"

#### GET /wifi_bindings
- List dedicated WiFi-over-VPN bindings.

#### POST /wifi_binding
- Create or update one binding.

Required fields:
- id
- ssid
- target

Sample request:

curl -s -X POST "http://192.168.1.1/cgi-bin/luci/admin/services/vpnmanager/wifi_binding" \
  --data-urlencode "id=guest_vpn" \
  --data-urlencode "ssid=Guest-VPN" \
  --data-urlencode "key=GuestPass123" \
  --data-urlencode "encryption=sae-mixed" \
  --data-urlencode "target=vpn_sg_01" \
  --data-urlencode "enabled=1"

#### POST /wifi_binding_delete
- Delete one WiFi binding by id.

### 4.15 MultiEbay APIs

#### GET /multiebay_settings
- Read saved integration settings.

#### POST /multiebay_settings_save
- Save api_base, api_key, allow_http_proxy.

#### POST /multiebay_settings_clear
- Remove saved API key.

#### POST /multiebay_import
- Generate and import profile from proxy or gateway.

Sample request:

curl -s -X POST "http://192.168.1.1/cgi-bin/luci/admin/services/vpnmanager/multiebay_import" \
  --data-urlencode "id=vpn_me_01" \
  --data-urlencode "api_base=https://multiebay.com" \
  --data-urlencode "api_key=YOUR_KEY" \
  --data-urlencode "proxy_url=socks5://user:pass@host:port" \
  --data-urlencode "profile_name=ME SG 01" \
  --data-urlencode "allow_http_proxy=1"

Sample success response:

{
  "ok": true,
  "id": "vpn_me_01",
  "gateway_name": "gw_123",
  "wg_name": "wg_client_123"
}

Sample integration errors:

{
  "ok": false,
  "error": "unable to validate MultiEbay API key"
}

{
  "ok": false,
  "error": "MultiEbay did not return a WireGuard config"
}

### 4.16 Apply and Rollback

#### POST /apply
- Reconcile and apply staged state.

Success:

{
  "ok": true
}

Failure:

{
  "ok": false,
  "error": "apply failed"
}

#### POST /rollback
- Roll back latest checkpoint.

## 5) End-To-End Scenarios

### Scenario A: Assign one device to VPN

1. Create or import profile.
2. Set device policy target to profile.
3. Call apply.
4. Check route_status and test profile.

### Scenario B: Emergency fallback to WAN

1. Set same policy section target to wan.
2. Call apply.
3. Verify route_status for wan egress.

### Scenario C: Dedicated Guest WiFi through VPN

1. Save or verify target profile.
2. Create wifi_binding with target profile.
3. Apply changes.
4. Connect client to that SSID and verify egress IP.

## 6) Client Implementation Recommendations

1. Use stable section ids for idempotent policy updates.
2. Always send MAC in lowercase format.
3. Send both MAC and IP whenever possible.
4. Poll devices and policies every 5 to 10 seconds.
5. Poll route_status less frequently, around 20 to 30 seconds.
6. On apply failed, fetch audit and offer rollback action.
7. Keep one-click WAN fallback in UI for incident handling.
