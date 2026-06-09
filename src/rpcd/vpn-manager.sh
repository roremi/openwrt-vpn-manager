#!/bin/sh

. /usr/libexec/vpn-manager/common.sh
. /usr/libexec/vpn-manager/uci.sh
. /usr/libexec/vpn-manager/health.sh

json_escape() {
    echo "$1" | sed 's/"/\\"/g'
}

http_json_request() {
    method="$1"
    url="$2"
    api_key="$3"
    body="${4:-}"
    headers_file="$VM_STATE_DIR/http-headers.$$"
    body_file="$VM_STATE_DIR/http-body.$$"

    vm_init_dirs
    rm -f "$headers_file" "$body_file"

    if [ -n "$body" ]; then
        curl -sS -X "$method" \
            -H "x-api-key: $api_key" \
            -H "Content-Type: application/json" \
            --data "$body" \
            -D "$headers_file" \
            -o "$body_file" \
            "$url" >/dev/null 2>&1 || {
            rm -f "$headers_file" "$body_file"
            return 1
        }
    else
        curl -sS -X "$method" \
            -H "x-api-key: $api_key" \
            -D "$headers_file" \
            -o "$body_file" \
            "$url" >/dev/null 2>&1 || {
            rm -f "$headers_file" "$body_file"
            return 1
        }
    fi

    status_code="$(awk 'toupper($1) ~ /^HTTP\// { code=$2 } END { print code }' "$headers_file")"
    body_text="$(cat "$body_file" 2>/dev/null || true)"
    rm -f "$headers_file" "$body_file"

    case "$status_code" in
        2*) printf '%s' "$body_text" ;;
        *)
            error_msg="$(printf '%s' "$body_text" | jq -r '.error // .message // .detail // empty' 2>/dev/null || true)"
            [ -n "$error_msg" ] || error_msg="HTTP ${status_code:-000} request failed"
            echo "$error_msg" >&2
            return 1
            ;;
    esac
}

multiebay_pick_gateway_name() {
    jq -r '[
        .name,
        .gateway_name,
        .gatewayName,
        (if (.gateway | type) == "string" then .gateway else empty end),
        .gateway.name,
        .data.name,
        .data.gateway_name,
        .data.gatewayName,
        (if (.data.gateway | type) == "string" then .data.gateway else empty end),
        .data.gateway.name,
        .result.name,
        .result.gateway_name,
        .result.gatewayName,
        (if (.result.gateway | type) == "string" then .result.gateway else empty end),
        .result.gateway.name
    ] | map(select(type == "string" and length > 0)) | .[0] // ""' 2>/dev/null
}

multiebay_pick_wg_name() {
    jq -r '[
        .wg_name,
        .wgName,
        .name,
        .client_name,
        .data.wg_name,
        .data.wgName,
        .data.name,
        .result.wg_name,
        .result.wgName,
        .result.name
    ] | map(select(type == "string" and length > 0)) | .[0] // ""' 2>/dev/null
}

multiebay_pick_conf() {
    jq -r '[
        .conf,
        .config,
        .wg_conf,
        .data.conf,
        .data.config,
        .data.wg_conf,
        .result.conf,
        .result.config,
        .result.wg_conf
    ] | map(select(type == "string" and length > 0)) | .[0] // ""' 2>/dev/null
}

multiebay_urlencode_component() {
    jq -nr --arg v "$1" '$v|@uri'
}

multiebay_normalize_proxy_url() {
    raw="$1"
    scheme="$(printf '%s' "$raw" | sed -E 's#^([a-zA-Z0-9+.-]+)://.*#\1#')"
    auth_host="$(printf '%s' "$raw" | sed -E 's#^[a-zA-Z0-9+.-]+://##; s#/.*$##')"

    if ! printf '%s' "$auth_host" | grep -q '@'; then
        printf '%s' "$raw"
        return 0
    fi

    auth="$(printf '%s' "$auth_host" | sed -E 's#^(.*)@[^@]*$#\1#')"
    hostport="$(printf '%s' "$auth_host" | sed -E 's#^.*@([^@]*)$#\1#')"

    if printf '%s' "$auth" | grep -q ':'; then
        user="${auth%%:*}"
        pass="${auth#*:}"
    else
        user="$auth"
        pass=""
    fi

    user_enc="$(multiebay_urlencode_component "$user")"
    if [ -n "$pass" ]; then
        pass_enc="$(multiebay_urlencode_component "$pass")"
        printf '%s://%s:%s@%s' "$scheme" "$user_enc" "$pass_enc" "$hostport"
    else
        printf '%s://%s@%s' "$scheme" "$user_enc" "$hostport"
    fi
}

multiebay_lookup_gateway_by_proxy() {
    proxy_url="$1"

    # Prefer exact URL matches first to avoid selecting the wrong gateway when many proxies share host:port.
    jq -r \
        --arg proxy "$proxy_url" \
        '[
        (.proxies[]? | select((.proxy_url // .proxy // .upstream // .url // "") == $proxy) | (.name // .gateway_name // .gatewayName // .gateway.name // .id // empty)),
        (.items[]? | select((.proxy_url // .proxy // .upstream // .url // "") == $proxy) | (.name // .gateway_name // .gatewayName // .gateway.name // .id // empty)),
        (.data[]? | select((.proxy_url // .proxy // .upstream // .url // "") == $proxy) | (.name // .gateway_name // .gatewayName // .gateway.name // .id // empty)),
        (.gateways[]? | select((.proxy_url // .proxy // .upstream // .url // "") == $proxy) | (.name // .gateway_name // .gatewayName // .gateway.name // .id // empty))
    ] | map(select(type == "string" and length > 0)) | .[0] // ""' 2>/dev/null
}

multiebay_lookup_gateway_by_hostport_unique() {
    proxy_url="$1"
    proxy_hostport="$(echo "$proxy_url" | sed -E 's#^[a-zA-Z0-9+.-]+://##; s#^.*@##; s#/.*$##')"
    proxy_host="$(printf '%s' "$proxy_hostport" | sed -E 's#:[0-9]+$##')"

    # Host/port fallback is used only when it maps to exactly one gateway.
    jq -r \
        --arg proxy_hostport "$proxy_hostport" \
        --arg proxy_host "$proxy_host" \
        '[
        (.proxies[]? | select(
            ((.proxy_url // .proxy // .upstream // .url // "") | contains("@" + $proxy_hostport)) or
            ((.proxy_url // .proxy // .upstream // .url // "") | endswith($proxy_hostport)) or
            ((.host // .hostname // "") == $proxy_host)
        ) | (.name // .gateway_name // .gatewayName // .gateway.name // .id // empty)),
        (.items[]? | select(
            ((.proxy_url // .proxy // .upstream // .url // "") | contains("@" + $proxy_hostport)) or
            ((.proxy_url // .proxy // .upstream // .url // "") | endswith($proxy_hostport)) or
            ((.host // .hostname // "") == $proxy_host)
        ) | (.name // .gateway_name // .gatewayName // .gateway.name // .id // empty)),
        (.data[]? | select(
            ((.proxy_url // .proxy // .upstream // .url // "") | contains("@" + $proxy_hostport)) or
            ((.proxy_url // .proxy // .upstream // .url // "") | endswith($proxy_hostport)) or
            ((.host // .hostname // "") == $proxy_host)
        ) | (.name // .gateway_name // .gatewayName // .gateway.name // .id // empty)),
        (.gateways[]? | select(
            ((.proxy_url // .proxy // .upstream // .url // "") | contains("@" + $proxy_hostport)) or
            ((.proxy_url // .proxy // .upstream // .url // "") | endswith($proxy_hostport)) or
            ((.proxy_display // "") | contains("@" + $proxy_hostport)) or
            ((.proxy_display // "") | endswith($proxy_hostport)) or
            ((.host // .hostname // "") == $proxy_host)
        ) | (.name // .gateway_name // .gatewayName // .gateway.name // .id // empty))
    ]
    | map(select(type == "string" and length > 0))
    | unique
    | if length == 1 then .[0] else "" end' 2>/dev/null
}

urlencode() {
    jq -nr --arg v "$1" '$v|@uri'
}

multiebay_slug() {
    echo "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//' | cut -c1-24
}

multiebay_proxy_to_url() {
    raw="$(echo "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$raw" ] || return 1

    case "$raw" in
        *://*)
            multiebay_normalize_proxy_url "$raw"
            return 0
            ;;
    esac

    if echo "$raw" | grep -Eq '^[^:]+:[0-9]+:[^:]+:.+$'; then
        host="${raw%%:*}"
        rest="${raw#*:}"
        port="${rest%%:*}"
        rest="${rest#*:}"
        user="${rest%%:*}"
        pass="${rest#*:}"
        user_enc="$(multiebay_urlencode_component "$user")"
        pass_enc="$(multiebay_urlencode_component "$pass")"
        printf 'socks5://%s:%s@%s:%s' "$user_enc" "$pass_enc" "$host" "$port"
        return 0
    fi

    if echo "$raw" | grep -Eq '^[^@]+@[^:]+:[0-9]+$'; then
        printf 'socks5://%s' "$raw"
        return 0
    fi

    if echo "$raw" | grep -Eq '^[^:]+:[0-9]+$'; then
        printf 'socks5://%s' "$raw"
        return 0
    fi

    return 1
}

multiebay_proxy_host() {
    proxy_url="$1"
    echo "$proxy_url" | sed -E 's#^[a-zA-Z0-9+.-]+://##; s#^[^@]+@##; s#[:/].*$##'
}

list_multiebay_settings() {
    vm_global_ensure
    api_base="$(vm_global_get multiebay_api_base)"
    api_key="$(vm_global_get multiebay_api_key)"
    allow_http_proxy="$(vm_global_get multiebay_allow_http_proxy)"
    api_key_saved="false"
    [ -n "$api_key" ] && api_key_saved="true"

    [ -n "$api_base" ] || api_base="https://multiebay.com"
    [ -n "$allow_http_proxy" ] || allow_http_proxy="1"

    printf '{"ok":true,"api_base":"%s","api_key_saved":%s,"api_key":"%s","allow_http_proxy":"%s"}' \
        "$(json_escape "$api_base")" \
        "$api_key_saved" \
        "$(json_escape "$api_key")" \
        "$(json_escape "$allow_http_proxy")"
}

save_multiebay_settings() {
    api_base="$2"
    api_key="$3"
    allow_http_proxy="$4"

    vm_global_ensure
    [ -n "$api_base" ] || api_base="https://multiebay.com"
    [ -n "$allow_http_proxy" ] || allow_http_proxy="1"

    vm_global_set multiebay_api_base "$api_base"
    vm_global_set multiebay_allow_http_proxy "$allow_http_proxy"
    if [ -n "$api_key" ]; then
        vm_global_set multiebay_api_key "$api_key"
    fi

    uci commit vpn-manager
    echo '{"ok":true}'
}

clear_multiebay_api_key() {
    vm_global_ensure
    uci -q delete vpn-manager.global.multiebay_api_key
    uci commit vpn-manager
    echo '{"ok":true}'
}

lookup_public_ip() {
    iface="$1"
    if [ -n "$iface" ]; then
        curl -sS --interface "$iface" --max-time 10 https://ipwho.is/ 2>/dev/null || true
    else
        curl -sS --max-time 10 https://ipwho.is/ 2>/dev/null || true
    fi
}

route_status() {
    printf '{"ok":true,"wan":'
    wan_json="$(lookup_public_ip "")"
    if [ -n "$wan_json" ]; then
        printf '%s' "$wan_json"
    else
        printf '{"success":false}'
    fi

    printf ',"profiles":['
    first=1
    for sec in $(vm_profile_list); do
        [ $first -eq 1 ] || printf ','
        first=0
        iface="$(uci -q get vpn-manager.$sec.iface)"
        ip_json="$(lookup_public_ip "$iface")"
        [ -n "$ip_json" ] || ip_json='{"success":false}'
        printf '{"id":"%s","name":"%s","iface":"%s","ip":%s}' \
            "$sec" \
            "$(json_escape "$(uci -q get vpn-manager.$sec.name)")" \
            "$(json_escape "$iface")" \
            "$ip_json"
    done
    printf ']}'
}

vm_wifi_binding_pick_radio() {
    uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-device$/\1/p' | head -n1
}

vm_wifi_binding_radio_for_default_iface() {
    uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p' | head -n1 | while read -r iface; do
        [ -n "$iface" ] || continue
        uci -q get wireless."$iface".device
        return 0
    done
}

vm_first_ipv4() {
    printf '%s\n' "$1" | tr ', ' '\n\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1
}

list_wifi_bindings() {
    printf '{"ok":true,"bindings":['
    first=1

    for sec in $(vm_wifi_binding_list); do
        [ $first -eq 1 ] || printf ','
        first=0

        ssid="$(uci -q get vpn-manager.$sec.ssid)"
        key="$(uci -q get vpn-manager.$sec.key)"
        encryption="$(uci -q get vpn-manager.$sec.encryption)"
        target="$(uci -q get vpn-manager.$sec.target)"
        enabled="$(uci -q get vpn-manager.$sec.enabled)"
        subnet_id="$(uci -q get vpn-manager.$sec.subnet_id)"
        network_name="$(uci -q get vpn-manager.$sec.network)"
        radio="$(uci -q get wireless.$sec.device)"
        gateway="$(uci -q get network.$network_name.ipaddr)"
        dns_ip=""
        target_iface=""
        status="unknown"

        [ -n "$network_name" ] || network_name="$sec"
        [ -n "$gateway" ] || gateway="$(vm_wifi_binding_gateway "$subnet_id")"
        [ -n "$radio" ] || radio="$(vm_wifi_binding_radio_for_default_iface)"

        if vm_profile_exists "$target"; then
            target_iface="$(uci -q get vpn-manager.$target.iface)"
            dns_ip="$(vm_first_ipv4 "$(uci -q get vpn-manager.$target.dns)")"
            status="$(vm_profile_health "$target_iface" "180" || true)"
        fi

        printf '{"id":"%s","ssid":"%s","key":"%s","encryption":"%s","target":"%s","target_iface":"%s","enabled":"%s","subnet_id":"%s","subnet":"%s","network":"%s","gateway":"%s","dns":"%s","radio":"%s","status":"%s"}' \
            "$sec" \
            "$(json_escape "$ssid")" \
            "$(json_escape "$key")" \
            "$(json_escape "$encryption")" \
            "$(json_escape "$target")" \
            "$(json_escape "$target_iface")" \
            "$enabled" \
            "$subnet_id" \
            "$(vm_wifi_binding_subnet_cidr "$subnet_id")" \
            "$(json_escape "$network_name")" \
            "$(json_escape "$gateway")" \
            "$(json_escape "$dns_ip")" \
            "$(json_escape "$radio")" \
            "$(json_escape "$status")"
    done

    printf ']}'
}

save_wifi_binding() {
    sec="$2"
    ssid="$3"
    key="$4"
    encryption="$5"
    target="$6"
    enabled="$7"

    [ -n "$ssid" ] || {
        echo '{"ok":false,"error":"ssid is required"}'
        return
    }

    target="$(vm_wifi_binding_target_profile "$target" 2>/dev/null || true)"
    [ -n "$target" ] || {
        echo '{"ok":false,"error":"target profile not found"}'
        return
    }

    [ -n "$sec" ] || sec="wifi_$(echo "$ssid" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//' | cut -c1-20)_$(date +%H%M%S)"

    radio="$(vm_wifi_binding_radio_for_default_iface)"
    [ -n "$radio" ] || radio="$(vm_wifi_binding_pick_radio)"
    [ -n "$radio" ] || {
        echo '{"ok":false,"error":"wifi radio not found"}'
        return
    }

    if vm_wifi_binding_exists "$sec"; then
        subnet_id="$(uci -q get vpn-manager.$sec.subnet_id)"
        network_name="$(uci -q get vpn-manager.$sec.network)"
    else
        subnet_id="$(vm_wifi_binding_next_subnet_id)"
        network_name="$sec"
        uci set "vpn-manager.$sec=wifi_binding"
    fi

    [ -n "$subnet_id" ] || subnet_id="$(vm_wifi_binding_next_subnet_id)"
    [ -n "$network_name" ] || network_name="$sec"

    gateway="$(vm_wifi_binding_gateway "$subnet_id")"
    dns_ip="$(vm_first_ipv4 "$(uci -q get vpn-manager.$target.dns)")"
    [ -n "$dns_ip" ] || dns_ip="$gateway"

    uci set "vpn-manager.$sec.enabled=${enabled:-1}"
    uci set "vpn-manager.$sec.ssid=$ssid"
    uci set "vpn-manager.$sec.key=$key"
    uci set "vpn-manager.$sec.encryption=${encryption:-sae-mixed}"
    uci set "vpn-manager.$sec.target=$target"
    uci set "vpn-manager.$sec.subnet_id=$subnet_id"
    uci set "vpn-manager.$sec.network=$network_name"

    uci -q delete "wireless.$sec"
    uci set "wireless.$sec=wifi-iface"
    uci set "wireless.$sec.device=$radio"
    uci set "wireless.$sec.mode=ap"
    uci set "wireless.$sec.network=$network_name"
    uci set "wireless.$sec.ssid=$ssid"
    uci set "wireless.$sec.encryption=${encryption:-sae-mixed}"
    if [ "${encryption:-sae-mixed}" != "none" ] && [ -n "$key" ]; then
        uci set "wireless.$sec.key=$key"
    else
        uci -q delete "wireless.$sec.key"
    fi
    uci set "wireless.$sec.isolate=1"
    if [ "${enabled:-1}" = "0" ]; then
        uci set "wireless.$sec.disabled=1"
    else
        uci set "wireless.$sec.disabled=0"
    fi

    uci -q delete "network.$network_name"
    uci set "network.$network_name=interface"
    uci set "network.$network_name.proto=static"
    uci set "network.$network_name.device=br-$network_name"
    uci set "network.$network_name.ipaddr=$gateway"
    uci set "network.$network_name.netmask=255.255.255.0"
    uci set "network.$network_name.defaultroute=0"
    uci set "network.$network_name.delegate=0"

    uci -q delete "network.${network_name}_dev"
    uci set "network.${network_name}_dev=device"
    uci set "network.${network_name}_dev.name=br-$network_name"
    uci set "network.${network_name}_dev.type=bridge"
    uci set "network.${network_name}_dev.bridge_empty=1"

    uci -q delete "dhcp.$network_name"
    uci set "dhcp.$network_name=dhcp"
    uci set "dhcp.$network_name.interface=$network_name"
    uci set "dhcp.$network_name.start=100"
    uci set "dhcp.$network_name.limit=100"
    uci set "dhcp.$network_name.leasetime=12h"
    uci set "dhcp.$network_name.dhcpv6=disabled"
    uci set "dhcp.$network_name.ra=disabled"
    uci set "dhcp.$network_name.ndp=disabled"
    uci add_list "dhcp.$network_name.dhcp_option=3,$gateway"
    uci add_list "dhcp.$network_name.dhcp_option=6,$dns_ip"

    uci -q delete "firewall.$network_name"
    uci set "firewall.$network_name=zone"
    uci set "firewall.$network_name.name=$network_name"
    uci add_list "firewall.$network_name.network=$network_name"
    uci set "firewall.$network_name.input=ACCEPT"
    uci set "firewall.$network_name.output=ACCEPT"
    uci set "firewall.$network_name.forward=DROP"
    uci set "firewall.$network_name.masq=0"
    uci set "firewall.$network_name.mtu_fix=0"

    uci commit vpn-manager
    uci commit wireless
    uci commit network
    uci commit dhcp
    uci commit firewall

    wifi reload >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    /etc/init.d/firewall restart >/dev/null 2>&1 || true
    echo '{"ok":true}'
}

delete_wifi_binding() {
    sec="$2"
    [ -n "$sec" ] || {
        echo '{"ok":false,"error":"missing section"}'
        return
    }

    vm_wifi_binding_exists "$sec" || {
        echo '{"ok":false,"error":"wifi binding not found"}'
        return
    }

    network_name="$(uci -q get vpn-manager.$sec.network)"
    [ -n "$network_name" ] || network_name="$sec"

    uci -q delete "vpn-manager.$sec"
    uci -q delete "wireless.$sec"
    uci -q delete "network.$network_name"
    uci -q delete "network.${network_name}_dev"
    uci -q delete "dhcp.$network_name"
    uci -q delete "firewall.$network_name"

    uci commit vpn-manager
    uci commit wireless
    uci commit network
    uci commit dhcp
    uci commit firewall

    wifi reload >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    /etc/init.d/firewall restart >/dev/null 2>&1 || true
    echo '{"ok":true}'
}

list_wifi() {
    iface="$(uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p' | head -n1)"
    [ -n "$iface" ] || {
        echo '{"ok":false,"error":"wifi iface not found"}'
        return
    }

    device="$(uci -q get wireless.$iface.device)"
    ssid="$(uci -q get wireless.$iface.ssid)"
    encryption="$(uci -q get wireless.$iface.encryption)"
    key="$(uci -q get wireless.$iface.key)"
    channel="$(uci -q get wireless.$device.channel)"
    country="$(uci -q get wireless.$device.country)"
    iface_disabled="$(uci -q get wireless.$iface.disabled)"
    dev_disabled="$(uci -q get wireless.$device.disabled)"

    enabled="1"
    [ "$iface_disabled" = "1" ] && enabled="0"
    [ "$dev_disabled" = "1" ] && enabled="0"

    printf '{"ok":true,"iface":"%s","device":"%s","ssid":"%s","encryption":"%s","key":"%s","channel":"%s","country":"%s","enabled":"%s"}' \
        "$(json_escape "$iface")" \
        "$(json_escape "$device")" \
        "$(json_escape "$ssid")" \
        "$(json_escape "$encryption")" \
        "$(json_escape "$key")" \
        "$(json_escape "$channel")" \
        "$(json_escape "$country")" \
        "$enabled"
}

set_wifi() {
    ssid="$2"
    key="$3"
    encryption="$4"
    channel="$5"
    enabled="$6"

    iface="$(uci -q show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p' | head -n1)"
    [ -n "$iface" ] || {
        echo '{"ok":false,"error":"wifi iface not found"}'
        return
    }
    device="$(uci -q get wireless.$iface.device)"

    [ -n "$ssid" ] && uci set "wireless.$iface.ssid=$ssid"
    [ -n "$encryption" ] && uci set "wireless.$iface.encryption=$encryption"
    [ -n "$key" ] && uci set "wireless.$iface.key=$key"
    [ -n "$channel" ] && uci set "wireless.$device.channel=$channel"

    if [ "$enabled" = "0" ]; then
        uci set "wireless.$iface.disabled=1"
        uci set "wireless.$device.disabled=1"
    else
        uci set "wireless.$iface.disabled=0"
        uci set "wireless.$device.disabled=0"
    fi

    uci commit wireless
    wifi reload >/dev/null 2>&1 || /etc/init.d/network reload >/dev/null 2>&1 || true
    echo '{"ok":true}'
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

normalize_mac() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

dedupe_device_policies() {
    keep_section="$1"
    keep_mac="$(normalize_mac "$2")"
    keep_ip="$3"

    for sec in $(uci -q show vpn-manager | sed -n 's/^vpn-manager\.\([^.=]*\)=device_policy$/\1/p'); do
        [ "$sec" = "$keep_section" ] && continue

        sec_mac="$(normalize_mac "$(uci -q get vpn-manager.$sec.mac)")"
        sec_ip="$(uci -q get vpn-manager.$sec.ip)"

        if [ -n "$keep_mac" ] && [ "$sec_mac" = "$keep_mac" ]; then
            uci -q delete "vpn-manager.$sec"
            continue
        fi

        if [ -n "$keep_ip" ] && [ "$sec_ip" = "$keep_ip" ]; then
            uci -q delete "vpn-manager.$sec"
            continue
        fi
    done
}

set_policy() {
    section="$2"
    mac="$(normalize_mac "$3")"
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
    dedupe_device_policies "$section" "$mac" "$ip"
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

create_multiebay_profile() {
    sec="$2"
    api_base="$3"
    api_key="$4"
    proxy_url="$5"
    gateway_name="$6"
    client_name="$7"
    profile_name="$8"
    allow_http_proxy="$9"

    vm_global_ensure
    [ -n "$api_base" ] || api_base="$(vm_global_get multiebay_api_base)"
    [ -n "$api_key" ] || api_key="$(vm_global_get multiebay_api_key)"
    [ -n "$allow_http_proxy" ] || allow_http_proxy="$(vm_global_get multiebay_allow_http_proxy)"

    if [ -n "$proxy_url" ]; then
        proxy_url="$(multiebay_proxy_to_url "$proxy_url" 2>/dev/null || true)"
        [ -n "$proxy_url" ] || {
            echo '{"ok":false,"error":"unsupported proxy format; use ip:port:user:pass or socks5://user:pass@host:port"}'
            return
        }
    fi

    if [ -z "$sec" ]; then
        seed_host="$(multiebay_slug "$(multiebay_proxy_host "$proxy_url")")"
        [ -n "$seed_host" ] || seed_host="proxy"
        sec="vpn_${seed_host}_$(date +%H%M%S)"
    fi

    [ -n "$api_key" ] || {
        echo '{"ok":false,"error":"missing api key"}'
        return
    }

    [ -n "$proxy_url" ] || [ -n "$gateway_name" ] || {
        echo '{"ok":false,"error":"proxy url or gateway name is required"}'
        return
    }

    vm_require_cmd curl >/dev/null 2>&1 || {
        echo '{"ok":false,"error":"missing command: curl"}'
        return
    }
    vm_require_cmd jq >/dev/null 2>&1 || {
        echo '{"ok":false,"error":"missing command: jq"}'
        return
    }

    api_base="${api_base%/}"
    [ -n "$api_base" ] || api_base="https://multiebay.com"
    [ -n "$client_name" ] || client_name="$sec"
    [ -n "$profile_name" ] || profile_name="$sec"

    if [ "$allow_http_proxy" = "1" ] || [ "$allow_http_proxy" = "true" ] || [ "$allow_http_proxy" = "yes" ]; then
        allow_http_proxy_json="true"
    else
        allow_http_proxy_json="false"
    fi

    if ! http_json_request "GET" "$api_base/api/key/me" "$api_key" >/dev/null 2>&1; then
        echo '{"ok":false,"error":"unable to validate MultiEbay API key"}'
        return
    fi

    if [ -n "$gateway_name" ] && [ -n "$proxy_url" ]; then
        proxy_payload="$(jq -cn --arg proxy_url "$proxy_url" --argjson allow_http_proxy "$allow_http_proxy_json" '{proxy_url:$proxy_url, allow_http_proxy:$allow_http_proxy}')"
        if ! http_json_request "PUT" "$api_base/api/customer/proxy/$(urlencode "$gateway_name")" "$api_key" "$proxy_payload" >/dev/null 2>&1; then
            echo '{"ok":false,"error":"unable to update MultiEbay gateway proxy"}'
            return
        fi
    elif [ -z "$gateway_name" ]; then
        proxy_payload="$(jq -cn --arg proxy_url "$proxy_url" --argjson allow_http_proxy "$allow_http_proxy_json" '{proxy_url:$proxy_url, allow_http_proxy:$allow_http_proxy}')"
        gateway_resp="$(http_json_request "POST" "$api_base/api/customer/proxy" "$api_key" "$proxy_payload" 2>/dev/null || true)"
        gateway_name="$(printf '%s' "$gateway_resp" | multiebay_pick_gateway_name)"

        if [ -z "$gateway_name" ]; then
            proxies_resp="$(http_json_request "GET" "$api_base/api/customer/proxies" "$api_key" 2>/dev/null || true)"
            gateway_name="$(printf '%s' "$proxies_resp" | multiebay_lookup_gateway_by_proxy "$proxy_url")"
        fi

        if [ -z "$gateway_name" ]; then
            gateway_name="$(printf '%s' "$proxies_resp" | multiebay_lookup_gateway_by_hostport_unique "$proxy_url")"
        fi

        if [ -z "$gateway_name" ]; then
            echo '{"ok":false,"error":"unable to determine created gateway name from MultiEbay (ambiguous host/port match)"}'
            return
        fi
    fi

    wg_payload="$(jq -cn --arg client_name "$client_name" '{client_name:$client_name}')"
    wg_resp="$(http_json_request "POST" "$api_base/api/customer/gateway/$(urlencode "$gateway_name")/wg-client" "$api_key" "$wg_payload" 2>/dev/null || true)"
    wg_conf="$(printf '%s' "$wg_resp" | multiebay_pick_conf)"
    wg_name="$(printf '%s' "$wg_resp" | multiebay_pick_wg_name)"

    if [ -z "$wg_conf" ] && [ -n "$wg_name" ]; then
        wg_detail_resp="$(http_json_request "GET" "$api_base/api/customer/wg/client/$(urlencode "$wg_name")" "$api_key" 2>/dev/null || true)"
        wg_conf="$(printf '%s' "$wg_detail_resp" | multiebay_pick_conf)"
    fi

    if [ -z "$wg_conf" ]; then
        echo '{"ok":false,"error":"MultiEbay did not return a WireGuard config"}'
        return
    fi

    tmp_conf="$VM_STATE_DIR/multiebay-${sec}-$$.conf"
    printf '%s\n' "$wg_conf" > "$tmp_conf"

    if ! import_profile import_profile "$sec" "$tmp_conf" >/dev/null 2>&1; then
        rm -f "$tmp_conf"
        echo '{"ok":false,"error":"unable to import WireGuard config into router"}'
        return
    fi

    rm -f "$tmp_conf"
    vm_profile_set "$sec" "name" "$profile_name"
    uci commit vpn-manager
    uci commit network

    printf '{"ok":true,"id":"%s","gateway_name":"%s","wg_name":"%s"}' \
        "$(json_escape "$sec")" \
        "$(json_escape "$gateway_name")" \
        "$(json_escape "$wg_name")"
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
    list_wifi) list_wifi ;;
    set_wifi) set_wifi "$@" ;;
    list_wifi_bindings) list_wifi_bindings ;;
    save_wifi_binding) save_wifi_binding "$@" ;;
    delete_wifi_binding) delete_wifi_binding "$@" ;;
    route_status) route_status ;;
    list_multiebay_settings) list_multiebay_settings ;;
    save_multiebay_settings) save_multiebay_settings "$@" ;;
    clear_multiebay_api_key) clear_multiebay_api_key ;;
    create_multiebay_profile) create_multiebay_profile "$@" ;;
    apply) apply_changes ;;
    rollback) rollback_changes ;;
    *) echo '{"error":"unsupported method"}' ;;
esac
