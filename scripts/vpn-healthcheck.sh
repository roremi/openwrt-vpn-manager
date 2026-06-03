#!/bin/sh
set -eu

. /usr/libexec/vpn-manager/common.sh
. /usr/libexec/vpn-manager/uci.sh
. /usr/libexec/vpn-manager/health.sh

vm_init_dirs

for sec in $(vm_profile_list); do
    [ "$(uci -q get vpn-manager.$sec.enabled)" = "1" ] || continue
    iface="$(uci -q get vpn-manager.$sec.iface)"
    [ -n "$iface" ] || continue

    state="$(vm_profile_health "$iface" "180" || true)"
    echo "$(vm_now) profile=$sec iface=$iface state=$state" >> /tmp/vpn-manager/health.log

    if [ "$state" = "down" ]; then
        vm_log "warn" "health down profile=$sec iface=$iface"
    fi
done
