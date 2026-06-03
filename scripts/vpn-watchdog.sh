#!/bin/sh
set -eu

. /usr/libexec/vpn-manager/common.sh
. /usr/libexec/vpn-manager/uci.sh
. /usr/libexec/vpn-manager/health.sh
. /usr/libexec/vpn-manager/pbr.sh

vm_init_dirs

state_file="/tmp/vpn-manager/profile-states.txt"
next_state_file="/tmp/vpn-manager/profile-states.next"
rm -f "$next_state_file"
touch "$next_state_file"

for sec in $(vm_profile_list); do
    [ "$(uci -q get vpn-manager.$sec.enabled)" = "1" ] || continue
    iface="$(uci -q get vpn-manager.$sec.iface)"
    [ -n "$iface" ] || continue

    state="$(vm_profile_health "$iface" "180" || true)"
    echo "$sec $state" >> "$next_state_file"
    if [ "$state" = "down" ]; then
        vm_log "warn" "watchdog reconnect profile=$sec iface=$iface"
        vm_profile_reconnect "$iface"

        if [ "$(uci -q get vpn-manager.$sec.kill_switch)" = "1" ]; then
            nft add rule inet vpn_manager prerouting_mark iifname br-lan oifname "$iface" drop 2>/dev/null || true
            vm_log "warn" "kill-switch engaged profile=$sec"
        fi
    fi
done

if [ ! -f "$state_file" ] || ! cmp -s "$state_file" "$next_state_file"; then
    vm_log "info" "profile health state changed, refreshing pbr rules"
    vm_pbr_generate_nft && vm_pbr_apply_rules || vm_log "warn" "pbr refresh failed after health change"
fi

mv "$next_state_file" "$state_file"
