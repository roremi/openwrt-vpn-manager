#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$TEST_DIR/../lib/testlib.sh"

ROOT_DIR="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
rpc_file="$ROOT_DIR/src/rpcd/vpn-manager.sh"
uci_file="$ROOT_DIR/src/lib/vpn-manager/uci.sh"
worker_file="$ROOT_DIR/scripts/vpn-apply-worker.sh"
dashboard_file="$ROOT_DIR/src/www/vpnmanager-dashboard.html"

grep -Fq "vm_wifi_binding_network_name" "$rpc_file" ||
    fail "dedicated WiFi does not use an isolated short network name"
grep -Fq "vm_wifi_binding_wireless_section" "$rpc_file" ||
    fail "dedicated WiFi does not use an isolated wireless section"
grep -Fq 'vpn_manager=1' "$rpc_file" ||
    fail "dedicated WiFi resources are not ownership-marked"
grep -Fq 'resource conflicts with existing' "$rpc_file" ||
    fail "dedicated WiFi does not reject UCI section collisions"
grep -Fq 'VM_NETWORK_CHANGE_CHECKPOINT' "$rpc_file" ||
    fail "dedicated WiFi mutation has no pre-change safety checkpoint"
grep -Fq "valid_bridge_network" "$uci_file" ||
    fail "dedicated WiFi bridge names have no separate validation"
grep -Fq "length(value) <= 12" "$uci_file" ||
    fail "dedicated WiFi network names are not bounded for br- IFNAMSIZ"

network_line="$(grep -nF 'ubus call network reload' "$worker_file" | head -n1 | cut -d: -f1)"
wifi_line="$(grep -nF 'wifi reload' "$worker_file" | head -n1 | cut -d: -f1)"
[ -n "$network_line" ] && [ -n "$wifi_line" ] && [ "$network_line" -lt "$wifi_line" ] ||
    fail "network must reload before WiFi attaches the new virtual AP"
grep -Fq 'vm_apply_network_rollback' "$worker_file" ||
    fail "unsafe dedicated WiFi changes have no automatic rollback"
grep -Fq 'vm_apply_dedicated_networks_ready' "$worker_file" ||
    fail "dedicated WiFi runtime is not checked after reload"
grep -Fq 'wifi_networks[network] = 1' "$uci_file" ||
    fail "dedicated WiFi interface is not protected from orphan cleanup"
grep -Fq 'wifi_networks[network "_dev"] = 1' "$uci_file" ||
    fail "dedicated WiFi bridge device is not protected from orphan cleanup"
grep -Fq 'post-reconcile network check failed' "$worker_file" ||
    fail "dedicated WiFi is not rechecked after reconcile"
grep -Fq 'id="wifi-binding-save-button"' "$dashboard_file" ||
    fail "dedicated WiFi save button cannot be gated during apply"
grep -Fq 'wifiBindingButton.disabled = isPending' "$dashboard_file" ||
    fail "dedicated WiFi permits overlapping network applies"

echo "dedicated WiFi management safety guards: ok"
