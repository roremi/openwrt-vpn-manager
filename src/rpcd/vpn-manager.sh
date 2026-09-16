#!/bin/sh

umask 077

VM_LIB_DIR="${VM_LIB_DIR:-/usr/libexec/vpn-manager}"
. "$VM_LIB_DIR/common.sh"
. "$VM_LIB_DIR/uci.sh"
. "$VM_LIB_DIR/health.sh"

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\r\n\t' '   '
}

# Build list responses from one UCI snapshot. Besides avoiding one `uci get`
# process per field, parsing the health snapshot in the same awk invocation
# avoids two full health-file scans per profile.
rpc_snapshot_json() {
    snapshot_view="$1"
    health_file="$VM_STATE_DIR/health-snapshot.txt"
    snapshot_file="$VM_STATE_DIR/rpc-config-snapshot.$$"
    [ -r "$health_file" ] || health_file=/dev/null

    vm_init_dirs
    rm -f "$snapshot_file"
    if ! (umask 077; uci -q show "$VM_CFG" > "$snapshot_file" 2>/dev/null); then
        rm -f "$snapshot_file"
        return 1
    fi

    awk \
        -v view="$snapshot_view" \
        -v config="$VM_CFG" \
        -v health_file="$health_file" '
        function uci_decode(input,    output, i, ch, quoted, pending_space, started) {
            output=""
            quoted=0
            pending_space=0
            started=0

            for (i=1; i<=length(input); i++) {
                ch=substr(input, i, 1)
                if (quoted) {
                    if (ch == "\047") {
                        quoted=0
                        started=1
                    } else {
                        output=output ch
                    }
                    continue
                }

                if (ch == "\047") {
                    if (pending_space && started) output=output " "
                    pending_space=0
                    quoted=1
                } else if (ch == "\\") {
                    if (pending_space && started) output=output " "
                    pending_space=0
                    if (i < length(input)) {
                        i++
                        output=output substr(input, i, 1)
                    }
                    started=1
                } else if (ch ~ /[[:space:]]/) {
                    pending_space=1
                } else {
                    if (pending_space && started) output=output " "
                    pending_space=0
                    output=output ch
                    started=1
                }
            }
            return output
        }

        function json_escape(input,    output, i, ch, code) {
            output=""
            for (i=1; i<=length(input); i++) {
                ch=substr(input, i, 1)
                if (ch == "\\") {
                    output=output "\\\\"
                } else if (ch == "\"") {
                    output=output "\\\""
                } else {
                    code=index(control_chars, ch)
                    if (code > 0) output=output sprintf("\\u%04x", code)
                    else output=output ch
                }
            }
            return output
        }

        function option(section, name) {
            return values[section SUBSEP name]
        }

        function remember_section(section) {
            if (!(section in section_seen)) {
                section_seen[section]=1
                section_order[++section_count]=section
            }
        }

        BEGIN {
            for (control_code=1; control_code<32; control_code++) {
                control_chars=control_chars sprintf("%c", control_code)
            }
        }

        FILENAME == health_file {
            health_fields=split($0, health_part, "|")
            if (health_fields >= 1 && health_part[1] != "") {
                health_seen[health_part[1]]=1
                health_status[health_part[1]]=health_part[3]
                health_age[health_part[1]]=health_part[4]
            }
            next
        }

        {
            equals=index($0, "=")
            if (equals == 0) next

            left=substr($0, 1, equals-1)
            prefix=config "."
            if (substr(left, 1, length(prefix)) != prefix) next

            path=substr(left, length(prefix)+1)
            dot=index(path, ".")
            decoded=uci_decode(substr($0, equals+1))
            if (dot == 0) {
                section=path
                remember_section(section)
                section_type[section]=decoded
            } else {
                section=substr(path, 1, dot-1)
                name=substr(path, dot+1)
                remember_section(section)
                values[section SUBSEP name]=decoded
            }
        }

        END {
            if (view == "profiles") {
                printf "{\"profiles\":["
                emitted=0
                for (index_no=1; index_no<=section_count; index_no++) {
                    section=section_order[index_no]
                    if (section_type[section] != "profile") continue
                    if (emitted++) printf ","

                    status="unknown"
                    age="999999"
                    if (health_seen[section]) {
                        if (health_status[section] != "") status=health_status[section]
                        if (health_age[section] != "") age=health_age[section]
                    }

                    endpoint=option(section, "endpoint_host") ":" option(section, "endpoint_port")
                    printf "{\"id\":\"%s\",\"name\":\"%s\",\"iface\":\"%s\",\"endpoint\":\"%s\",\"enabled\":\"%s\",\"status\":\"%s\",\"handshake_age\":\"%s\",\"address\":\"%s\",\"dns\":\"%s\",\"allowed_ips\":\"%s\",\"mtu\":\"%s\",\"persistent_keepalive\":\"%s\",\"public_key\":\"%s\"}", \
                        json_escape(section), \
                        json_escape(option(section, "name")), \
                        json_escape(option(section, "iface")), \
                        json_escape(endpoint), \
                        json_escape(option(section, "enabled")), \
                        json_escape(status), \
                        json_escape(age), \
                        json_escape(option(section, "address")), \
                        json_escape(option(section, "dns")), \
                        json_escape(option(section, "allowed_ips")), \
                        json_escape(option(section, "mtu")), \
                        json_escape(option(section, "persistent_keepalive")), \
                        json_escape(option(section, "public_key"))
                }
                printf "]}"
                exit
            }

            if (view == "policies") {
                printf "{\"policies\":["
                emitted=0
                for (index_no=1; index_no<=section_count; index_no++) {
                    section=section_order[index_no]
                    if (section_type[section] != "device_policy") continue
                    if (emitted++) printf ","
                    printf "{\"section\":\"%s\",\"hostname\":\"%s\",\"mac\":\"%s\",\"ip\":\"%s\",\"target\":\"%s\"}", \
                        json_escape(section), \
                        json_escape(option(section, "hostname")), \
                        json_escape(option(section, "mac")), \
                        json_escape(option(section, "ip")), \
                        json_escape(option(section, "target"))
                }
                printf "]}"
                exit
            }

            if (view == "blocked_domains") {
                printf "{\"ok\":true,\"domains\":["
                emitted=0
                for (index_no=1; index_no<=section_count; index_no++) {
                    section=section_order[index_no]
                    if (section_type[section] != "blocked_domain") continue
                    if (emitted++) printf ","
                    printf "{\"id\":\"%s\",\"domain\":\"%s\",\"mode\":\"%s\",\"enabled\":\"%s\"}", \
                        json_escape(section), \
                        json_escape(option(section, "domain")), \
                        json_escape(option(section, "mode")), \
                        json_escape(option(section, "enabled"))
                }
                printf "]}"
                exit
            }

            if (view == "status") {
                up=0
                down=0
                unknown=0
                for (index_no=1; index_no<=section_count; index_no++) {
                    section=section_order[index_no]
                    if (section_type[section] != "profile") continue
                    status=(health_seen[section] && health_status[section] != "") ? health_status[section] : "unknown"
                    if (status == "healthy") up++
                    else if (status == "unknown") unknown++
                    else down++
                }
                printf "{\"up\":%d,\"down\":%d,\"unknown\":%d", up, down, unknown
                exit
            }

            if (view == "route_manifest") {
                for (index_no=1; index_no<=section_count; index_no++) {
                    section=section_order[index_no]
                    if (section_type[section] != "profile") continue
                    iface=option(section, "iface")
                    printf "%s|{\"id\":\"%s\",\"name\":\"%s\",\"iface\":\"%s\",\"ip\":\n", \
                        iface, \
                        json_escape(section), \
                        json_escape(option(section, "name")), \
                        json_escape(iface)
                }
            }
        }
    ' "$health_file" "$snapshot_file"
    snapshot_rc=$?
    rm -f "$snapshot_file"
    return "$snapshot_rc"
}

# Generate all UCI mutations for a large relationship scan in one batch. The
# emitted section names originate from UCI itself; request values are used only
# for exact comparisons and are never interpolated into batch commands.
rpc_reference_batch() {
    batch_mode="$1"
    batch_keep_section="${2:-}"
    batch_mac="${3:-}"
    batch_ip="${4:-}"
    snapshot_file="$VM_STATE_DIR/rpc-reference-snapshot.$$"

    vm_init_dirs
    rm -f "$snapshot_file"
    if ! (umask 077; uci -q show "$VM_CFG" > "$snapshot_file" 2>/dev/null); then
        rm -f "$snapshot_file"
        return 1
    fi

    awk \
        -v mode="$batch_mode" \
        -v config="$VM_CFG" \
        -v keep_section="$batch_keep_section" \
        -v keep_mac="$batch_mac" \
        -v keep_ip="$batch_ip" '
        function uci_decode(input,    output, i, ch, quoted, pending_space, started) {
            output=""
            quoted=0
            pending_space=0
            started=0
            for (i=1; i<=length(input); i++) {
                ch=substr(input, i, 1)
                if (quoted) {
                    if (ch == "\047") {
                        quoted=0
                        started=1
                    } else output=output ch
                } else if (ch == "\047") {
                    if (pending_space && started) output=output " "
                    pending_space=0
                    quoted=1
                } else if (ch == "\\") {
                    if (pending_space && started) output=output " "
                    pending_space=0
                    if (i < length(input)) output=output substr(input, ++i, 1)
                    started=1
                } else if (ch ~ /[[:space:]]/) {
                    pending_space=1
                } else {
                    if (pending_space && started) output=output " "
                    pending_space=0
                    output=output ch
                    started=1
                }
            }
            return output
        }

        function option(section, name) {
            return values[section SUBSEP name]
        }

        function remember_section(section) {
            if (!(section in section_seen)) {
                section_seen[section]=1
                section_order[++section_count]=section
            }
        }

        {
            equals=index($0, "=")
            if (equals == 0) next
            left=substr($0, 1, equals-1)
            prefix=config "."
            if (substr(left, 1, length(prefix)) != prefix) next
            path=substr(left, length(prefix)+1)
            dot=index(path, ".")
            decoded=uci_decode(substr($0, equals+1))
            if (dot == 0) {
                section=path
                remember_section(section)
                section_type[section]=decoded
            } else {
                section=substr(path, 1, dot-1)
                name=substr(path, dot+1)
                remember_section(section)
                values[section SUBSEP name]=decoded
            }
        }

        END {
            for (index_no=1; index_no<=section_count; index_no++) {
                section=section_order[index_no]
                if (mode == "dedupe-policy") {
                    if (section_type[section] != "device_policy" || section == keep_section) continue
                    section_mac=tolower(option(section, "mac"))
                    section_ip=option(section, "ip")
                    if ((keep_mac != "" && section_mac == keep_mac) || (keep_ip != "" && section_ip == keep_ip)) {
                        print "R:delete " config "." section
                    }
                } else if (mode == "delete-profile") {
                    if (option(section, "target") != keep_section) continue
                    if (section_type[section] == "device_policy") {
                        print "R:set " config "." section ".target=\047wan\047"
                    } else if (section_type[section] == "wifi_binding") {
                        print "R:set " config "." section ".enabled=\0470\047"
                        print "O:set wireless." section ".disabled=\0471\047"
                    }
                }
            }
        }
    ' "$snapshot_file"
    snapshot_rc=$?
    rm -f "$snapshot_file"
    return "$snapshot_rc"
}

rpc_apply_reference_batch() {
    RPC_REFERENCE_WIRELESS_CHANGED=0
    reference_commands="$(rpc_reference_batch "$@")" || return 1
    [ -n "$reference_commands" ] || return 0
    required_commands="$(printf '%s\n' "$reference_commands" | sed -n 's/^R://p')"
    optional_commands="$(printf '%s\n' "$reference_commands" | sed -n 's/^O://p')"
    reference_batch="$VM_STATE_DIR/rpc-reference-batch.$$"

    if [ -n "$required_commands" ]; then
        printf '%s\n' "$required_commands" > "$reference_batch"
        if ! vm_uci_batch_checked "$reference_batch"; then
            rm -f "$reference_batch"
            uci -q revert "$VM_CFG" >/dev/null 2>&1 || true
            return 1
        fi
    fi
    if [ -n "$optional_commands" ]; then
        printf '%s\n' "$optional_commands" > "$reference_batch"
        if vm_uci_batch_checked "$reference_batch"; then
            RPC_REFERENCE_WIRELESS_CHANGED=1
        else
            uci -q revert wireless >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$reference_batch"
    return 0
}

RPC_CONFIG_LOCKED=0

rpc_config_lock() {
    if vm_config_lock; then
        RPC_CONFIG_LOCKED=1
        return 0
    fi
    echo '{"ok":false,"error":"configuration is busy; retry"}'
    return 1
}

rpc_config_unlock() {
    [ "$RPC_CONFIG_LOCKED" = "1" ] || return 0
    vm_config_unlock
    RPC_CONFIG_LOCKED=0
}

rpc_cleanup() {
    rpc_config_unlock
    rm -f "$VM_STATE_DIR/rpc-config-snapshot.$$" \
        "$VM_STATE_DIR/rpc-reference-snapshot.$$" \
        "$VM_STATE_DIR/rpc-reference-batch.$$" \
        "$VM_STATE_DIR/import-normalized-$$.conf" \
        "$VM_STATE_DIR/http-headers.$$" \
        "$VM_STATE_DIR/http-body.$$" 2>/dev/null || true
    rm -f "$VM_STATE_DIR"/multiebay-*-"$$".conf 2>/dev/null || true
}

trap 'rpc_cleanup' EXIT
trap 'rpc_cleanup; exit 129' HUP
trap 'rpc_cleanup; exit 130' INT
trap 'rpc_cleanup; exit 143' TERM

vm_ensure_jq() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi

    vm_init_dirs
    jq_dir="$VM_STATE_DIR/bin"
    jq_bin="$jq_dir/jq"
    mkdir -p "$jq_dir"

    if [ -x "$jq_bin" ]; then
        PATH="$jq_dir:$PATH"
        export PATH
        return 0
    fi

    vm_require_cmd curl >/dev/null 2>&1 || return 1

    arch="$(uname -m 2>/dev/null || echo unknown)"
    case "$arch" in
        aarch64|arm64) jq_asset="jq-linux-arm64" ;;
        armv7l|armv7|armhf) jq_asset="jq-linux-armel" ;;
        x86_64|amd64) jq_asset="jq-linux-amd64" ;;
        *) return 1 ;;
    esac

    jq_url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/$jq_asset"
    jq_tmp="$jq_bin.tmp.$$"

    rm -f "$jq_tmp"
    if ! curl -fsSL --connect-timeout 8 --max-time 60 -o "$jq_tmp" "$jq_url"; then
        rm -f "$jq_tmp"
        return 1
    fi

    chmod +x "$jq_tmp" || {
        rm -f "$jq_tmp"
        return 1
    }
    mv "$jq_tmp" "$jq_bin" || {
        rm -f "$jq_tmp"
        return 1
    }

    PATH="$jq_dir:$PATH"
    export PATH
    jq --version >/dev/null 2>&1
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
        .gateway,
        .name,
        (.id | tostring?),
        .gateway_id,
        .gateway_name,
        .gatewayName,
        (if (.gateway | type) == "string" then .gateway else empty end),
        .gateway.name,
        (.gateway.id | tostring?),
        .data.name,
        (.data.id | tostring?),
        .data.gateway_id,
        .data.gateway_name,
        .data.gatewayName,
        (if (.data.gateway | type) == "string" then .data.gateway else empty end),
        .data.gateway.name,
        (.data.gateway.id | tostring?),
        .result.name,
        (.result.id | tostring?),
        .result.gateway_id,
        .result.gateway_name,
        .result.gatewayName,
        (if (.result.gateway | type) == "string" then .result.gateway else empty end),
        .result.gateway.name,
        (.result.gateway.id | tostring?)
    ] | map(select(type == "string" and length > 0)) | .[0] // ""' 2>/dev/null
}

multiebay_pick_new_gateway_from_lists() {
    before_json="$1"
    after_json="$2"

    jq -nr \
        --argjson before "${before_json:-[]}" \
        --argjson after "${after_json:-[]}" \
        '
        def names($doc):
            [
                $doc.proxies[]?,
                $doc.items[]?,
                $doc.data[]?,
                $doc.gateways[]?
            ]
            | map(
                .name // .gateway_name // .gatewayName // .gateway.name // (.id|tostring?) // (.gateway.id|tostring?) // empty
            )
            | map(select(type == "string" and length > 0))
            | unique;

        (names($after) - names($before)) as $added
        | if ($added | length) == 1 then $added[0] else "" end
        ' 2>/dev/null
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

# Pick new gateway by comparing proxy_url field between before/after lists.
# More reliable than name-diff when API reuses names.
multiebay_pick_new_gateway_by_proxy_url() {
    before_json="$1"
    after_json="$2"
    proxy_url="$3"

    # Step 1: find gateways in after whose proxy_url matches and were NOT in before.
    jq -nr \
        --argjson before "${before_json:-[]}" \
        --argjson after "${after_json:-[]}" \
        --arg proxy "$proxy_url" \
        '
        def items($doc):
            [
                $doc.proxies[]?,
                $doc.items[]?,
                $doc.data[]?,
                $doc.gateways[]?
            ];
        def nameOf($o): ($o.name // $o.gateway_name // $o.gatewayName // $o.gateway.name // ($o.id|tostring?) // "");
        def proxyOf($o): ($o.proxy_url // $o.proxy // $o.upstream // $o.url // "");

        (items($before) | map(nameOf(.)) | unique) as $before_names |
        [
            items($after)
            | select(
                (proxyOf(.) | . != "" and (. == $proxy or contains($proxy[-20:])))
                and ((nameOf(.)) as $n | ($before_names | index($n)) == null)
              )
            | nameOf(.)
            | select(type == "string" and length > 0)
        ] | unique | .[0] // ""
        ' 2>/dev/null
}

# Last resort: pick the most recently created gateway by created_at timestamp.
# Reliable because the just-created gateway will always have the newest timestamp,
# regardless of how the API structures its proxy_url/proxy_display fields.
multiebay_pick_newest_gateway_by_created_at() {
    proxies_json="$1"
    printf '%s' "$proxies_json" | jq -r '
        [
            (.proxies[]?, .items[]?, .data[]?, .gateways[]?)
            | select(.created_at? // .createdAt? // .created? | type == "string")
        ]
        | sort_by(.created_at // .createdAt // .created)
        | last
        | (.name // .gateway_name // .gatewayName // (.id|tostring?) // "")
    ' 2>/dev/null
}

urlencode() {
    jq -nr --arg v "$1" '$v|@uri'
}

multiebay_slug() {
    echo "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//' | cut -c1-24
}

multiebay_proxy_to_url() {
    raw="$(printf '%s' "$1" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$raw" ] || return 1

    case "$raw" in
        *://*)
            multiebay_normalize_proxy_url "$raw"
            return 0
            ;;
    esac

    # Robust ip:port:user:pass parsing (password may contain additional colons).
    field_count="$(printf '%s' "$raw" | awk -F: '{print NF}')"
    if [ -n "$field_count" ] && [ "$field_count" -ge 4 ]; then
        host="${raw%%:*}"
        rest="${raw#*:}"
        port="${rest%%:*}"
        rest="${rest#*:}"
        user="${rest%%:*}"
        pass="${rest#*:}"

        if echo "$port" | grep -Eq '^[0-9]+$' && [ -n "$host" ] && [ -n "$user" ] && [ -n "$pass" ]; then
            user_enc="$(multiebay_urlencode_component "$user")"
            pass_enc="$(multiebay_urlencode_component "$pass")"
            printf 'socks5://%s:%s@%s:%s' "$user_enc" "$pass_enc" "$host" "$port"
            return 0
        fi
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

multiebay_switch_proxy_scheme() {
    url="$1"
    case "$url" in
        socks5://*) echo "http://${url#socks5://}" ;;
        http://*) echo "socks5://${url#http://}" ;;
        *) echo "$url" ;;
    esac
}

multiebay_proxy_candidates() {
    raw="$1"
    normalized="$2"

    case "$raw" in
        *://*)
            printf '%s\n' "$normalized"
            ;;
        *)
            alt="$(multiebay_switch_proxy_scheme "$normalized")"
            printf '%s\n' "$normalized"
            [ "$alt" != "$normalized" ] && printf '%s\n' "$alt"
            ;;
    esac
}

multiebay_create_gateway() {
    api_base="$1"
    api_key="$2"
    proxy_url="$3"
    allow_http_proxy_json="$4"

    payload="$(jq -cn --arg proxy_url "$proxy_url" --argjson allow_http_proxy "$allow_http_proxy_json" '{proxy_url:$proxy_url, allow_http_proxy:$allow_http_proxy}')"
    http_json_request "POST" "$api_base/api/customer/proxy" "$api_key" "$payload"
}

multiebay_proxy_host() {
    proxy_url="$1"
    echo "$proxy_url" | sed -E 's#^[a-zA-Z0-9+.-]+://##; s#^[^@]+@##; s#[:/].*$##'
}

list_multiebay_settings() {
    api_base="$(vm_global_get multiebay_api_base 2>/dev/null || true)"
    api_key="$(vm_global_get multiebay_api_key 2>/dev/null || true)"
    allow_http_proxy="$(vm_global_get multiebay_allow_http_proxy 2>/dev/null || true)"
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

    [ -n "$api_base" ] || api_base="https://multiebay.com"
    [ -n "$allow_http_proxy" ] || allow_http_proxy="1"

    rpc_config_lock || return
    vm_global_ensure
    vm_global_set multiebay_api_base "$api_base"
    vm_global_set multiebay_allow_http_proxy "$allow_http_proxy"
    if [ -n "$api_key" ]; then
        vm_global_set multiebay_api_key "$api_key"
    fi

    uci commit vpn-manager
    rpc_config_unlock
    echo '{"ok":true}'
}

clear_multiebay_api_key() {
    rpc_config_lock || return
    vm_global_ensure
    uci -q delete vpn-manager.global.multiebay_api_key
    uci commit vpn-manager
    rpc_config_unlock
    echo '{"ok":true}'
}

list_software_api_settings() {
    api_key="$(vm_global_get software_api_key 2>/dev/null || true)"
    api_key_saved="false"
    [ -n "$api_key" ] && api_key_saved="true"

    printf '{"ok":true,"api_key_saved":%s,"api_key":"%s"}' \
        "$api_key_saved" \
        "$(json_escape "$api_key")"
}

save_software_api_key() {
    api_key="$2"

    [ -n "$api_key" ] || {
        echo '{"ok":false,"error":"api key is required"}'
        return
    }

    rpc_config_lock || return
    vm_global_ensure
    vm_global_set software_api_key "$api_key"
    uci commit vpn-manager
    rpc_config_unlock
    echo '{"ok":true}'
}

clear_software_api_key() {
    rpc_config_lock || return
    vm_global_ensure
    uci -q delete vpn-manager.global.software_api_key
    uci commit vpn-manager
    rpc_config_unlock
    echo '{"ok":true}'
}

rotate_software_api_key() {
    new_key="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)"
    [ -n "$new_key" ] || {
        echo '{"ok":false,"error":"unable to generate api key"}'
        return
    }

    rpc_config_lock || return
    vm_global_ensure
    vm_global_set software_api_key "$new_key"
    uci commit vpn-manager
    rpc_config_unlock
    printf '{"ok":true,"api_key":"%s"}' "$(json_escape "$new_key")"
}

lookup_public_ip() {
    iface="$1"
    if [ -n "$iface" ]; then
        curl -sS --interface "$iface" --connect-timeout 2 --max-time 4 https://ipwho.is/ 2>/dev/null || true
    else
        curl -sS --connect-timeout 2 --max-time 4 https://ipwho.is/ 2>/dev/null || true
    fi
}

route_status() {
    cache_file="$VM_STATE_DIR/route-status-cache.json"
    vm_init_dirs
    if [ -s "$cache_file" ]; then
        cat "$cache_file"
    else
        echo '{"ok":true,"wan":{"success":false,"pending":true},"profiles":[],"refreshing":true}'
    fi
}

refresh_route_status() {
    cache_file="$VM_STATE_DIR/route-status-cache.json"
    work="$VM_STATE_DIR/route-status-work.$$"
    tmp_file="$VM_STATE_DIR/route-status-cache.$$.json"
    workers="${VM_ROUTE_STATUS_WORKERS:-4}"
    active=0
    pids=""
    index=0

    vm_init_dirs
    lock -n "$VM_STATE_DIR/route-status.lock" 2>/dev/null || return 0
    trap 'lock -u "$VM_STATE_DIR/route-status.lock" 2>/dev/null || true; rm -rf "$work"; rpc_cleanup' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir -p "$work"
    if ! rpc_snapshot_json route_manifest > "$work/profiles.manifest"; then
        return 1
    fi

    (
        wan_json="$(lookup_public_ip "")"
        [ -n "$wan_json" ] || wan_json='{"success":false}'
        printf '%s' "$wan_json" > "$work/wan.json"
    ) &
    pids="$!"
    active=1

    while IFS='|' read -r iface profile_prefix; do
        [ -n "$iface" ] || continue
        index=$((index + 1))
        output="$work/profile.$(printf '%06d' "$index").json"
        (
            ip_json="$(lookup_public_ip "$iface")"
            [ -n "$ip_json" ] || ip_json='{"success":false}'
            printf '%s%s}' "$profile_prefix" "$ip_json" > "$output"
        ) &
        pids="$pids $!"
        active=$((active + 1))

        if [ "$active" -ge "$workers" ]; then
            for pid in $pids; do wait "$pid" 2>/dev/null || true; done
            pids=""
            active=0
        fi
    done < "$work/profiles.manifest"
    for pid in $pids; do wait "$pid" 2>/dev/null || true; done

    {
        printf '{"ok":true,"wan":'
        cat "$work/wan.json" 2>/dev/null || printf '{"success":false}'
        printf ',"profiles":['
        first=1
        for output in "$work"/profile.*.json; do
            [ -f "$output" ] || continue
            [ $first -eq 1 ] || printf ','
            first=0
            cat "$output"
        done
        printf '],"refreshing":false,"updated_at":%s}' "$(date +%s)"
    } > "$tmp_file"

    if [ ! -s "$tmp_file" ] \
        || ! vm_ensure_jq \
        || ! jq -e '
            type == "object" and
            .ok == true and
            (.wan | type) == "object" and
            (.profiles | type) == "array" and
            all(.profiles[];
                type == "object" and
                (.id | type) == "string" and
                (.name | type) == "string" and
                (.iface | type) == "string" and
                (.ip | type) == "object"
            )
        ' "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file"
        return 1
    fi

    mv "$tmp_file" "$cache_file" || {
        rm -f "$tmp_file"
        return 1
    }
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
        wifi_section="$(uci -q get vpn-manager.$sec.wifi_section)"
        [ -n "$wifi_section" ] || wifi_section="$sec"
        radio="$(uci -q get wireless.$wifi_section.device)"
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
            status="$(vm_profile_health_cached "$target")"
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

    case "$sec" in
        *[!A-Za-z0-9_]*)
            echo '{"ok":false,"error":"binding id may contain only letters, numbers, and underscore"}'
            return
            ;;
    esac
    [ "${#sec}" -le 32 ] || {
        echo '{"ok":false,"error":"binding id must be 32 characters or fewer"}'
        return
    }
    [ -n "$ssid" ] || {
        echo '{"ok":false,"error":"ssid is required"}'
        return
    }
    [ "${#ssid}" -le 32 ] || {
        echo '{"ok":false,"error":"ssid must be 32 characters or fewer"}'
        return
    }
    case "${encryption:-sae-mixed}" in
        none) ;;
        psk2|sae|sae-mixed)
            [ "${#key}" -ge 8 ] && [ "${#key}" -le 63 ] || {
                echo '{"ok":false,"error":"wifi password must contain 8 to 63 characters"}'
                return
            }
            ;;
        *)
            echo '{"ok":false,"error":"unsupported wifi encryption"}'
            return
            ;;
    esac
    case "${enabled:-1}" in
        0|1) ;;
        *)
            echo '{"ok":false,"error":"invalid enabled value"}'
            return
            ;;
    esac

    target="$(vm_wifi_binding_target_profile "$target" 2>/dev/null || true)"
    [ -n "$target" ] || {
        echo '{"ok":false,"error":"target profile not found"}'
        return
    }

    radio="$(vm_wifi_binding_radio_for_default_iface)"
    [ -n "$radio" ] || radio="$(vm_wifi_binding_pick_radio)"
    [ -n "$radio" ] || {
        echo '{"ok":false,"error":"wifi radio not found"}'
        return
    }

    rpc_config_lock || return
    if vm_wifi_binding_exists "$sec"; then
        [ "$(uci -q get vpn-manager.$sec)" = "wifi_binding" ] || {
            rpc_config_unlock
            echo '{"ok":false,"error":"binding id conflicts with another VPN Manager section"}'
            return
        }
        subnet_id="$(uci -q get vpn-manager.$sec.subnet_id)"
        network_name="$(uci -q get vpn-manager.$sec.network)"
        wifi_section="$(uci -q get vpn-manager.$sec.wifi_section)"
    else
        subnet_id="$(vm_wifi_binding_next_subnet_id 2>/dev/null || true)"
        [ -n "$subnet_id" ] || {
            rpc_config_unlock
            echo '{"ok":false,"error":"no free dedicated wifi subnet"}'
            return
        }
        [ -n "$sec" ] || sec="wifi_$subnet_id"
        vm_wifi_binding_exists "$sec" && {
            rpc_config_unlock
            echo '{"ok":false,"error":"binding id already exists"}'
            return
        }
        network_name="$(vm_wifi_binding_network_name "$subnet_id")"
        wifi_section="$(vm_wifi_binding_wireless_section "$subnet_id")"
    fi

    [ -n "$subnet_id" ] || subnet_id="$(vm_wifi_binding_next_subnet_id 2>/dev/null || true)"
    [ -n "$network_name" ] || network_name="$(vm_wifi_binding_network_name "$subnet_id")"
    [ -n "$wifi_section" ] || wifi_section="$(vm_wifi_binding_wireless_section "$subnet_id")"

    expected_network="$(vm_wifi_binding_network_name "$subnet_id")"
    expected_wifi_section="$(vm_wifi_binding_wireless_section "$subnet_id")"
    if [ "$network_name" != "$expected_network" ] || [ "$wifi_section" != "$expected_wifi_section" ]; then
        rpc_config_unlock
        echo '{"ok":false,"error":"legacy dedicated wifi names are unsafe; delete and recreate this binding"}'
        return
    fi

    for resource in \
        "network:$network_name" \
        "network:${network_name}_dev" \
        "wireless:$wifi_section" \
        "dhcp:$network_name" \
        "firewall:$network_name"
    do
        package="${resource%%:*}"
        section="${resource#*:}"
        if uci -q get "$package.$section" >/dev/null 2>&1 \
            && [ "$(uci -q get "$package.$section.vpn_manager")" != "1" ]; then
            rpc_config_unlock
            printf '{"ok":false,"error":"dedicated wifi resource conflicts with existing %s.%s"}' "$package" "$section"
            return
        fi
    done

    checkpoint=""
    if [ -s "$VM_NETWORK_CHANGE_CHECKPOINT" ]; then
        checkpoint="$(cat "$VM_NETWORK_CHANGE_CHECKPOINT" 2>/dev/null || true)"
        vm_checkpoint_valid "$checkpoint" || checkpoint=""
    fi
    if [ -z "$checkpoint" ]; then
        checkpoint="$(vm_checkpoint_create 2>/dev/null || true)"
        [ -n "$checkpoint" ] || {
            rpc_config_unlock
            echo '{"ok":false,"error":"unable to create safety checkpoint"}'
            return
        }
        printf '%s\n' "$checkpoint" > "$VM_NETWORK_CHANGE_CHECKPOINT"
        chmod 600 "$VM_NETWORK_CHANGE_CHECKPOINT" 2>/dev/null || true
    fi

    gateway="$(vm_wifi_binding_gateway "$subnet_id")"
    dns_ip="$(vm_first_ipv4 "$(uci -q get vpn-manager.$target.dns)")"
    [ -n "$dns_ip" ] || dns_ip="$gateway"

    if ! (
    set -e
    uci set "vpn-manager.$sec=wifi_binding"
    uci set "vpn-manager.$sec.enabled=${enabled:-1}"
    uci set "vpn-manager.$sec.ssid=$ssid"
    uci set "vpn-manager.$sec.key=$key"
    uci set "vpn-manager.$sec.encryption=${encryption:-sae-mixed}"
    uci set "vpn-manager.$sec.target=$target"
    uci set "vpn-manager.$sec.subnet_id=$subnet_id"
    uci set "vpn-manager.$sec.network=$network_name"
    uci set "vpn-manager.$sec.wifi_section=$wifi_section"

    uci -q delete "wireless.$wifi_section" || true
    uci set "wireless.$wifi_section=wifi-iface"
    uci set "wireless.$wifi_section.vpn_manager=1"
    uci set "wireless.$wifi_section.device=$radio"
    uci set "wireless.$wifi_section.mode=ap"
    uci set "wireless.$wifi_section.network=$network_name"
    uci set "wireless.$wifi_section.ssid=$ssid"
    uci set "wireless.$wifi_section.encryption=${encryption:-sae-mixed}"
    if [ "${encryption:-sae-mixed}" != "none" ] && [ -n "$key" ]; then
        uci set "wireless.$wifi_section.key=$key"
    else
        uci -q delete "wireless.$wifi_section.key" || true
    fi
    uci set "wireless.$wifi_section.isolate=1"
    if [ "${enabled:-1}" = "0" ]; then
        uci set "wireless.$wifi_section.disabled=1"
    else
        uci set "wireless.$wifi_section.disabled=0"
    fi

    uci -q delete "network.$network_name" || true
    uci set "network.$network_name=interface"
    uci set "network.$network_name.vpn_manager=1"
    uci set "network.$network_name.proto=static"
    uci set "network.$network_name.device=br-$network_name"
    uci set "network.$network_name.ipaddr=$gateway"
    uci set "network.$network_name.netmask=255.255.255.0"
    uci set "network.$network_name.defaultroute=0"
    uci set "network.$network_name.delegate=0"

    uci -q delete "network.${network_name}_dev" || true
    uci set "network.${network_name}_dev=device"
    uci set "network.${network_name}_dev.vpn_manager=1"
    uci set "network.${network_name}_dev.name=br-$network_name"
    uci set "network.${network_name}_dev.type=bridge"
    uci set "network.${network_name}_dev.bridge_empty=1"

    uci -q delete "dhcp.$network_name" || true
    uci set "dhcp.$network_name=dhcp"
    uci set "dhcp.$network_name.vpn_manager=1"
    uci set "dhcp.$network_name.interface=$network_name"
    uci set "dhcp.$network_name.start=100"
    uci set "dhcp.$network_name.limit=100"
    uci set "dhcp.$network_name.leasetime=12h"
    uci set "dhcp.$network_name.dhcpv6=disabled"
    uci set "dhcp.$network_name.ra=disabled"
    uci set "dhcp.$network_name.ndp=disabled"
    uci add_list "dhcp.$network_name.dhcp_option=3,$gateway"
    uci add_list "dhcp.$network_name.dhcp_option=6,$dns_ip"

    uci -q delete "firewall.$network_name" || true
    uci set "firewall.$network_name=zone"
    uci set "firewall.$network_name.vpn_manager=1"
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
    ); then
        vm_checkpoint_restore_config "$checkpoint" >/dev/null 2>&1 || true
        rm -f "$VM_NETWORK_CHANGE_CHECKPOINT"
        rpc_config_unlock
        echo '{"ok":false,"error":"unable to save dedicated wifi safely"}'
        return
    fi

    rpc_config_unlock
    if ! vm_apply_request network wifi-binding-save; then
        rpc_config_lock || {
            echo '{"ok":false,"error":"wifi saved but apply queue is busy; safety rollback remains armed"}'
            return
        }
        vm_checkpoint_restore_config "$checkpoint" >/dev/null 2>&1 || true
        rm -f "$VM_NETWORK_CHANGE_CHECKPOINT"
        rpc_config_unlock
        echo '{"ok":false,"error":"unable to queue dedicated wifi apply; configuration restored"}'
        return
    fi
    echo '{"ok":true,"queued":true,"job":"network"}'
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

    rpc_config_lock || return
    network_name="$(uci -q get vpn-manager.$sec.network)"
    wifi_section="$(uci -q get vpn-manager.$sec.wifi_section)"
    [ -n "$network_name" ] || network_name="$sec"
    [ -n "$wifi_section" ] || wifi_section="$sec"

    checkpoint=""
    if [ -s "$VM_NETWORK_CHANGE_CHECKPOINT" ]; then
        checkpoint="$(cat "$VM_NETWORK_CHANGE_CHECKPOINT" 2>/dev/null || true)"
        vm_checkpoint_valid "$checkpoint" || checkpoint=""
    fi
    if [ -z "$checkpoint" ]; then
        checkpoint="$(vm_checkpoint_create 2>/dev/null || true)"
        [ -n "$checkpoint" ] || {
            rpc_config_unlock
            echo '{"ok":false,"error":"unable to create safety checkpoint"}'
            return
        }
        printf '%s\n' "$checkpoint" > "$VM_NETWORK_CHANGE_CHECKPOINT"
        chmod 600 "$VM_NETWORK_CHANGE_CHECKPOINT" 2>/dev/null || true
    fi

    if ! (
    set -e
    uci -q delete "vpn-manager.$sec"
    [ "$(uci -q get wireless.$wifi_section.vpn_manager)" != "1" ] || uci -q delete "wireless.$wifi_section"
    [ "$(uci -q get network.$network_name.vpn_manager)" != "1" ] || uci -q delete "network.$network_name"
    [ "$(uci -q get network.${network_name}_dev.vpn_manager)" != "1" ] || uci -q delete "network.${network_name}_dev"
    [ "$(uci -q get dhcp.$network_name.vpn_manager)" != "1" ] || uci -q delete "dhcp.$network_name"
    [ "$(uci -q get firewall.$network_name.vpn_manager)" != "1" ] || uci -q delete "firewall.$network_name"

    uci commit vpn-manager
    uci commit wireless
    uci commit network
    uci commit dhcp
    uci commit firewall
    ); then
        vm_checkpoint_restore_config "$checkpoint" >/dev/null 2>&1 || true
        rm -f "$VM_NETWORK_CHANGE_CHECKPOINT"
        rpc_config_unlock
        echo '{"ok":false,"error":"unable to delete dedicated wifi safely"}'
        return
    fi

    rpc_config_unlock
    if ! vm_apply_request network wifi-binding-delete; then
        rpc_config_lock || {
            echo '{"ok":false,"error":"wifi deleted but apply queue is busy; safety rollback remains armed"}'
            return
        }
        vm_checkpoint_restore_config "$checkpoint" >/dev/null 2>&1 || true
        rm -f "$VM_NETWORK_CHANGE_CHECKPOINT"
        rpc_config_unlock
        echo '{"ok":false,"error":"unable to queue dedicated wifi delete; configuration restored"}'
        return
    fi
    echo '{"ok":true,"queued":true,"job":"network"}'
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

    rpc_config_lock || return
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
    rpc_config_unlock
    vm_apply_request network wifi-settings
    echo '{"ok":true,"queued":true,"job":"network"}'
}

list_profiles() {
    rpc_snapshot_json profiles || echo '{"ok":false,"error":"unable to read configuration"}'
}

list_devices() {
    local tmp obj mac
    tmp="/tmp/vpn-manager/devices.$$"

    {
        awk '{print "dhcp|"$3"|"tolower($2)"|"$4"|unknown"}' /tmp/dhcp.leases 2>/dev/null
        ip -4 neigh show 2>/dev/null | awk '
            /lladdr/ {
                ip=$1; dev=""; mac=""; st="unknown";
                for (i=1; i<=NF; i++) {
                    if ($i=="dev" && (i+1)<=NF) { dev=$(i+1); }
                    if ($i=="lladdr" && (i+1)<=NF) { mac=tolower($(i+1)); }
                }
                st=$NF;
                if (ip ~ /^[0-9]+\./ && dev ~ /^br-/ && dev !~ /(^|[-_.])wan($|[-_.])/ && mac != "" && mac != "00:00:00:00:00:00") {
                    print "neigh|" ip "|" mac "|unknown|" st;
                }
            }
        '

        # hostapd is authoritative for Wi-Fi association state and updates as
        # soon as a station joins or leaves. Keep the neighbor table as the
        # lightweight fallback for Ethernet and non-hostapd LAN bridges.
        if command -v ubus >/dev/null 2>&1; then
            for obj in $(ubus list 'hostapd.*' 2>/dev/null); do
                ubus call "$obj" get_clients 2>/dev/null |
                    sed -n 's/^[[:space:]]*"\([0-9A-Fa-f:]*\)"[[:space:]]*:.*/\1/p' |
                    grep -Ei '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' |
                    while IFS= read -r mac; do
                        printf 'wifi||%s|unknown|associated\n' "$(printf '%s' "$mac" | tr 'A-Z' 'a-z')"
                    done
            done
        fi
    } | awk -F'\|' '
        NF>=5 {
            src=$1; ip=$2; mac=tolower($3); host=$4; st=tolower($5);
            if (mac == "") next;

            if (src == "wifi") {
                wifi_by_mac[mac]=1;
                next;
            }

            if (ip == "") next;
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
                if (mac in wifi_by_mac) {
                    st="associated";
                    conn="true";
                } else {
                    conn=((st=="reachable" || st=="stale" || st=="delay" || st=="probe" || st=="permanent")?"true":"false");
                }
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
    rpc_snapshot_json policies || echo '{"ok":false,"error":"unable to read configuration"}'
}

list_blocked_domains() {
    rpc_snapshot_json blocked_domains || echo '{"ok":false,"error":"unable to read configuration"}'
}

http_debug_status() {
    enabled="$(vm_global_get http_debug_enabled 2>/dev/null || true)"
    [ "$enabled" = "1" ] || enabled="0"
    binary_ready=false
    running=false
    ca_ready=false
    [ -x /usr/sbin/squid ] && [ -x /usr/lib/squid/security_file_certgen ] && binary_ready=true
    for proc in /proc/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        [ "$(readlink "$proc/exe" 2>/dev/null || true)" = "/usr/sbin/squid" ] || continue
        proxy_cmd="$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null || true)"
        case "$proxy_cmd" in
            *'/usr/sbin/squid -n vpnmanagerhttpdebug '*) running=true; break ;;
        esac
    done
    [ -s /etc/vpn-manager/mitmproxy/mitmproxy-ca-cert.pem ] && ca_ready=true

    printf '{"ok":true,"mode":"transparent","enabled":"%s","binary_ready":%s,"running":%s,"ca_ready":%s,"clients":[' \
        "$enabled" "$binary_ready" "$running" "$ca_ready"
    first=1
    for sec in $(vm_http_debug_client_list); do
        [ $first -eq 1 ] || printf ','
        first=0
        printf '{"id":"%s","hostname":"%s","mac":"%s","ip":"%s","enabled":"%s"}' \
            "$(json_escape "$sec")" \
            "$(json_escape "$(uci -q get "vpn-manager.$sec.hostname" 2>/dev/null || true)")" \
            "$(json_escape "$(uci -q get "vpn-manager.$sec.mac" 2>/dev/null || true)")" \
            "$(json_escape "$(uci -q get "vpn-manager.$sec.ip" 2>/dev/null || true)")" \
            "$(json_escape "$(uci -q get "vpn-manager.$sec.enabled" 2>/dev/null || true)")"
    done
    printf '],"rules":['
    first=1
    for sec in $(vm_blocked_url_list); do
        [ $first -eq 1 ] || printf ','
        first=0
        printf '{"id":"%s","protocol":"%s","host":"%s","method":"%s","path":"%s","enabled":"%s"}' \
            "$(json_escape "$sec")" \
            "$(json_escape "$(uci -q get "vpn-manager.$sec.protocol" 2>/dev/null || true)")" \
            "$(json_escape "$(uci -q get "vpn-manager.$sec.host" 2>/dev/null || true)")" \
            "$(json_escape "$(uci -q get "vpn-manager.$sec.method" 2>/dev/null || true)")" \
            "$(json_escape "$(uci -q get "vpn-manager.$sec.path" 2>/dev/null || true)")" \
            "$(json_escape "$(uci -q get "vpn-manager.$sec.enabled" 2>/dev/null || true)")"
    done
    printf ']}'
}

http_debug_log() {
    log_file="/var/log/vpn-manager/http-debug/access.log"
    printf '{"ok":true,"lines":['
    first=1
    tail -n 200 "$log_file" 2>/dev/null | while IFS= read -r line; do
        [ $first -eq 1 ] || printf ','
        first=0
        printf '"%s"' "$(json_escape "$line")"
    done
    printf ']}'
}

save_http_debug_settings() {
    enabled="$2"
    [ "$enabled" = "1" ] || enabled="0"
    rpc_config_lock || return
    vm_global_ensure
    vm_global_set http_debug_enabled "$enabled"
    uci commit vpn-manager
    rpc_config_unlock
    echo '{"ok":true}'
}

save_http_debug_client() {
    sec="$2"
    mac="$(normalize_mac "$3")"
    ip="$4"
    hostname="$5"
    enabled="$6"

    [ -n "$mac" ] && rpc_valid_mac "$mac" || {
        echo '{"ok":false,"error":"valid MAC address is required"}'
        return
    }
    rpc_valid_ipv4 "$ip" || {
        echo '{"ok":false,"error":"valid IPv4 address is required"}'
        return
    }
    [ "$enabled" = "0" ] || enabled="1"
    [ -n "$sec" ] || sec="http_$(printf '%s' "$mac" | tr -d ':' | cut -c1-12)"

    rpc_config_lock || return
    uci set "vpn-manager.$sec=http_debug_client"
    uci set "vpn-manager.$sec.mac=$mac"
    uci set "vpn-manager.$sec.ip=$ip"
    uci set "vpn-manager.$sec.hostname=$hostname"
    uci set "vpn-manager.$sec.enabled=$enabled"
    uci commit vpn-manager
    rpc_config_unlock
    printf '{"ok":true,"id":"%s"}' "$(json_escape "$sec")"
}

delete_http_debug_client() {
    sec="$2"
    vm_http_debug_client_exists "$sec" || {
        echo '{"ok":false,"error":"HTTP debug client not found"}'
        return
    }
    rpc_config_lock || return
    uci -q delete "vpn-manager.$sec"
    uci commit vpn-manager
    rpc_config_unlock
    echo '{"ok":true}'
}

save_blocked_url() {
    sec="$2"
    input="$3"
    method="$(printf '%s' "$4" | tr 'a-z' 'A-Z')"
    enabled="$5"

    case "$input" in
        http://*) protocol=http; rest="${input#http://}" ;;
        https://*) protocol=https; rest="${input#https://}" ;;
        *) echo '{"ok":false,"error":"URL must start with http:// or https://"}'; return ;;
    esac
    host="${rest%%/*}"
    if [ "$host" = "$rest" ]; then
        url_path='/*'
    else
        url_path="/${rest#*/}"
        url_path="${url_path%%\?*}"
        [ -n "$url_path" ] || url_path='/'
    fi
    host="$(printf '%s' "$host" | tr 'A-Z' 'a-z')"
    printf '%s\n' "$host" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' || {
        echo '{"ok":false,"error":"invalid URL host"}'
        return
    }
    case "$url_path" in
        /*) : ;;
        *) echo '{"ok":false,"error":"invalid URL path"}'; return ;;
    esac
    printf '%s\n' "$url_path" | grep -Eq '^[^|"\\[:space:][:cntrl:]]+$' || {
        echo '{"ok":false,"error":"URL path contains unsupported characters"}'
        return
    }
    case "$method" in
        GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|'*') : ;;
        *) echo '{"ok":false,"error":"unsupported HTTP method"}'; return ;;
    esac
    [ "$enabled" = "0" ] || enabled="1"
    [ -n "$sec" ] || sec="url_$(printf '%s' "$protocol://$host$url_path|$method" | sha256sum | cut -c1-12)"

    rpc_config_lock || return
    uci set "vpn-manager.$sec=blocked_url"
    uci set "vpn-manager.$sec.protocol=$protocol"
    uci set "vpn-manager.$sec.host=$host"
    uci set "vpn-manager.$sec.method=$method"
    uci set "vpn-manager.$sec.path=$url_path"
    uci set "vpn-manager.$sec.enabled=$enabled"
    uci commit vpn-manager
    rpc_config_unlock
    printf '{"ok":true,"id":"%s"}' "$(json_escape "$sec")"
}

delete_blocked_url() {
    sec="$2"
    vm_blocked_url_exists "$sec" || {
        echo '{"ok":false,"error":"blocked URL not found"}'
        return
    }
    rpc_config_lock || return
    uci -q delete "vpn-manager.$sec"
    uci commit vpn-manager
    rpc_config_unlock
    echo '{"ok":true}'
}

vm_block_slug() {
    printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//' | cut -c1-32
}

save_blocked_domain() {
    sec="$2"
    domain="$3"
    mode="$4"
    enabled="$5"

    domain="$(printf '%s' "$domain" | tr 'A-Z' 'a-z' | tr -d ' \t\r\n' | sed -E 's#^[a-z][a-z0-9+.-]*://##; s#/.*$##; s#\?.*$##; s#^[^@]*@##; s#:[0-9]+$##; s#^\*\.##; s#^\.+##; s#\.+$##')"

    [ -n "$domain" ] || {
        echo '{"ok":false,"error":"domain is required"}'
        return
    }
    echo "$domain" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' || {
        echo '{"ok":false,"error":"invalid domain"}'
        return
    }

    case "$mode" in
        exact) : ;;
        *) mode="wildcard" ;;
    esac
    [ "$enabled" = "0" ] && enabled="0" || enabled="1"

    [ -n "$sec" ] || sec="blk_$(vm_block_slug "$domain")"

    rpc_config_lock || return
    uci set "vpn-manager.$sec=blocked_domain"
    uci set "vpn-manager.$sec.domain=$domain"
    uci set "vpn-manager.$sec.mode=$mode"
    uci set "vpn-manager.$sec.enabled=$enabled"
    uci commit vpn-manager
    rpc_config_unlock

    vm_block_request domain-save
    printf '{"ok":true,"id":"%s","queued":true,"job":"block"}' "$(json_escape "$sec")"
}

delete_blocked_domain() {
    sec="$2"
    [ -n "$sec" ] || {
        echo '{"ok":false,"error":"missing section"}'
        return
    }
    vm_blocked_domain_exists "$sec" || {
        echo '{"ok":false,"error":"blocked domain not found"}'
        return
    }
    rpc_config_lock || return
    uci -q delete "vpn-manager.$sec"
    uci commit vpn-manager
    rpc_config_unlock
    rm -f "$VM_STATE_DIR/block-cache/$sec.meta" "$VM_STATE_DIR/block-cache/$sec.v4" "$VM_STATE_DIR/block-cache/$sec.v6" 2>/dev/null || true
    vm_block_request domain-delete
    echo '{"ok":true,"queued":true,"job":"block"}'
}
status() {
    if rpc_snapshot_json status; then
        printf ',"timestamp":"%s"}' "$(vm_now)"
    else
        echo '{"ok":false,"error":"unable to read configuration"}'
    fi
}

apply_changes() {
    vm_apply_request full manual-apply
    echo '{"ok":true,"queued":true,"job":"full"}'
}

apply_status() {
    vm_apply_status_json
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
    rpc_config_lock || return
    vm_profile_set "$sec" "enabled" "$enabled"
    uci commit vpn-manager
    rpc_config_unlock
    vm_apply_request full profile-toggle
    vm_block_request profile-toggle
    echo '{"ok":true,"queued":true,"job":"full"}'
}

normalize_mac() {
    echo "$1" | tr 'A-Z' 'a-z'
}

rpc_valid_mac() {
    printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'
}

rpc_valid_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i=1; i<=4; i++)
                if ($i !~ /^[0-9]+$/ || $i + 0 > 255) exit 1
        }
    '
}

dedupe_device_policies() {
    keep_section="$1"
    keep_mac="$(normalize_mac "$2")"
    keep_ip="$3"
    rpc_apply_reference_batch dedupe-policy "$keep_section" "$keep_mac" "$keep_ip"
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
    rpc_valid_mac "$mac" || {
        echo '{"ok":false,"error":"invalid MAC address"}'
        return
    }
    if [ -n "$ip" ] && ! rpc_valid_ipv4 "$ip"; then
        echo '{"ok":false,"error":"invalid IPv4 address"}'
        return
    fi

    if [ "$target" != "wan" ] && ! vm_profile_exists "$target"; then
        mapped_target="$(vm_profile_by_iface "$target" 2>/dev/null || true)"
        if [ -n "$mapped_target" ]; then
            target="$mapped_target"
        else
            printf '{"ok":false,"error":"target profile not found: %s"}' "$(json_escape "$target")"
            return
        fi
    fi

    rpc_config_lock || return
    if ! dedupe_device_policies "$section" "$mac" "$ip"; then
        rpc_config_unlock
        echo '{"ok":false,"error":"unable to deduplicate policies"}'
        return
    fi
    vm_policy_set_device_target "$section" "$mac" "$ip" "$hostname" "$target"
    uci commit vpn-manager
    rpc_config_unlock

    vm_apply_request pbr policy-save
    echo '{"ok":true,"queued":true,"job":"pbr"}'
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

    rpc_config_lock || return
    if vm_profile_exists "$sec"; then
        :
    else
        vm_profile_add "$sec"
        vm_profile_set "$sec" "iface" "$(vm_iface_name_for_section "$sec")"
        table_id="$(vm_profile_next_table_id 2>/dev/null || true)"
        [ -n "$table_id" ] || {
            rpc_config_unlock
            echo '{"ok":false,"error":"no free routing table id"}'
            return
        }
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

    uci commit vpn-manager
    rpc_config_unlock
    vm_apply_request full profile-save
    vm_block_request profile-save
    echo '{"ok":true,"queued":true,"job":"full"}'
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

    rpc_config_lock || return
    if ! rpc_apply_reference_batch delete-profile "$sec"; then
        rpc_config_unlock
        echo '{"ok":false,"error":"unable to update profile references"}'
        return
    fi
    vm_profile_delete "$sec"

    uci commit vpn-manager
    if [ "$RPC_REFERENCE_WIRELESS_CHANGED" = "1" ]; then
        uci commit wireless 2>/dev/null || true
    fi
    rpc_config_unlock

    vm_apply_request full profile-delete
    vm_block_request profile-delete
    echo '{"ok":true,"queued":true,"job":"full"}'
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

    rpc_config_lock || return
    uci -q delete "vpn-manager.$section"
    uci commit vpn-manager
    rpc_config_unlock
    vm_apply_request pbr policy-delete
    echo '{"ok":true,"queued":true,"job":"pbr"}'
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
    normalized_conf="$VM_STATE_DIR/import-normalized-$$.conf"
    vm_init_dirs
    tr -d '\r' < "$conf_file" > "$normalized_conf"
    conf_file="$normalized_conf"
    if ! rpc_config_lock; then
        rm -f "$normalized_conf"
        return
    fi
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

    new_iface="$(vm_iface_name_for_section "$sec")"
    table_id="$(vm_profile_next_table_id 2>/dev/null || true)"
    [ -n "$table_id" ] || {
        rpc_config_unlock
        rm -f "$normalized_conf"
        echo '{"ok":false,"error":"no free routing table id"}'
        return
    }
    fwmark="$(vm_profile_fwmark_for_table "$table_id")"

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

    uci commit vpn-manager
    rpc_config_unlock
    rm -f "$normalized_conf"
    vm_apply_request full profile-import
    vm_block_request profile-import
    echo '{"ok":true,"queued":true,"job":"full"}'
}

create_multiebay_profile() {
    sec="$2"
    api_base="$3"
    api_key="$4"
    proxy_input="$5"
    proxy_url="$5"
    gateway_name="$6"
    client_name="$7"
    profile_name="$8"
    allow_http_proxy="$9"

    [ -n "$api_base" ] || api_base="$(vm_global_get multiebay_api_base 2>/dev/null || true)"
    [ -n "$api_key" ] || api_key="$(vm_global_get multiebay_api_key 2>/dev/null || true)"
    [ -n "$allow_http_proxy" ] || allow_http_proxy="$(vm_global_get multiebay_allow_http_proxy 2>/dev/null || true)"

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
    vm_ensure_jq >/dev/null 2>&1 || {
        echo '{"ok":false,"error":"missing command: jq (auto-download failed)"}'
        return
    }

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
        proxies_before="$(http_json_request "GET" "$api_base/api/customer/proxies" "$api_key" 2>/dev/null || true)"
        gateway_resp=""
        gateway_errs=""
        created_proxy_url=""

        for candidate_proxy in $(multiebay_proxy_candidates "$proxy_input" "$proxy_url"); do
            if candidate_resp="$(multiebay_create_gateway "$api_base" "$api_key" "$candidate_proxy" "$allow_http_proxy_json" 2>&1)"; then
                gateway_resp="$candidate_resp"
                created_proxy_url="$candidate_proxy"
                break
            fi
            if [ -n "$gateway_errs" ]; then
                gateway_errs="$gateway_errs; $candidate_proxy => $candidate_resp"
            else
                gateway_errs="$candidate_proxy => $candidate_resp"
            fi
        done

        [ -n "$gateway_resp" ] || {
            printf '{"ok":false,"error":"unable to create MultiEbay gateway: %s"}' "$(json_escape "$gateway_errs")"
            return
        }

        proxy_url="$created_proxy_url"
        gateway_name="$(printf '%s' "$gateway_resp" | multiebay_pick_gateway_name)"
        # Small delay to allow the API to register the newly created gateway.
        [ -n "$gateway_name" ] || sleep 1

        if [ -z "$gateway_name" ]; then
            for _ in 1 2 3; do
                proxies_resp="$(http_json_request "GET" "$api_base/api/customer/proxies" "$api_key" 2>/dev/null || true)"
                gateway_name="$(multiebay_pick_new_gateway_from_lists "$proxies_before" "$proxies_resp")"
                [ -n "$gateway_name" ] || gateway_name="$(printf '%s' "$proxies_resp" | multiebay_lookup_gateway_by_proxy "$proxy_url")"
                [ -n "$gateway_name" ] || gateway_name="$(printf '%s' "$proxies_resp" | multiebay_lookup_gateway_by_hostport_unique "$proxy_url")"
                [ -n "$gateway_name" ] || gateway_name="$(multiebay_pick_new_gateway_by_proxy_url "$proxies_before" "$proxies_resp" "$proxy_url")"
                [ -n "$gateway_name" ] && break
                sleep 1
            done
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
    rpc_config_lock || {
        echo '{"ok":false,"error":"profile imported but name update is busy"}'
        return
    }
    vm_profile_set "$sec" "name" "$profile_name"
    uci commit vpn-manager
    rpc_config_unlock

    printf '{"ok":true,"id":"%s","gateway_name":"%s","wg_name":"%s","queued":true,"job":"full"}' \
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
    list_blocked_domains) list_blocked_domains ;;
    save_blocked_domain) save_blocked_domain "$@" ;;
    delete_blocked_domain) delete_blocked_domain "$@" ;;
    http_debug_status) http_debug_status ;;
    http_debug_log) http_debug_log ;;
    save_http_debug_settings) save_http_debug_settings "$@" ;;
    save_http_debug_client) save_http_debug_client "$@" ;;
    delete_http_debug_client) delete_http_debug_client "$@" ;;
    save_blocked_url) save_blocked_url "$@" ;;
    delete_blocked_url) delete_blocked_url "$@" ;;
    route_status) route_status ;;
    refresh_route_status) refresh_route_status ;;
    apply_status) apply_status ;;
    list_multiebay_settings) list_multiebay_settings ;;
    save_multiebay_settings) save_multiebay_settings "$@" ;;
    clear_multiebay_api_key) clear_multiebay_api_key ;;
    list_software_api_settings) list_software_api_settings ;;
    save_software_api_key) save_software_api_key "$@" ;;
    clear_software_api_key) clear_software_api_key ;;
    rotate_software_api_key) rotate_software_api_key ;;
    create_multiebay_profile) create_multiebay_profile "$@" ;;
    apply) apply_changes ;;
    rollback) rollback_changes ;;
    *) echo '{"error":"unsupported method"}' ;;
esac
