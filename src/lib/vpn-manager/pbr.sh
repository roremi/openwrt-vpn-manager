#!/bin/sh

. /usr/libexec/vpn-manager/common.sh
. /usr/libexec/vpn-manager/uci.sh

VM_NFT_FILE="/tmp/vpn-manager/vpn-manager.nft"
VM_NFT_NAT_FILE="/tmp/vpn-manager/vpn-manager-nat.nft"
VM_NFT_DNS_FILE="/tmp/vpn-manager/vpn-manager-dns.nft"
VM_NFT_DNS_GUARD_FILE="/tmp/vpn-manager/vpn-manager-dns-guard.nft"
VM_NFT_STRICT_FILE="/tmp/vpn-manager/vpn-manager-strict.nft"
VM_SRC_RULES_FILE="/tmp/vpn-manager/source-rules.txt"
VM_NFT_APPLY_FILE="/tmp/vpn-manager/vpn-manager-apply.nft"

vm_pbr_validate_profile() {
    local section="$1"
    local table_id fwmark iface

    table_id="$(uci -q get vpn-manager.$section.table_id)"
    fwmark="$(uci -q get vpn-manager.$section.fwmark)"
    iface="$(uci -q get vpn-manager.$section.iface)"

    [ -n "$table_id" ] || vm_fail "profile $section missing table_id"
    [ -n "$fwmark" ] || vm_fail "profile $section missing fwmark"
    [ -n "$iface" ] || vm_fail "profile $section missing iface"

    case "$table_id" in
        ''|*[!0-9]*) vm_fail "invalid table_id for $section" ;;
    esac

    return 0
}

vm_pbr_first_ipv4() {
    printf '%s\n' "$1" | tr ', ' '\n\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1
}

vm_pbr_wan_dns() {
    awk '
        /^# Interface wan$/ { inwan=1; next }
        /^# Interface / && inwan { exit }
        inwan && $1 == "nameserver" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2; exit }
    ' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null
}

vm_pbr_target_dns() {
    local target="$1"

    if [ "$target" = "wan" ]; then
        vm_pbr_wan_dns
    else
        vm_pbr_first_ipv4 "$(uci -q get vpn-manager.$target.dns)"
    fi
}

vm_pbr_generate_nft() {
    vm_init_dirs

    cat > "$VM_NFT_FILE" << 'EOF'
table inet vpn_manager {
    chain prerouting_mark {
        type filter hook prerouting priority mangle; policy accept;
    }
}
EOF

    cat > "$VM_NFT_NAT_FILE" << 'EOF'
table ip vpn_manager_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
    }
}
EOF

    cat > "$VM_NFT_DNS_FILE" << 'EOF'
table ip vpn_manager_dns {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
    }
}
EOF

    cat > "$VM_NFT_DNS_GUARD_FILE" << 'EOF'
table inet vpn_manager_dns_guard {
    chain prerouting {
        type filter hook prerouting priority filter; policy accept;
    }
}
EOF

    cat > "$VM_NFT_STRICT_FILE" << 'EOF'
table inet vpn_manager_strict {
    chain forward {
        type filter hook forward priority -200; policy accept;
    }
    chain mangle_mss {
        type filter hook forward priority mangle; policy accept;
    }
}
EOF

    local sec target fwmark mac ip_addr iface dns_ip
    local nat_ifaces=""
    for sec in $(uci -q show vpn-manager | sed -n 's/^vpn-manager\.\([^.=]*\)=device_policy$/\1/p'); do
        target="$(uci -q get vpn-manager.$sec.target)"
        mac="$(uci -q get vpn-manager.$sec.mac | tr '[:upper:]' '[:lower:]')"
        ip_addr="$(uci -q get vpn-manager.$sec.ip)"
        dns_ip="$(vm_pbr_target_dns "$target")"

        [ -n "$mac" ] || [ -n "$ip_addr" ] || continue

        if [ "$target" = "wan" ]; then
            fwmark="0x0"
        else
            vm_profile_exists "$target" || continue
            fwmark="$(uci -q get vpn-manager.$target.fwmark)"
            iface="$(uci -q get vpn-manager.$target.iface)"
            [ -n "$iface" ] && nat_ifaces="$nat_ifaces $iface"

            # Strict anti-leak: VPN-targeted clients must not egress via non-VPN interfaces.
            if [ -n "$iface" ]; then
                [ -n "$mac" ] && echo "add rule inet vpn_manager_strict forward iifname \"br-lan\" ether saddr $mac oifname != \"$iface\" drop" >> "$VM_NFT_STRICT_FILE"
                if echo "$ip_addr" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                    echo "add rule inet vpn_manager_strict forward iifname \"br-lan\" ip saddr $ip_addr oifname != \"$iface\" drop" >> "$VM_NFT_STRICT_FILE"
                fi
            fi

            # IPv4-only tunnels: hard-drop client IPv6 forwarding so a native IPv6
            # path can never leak the real address past the VPN.
            [ -n "$mac" ] && echo "add rule inet vpn_manager_strict forward iifname \"br-lan\" ether saddr $mac meta nfproto ipv6 drop" >> "$VM_NFT_STRICT_FILE"

        fi

        # Pin DNS of routed clients to the target DNS to avoid dnsmasq upstream leakage.
        if echo "$dns_ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            if [ -n "$mac" ]; then
                echo "add rule ip vpn_manager_dns prerouting ether saddr $mac udp dport 53 dnat to $dns_ip" >> "$VM_NFT_DNS_FILE"
                echo "add rule ip vpn_manager_dns prerouting ether saddr $mac tcp dport 53 dnat to $dns_ip" >> "$VM_NFT_DNS_FILE"
                echo "add rule inet vpn_manager_dns_guard prerouting ether saddr $mac ip daddr $dns_ip udp dport 53 accept" >> "$VM_NFT_DNS_GUARD_FILE"
                echo "add rule inet vpn_manager_dns_guard prerouting ether saddr $mac ip daddr $dns_ip tcp dport 53 accept" >> "$VM_NFT_DNS_GUARD_FILE"
                echo "add rule inet vpn_manager_dns_guard prerouting ether saddr $mac udp dport 53 drop" >> "$VM_NFT_DNS_GUARD_FILE"
                echo "add rule inet vpn_manager_dns_guard prerouting ether saddr $mac tcp dport 53 drop" >> "$VM_NFT_DNS_GUARD_FILE"
                echo "add rule inet vpn_manager_dns_guard prerouting ether saddr $mac udp dport 853 drop" >> "$VM_NFT_DNS_GUARD_FILE"
                echo "add rule inet vpn_manager_dns_guard prerouting ether saddr $mac tcp dport 853 drop" >> "$VM_NFT_DNS_GUARD_FILE"
            fi

            if echo "$ip_addr" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
                echo "add rule ip vpn_manager_dns prerouting ip saddr $ip_addr udp dport 53 dnat to $dns_ip" >> "$VM_NFT_DNS_FILE"
                echo "add rule ip vpn_manager_dns prerouting ip saddr $ip_addr tcp dport 53 dnat to $dns_ip" >> "$VM_NFT_DNS_FILE"
                echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $ip_addr ip daddr $dns_ip udp dport 53 accept" >> "$VM_NFT_DNS_GUARD_FILE"
                echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $ip_addr ip daddr $dns_ip tcp dport 53 accept" >> "$VM_NFT_DNS_GUARD_FILE"
                echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $ip_addr udp dport 53 drop" >> "$VM_NFT_DNS_GUARD_FILE"
                echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $ip_addr tcp dport 53 drop" >> "$VM_NFT_DNS_GUARD_FILE"
                echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $ip_addr udp dport 853 drop" >> "$VM_NFT_DNS_GUARD_FILE"
                echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $ip_addr tcp dport 853 drop" >> "$VM_NFT_DNS_GUARD_FILE"
            fi
        fi

        [ -n "$fwmark" ] || continue
        [ -n "$mac" ] && echo "add rule inet vpn_manager prerouting_mark iifname \"br-lan\" ether saddr $mac meta mark set $fwmark" >> "$VM_NFT_FILE"
        if echo "$ip_addr" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "add rule inet vpn_manager prerouting_mark iifname \"br-lan\" ip saddr $ip_addr meta mark set $fwmark" >> "$VM_NFT_FILE"
        fi
    done

    local wifi_sec wifi_target wifi_subnet_id wifi_subnet_cidr wifi_network
    for wifi_sec in $(vm_wifi_binding_list); do
        [ "$(uci -q get vpn-manager.$wifi_sec.enabled)" = "1" ] || continue

        wifi_target="$(uci -q get vpn-manager.$wifi_sec.target)"

        dns_ip="$(vm_pbr_target_dns "$wifi_target")"
        wifi_subnet_id="$(uci -q get vpn-manager.$wifi_sec.subnet_id)"
        wifi_subnet_cidr="$(vm_wifi_binding_subnet_cidr "$wifi_subnet_id")"

        [ -n "$wifi_subnet_id" ] || continue

        if [ "$wifi_target" = "wan" ]; then
            iface="wan"
        else
            vm_profile_exists "$wifi_target" || continue
            iface="$(uci -q get vpn-manager.$wifi_target.iface)"
        fi

        [ -n "$iface" ] || continue

        nat_ifaces="$nat_ifaces $iface"
        echo "add rule inet vpn_manager_strict forward ip saddr $wifi_subnet_cidr oifname != \"$iface\" drop" >> "$VM_NFT_STRICT_FILE"
        echo "add rule inet vpn_manager_strict forward ip saddr $wifi_subnet_cidr oifname \"$iface\" accept" >> "$VM_NFT_STRICT_FILE"

        # IPv4-only tunnels: hard-drop all IPv6 from a VPN-bound SSID bridge so the
        # dedicated WiFi cannot leak a native IPv6 address around the tunnel.
        if [ "$wifi_target" != "wan" ]; then
            wifi_network="$(uci -q get vpn-manager.$wifi_sec.network)"
            [ -n "$wifi_network" ] || wifi_network="$wifi_sec"
            echo "add rule inet vpn_manager_strict forward iifname \"br-$wifi_network\" meta nfproto ipv6 drop" >> "$VM_NFT_STRICT_FILE"
        fi

        if echo "$dns_ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "add rule ip vpn_manager_dns prerouting ip saddr $wifi_subnet_cidr udp dport 53 dnat to $dns_ip" >> "$VM_NFT_DNS_FILE"
            echo "add rule ip vpn_manager_dns prerouting ip saddr $wifi_subnet_cidr tcp dport 53 dnat to $dns_ip" >> "$VM_NFT_DNS_FILE"
            echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $wifi_subnet_cidr ip daddr $dns_ip udp dport 53 accept" >> "$VM_NFT_DNS_GUARD_FILE"
            echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $wifi_subnet_cidr ip daddr $dns_ip tcp dport 53 accept" >> "$VM_NFT_DNS_GUARD_FILE"
            echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $wifi_subnet_cidr udp dport 53 drop" >> "$VM_NFT_DNS_GUARD_FILE"
            echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $wifi_subnet_cidr tcp dport 53 drop" >> "$VM_NFT_DNS_GUARD_FILE"
            echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $wifi_subnet_cidr udp dport 853 drop" >> "$VM_NFT_DNS_GUARD_FILE"
            echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $wifi_subnet_cidr tcp dport 853 drop" >> "$VM_NFT_DNS_GUARD_FILE"
        fi
    done

    local seen_ifaces=""
    for iface in $nat_ifaces; do
        case " $seen_ifaces " in
            *" $iface "*) continue ;;
        esac
        seen_ifaces="$seen_ifaces $iface"

        echo "add rule ip vpn_manager_nat postrouting oifname \"$iface\" masquerade" >> "$VM_NFT_NAT_FILE"

        # MSS clamp to path MTU on TCP SYN crossing the tunnel. Runs in its own
        # base chain so it still applies to flows the strict chain terminally
        # accepts (e.g. dedicated WiFi). Avoids PMTUD black-holes and stops the
        # fixed WireGuard MTU from emitting oversized segments that fingerprint
        # the link as tunneled.
        echo "add rule inet vpn_manager_strict mangle_mss oifname \"$iface\" tcp flags syn tcp option maxseg size set rt mtu" >> "$VM_NFT_STRICT_FILE"
        echo "add rule inet vpn_manager_strict mangle_mss iifname \"$iface\" tcp flags syn tcp option maxseg size set rt mtu" >> "$VM_NFT_STRICT_FILE"
    done

    nft -c -f "$VM_NFT_STRICT_FILE" || vm_fail "nft strict validation failed"
    nft -c -f "$VM_NFT_FILE" || vm_fail "nft validation failed"
    nft -c -f "$VM_NFT_NAT_FILE" || vm_fail "nft nat validation failed"
    nft -c -f "$VM_NFT_DNS_FILE" || vm_fail "nft dns validation failed"
    nft -c -f "$VM_NFT_DNS_GUARD_FILE" || vm_fail "nft dns guard validation failed"
}

vm_pbr_apply_rules() {
    {
        echo "destroy table inet vpn_manager"
        echo "destroy table ip vpn_manager_nat"
        echo "destroy table ip vpn_manager_dns"
        echo "destroy table inet vpn_manager_dns_guard"
        echo "destroy table inet vpn_manager_strict"
        cat "$VM_NFT_FILE"
        cat "$VM_NFT_NAT_FILE"
        cat "$VM_NFT_DNS_FILE"
        cat "$VM_NFT_DNS_GUARD_FILE"
        cat "$VM_NFT_STRICT_FILE"
    } > "$VM_NFT_APPLY_FILE"

    # One-shot nft transaction avoids brief periods without strict anti-leak rules.
    nft -f "$VM_NFT_APPLY_FILE" || vm_fail "failed applying nft transaction"

    # Reconcile source-IP rules managed by vpn-manager to force VPN table per device IP.
    if [ -f "$VM_SRC_RULES_FILE" ]; then
        while IFS=' ' read -r src_prefix table_id; do
            [ -n "$src_prefix" ] || continue
            [ -n "$table_id" ] || continue
            while ip -4 rule del from "$src_prefix" table "$table_id" priority 9990 2>/dev/null; do :; done
        done < "$VM_SRC_RULES_FILE"
    fi

    : > "$VM_SRC_RULES_FILE"

    local pol target src_prefix src_table
    for pol in $(uci -q show vpn-manager | sed -n 's/^vpn-manager\.\([^.=]*\)=device_policy$/\1/p'); do
        target="$(uci -q get vpn-manager.$pol.target)"
        src_prefix="$(uci -q get vpn-manager.$pol.ip)"
        [ "$target" = "wan" ] && continue
        vm_profile_exists "$target" || continue
        echo "$src_prefix" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || continue

        src_table="$(uci -q get vpn-manager.$target.table_id)"
        [ -n "$src_table" ] || continue

        src_prefix="$src_prefix/32"
        ip -4 rule add from "$src_prefix" table "$src_table" priority 9990 2>/dev/null || true
        echo "$src_prefix $src_table" >> "$VM_SRC_RULES_FILE"
    done

    for wifi_sec in $(vm_wifi_binding_list); do
        [ "$(uci -q get vpn-manager.$wifi_sec.enabled)" = "1" ] || continue

        wifi_target="$(uci -q get vpn-manager.$wifi_sec.target)"
        vm_profile_exists "$wifi_target" || continue

        wifi_subnet_id="$(uci -q get vpn-manager.$wifi_sec.subnet_id)"
        wifi_subnet_cidr="$(vm_wifi_binding_subnet_cidr "$wifi_subnet_id")"
        wifi_table="$(uci -q get vpn-manager.$wifi_target.table_id)"

        [ -n "$wifi_subnet_id" ] || continue
        [ -n "$wifi_table" ] || continue

        ip -4 rule add from "$wifi_subnet_cidr" table "$wifi_table" priority 9990 2>/dev/null || true
        echo "$wifi_subnet_cidr $wifi_table" >> "$VM_SRC_RULES_FILE"
    done

    local sec table fwmark iface dns_ip
    for sec in $(vm_profile_list); do
        [ "$(uci -q get vpn-manager.$sec.enabled)" = "1" ] || continue
        table="$(uci -q get vpn-manager.$sec.table_id)"
        fwmark="$(uci -q get vpn-manager.$sec.fwmark)"
        iface="$(uci -q get vpn-manager.$sec.iface)"
        dns_ip="$(uci -q get vpn-manager.$sec.dns | awk '{print $1}')"

        ip link show dev "$iface" >/dev/null 2>&1 || {
            vm_log "warn" "skip pbr for $sec: iface $iface not found"
            continue
        }

        ip -4 rule del fwmark "$fwmark" table "$table" 2>/dev/null || true
        ip -6 rule del fwmark "$fwmark" table "$table" 2>/dev/null || true

        ip -4 rule add fwmark "$fwmark" table "$table" priority 10000
        ip -6 rule add fwmark "$fwmark" table "$table" priority 10000

        ip -4 route replace default dev "$iface" scope link table "$table" 2>/dev/null || true
        ip -6 route replace default dev "$iface" table "$table" 2>/dev/null || true

        # Keep the router's own DNS lookups for this profile on the tunnel.
        if echo "$dns_ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            ip -4 route replace "$dns_ip/32" dev "$iface" scope link 2>/dev/null || true
        fi

        # Allow only LAN <-> VPN-forwarded traffic for this interface.
        if nft list chain inet fw4 forward 2>/dev/null | grep -Fq "iifname \"br-lan\" oifname \"$iface\""; then
            :
        else
            nft insert rule inet fw4 forward iifname "br-lan" oifname "$iface" counter accept 2>/dev/null || true
        fi

        if nft list chain inet fw4 forward 2>/dev/null | grep -Fq "iifname \"$iface\" oifname \"br-lan\" ct state established,related"; then
            :
        else
            nft insert rule inet fw4 forward iifname "$iface" oifname "br-lan" ct state established,related counter accept 2>/dev/null || true
        fi

        for wifi_sec in $(vm_wifi_binding_list); do
            [ "$(uci -q get vpn-manager.$wifi_sec.enabled)" = "1" ] || continue
            [ "$(uci -q get vpn-manager.$wifi_sec.target)" = "$sec" ] || continue

            wifi_network="$(uci -q get vpn-manager.$wifi_sec.network)"
            [ -n "$wifi_network" ] || wifi_network="$wifi_sec"
            wifi_chain="forward_${wifi_network}"

            if nft list chain inet fw4 "$wifi_chain" 2>/dev/null | grep -Fq "oifname \"$iface\""; then
                :
            else
                nft insert rule inet fw4 "$wifi_chain" oifname "$iface" counter accept 2>/dev/null || true
            fi

            if nft list chain inet fw4 forward 2>/dev/null | grep -Fq "iifname \"$iface\" oifname \"br-$wifi_network\" ct state established,related"; then
                :
            else
                nft insert rule inet fw4 forward iifname "$iface" oifname "br-$wifi_network" ct state established,related counter accept 2>/dev/null || true
            fi
        done

    done

    # Clear route cache so new source rules and marks take effect immediately.
    ip -4 route flush cache 2>/dev/null || true

    vm_log "info" "pbr rules updated"
}
