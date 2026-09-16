#!/bin/sh

VM_LIB_DIR="${VM_LIB_DIR:-/usr/libexec/vpn-manager}"
. "$VM_LIB_DIR/common.sh"
. "$VM_LIB_DIR/uci.sh"

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

vm_profile_health_from_age() {
    local iface="$1"
    local age="$2"
    local max_age="${3:-180}"
    local probe="${4:-1}"
    local link_line

    ip link show dev "$iface" >/dev/null 2>&1 || {
        echo "down"
        return 2
    }

    link_line="$(ip link show dev "$iface" 2>/dev/null | head -n1)"
    echo "$link_line" | grep -q '<[^>]*UP[^>]*>' || {
        echo "down"
        return 2
    }

    if [ "$age" -le "$max_age" ]; then
        echo "healthy"
        return 0
    fi

    # Periodic sweeps use the WireGuard handshake only. Serial ping fallbacks
    # can otherwise turn 100 unreachable profiles into a many-minute monitor
    # pass. Explicit profile tests still opt into the active probe.
    if [ "$probe" != "1" ]; then
        echo "down"
        return 2
    fi

    if vm_ping_iface "$iface"; then
        echo "degraded"
        return 1
    fi

    echo "down"
    return 2
}

vm_profile_health() {
    local iface="$1"
    local max_age="${2:-180}"
    local age

    age="$(vm_handshake_age "$iface")"
    vm_profile_health_from_age "$iface" "$age" "$max_age"
}

vm_health_snapshot_line() {
    local section="$1"
    [ -f "$VM_STATE_DIR/health-snapshot.txt" ] || return 1
    awk -F'|' -v section="$section" '$1 == section { line=$0 } END { if (line != "") print line; else exit 1 }' \
        "$VM_STATE_DIR/health-snapshot.txt"
}

vm_profile_health_cached() {
    local line
    line="$(vm_health_snapshot_line "$1" 2>/dev/null || true)"
    [ -n "$line" ] || {
        echo unknown
        return
    }
    printf '%s\n' "$line" | awk -F'|' '{print $3}'
}

vm_profile_handshake_age_cached() {
    local line
    line="$(vm_health_snapshot_line "$1" 2>/dev/null || true)"
    [ -n "$line" ] || {
        echo 999999
        return
    }
    printf '%s\n' "$line" | awk -F'|' '{print $4}'
}

vm_profile_reconnect() {
    local iface="$1"
    local sec="${2:-}"

    # The monitor already has the profile/iface pair in its health snapshot.
    # Accepting it here avoids scanning the complete UCI configuration for
    # every reconnect attempt while preserving the old caller contract.
    [ -n "$sec" ] || sec="$(vm_profile_by_iface "$iface" || true)"

    ip link set dev "$iface" down 2>/dev/null || true
    sleep 1

    if [ -n "$sec" ]; then
        vm_wireguard_runtime_up_profile "$sec" || true
    else
        ip link set dev "$iface" up 2>/dev/null || true
    fi

    vm_log "warn" "reconnect attempted for $iface"
}
