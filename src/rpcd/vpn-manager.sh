#!/bin/sh

. /usr/libexec/vpn-manager/common.sh
. /usr/libexec/vpn-manager/uci.sh
. /usr/libexec/vpn-manager/health.sh

json_escape() {
    echo "$1" | sed 's/"/\\"/g'
}

list_profiles() {
    printf '{"profiles":['
    first=1
    for sec in $(vm_profile_list); do
        [ $first -eq 1 ] || printf ','
        first=0
        name="$(uci -q get vpn-manager.$sec.name)"
        iface="$(uci -q get vpn-manager.$sec.iface)"
        endpoint="$(uci -q get vpn-manager.$sec.endpoint_host):$(uci -q get vpn-manager.$sec.endpoint_port)"
        enabled="$(uci -q get vpn-manager.$sec.enabled)"
        address="$(uci -q get vpn-manager.$sec.address)"
        dns="$(uci -q get vpn-manager.$sec.dns)"
        allowed_ips="$(uci -q get vpn-manager.$sec.allowed_ips)"
        mtu="$(uci -q get vpn-manager.$sec.mtu)"
        keepalive="$(uci -q get vpn-manager.$sec.persistent_keepalive)"
        public_key="$(uci -q get vpn-manager.$sec.public_key)"
        status="$(vm_profile_health "$iface" "180" || true)"
        hs_age="$(vm_handshake_age "$iface")"
        printf '{"id":"%s","name":"%s","iface":"%s","endpoint":"%s","enabled":"%s","status":"%s","handshake_age":"%s","address":"%s","dns":"%s","allowed_ips":"%s","mtu":"%s","persistent_keepalive":"%s","public_key":"%s"}' \
            "$sec" "$(json_escape "$name")" "$iface" "$endpoint" "$enabled" "$status" "$hs_age" "$(json_escape "$address")" "$(json_escape "$dns")" "$(json_escape "$allowed_ips")" "$mtu" "$keepalive" "$(json_escape "$public_key")"
    done
    printf ']}'
}

list_devices() {
    local tmp
    tmp="/tmp/vpn-manager/devices.$$"

    {
        awk '{print "dhcp|"$3"|"tolower($2)"|"$4"|unknown"}' /tmp/dhcp.leases 2>/dev/null
        ip neigh show dev br-lan 2>/dev/null | awk '
            /lladdr/ {
                ip=$1; mac=""; st="unknown";
                for (i=1; i<=NF; i++) {
                    if ($i=="lladdr" && (i+1)<=NF) { mac=tolower($(i+1)); }
                }
                st=$NF;
                if (ip ~ /^[0-9]+\./ && mac != "" && mac != "00:00:00:00:00:00") {
                    print "neigh|" ip "|" mac "|unknown|" st;
                }
            }
        '
    } | awk -F'\|' '
        NF>=5 {
            src=$1; ip=$2; mac=tolower($3); host=$4; st=tolower($5);
            if (mac == "" || ip == "") next;
            if (!(mac in ip_by_mac) || source_by_mac[mac] == "arp") {
                ip_by_mac[mac]=ip;
            }

            if (src == "dhcp") {
                source_by_mac[mac]="dhcp";
            } else if (!(mac in source_by_mac)) {
                source_by_mac[mac]="arp";
            }

            if (host != "" && host != "*" && host != "unknown") {
                host_by_mac[mac]=host;
            }

            if (st != "" && st != "unknown") {
                state_by_mac[mac]=st;
            }
        }
        END {
            for (mac in ip_by_mac) {
                host=(mac in host_by_mac)?host_by_mac[mac]:"unknown";
                st=(mac in state_by_mac)?state_by_mac[mac]:"unknown";
                conn=((st=="reachable" || st=="delay" || st=="probe" || st=="permanent")?"true":"false");
                print ip_by_mac[mac] "|" mac "|" host "|" st "|" conn;
            }
        }
    ' | sort -t '|' -k1,1V > "$tmp"

    printf '{"devices":['
    first=1
    while IFS='|' read -r ip mac host st conn; do
        [ -n "$ip" ] || continue
        [ $first -eq 1 ] || printf ','
        first=0
        [ -n "$host" ] || host="unknown"
        [ "$conn" = "true" ] || conn="false"
        printf '{"ip":"%s","mac":"%s","hostname":"%s","state":"%s","connected":%s}' "$ip" "$mac" "$(json_escape "$host")" "$st" "$conn"
    done < "$tmp"
    printf ']}'

    rm -f "$tmp" 2>/dev/null || true
}

list_policies() {
    printf '{"policies":['
    first=1
    for sec in $(uci -q show vpn-manager | sed -n 's/^vpn-manager\.\([^.=]*\)=device_policy$/\1/p'); do
        [ $first -eq 1 ] || printf ','
        first=0
        printf '{"section":"%s","hostname":"%s","mac":"%s","ip":"%s","target":"%s"}' \
            "$sec" \
            "$(json_escape "$(uci -q get vpn-manager.$sec.hostname)")" \
            "$(uci -q get vpn-manager.$sec.mac)" \
            "$(uci -q get vpn-manager.$sec.ip)" \
            "$(uci -q get vpn-manager.$sec.target)"
    done
    printf ']}'
}

status() {
    up=0
    down=0
    for sec in $(vm_profile_list); do
        iface="$(uci -q get vpn-manager.$sec.iface)"
        s="$(vm_profile_health "$iface" "180" || true)"
        if [ "$s" = "healthy" ]; then
            up=$((up + 1))
        else
            down=$((down + 1))
        fi
    done
    printf '{"up":%s,"down":%s,"timestamp":"%s"}' "$up" "$down" "$(vm_now)"
}

apply_changes() {
    /usr/libexec/vpn-manager/reconcile.sh >/dev/null 2>&1 || {
        echo '{"ok":false,"error":"apply failed"}'
        return
    }
    echo '{"ok":true}'
}

rollback_changes() {
    /usr/libexec/vpn-manager/rollback.sh last >/dev/null 2>&1 || {
        echo '{"ok":false}'
        return
    }
    echo '{"ok":true}'
}

audit_log() {
    tail -n 200 /var/log/vpn-manager/audit.log 2>/dev/null | sed 's/"/\\"/g' | awk 'BEGIN {print "{\"lines\":["} {if (NR>1) printf ","; printf "\"%s\"", $0} END {print "]}"}'
}

toggle_profile() {
    sec="$2"
    enabled="$3"
    vm_profile_exists "$sec" || {
        echo '{"ok":false,"error":"profile not found"}'
        return
    }
    [ "$enabled" = "0" ] || enabled="1"
    vm_profile_set "$sec" "enabled" "$enabled"
    uci commit vpn-manager
    echo '{"ok":true}'
}

set_policy() {
    section="$2"
    mac="$3"
    ip="$4"
    hostname="$5"
    target="$6"
    [ -n "$section" ] && [ -n "$mac" ] && [ -n "$target" ] || {
        echo '{"ok":false,"error":"missing args"}'
        return
    }

    if [ "$target" != "wan" ] && ! vm_profile_exists "$target"; then
        mapped_target="$(vm_profile_by_iface "$target" 2>/dev/null || true)"
        if [ -n "$mapped_target" ]; then
            target="$mapped_target"
        else
            printf '{"ok":false,"error":"target profile not found: %s"}' "$(json_escape "$target")"
            return
        fi
    fi

    vm_policy_set_device_target "$section" "$mac" "$ip" "$hostname" "$target"
    uci commit vpn-manager

    if /usr/libexec/vpn-manager/reconcile.sh >/dev/null 2>&1; then
        :
    else
        echo '{"ok":false,"error":"apply failed"}'
        return
    fi

    echo '{"ok":true}'
}

set_profile() {
    sec="$2"
    name="$3"
    endpoint_host="$4"
    endpoint_port="$5"
    public_key="$6"
    private_key="$7"
    address="$8"
    dns="$9"
    allowed_ips="${10}"
    mtu="${11}"
    keepalive="${12}"
    enabled="${13}"
    preshared_key="${14}"

    [ -n "$sec" ] || {
        echo '{"ok":false,"error":"missing profile id"}'
        return
    }

    if vm_profile_exists "$sec"; then
        :
    else
        vm_profile_add "$sec"
        vm_profile_set "$sec" "iface" "$(vm_iface_name_for_section "$sec")"
        table_id="$(vm_profile_next_table_id)"
        vm_profile_set "$sec" "table_id" "$table_id"
        vm_profile_set "$sec" "fwmark" "$(vm_profile_fwmark_for_table "$table_id")"
        vm_profile_set "$sec" "kill_switch" "0"
    fi

    [ -n "$name" ] && vm_profile_set "$sec" "name" "$name" || vm_profile_set "$sec" "name" "$sec"
    [ -n "$endpoint_host" ] && vm_profile_set "$sec" "endpoint_host" "$endpoint_host"
    [ -n "$endpoint_port" ] && vm_profile_set "$sec" "endpoint_port" "$endpoint_port"
    [ -n "$public_key" ] && vm_profile_set "$sec" "public_key" "$public_key"
    [ -n "$private_key" ] && vm_profile_set "$sec" "private_key" "$private_key"
    [ -n "$address" ] && vm_profile_set "$sec" "address" "$address"
    [ -n "$dns" ] && vm_profile_set "$sec" "dns" "$dns"
    [ -n "$mtu" ] && vm_profile_set "$sec" "mtu" "$mtu"
    [ -n "$keepalive" ] && vm_profile_set "$sec" "persistent_keepalive" "$keepalive"
    [ -n "$preshared_key" ] && vm_profile_set "$sec" "preshared_key" "$preshared_key"

    if [ -n "$allowed_ips" ]; then
        uci -q delete "vpn-manager.$sec.allowed_ips"
        IFS=','
        for cidr in $allowed_ips; do
            cidr_trim="$(echo "$cidr" | xargs)"
            [ -n "$cidr_trim" ] && uci add_list "vpn-manager.$sec.allowed_ips=$cidr_trim"
        done
        unset IFS
    fi

    [ "$enabled" = "0" ] && vm_profile_set "$sec" "enabled" "0" || vm_profile_set "$sec" "enabled" "1"

    vm_wireguard_sync_profile "$sec"
    uci commit vpn-manager
    uci commit network
    echo '{"ok":true}'
}

delete_profile() {
    sec="$2"
    [ -n "$sec" ] || {
        echo '{"ok":false,"error":"missing profile id"}'
        return
    }

    vm_profile_exists "$sec" || {
        echo '{"ok":false,"error":"profile not found"}'
        return
    }

    iface="$(uci -q get vpn-manager.$sec.iface)"
    vm_profile_delete "$sec"
    [ -n "$iface" ] && uci -q delete "network.$iface"
    [ -n "$iface" ] && uci -q delete "network.${iface}_peer"

    uci commit vpn-manager
    uci commit network
    echo '{"ok":true}'
}

delete_policy() {
    section="$2"
    [ -n "$section" ] || {
        echo '{"ok":false,"error":"missing section"}'
        return
    }

    uci -q get "vpn-manager.$section" >/dev/null 2>&1 || {
        echo '{"ok":false,"error":"policy not found"}'
        return
    }

    uci -q delete "vpn-manager.$section"
    uci commit vpn-manager
    echo '{"ok":true}'
}

test_profile() {
    sec="$2"
    vm_profile_exists "$sec" || {
        echo '{"ok":false,"error":"profile not found"}'
        return
    }
    iface="$(uci -q get vpn-manager.$sec.iface)"
    state="$(vm_profile_health "$iface" "180" || true)"
    if ping -I "$iface" -c 3 -W 2 1.1.1.1 >/tmp/vpn-manager/ping.$$ 2>&1; then
        rtt="$(awk -F'/' '/rtt/ {print $5" ms"}' /tmp/vpn-manager/ping.$$)"
    else
        rtt="n/a"
    fi
    rm -f /tmp/vpn-manager/ping.$$ 2>/dev/null || true
    printf '{"ok":true,"state":"%s","latency":"%s"}' "$state" "$rtt"
}

import_profile() {
    sec="$2"
    conf_file="$3"
    [ -f "$conf_file" ] || {
        echo '{"ok":false,"error":"conf file not found"}'
        return
    }
    vm_profile_add "$sec"

    pk="$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "$conf_file" | head -n1)"
    pub="$(sed -n 's/^PublicKey[[:space:]]*=[[:space:]]*//p' "$conf_file" | head -n1)"
    psk="$(sed -n 's/^PresharedKey[[:space:]]*=[[:space:]]*//p' "$conf_file" | head -n1)"
    endpoint="$(sed -n 's/^Endpoint[[:space:]]*=[[:space:]]*//p' "$conf_file" | head -n1)"
    allowed="$(sed -n 's/^AllowedIPs[[:space:]]*=[[:space:]]*//p' "$conf_file" | head -n1)"
    address="$(sed -n 's/^Address[[:space:]]*=[[:space:]]*//p' "$conf_file" | head -n1)"
    mtu="$(sed -n 's/^MTU[[:space:]]*=[[:space:]]*//p' "$conf_file" | head -n1)"
    dns="$(sed -n 's/^DNS[[:space:]]*=[[:space:]]*//p' "$conf_file" | head -n1)"
    keepalive="$(sed -n 's/^PersistentKeepalive[[:space:]]*=[[:space:]]*//p' "$conf_file" | head -n1)"

    host="${endpoint%:*}"
    port="${endpoint##*:}"

    old_iface="$(uci -q get vpn-manager.$sec.iface)"
    new_iface="$(vm_iface_name_for_section "$sec")"
    table_id="$(vm_profile_next_table_id)"
    fwmark="$(vm_profile_fwmark_for_table "$table_id")"
    [ -n "$old_iface" ] && [ "$old_iface" != "$new_iface" ] && uci -q delete "network.$old_iface"

    vm_profile_set "$sec" name "$sec"
    vm_profile_set "$sec" iface "$new_iface"
    vm_profile_set "$sec" private_key "$pk"
    vm_profile_set "$sec" public_key "$pub"
    [ -n "$psk" ] && vm_profile_set "$sec" preshared_key "$psk"
    vm_profile_set "$sec" endpoint_host "$host"
    vm_profile_set "$sec" endpoint_port "$port"
    [ -n "$address" ] && vm_profile_set "$sec" address "$address"
    [ -n "$mtu" ] && vm_profile_set "$sec" mtu "$mtu"
    [ -n "$dns" ] && vm_profile_set "$sec" dns "$dns"
    [ -n "$keepalive" ] && vm_profile_set "$sec" persistent_keepalive "$keepalive"
    vm_profile_set "$sec" table_id "$table_id"
    vm_profile_set "$sec" fwmark "$fwmark"
    vm_profile_set "$sec" kill_switch "0"

    uci -q delete "vpn-manager.$sec.allowed_ips"
    IFS=','
    for cidr in $allowed; do
        uci add_list "vpn-manager.$sec.allowed_ips=$(echo "$cidr" | xargs)"
    done
    unset IFS

    vm_wireguard_sync_profile "$sec"
    uci commit vpn-manager
    uci commit network
    echo '{"ok":true}'
}

case "$1" in
    list_profiles) list_profiles ;;
    list_devices) list_devices ;;
    list_policies) list_policies ;;
    status) status ;;
    audit_log) audit_log ;;
    toggle_profile) toggle_profile "$@" ;;
    set_policy) set_policy "$@" ;;
    delete_policy) delete_policy "$@" ;;
    set_profile) set_profile "$@" ;;
    delete_profile) delete_profile "$@" ;;
    test_profile) test_profile "$@" ;;
    import_profile) import_profile "$@" ;;
    apply) apply_changes ;;
    rollback) rollback_changes ;;
    *) echo '{"error":"unsupported method"}' ;;
esac
