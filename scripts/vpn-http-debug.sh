#!/bin/sh
set -eu

PATH="${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin"
export PATH

VM_CFG="${VM_CFG:-vpn-manager}"
VM_HTTP_DEBUG_DIR="${VM_HTTP_DEBUG_DIR:-/tmp/vpn-manager-http-debug}"
VM_HTTP_DEBUG_CERT_DIR="${VM_HTTP_DEBUG_CERT_DIR:-/etc/vpn-manager/mitmproxy}"
VM_HTTP_DEBUG_CONFIG_FILE="${VM_HTTP_DEBUG_CONFIG_FILE:-/etc/config/$VM_CFG}"
VM_HTTP_DEBUG_SQUID="${VM_HTTP_DEBUG_SQUID:-/usr/sbin/squid}"
VM_HTTP_DEBUG_SQUID_CONFIG="${VM_HTTP_DEBUG_SQUID_CONFIG:-$VM_HTTP_DEBUG_DIR/squid.conf}"
VM_HTTP_DEBUG_CLIENTS="${VM_HTTP_DEBUG_CLIENTS:-$VM_HTTP_DEBUG_DIR/clients.manifest}"
VM_HTTP_DEBUG_ROUTES="${VM_HTTP_DEBUG_ROUTES:-$VM_HTTP_DEBUG_DIR/routes.manifest}"
VM_HTTP_DEBUG_URL_RULES="${VM_HTTP_DEBUG_URL_RULES:-$VM_HTTP_DEBUG_DIR/url-rules.manifest}"
VM_HTTP_DEBUG_BUMP_HOSTS="${VM_HTTP_DEBUG_BUMP_HOSTS:-$VM_HTTP_DEBUG_DIR/bump-hosts.manifest}"
VM_HTTP_DEBUG_RESOLVERS="${VM_HTTP_DEBUG_RESOLVERS:-$VM_HTTP_DEBUG_DIR/resolvers.manifest}"
VM_HTTP_DEBUG_BLOCKED_DOMAINS="${VM_HTTP_DEBUG_BLOCKED_DOMAINS:-$VM_HTTP_DEBUG_DIR/blocked-domains.manifest}"
VM_HTTP_DEBUG_NFT_FILE="${VM_HTTP_DEBUG_NFT_FILE:-$VM_HTTP_DEBUG_DIR/access.nft}"
VM_HTTP_DEBUG_PID_FILE="${VM_HTTP_DEBUG_PID_FILE:-$VM_HTTP_DEBUG_DIR/proxy.pid}"
VM_HTTP_DEBUG_ROUTE_STATE="${VM_HTTP_DEBUG_ROUTE_STATE:-$VM_HTTP_DEBUG_DIR/route-state}"
VM_HTTP_DEBUG_RETURN_STATE="${VM_HTTP_DEBUG_RETURN_STATE:-$VM_HTTP_DEBUG_DIR/return-route-state}"
VM_HTTP_DEBUG_SSL_DB="${VM_HTTP_DEBUG_SSL_DB:-$VM_HTTP_DEBUG_DIR/ssl-db}"
VM_HTTP_DEBUG_LOG_DIR="${VM_HTTP_DEBUG_LOG_DIR:-/var/log/vpn-manager/http-debug}"
VM_HTTP_DEBUG_ACCESS_LOG="${VM_HTTP_DEBUG_ACCESS_LOG:-$VM_HTTP_DEBUG_LOG_DIR/access.log}"

vm_http_debug_snapshot_plan() {
    local snapshot="${1:-$VM_HTTP_DEBUG_DIR/config.show}"
    local clients="${2:-$VM_HTTP_DEBUG_CLIENTS}"
    local routes="${3:-$VM_HTTP_DEBUG_ROUTES}"
    local rules="${4:-$VM_HTTP_DEBUG_URL_RULES}"
    local bump_hosts="${5:-$VM_HTTP_DEBUG_BUMP_HOSTS}"
    local resolvers="${6:-$VM_HTTP_DEBUG_RESOLVERS}"
    local blocked_domains="${7:-$VM_HTTP_DEBUG_BLOCKED_DOMAINS}"

    mkdir -p "$VM_HTTP_DEBUG_DIR"
    umask 077
    uci -q show "$VM_CFG" > "$snapshot"

    awk -v config="$VM_CFG" -v clients="$clients" -v routes="$routes" -v rules="$rules" -v bump_hosts="$bump_hosts" -v resolvers="$resolvers" -v blocked_domains="$blocked_domains" '
        function decode(input,    output, i, ch, quoted) {
            output=""
            quoted=0
            for (i=1; i<=length(input); i++) {
                ch=substr(input, i, 1)
                if (quoted) {
                    if (ch == "\047") quoted=0
                    else output=output ch
                } else if (ch == "\047") quoted=1
                else if (ch == "\\" && i < length(input)) output=output substr(input, ++i, 1)
                else output=output ch
            }
            return output
        }
        function opt(section, name) {
            return values[section SUBSEP name]
        }
        function ipv4(value,    count, octet, i) {
            count=split(value, octet, ".")
            if (count != 4) return 0
            for (i=1; i<=4; i++)
                if (octet[i] !~ /^[0-9]+$/ || octet[i] + 0 > 255) return 0
            return 1
        }
        function first_ipv4(value,    count, part, i, addr) {
            gsub(/,/, " ", value)
            count=split(value, part, /[[:space:]]+/)
            for (i=1; i<=count; i++) {
                addr=part[i]
                sub(/\/.*/, "", addr)
                if (ipv4(addr)) return addr
            }
            return ""
        }
        function wifi_contains(ip, subnet_id,    octet) {
            if (!ipv4(ip) || subnet_id !~ /^[0-9]+$/) return 0
            split(ip, octet, ".")
            return octet[1] == 10 && octet[2] == 77 && octet[3] + 0 == subnet_id + 0
        }
        function regex_escape(input,    output, i, ch) {
            output=""
            for (i=1; i<=length(input); i++) {
                ch=substr(input, i, 1)
                if (ch ~ /[][(){}.^$+?|\\*]/) output=output "\\"
                output=output ch
            }
            return output
        }
        function url_regex(protocol, host, url_path,    wildcard, base) {
            wildcard=(substr(url_path, length(url_path), 1) == "*")
            if (wildcard) url_path=substr(url_path, 1, length(url_path)-1)
            base="^" protocol "://" regex_escape(host) "(:[0-9]+)?" regex_escape(url_path)
            if (wildcard) return base ".*$"
            return base "([?].*)?$"
        }
        {
            equals=index($0, "=")
            if (!equals) next
            left=substr($0, 1, equals-1)
            prefix=config "."
            if (substr(left, 1, length(prefix)) != prefix) next
            path=substr(left, length(prefix)+1)
            dot=index(path, ".")
            value=decode(substr($0, equals+1))
            if (!dot) {
                section=path
                if (!(section in seen)) order[++count]=section
                seen[section]=1
                kinds[section]=value
            } else {
                section=substr(path, 1, dot-1)
                name=substr(path, dot+1)
                values[section SUBSEP name]=value
            }
        }
        END {
            for (i=1; i<=count; i++) {
                section=order[i]
                if (kinds[section] == "device_policy" && opt(section, "enabled") != "0" && ipv4(opt(section, "ip")))
                    policy_target[opt(section, "ip")]=opt(section, "target")
            }

            for (i=1; i<=count; i++) {
                section=order[i]
                if (kinds[section] != "http_debug_client" || opt(section, "enabled") == "0") continue
                ip=opt(section, "ip")
                if (!ipv4(ip)) continue
                target=""
                for (w=1; w<=count; w++) {
                    wifi=order[w]
                    if (kinds[wifi] == "wifi_binding" && opt(wifi, "enabled") == "1" && wifi_contains(ip, opt(wifi, "subnet_id"))) {
                        target=opt(wifi, "target")
                        break
                    }
                }
                if (target == "") target=policy_target[ip]
                if (target == "") target="wan"

                if (target == "wan") {
                    print ip "|||wan" > clients
                    if (!resolver_seen["127.0.0.1"]++) print "127.0.0.1" > resolvers
                    continue
                }
                if (kinds[target] != "profile" || opt(target, "enabled") != "1") continue
                source=first_ipv4(opt(target, "address"))
                table_id=opt(target, "table_id")
                iface=opt(target, "iface")
                if (!ipv4(source) || table_id !~ /^[0-9]+$/ || iface !~ /^[A-Za-z0-9_.-]+$/) continue
                print ip "|" source "|" table_id "|" iface > clients
                route_key=source SUBSEP table_id SUBSEP iface
                if (!route_seen[route_key]++) print source "|" table_id "|" iface > routes
                resolver=first_ipv4(opt(target, "dns"))
                if (ipv4(resolver) && !resolver_seen[resolver]++) print resolver > resolvers
            }

            for (i=1; i<=count; i++) {
                section=order[i]
                if (kinds[section] == "blocked_domain" && opt(section, "enabled") != "0") {
                    domain=tolower(opt(section, "domain"))
                    mode=(opt(section, "mode") == "exact" ? "exact" : "wildcard")
                    if (domain ~ /^[a-z0-9._-]+$/ && domain !~ /\.\./)
                        print domain "|" mode > blocked_domains
                    continue
                }
                if (kinds[section] != "blocked_url" || opt(section, "enabled") == "0") continue
                protocol=opt(section, "protocol")
                host=opt(section, "host")
                method=opt(section, "method")
                url_path=opt(section, "path")
                if (protocol != "http" && protocol != "https") continue
                if (host !~ /^[a-z0-9.-]+$/ || host ~ /\.\./) continue
                if (method != "GET" && method != "POST" && method != "PUT" && method != "PATCH" && method != "DELETE" && method != "HEAD" && method != "OPTIONS" && method != "*") continue
                if (url_path !~ /^\// || url_path ~ /[|"\\[:space:][:cntrl:]]/) continue
                print url_regex(protocol, host, url_path) "|" method > rules
                if (protocol == "https" && !bump_seen[host]++) print host > bump_hosts
            }
        }
    ' "$snapshot"

    [ -f "$clients" ] || : > "$clients"
    [ -f "$routes" ] || : > "$routes"
    [ -f "$rules" ] || : > "$rules"
    [ -f "$bump_hosts" ] || : > "$bump_hosts"
    [ -f "$resolvers" ] || : > "$resolvers"
    [ -f "$blocked_domains" ] || : > "$blocked_domains"
}

vm_http_debug_prepare_ca() {
    local ca_pem="$VM_HTTP_DEBUG_CERT_DIR/mitmproxy-ca.pem"
    local ca_cert="$VM_HTTP_DEBUG_CERT_DIR/mitmproxy-ca-cert.pem"
    local ca_key="$VM_HTTP_DEBUG_CERT_DIR/mitmproxy-ca.key"

    mkdir -p "$VM_HTTP_DEBUG_CERT_DIR"
    chmod 700 "$VM_HTTP_DEBUG_CERT_DIR"
    if [ ! -s "$ca_pem" ] || [ ! -s "$ca_cert" ]; then
        openssl req -new -newkey rsa:2048 -sha256 -days 3650 -nodes -x509 \
            -extensions v3_ca -subj "/CN=VPN Manager HTTP Debug CA" \
            -keyout "$ca_key" -out "$ca_cert"
        cat "$ca_key" "$ca_cert" > "$ca_pem"
        rm -f "$ca_key"
    fi
    chown root:squid "$ca_pem"
    chmod 640 "$ca_pem"
    chmod 600 "$ca_cert"

    rm -rf "$VM_HTTP_DEBUG_SSL_DB"
    /usr/lib/squid/security_file_certgen -c -s "$VM_HTTP_DEBUG_SSL_DB" -M 4MB
    chown -R squid:squid "$VM_HTTP_DEBUG_SSL_DB"
}

vm_http_debug_prepare_runtime_dirs() {
    local log_parent

    mkdir -p "$VM_HTTP_DEBUG_DIR" "$VM_HTTP_DEBUG_LOG_DIR"
    chown root:squid "$VM_HTTP_DEBUG_DIR"
    chmod 750 "$VM_HTTP_DEBUG_DIR"
    log_parent="$(dirname "$VM_HTTP_DEBUG_LOG_DIR")"
    chown root:squid "$log_parent" 2>/dev/null || true
    chmod 750 "$log_parent" 2>/dev/null || true
    chown squid:squid "$VM_HTTP_DEBUG_LOG_DIR"
    chmod 700 "$VM_HTTP_DEBUG_LOG_DIR"
}

vm_http_debug_generate_squid() {
    local output="${1:-$VM_HTTP_DEBUG_SQUID_CONFIG}"
    local tmp="$output.$$"
    local index ip source table_id iface regex method domain mode

    mkdir -p "$VM_HTTP_DEBUG_LOG_DIR"
    chown squid:squid "$VM_HTTP_DEBUG_LOG_DIR" 2>/dev/null || true
    chmod 700 "$VM_HTTP_DEBUG_LOG_DIR"

    cat > "$tmp" <<EOF
visible_hostname vpn-manager-http-debug
cache_effective_user squid
cache_effective_group squid
pid_filename $VM_HTTP_DEBUG_PID_FILE
coredump_dir $VM_HTTP_DEBUG_DIR
cache_mem 16 MB
maximum_object_size_in_memory 256 KB
cache deny all
cache_store_log none
cache_log $VM_HTTP_DEBUG_LOG_DIR/cache.log
access_log stdio:$VM_HTTP_DEBUG_ACCESS_LOG squid
log_mime_hdrs on
forwarded_for delete
via off
http_port 3128 intercept
https_port 3129 intercept ssl-bump tls-cert=$VM_HTTP_DEBUG_CERT_DIR/mitmproxy-ca.pem generate-host-certificates=on dynamic_cert_mem_cache_size=4MB
sslcrtd_program /usr/lib/squid/security_file_certgen -s $VM_HTTP_DEBUG_SSL_DB -M 4MB
sslcrtd_children 2 startup=1 idle=1
acl vm_step1 at_step SslBump1
ssl_bump peek vm_step1
EOF

    if [ -s "$VM_HTTP_DEBUG_RESOLVERS" ]; then
        printf 'dns_nameservers' >> "$tmp"
        while IFS= read -r resolver; do
            [ -n "$resolver" ] || continue
            printf ' %s' "$resolver" >> "$tmp"
        done < "$VM_HTTP_DEBUG_RESOLVERS"
        printf '\n' >> "$tmp"
    fi

    if [ -s "$VM_HTTP_DEBUG_BUMP_HOSTS" ]; then
        printf 'acl vm_bump_hosts ssl::server_name' >> "$tmp"
        while IFS= read -r host; do
            [ -n "$host" ] || continue
            printf ' %s' "$host" >> "$tmp"
        done < "$VM_HTTP_DEBUG_BUMP_HOSTS"
        printf '\nssl_bump bump vm_bump_hosts\n' >> "$tmp"
    fi
    echo 'ssl_bump splice all' >> "$tmp"

    index=0
    while IFS='|' read -r domain mode; do
        [ -n "$domain" ] || continue
        index=$((index + 1))
        if [ "$mode" = "exact" ]; then
            printf 'acl vm_domain_%s dstdomain %s\n' "$index" "$domain" >> "$tmp"
        else
            printf 'acl vm_domain_%s dstdomain .%s\n' "$index" "$domain" >> "$tmp"
        fi
        printf 'http_access deny vm_domain_%s\n' "$index" >> "$tmp"
    done < "$VM_HTTP_DEBUG_BLOCKED_DOMAINS"

    index=0
    while IFS='|' read -r regex method; do
        [ -n "$regex" ] || continue
        index=$((index + 1))
        printf 'acl vm_url_%s url_regex -i %s\n' "$index" "$regex" >> "$tmp"
        if [ "$method" = "*" ]; then
            printf 'http_access deny vm_url_%s\n' "$index" >> "$tmp"
        else
            printf 'acl vm_method_%s method %s\n' "$index" "$method" >> "$tmp"
            printf 'http_access deny vm_url_%s vm_method_%s\n' "$index" "$index" >> "$tmp"
        fi
    done < "$VM_HTTP_DEBUG_URL_RULES"

    index=0
    while IFS='|' read -r ip source table_id iface; do
        [ -n "$ip" ] || continue
        index=$((index + 1))
        printf 'acl vm_client_%s src %s/32\n' "$index" "$ip" >> "$tmp"
        [ -z "$source" ] || printf 'tcp_outgoing_address %s vm_client_%s\n' "$source" "$index" >> "$tmp"
        printf 'http_access allow vm_client_%s\n' "$index" >> "$tmp"
    done < "$VM_HTTP_DEBUG_CLIENTS"
    echo 'http_access deny all' >> "$tmp"

    chown root:squid "$tmp" 2>/dev/null || true
    chmod 640 "$tmp"
    mv "$tmp" "$output"
}

vm_http_debug_generate_access() {
    local output="${1:-$VM_HTTP_DEBUG_NFT_FILE}"
    local tmp="$output.$$"
    local clients="$VM_HTTP_DEBUG_DIR/clients4"
    local source table_id iface

    cut -d '|' -f1 "$VM_HTTP_DEBUG_CLIENTS" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u > "$clients" || : > "$clients"
    {
        echo 'table inet vpn_manager_http_debug {'
        echo '    set clients4 {'
        echo '        type ipv4_addr'
        if [ -s "$clients" ]; then
            printf '        elements = { '
            awk 'BEGIN { first=1 } { if (!first) printf ", "; printf "%s", $0; first=0 } END { print " }" }' "$clients"
        fi
        echo '    }'
        echo '    chain prerouting {'
        echo '        type nat hook prerouting priority dstnat; policy accept;'
        echo '        ip saddr @clients4 tcp dport 80 redirect to :3128'
        echo '        ip saddr @clients4 tcp dport 443 redirect to :3129'
        echo '    }'
        echo '    chain forward {'
        echo '        type filter hook forward priority -210; policy accept;'
        echo '        ip saddr @clients4 udp dport 443 reject'
        echo '    }'
        echo '    chain input {'
        echo '        type filter hook input priority -110; policy accept;'
        echo '        ip saddr @clients4 tcp dport { 3128, 3129 } accept'
        echo '        tcp dport { 3128, 3129 } drop'
        echo '    }'
        echo '    chain output {'
        echo '        type filter hook output priority -210; policy accept;'
        while IFS='|' read -r source table_id iface; do
            [ -n "$source" ] || continue
            printf '        ip saddr %s oifname != "%s" drop\n' "$source" "$iface"
        done < "$VM_HTTP_DEBUG_ROUTES"
        echo '    }'
        echo '}'
    } > "$tmp"
    mv "$tmp" "$output"
}

vm_http_debug_remove_access() {
    nft list table inet vpn_manager_http_debug >/dev/null 2>&1 && \
        nft delete table inet vpn_manager_http_debug || true
}

vm_http_debug_apply_access() {
    local apply_file="$VM_HTTP_DEBUG_DIR/access-apply.nft"

    vm_http_debug_generate_access
    nft -c -f "$VM_HTTP_DEBUG_NFT_FILE"
    {
        nft list table inet vpn_manager_http_debug >/dev/null 2>&1 && \
            echo 'destroy table inet vpn_manager_http_debug'
        cat "$VM_HTTP_DEBUG_NFT_FILE"
    } > "$apply_file"
    nft -f "$apply_file"
    rm -f "$apply_file"
}

vm_http_debug_reset_client_flows() {
    local ip source table_id iface

    command -v conntrack >/dev/null 2>&1 || return 0
    while IFS='|' read -r ip source table_id iface; do
        [ -n "$ip" ] || continue
        conntrack -D -s "$ip" -p tcp >/dev/null 2>&1 || true
        conntrack -D -s "$ip" -p udp >/dev/null 2>&1 || true
    done < "$VM_HTTP_DEBUG_CLIENTS"
}

vm_http_debug_remove_routes() {
    local source table_id iface subnet

    if [ -f "$VM_HTTP_DEBUG_ROUTE_STATE" ]; then
        while IFS='|' read -r source table_id iface; do
            [ -n "$source" ] || continue
            ip -4 rule del from "$source/32" table "$table_id" priority 9985 2>/dev/null || true
        done < "$VM_HTTP_DEBUG_ROUTE_STATE"
        rm -f "$VM_HTTP_DEBUG_ROUTE_STATE"
    fi

    if [ -f "$VM_HTTP_DEBUG_RETURN_STATE" ]; then
        while IFS= read -r subnet; do
            [ -n "$subnet" ] || continue
            ip -4 rule del to "$subnet" table main priority 9980 2>/dev/null || true
        done < "$VM_HTTP_DEBUG_RETURN_STATE"
        rm -f "$VM_HTTP_DEBUG_RETURN_STATE"
    fi
}

vm_http_debug_apply_routes() {
    local source table_id iface ip subnet

    vm_http_debug_remove_routes
    : > "$VM_HTTP_DEBUG_ROUTE_STATE"
    while IFS='|' read -r source table_id iface; do
        [ -n "$source" ] || continue
        ip -4 rule add from "$source/32" table "$table_id" priority 9985
        printf '%s|%s|%s\n' "$source" "$table_id" "$iface" >> "$VM_HTTP_DEBUG_ROUTE_STATE"
    done < "$VM_HTTP_DEBUG_ROUTES"

    : > "$VM_HTTP_DEBUG_RETURN_STATE"
    while IFS='|' read -r ip source table_id iface; do
        case "$ip" in
            10.77.*.*)
                subnet="$(printf '%s\n' "$ip" | awk -F. '{ print $1 "." $2 "." $3 ".0/24" }')"
                ;;
            *) continue ;;
        esac
        grep -Fqx "$subnet" "$VM_HTTP_DEBUG_RETURN_STATE" 2>/dev/null && continue
        ip -4 rule del to "$subnet" table main priority 9980 2>/dev/null || true
        ip -4 rule add to "$subnet" table main priority 9980
        printf '%s\n' "$subnet" >> "$VM_HTTP_DEBUG_RETURN_STATE"
    done < "$VM_HTTP_DEBUG_CLIENTS"
}

HTTP_DEBUG_PROXY_PID=""

vm_http_debug_port_listening() {
    local port_hex="$1"

    awk -v port="$port_hex" '
        $2 ~ (":" port "$") && $4 == "0A" { found=1 }
        END { exit found ? 0 : 1 }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

vm_http_debug_proxy_pids() {
    local proc pid cmd

    for proc in /proc/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        [ "$(readlink "$proc/exe" 2>/dev/null || true)" = "/usr/sbin/squid" ] || continue
        cmd="$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null || true)"
        case "$cmd" in
            *'/usr/sbin/squid -n vpnmanagerhttpdebug '*)
                pid="${proc#/proc/}"
                printf '%s\n' "$pid"
                ;;
        esac
    done
}

vm_http_debug_stop_proxy() {
    local pid pids="$HTTP_DEBUG_PROXY_PID"

    if [ -s "$VM_HTTP_DEBUG_PID_FILE" ]; then
        IFS= read -r pid < "$VM_HTTP_DEBUG_PID_FILE" || pid=""
        pids="$pids $pid"
    fi
    pids="$pids $(vm_http_debug_proxy_pids)"
    for pid in $pids; do
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        kill "$pid" 2>/dev/null || true
    done
    case "$HTTP_DEBUG_PROXY_PID" in
        ''|*[!0-9]*) : ;;
        *) wait "$HTTP_DEBUG_PROXY_PID" 2>/dev/null || true ;;
    esac
    HTTP_DEBUG_PROXY_PID=""
    rm -f "$VM_HTTP_DEBUG_PID_FILE"
}

vm_http_debug_launch_proxy() {
    local ready

    [ -x "$VM_HTTP_DEBUG_SQUID" ] || {
        echo "Squid is not installed" >&2
        return 1
    }

    vm_http_debug_prepare_runtime_dirs
    vm_http_debug_prepare_ca
    vm_http_debug_generate_squid
    "$VM_HTTP_DEBUG_SQUID" -n vpnmanagerhttpdebug -k parse -f "$VM_HTTP_DEBUG_SQUID_CONFIG"
    vm_http_debug_apply_routes

    "$VM_HTTP_DEBUG_SQUID" -n vpnmanagerhttpdebug -N -f "$VM_HTTP_DEBUG_SQUID_CONFIG" &
    HTTP_DEBUG_PROXY_PID=$!
    kill -0 "$HTTP_DEBUG_PROXY_PID" 2>/dev/null || return 1

    ready=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if vm_http_debug_port_listening 0C38 \
            && vm_http_debug_port_listening 0C39; then
            ready=1
            break
        fi
        kill -0 "$HTTP_DEBUG_PROXY_PID" 2>/dev/null || break
        sleep 1
    done
    [ "$ready" = "1" ] || return 1
    vm_http_debug_apply_access
    vm_http_debug_reset_client_flows
}

vm_http_debug_stop_all() {
    vm_http_debug_remove_access
    vm_http_debug_stop_proxy
    vm_http_debug_remove_routes
}

vm_http_debug_start() {
    local generation="" next_generation enabled

    mkdir -p "$VM_HTTP_DEBUG_DIR"
    /etc/init.d/squid stop >/dev/null 2>&1 || true
    trap 'vm_http_debug_stop_all; exit 0' HUP INT TERM

    while true; do
        next_generation="$(sha256sum "$VM_HTTP_DEBUG_CONFIG_FILE" 2>/dev/null | awk '{print $1}')"
        enabled="$(uci -q get "$VM_CFG.global.http_debug_enabled" 2>/dev/null || true)"
        [ "$enabled" = "1" ] || enabled="0"

        if [ "$next_generation" != "$generation" ]; then
            vm_http_debug_stop_all
            generation="$next_generation"
            if [ "$enabled" = "1" ]; then
                vm_http_debug_snapshot_plan || true
                vm_http_debug_launch_proxy || vm_http_debug_stop_all
            fi
        elif [ "$enabled" = "1" ] && [ -z "$(vm_http_debug_proxy_pids)" ]; then
            vm_http_debug_stop_all
            vm_http_debug_snapshot_plan || true
            vm_http_debug_launch_proxy || vm_http_debug_stop_all
        fi
        sleep 2
    done
}

case "${1:-start}" in
    plan) vm_http_debug_snapshot_plan "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" ;;
    generate-squid) vm_http_debug_generate_squid "${2:-}" ;;
    generate-access) vm_http_debug_generate_access "${2:-}" ;;
    start) vm_http_debug_start ;;
    *) echo "usage: $0 [start|plan|generate-squid|generate-access]" >&2; exit 2 ;;
esac
