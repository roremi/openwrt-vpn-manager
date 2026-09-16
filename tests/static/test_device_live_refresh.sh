#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
dashboard="$REPO_ROOT/src/www/vpnmanager-dashboard.html"
rpc="$REPO_ROOT/src/rpcd/vpn-manager.sh"

grep -q 'const DEVICE_POLL_MS = 5000;' "$dashboard"
grep -q "activeTab !== 'devices'" "$dashboard"
grep -q 'scheduleDevicePoll(0);' "$dashboard"
grep -q 'signature === cachedDevicesSignature' "$dashboard"
grep -q "ubus list 'hostapd\.\*'" "$rpc"
grep -q 'dev ~ /\^br-/' "$rpc"
grep -q 'st=="stale"' "$rpc"

echo "ok: device live refresh is bounded, tab-aware, and association-aware"
