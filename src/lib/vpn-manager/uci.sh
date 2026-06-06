#!/bin/sh

. /usr/libexec/vpn-manager/common.sh

vm_checkpoint_create() {
    vm_init_dirs
    local ts
    ts="$(date +%s)"
    local base="$VM_STATE_DIR/checkpoint-$ts"

    uci export network > "$base.network.uci" 2>/dev/null || true
    uci export firewall > "$base.firewall.uci" 2>/dev/null || true
    uci export "$VM_CFG" > "$base.vpn-manager.uci" 2>/dev/null || true
    nft list ruleset > "$base.ruleset.nft" 2>/dev/null || true

    echo "$base" > "$VM_STATE_DIR/latest.checkpoint"
    vm_log "info" "checkpoint created: $base"
    echo "$base"
}

vm_checkpoint_last() {
    [ -f "$VM_STATE_DIR/latest.checkpoint" ] || return 1
    cat "$VM_STATE_DIR/latest.checkpoint"
}

vm_checkpoint_rollback() {
    local base="${1:-$(vm_checkpoint_last)}"
    [ -n "$base" ] || vm_fail "no checkpoint available"

    [ -f "$base.network.uci" ] && uci import network < "$base.network.uci"
    [ -f "$base.firewall.uci" ] && uci import firewall < "$base.firewall.uci"
    [ -f "$base.vpn-manager.uci" ] && uci import "$VM_CFG" < "$base.vpn-manager.uci"

    uci commit network
    uci commit firewall
    uci commit "$VM_CFG"

    /etc/init.d/network reload
    /etc/init.d/firewall reload

    vm_log "warn" "rolled back to checkpoint: $base"
}

vm_profile_list() {
    uci -q show "$VM_CFG" | sed -n 's/^vpn-manager\.\([^.=]*\)=profile$/\1/p'
}

vm_global_ensure() {
    uci -q get "$VM_CFG.global" >/dev/null 2>&1 || uci set "$VM_CFG.global=global"
}

vm_global_get() {
    uci -q get "$VM_CFG.global.$1"
}

vm_global_set() {
    uci set "$VM_CFG.global.$1=$2"
}

vm_profile_by_iface() {
    local iface="$1"
    local sec
    for sec in $(vm_profile_list); do
        [ "$(uci -q get "$VM_CFG.$sec.iface")" = "$iface" ] && {
            echo "$sec"
            return 0
        }
    done
    return 1
}

vm_profile_exists() {
    uci -q get "$VM_CFG.$1" >/dev/null 2>&1
}

vm_profile_set() {
    local section="$1"
    local key="$2"
    local value="$3"
    uci set "$VM_CFG.$section.$key=$value"
}

vm_profile_add() {
    local section="$1"
    uci set "$VM_CFG.$section=profile"
    uci set "$VM_CFG.$section.enabled=1"
}

vm_iface_name_for_section() {
    local section="$1"
    local compact
    compact="$(echo "$section" | sed 's/[^a-zA-Z0-9]//g' | tr 'A-Z' 'a-z' | cut -c1-11)"
    [ -n "$compact" ] || compact="auto"
    printf 'wg_%s' "$compact"
}

vm_profile_next_table_id() {
    local used id
    used="$(uci -q show "$VM_CFG" | sed -n 's/^vpn-manager\.[^.]*\.table_id=\(.*\)$/\1/p' | tr -d "'")"
    id=101
    while [ "$id" -le 250 ]; do
        echo "$used" | grep -qx "$id" || {
            echo "$id"
            return 0
        }
        id=$((id + 1))
    done
    echo 250
}

vm_profile_fwmark_for_table() {
    local table_id="$1"
    printf '0x%x' "$table_id"
}

vm_wireguard_sync_profile() {
    local section="$1"
    local iface private_key address mtu dns pubkey psk endpoint_host endpoint_port allowed_ips keepalive
    iface="$(uci -q get "$VM_CFG.$section.iface")"
    private_key="$(uci -q get "$VM_CFG.$section.private_key")"
    address="$(uci -q get "$VM_CFG.$section.address")"
    mtu="$(uci -q get "$VM_CFG.$section.mtu")"
    dns="$(uci -q get "$VM_CFG.$section.dns")"
    pubkey="$(uci -q get "$VM_CFG.$section.public_key")"
    psk="$(uci -q get "$VM_CFG.$section.preshared_key")"
    endpoint_host="$(uci -q get "$VM_CFG.$section.endpoint_host")"
    endpoint_port="$(uci -q get "$VM_CFG.$section.endpoint_port")"
    allowed_ips="$(uci -q get "$VM_CFG.$section.allowed_ips")"
    keepalive="$(uci -q get "$VM_CFG.$section.persistent_keepalive")"

    [ -n "$iface" ] || return 1

    uci -q delete "network.$iface"
    uci set "network.$iface=interface"
    uci set "network.$iface.proto=wireguard"
    uci set "network.$iface.defaultroute=0"
    [ -n "$private_key" ] && uci set "network.$iface.private_key=$private_key"
    [ -n "$mtu" ] && uci set "network.$iface.mtu=$mtu"
    [ -n "$dns" ] && uci add_list "network.$iface.dns=$dns"
    [ -n "$address" ] && uci add_list "network.$iface.addresses=$address"

    uci -q delete "network.${iface}_peer"
    uci set "network.${iface}_peer=wireguard_${iface}"
    [ -n "$pubkey" ] && uci set "network.${iface}_peer.public_key=$pubkey"
    [ -n "$psk" ] && uci set "network.${iface}_peer.preshared_key=$psk"
    [ -n "$endpoint_host" ] && uci set "network.${iface}_peer.endpoint_host=$endpoint_host"
    [ -n "$endpoint_port" ] && uci set "network.${iface}_peer.endpoint_port=$endpoint_port"
    [ -n "$keepalive" ] && uci set "network.${iface}_peer.persistent_keepalive=$keepalive"
    [ -n "$allowed_ips" ] && uci add_list "network.${iface}_peer.allowed_ips=$allowed_ips"
    uci set "network.${iface}_peer.route_allowed_ips=0"
}

vm_wireguard_sync_all() {
    local sec
    for sec in $(vm_profile_list); do
        [ "$(uci -q get "$VM_CFG.$sec.enabled")" = "1" ] || continue
        vm_wireguard_sync_profile "$sec"
    done
}

vm_wireguard_runtime_up_profile() {
    local section="$1"
    local iface private_key address mtu pubkey psk endpoint_host endpoint_port allowed_ips keepalive keyfile pskfile endpoint

    iface="$(uci -q get "$VM_CFG.$section.iface")"
    private_key="$(uci -q get "$VM_CFG.$section.private_key")"
    address="$(uci -q get "$VM_CFG.$section.address")"
    mtu="$(uci -q get "$VM_CFG.$section.mtu")"
    pubkey="$(uci -q get "$VM_CFG.$section.public_key")"
    psk="$(uci -q get "$VM_CFG.$section.preshared_key")"
    endpoint_host="$(uci -q get "$VM_CFG.$section.endpoint_host")"
    endpoint_port="$(uci -q get "$VM_CFG.$section.endpoint_port")"
    allowed_ips="$(uci -q get "$VM_CFG.$section.allowed_ips")"
    keepalive="$(uci -q get "$VM_CFG.$section.persistent_keepalive")"

    [ -n "$iface" ] || return 1

    mkdir -p "$VM_STATE_DIR/keys"
    keyfile="$VM_STATE_DIR/keys/$iface.key"
    pskfile="$VM_STATE_DIR/keys/$iface.psk"
    endpoint="${endpoint_host}:${endpoint_port}"

    [ -n "$private_key" ] && { printf '%s\n' "$private_key" > "$keyfile"; chmod 600 "$keyfile"; }
    [ -n "$psk" ] && { printf '%s\n' "$psk" > "$pskfile"; chmod 600 "$pskfile"; }

    ip link show dev "$iface" >/dev/null 2>&1 || ip link add dev "$iface" type wireguard
    [ -n "$private_key" ] && wg set "$iface" private-key "$keyfile"
    [ -n "$mtu" ] && ip link set dev "$iface" mtu "$mtu" || true
    [ -n "$address" ] && ip addr replace "$address" dev "$iface"

    if [ -n "$pubkey" ]; then
        if [ -n "$psk" ]; then
            wg set "$iface" peer "$pubkey" preshared-key "$pskfile" endpoint "$endpoint" persistent-keepalive "$keepalive" allowed-ips "$allowed_ips"
        else
            wg set "$iface" peer "$pubkey" endpoint "$endpoint" persistent-keepalive "$keepalive" allowed-ips "$allowed_ips"
        fi
    fi

    ip link set dev "$iface" up
}

vm_wireguard_runtime_up_all() {
    local sec
    for sec in $(vm_profile_list); do
        [ "$(uci -q get "$VM_CFG.$sec.enabled")" = "1" ] || continue
        vm_wireguard_runtime_up_profile "$sec"
    done
}

vm_profile_delete() {
    local section="$1"
    uci -q delete "$VM_CFG.$section"
}

vm_policy_set_device_target() {
    local section="$1"
    local mac="$2"
    local ip="$3"
    local hostname="$4"
    local target="$5"

    uci set "$VM_CFG.$section=device_policy"
    uci set "$VM_CFG.$section.mac=$mac"
    uci set "$VM_CFG.$section.ip=$ip"
    uci set "$VM_CFG.$section.hostname=$hostname"
    uci set "$VM_CFG.$section.target=$target"
    uci set "$VM_CFG.$section.enabled=1"
}

vm_wifi_profile_list() {
    uci -q show "$VM_CFG" | sed -n 's/^vpn-manager\.\([^.=]*\)=wifi_profile$/\1/p'
}

vm_wifi_profile_exists() {
    uci -q get "$VM_CFG.$1" >/dev/null 2>&1
}

vm_wifi_profile_next_subnet_id() {
    local used id
    used="$(uci -q show "$VM_CFG" | sed -n 's/^vpn-manager\.[^.]*\.subnet_id=\(.*\)$/\1/p' | tr -d "'")"
    id=20
    while [ "$id" -le 250 ]; do
        echo "$used" | grep -qx "$id" || {
            echo "$id"
            return 0
        }
        id=$((id + 1))
    done
    echo 250
}

vm_wifi_profile_subnet_cidr() {
    local subnet_id="$1"
    printf '10.77.%s.0/24' "$subnet_id"
}

vm_commit_all() {
    uci commit "$VM_CFG"
    uci commit network
    uci commit firewall
}
