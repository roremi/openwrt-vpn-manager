#!/bin/sh

. /usr/libexec/vpn-manager/common.sh
. /usr/libexec/vpn-manager/uci.sh

vm_handshake_age() {
    local iface="$1"
    local now hs
    now="$(date +%s)"
    hs="$(wg show "$iface" latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}')"
    [ -n "$hs" ] && [ "$hs" -gt 0 ] || {
        echo "999999"
        return
    }
    echo $((now - hs))
}

vm_ping_iface() {
    local iface="$1"
    ping -I "$iface" -c 2 -W 2 1.1.1.1 >/dev/null 2>&1 && return 0
    ping6 -I "$iface" -c 2 -W 2 2606:4700:4700::1111 >/dev/null 2>&1 && return 0
    return 1
}

vm_profile_health() {
    local iface="$1"
    local max_age="${2:-180}"
    local age link_line

    ip link show dev "$iface" >/dev/null 2>&1 || {
        echo "down"
        return 2
    }

    link_line="$(ip link show dev "$iface" 2>/dev/null | head -n1)"
    echo "$link_line" | grep -q '<[^>]*UP[^>]*>' || {
        echo "down"
        return 2
    }

    age="$(vm_handshake_age "$iface")"

    if [ "$age" -le "$max_age" ]; then
        echo "healthy"
        return 0
    fi

    if vm_ping_iface "$iface"; then
        echo "degraded"
        return 1
    fi

    echo "down"
    return 2
}

vm_profile_reconnect() {
    local iface="$1"
    local sec
    sec="$(vm_profile_by_iface "$iface" || true)"

    ip link set dev "$iface" down 2>/dev/null || true
    sleep 1

    if [ -n "$sec" ]; then
        vm_wireguard_runtime_up_profile "$sec" || true
    else
        ip link set dev "$iface" up 2>/dev/null || true
    fi

    vm_log "warn" "reconnect attempted for $iface"
}
