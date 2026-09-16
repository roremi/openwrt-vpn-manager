#!/bin/sh
set -u

. /usr/libexec/vpn-manager/common.sh

VM_ROUTE_STATUS_INTERVAL="${VM_ROUTE_STATUS_INTERVAL:-60}"

vm_init_dirs

while true; do
    if /usr/libexec/rpcd/vpn-manager refresh_route_status >/dev/null 2>&1; then
        :
    else
        rc=$?
        vm_log "warn" "route status refresh failed rc=$rc"
    fi

    sleep "$VM_ROUTE_STATUS_INTERVAL"
done
