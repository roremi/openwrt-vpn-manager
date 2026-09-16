#!/bin/sh

VM_LIB_DIR="${VM_LIB_DIR:-/usr/libexec/vpn-manager}"
. "$VM_LIB_DIR/common.sh"
. "$VM_LIB_DIR/uci.sh"

VM_NFT_FILE="${VM_NFT_FILE:-$VM_STATE_DIR/vpn-manager.nft}"
VM_NFT_NAT_FILE="${VM_NFT_NAT_FILE:-$VM_STATE_DIR/vpn-manager-nat.nft}"
VM_NFT_DNS_FILE="${VM_NFT_DNS_FILE:-$VM_STATE_DIR/vpn-manager-dns.nft}"
VM_NFT_DNS_GUARD_FILE="${VM_NFT_DNS_GUARD_FILE:-$VM_STATE_DIR/vpn-manager-dns-guard.nft}"
VM_NFT_STRICT_FILE="${VM_NFT_STRICT_FILE:-$VM_STATE_DIR/vpn-manager-strict.nft}"
VM_NFT_BLOCK_FILE="${VM_NFT_BLOCK_FILE:-$VM_STATE_DIR/vpn-manager-block.nft}"
VM_SRC_RULES_FILE="${VM_SRC_RULES_FILE:-$VM_STATE_DIR/source-rules.txt}"
VM_NFT_APPLY_FILE="${VM_NFT_APPLY_FILE:-$VM_STATE_DIR/vpn-manager-apply.nft}"
VM_BLOCK_CACHE_DIR="$VM_STATE_DIR/block-cache"
VM_BLOCK_RESOLVE_WORKERS="${VM_BLOCK_RESOLVE_WORKERS:-6}"
VM_BLOCK_QUERY_TIMEOUT="${VM_BLOCK_QUERY_TIMEOUT:-3}"
VM_BLOCK_CACHE_TTL="${VM_BLOCK_CACHE_TTL:-1800}"
VM_BLOCK_REFRESH_BUDGET="${VM_BLOCK_REFRESH_BUDGET:-25}"
VM_BLOCK_FAILURE_RETRY="${VM_BLOCK_FAILURE_RETRY:-60}"
VM_BLOCK_FINALIZE_RESERVE="${VM_BLOCK_FINALIZE_RESERVE:-14}"

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

# --- Domain blocking -------------------------------------------------------
# Blocking is IP-based (nftables set) so it works uniformly for every client,
# including VPN-routed devices whose DNS is force-pinned to a remote resolver
# and therefore never traverses the local dnsmasq. Each enabled blocked_domain
# is resolved (via the local resolver AND every active VPN resolver so both the
# direct and VPN-exit GeoDNS addresses are captured) and its A/AAAA records are
# dropped in a dedicated forward-hook chain.

# Turn a pasted URL or bare host into a lowercase hostname.
vm_pbr_block_normalize_domain() {
    printf '%s' "$1" \
        | tr 'A-Z' 'a-z' \
        | tr -d ' \t\r\n' \
        | sed -E 's#^[a-z][a-z0-9+.-]*://##; s#/.*$##; s#\?.*$##; s#^[^@]*@##; s#:[0-9]+$##; s#^\*\.##; s#^\.+##; s#\.+$##'
}

# Unique list of resolver IPs to query (local dnsmasq + each enabled VPN DNS).
vm_pbr_block_resolvers() {
    {
        echo "127.0.0.1"
        echo "1.1.1.1"
        echo "8.8.8.8"
        local p dns
        for p in $(vm_profile_list); do
            [ "$(uci -q get vpn-manager.$p.enabled)" = "1" ] || continue
            dns="$(vm_pbr_first_ipv4 "$(uci -q get vpn-manager.$p.dns)")"
            [ -n "$dns" ] && echo "$dns"
        done
    } | awk 'NF && !seen[$0]++'
}

# Read the complete resolver/domain plan from one checked UCI snapshot. The
# block worker intentionally does this without config.lock; refresh_block later
# verifies the persistent config generation immediately before the nft swap.
vm_pbr_block_snapshot_config() {
    local config_snapshot="$1"
    local resolver_file="$2"
    local domain_file="$3"
    local old_umask

    old_umask="$(umask)"
    umask 077
    if ! uci -q show "$VM_CFG" > "$config_snapshot"; then
        umask "$old_umask"
        return 1
    fi
    umask "$old_umask"

    awk -v config="$VM_CFG" -v resolvers="$resolver_file" -v domains="$domain_file" '
        function decode(input,    output, i, ch, quoted, pending_space, started) {
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
        function first_ipv4(value,    count, parts, i) {
            gsub(/,/, " ", value)
            count=split(value, parts, /[[:space:]]+/)
            for (i=1; i<=count; i++) {
                if (parts[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return parts[i]
            }
            return ""
        }
        function normalize_domain(value) {
            value=tolower(value)
            gsub(/[[:space:]]/, "", value)
            sub(/^[a-z][a-z0-9+.-]*:\/\//, "", value)
            sub(/\/.*/, "", value)
            sub(/\?.*/, "", value)
            sub(/^[^@]*@/, "", value)
            sub(/:[0-9]+$/, "", value)
            sub(/^\*\./, "", value)
            sub(/^\.+/, "", value)
            sub(/\.+$/, "", value)
            return value
        }
        BEGIN {
            print "127.0.0.1" > resolvers
            print "1.1.1.1" > resolvers
            print "8.8.8.8" > resolvers
            prefix=config "."
        }
        {
            equals=index($0, "=")
            if (!equals) next
            left=substr($0, 1, equals-1)
            if (substr(left, 1, length(prefix)) != prefix) next
            path=substr(left, length(prefix)+1)
            dot=index(path, ".")
            value=decode(substr($0, equals+1))
            if (!dot) {
                section=path
                if (!(section in seen)) {
                    seen[section]=1
                    order[++section_count]=section
                }
                kinds[section]=value
            } else {
                section=substr(path, 1, dot-1)
                name=substr(path, dot+1)
                values[section SUBSEP name]=value
            }
        }
        END {
            for (i=1; i<=section_count; i++) {
                section=order[i]
                if (kinds[section] == "profile" && option(section, "enabled") == "1") {
                    resolver=first_ipv4(option(section, "dns"))
                    if (resolver != "") print resolver > resolvers
                } else if (kinds[section] == "blocked_domain" && option(section, "enabled") != "0") {
                    domain=normalize_domain(option(section, "domain"))
                    if (domain == "" || domain ~ /[^a-z0-9._-]/ || domain ~ /\.\./) continue
                    mode=(option(section, "mode") == "exact" ? "exact" : "wildcard")
                    print domain "|" mode > domains
                }
            }
        }
    ' "$config_snapshot"
}

# Return the concrete hostnames represented by a block rule. Wildcard support
# remains deliberately bounded: querying arbitrary DNS descendants is not
# possible without observing client DNS traffic.
vm_pbr_block_names() {
    local domain="$1"
    local mode="$2"

    if [ "$mode" = "exact" ]; then
        printf '%s\n' "$domain"
    else
        printf '%s\n' "$domain" "www.$domain" "api.$domain" "cdn.$domain" \
            "m.$domain" "static.$domain" "assets.$domain" "login.$domain"
    fi
}

vm_pbr_block_valid_domain() {
    case "$1" in
        ''|*[!a-z0-9._-]*|*..*) return 1 ;;
        *) return 0 ;;
    esac
}

# Resolve one hostname with an integer-second deadline. The timeout marker is
# written before terminating nslookup, so an answer racing the deadline is
# conservatively treated as a failure and cannot erase last-known-good data.
vm_pbr_block_resolve_one() {
    local host="$1"
    local resolver="$2"
    local output="$3"
    local query_timeout="${4:-$VM_BLOCK_QUERY_TIMEOUT}"
    local raw="$output.raw"
    local timer_pid_file="$output.timer-pid"
    local query_pid timer_pid timer_sleep_pid query_rc

    rm -f "$output" "$output.ok" "$output.timeout" "$timer_pid_file" "$raw"
    nslookup "$host" "$resolver" > "$raw" 2>/dev/null &
    query_pid=$!
    (
        sleep "$query_timeout" &
        timer_sleep_pid=$!
        printf '%s\n' "$timer_sleep_pid" > "$timer_pid_file"
        wait "$timer_sleep_pid" 2>/dev/null || exit 0
        : > "$output.timeout"
        kill -TERM "$query_pid" 2>/dev/null || exit 0
        kill -KILL "$query_pid" 2>/dev/null || true
    ) &
    timer_pid=$!

    query_rc=0
    wait "$query_pid" 2>/dev/null || query_rc=$?
    while [ ! -s "$timer_pid_file" ] && kill -0 "$timer_pid" 2>/dev/null; do :; done
    timer_sleep_pid=""
    if [ -s "$timer_pid_file" ]; then
        IFS= read -r timer_sleep_pid < "$timer_pid_file" || true
    fi
    case "$timer_sleep_pid" in
        ''|*[!0-9]*) : ;;
        *) [ -f "$output.timeout" ] || kill "$timer_sleep_pid" 2>/dev/null || true ;;
    esac
    kill "$timer_pid" 2>/dev/null || true
    wait "$timer_pid" 2>/dev/null || true

    if [ "$query_rc" -eq 0 ] && [ ! -f "$output.timeout" ]; then
        if awk '
            NF == 0 { past=1; next }
            past == 1 && $1 ~ /^Address/ { print $NF }
        ' "$raw" > "$output" 2>/dev/null; then
            : > "$output.ok"
        fi
    fi
    rm -f "$raw" "$output.timeout" "$timer_pid_file"
    [ -f "$output.ok" ]
}

vm_pbr_block_cache_key() {
    printf '%s\n%s\n%s\n' "$1" "$2" "$3" | sha256sum | awk '{print $1}'
}

vm_pbr_block_meta_matches() {
    local meta="$1"
    local expected="$2"
    local actual=""

    [ -f "$meta" ] || return 1
    IFS= read -r actual < "$meta" || true
    [ "$actual" = "$expected" ]
}

vm_pbr_block_trace_phase() {
    [ -n "${VM_BLOCK_PHASE_TRACE:-}" ] || return 0
    printf '%s|%s\n' "$(date +%s)" "$1" >> "$VM_BLOCK_PHASE_TRACE"
}

# Successful and failed results are accumulated, then merged into one compact
# cache transaction. This removes 10k tiny pair files while preserving LKG per
# exact domain/mode/resolver/hostname key.
vm_pbr_block_update_success() {
    local updates="$1"
    local domain="$2"
    local mode="$3"
    local resolver="$4"
    local host="$5"
    local result="$6"
    local now="$7"
    local v4 v6

    v4="$(awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print }' "$result" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    v6="$(awk '/^[0-9a-fA-F:]+$/ && /:/ { print }' "$result" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    printf '%s|%s|%s|%s|S|%s|%s|%s\n' \
        "$domain" "$mode" "$resolver" "$host" "$now" "$v4" "$v6" >> "$updates"
}

vm_pbr_block_update_failure() {
    printf '%s|%s|%s|%s|F|%s||\n' \
        "$2" "$3" "$4" "$5" "$6" >> "$1"
}

vm_pbr_block_merge_updates() {
    local records="$1"
    local updates="$2"
    local source="$records"
    local merged="$records.merge.$$"
    local next="$records.next.$$"

    [ -s "$updates" ] || return 0
    [ -f "$source" ] || source=/dev/null
    awk -F '|' -v OFS='|' -v updates="$updates" '
        function slot_for(domain, host) {
            if (host == domain) return 1
            if (host == "www." domain) return 2
            if (host == "api." domain) return 3
            if (host == "cdn." domain) return 4
            if (host == "m." domain) return 5
            if (host == "static." domain) return 6
            if (host == "assets." domain) return 7
            if (host == "login." domain) return 8
            return 0
        }
        function emit(domain, mode, resolver, pair, have_old,
                      slot, base, update_key, success, v4, v6, retry, line) {
            line=domain OFS mode OFS resolver
            for (slot=1; slot<=8; slot++) {
                base=4 + ((slot - 1) * 4)
                if (have_old) {
                    success=$base
                    v4=$(base + 1)
                    v6=$(base + 2)
                    retry=$(base + 3)
                } else {
                    success=0
                    v4=""
                    v6=""
                    retry=0
                }
                update_key=pair SUBSEP slot
                if (update_key in state) {
                    if (state[update_key] == "S") {
                        success=stamp[update_key]
                        v4=new_v4[update_key]
                        v6=new_v6[update_key]
                        retry=0
                    } else {
                        if (success !~ /^[0-9]+$/) success=0
                        retry=stamp[update_key]
                    }
                }
                line=line OFS success OFS v4 OFS v6 OFS retry
            }
            print line
        }
        FILENAME == updates {
            pair=$1 FS $2 FS $3
            slot=slot_for($1, $4)
            if (slot == 0)
                next
            key=pair SUBSEP slot
            pair_domain[pair]=$1
            pair_mode[pair]=$2
            pair_resolver[pair]=$3
            state[key]=$5
            stamp[key]=$6
            new_v4[key]=$7
            new_v6[key]=$8
            next
        }
        $1 != "" {
            pair=$1 FS $2 FS $3
            if (seen_old[pair]++)
                next
            emit($1, $2, $3, pair, 1)
            emitted[pair]=1
        }
        END {
            for (pair in pair_domain) {
                if (pair in emitted)
                    continue
                emit(pair_domain[pair], pair_mode[pair], pair_resolver[pair], pair, 0)
            }
        }
    ' "$updates" "$source" > "$merged" || return 1
    sort -u "$merged" > "$next" || {
        rm -f "$merged" "$next"
        return 1
    }
    rm -f "$merged"
    mv "$next" "$records"
}

# Build the vpn_manager_block nft table from active domain/resolver pairs. DNS
# work is a fixed-width series of waves with a wall-clock budget; unfinished
# work is coalesced back into the block queue and resumed after a persistent
# lexical cursor. Cache records are never aggregated for an inactive rule or
# resolver, while failures retain only that resolver's last-known-good answers.
# Compact cache implementation. active.tsv is the current Cartesian product of
# configured domain rules and active resolvers. records.tsv keeps one row per
# pair with eight hostname slots, independently of the active set, so resolver
# removal/re-addition does not invalidate LKG. Files publish by rename.
vm_pbr_generate_block() {
    local cache_v2 work config_snapshot resolver_file domain_file active_file active_meta active_raw active_next
    local records records_source updates task_file ordered cursor_file cursor config_key meta_next
    local aggregate4 aggregate6 sorted4 sorted6 output_tmp backlog_flag retry_file earliest_file
    local aggregate_cache4 aggregate_cache6 aggregate_meta aggregate_key ip_generation_file ip_generation
    local sec domain mode resolver name now total workers budget query_timeout failure_retry ttl finalize_reserve
    local refresh_started deadline dns_deadline remaining wave_timeout attempted wave id output pids ids pid
    local last_cursor retry_after backlog have_success

    vm_init_dirs
    vm_pbr_block_trace_phase start
    refresh_started="$(date +%s)"
    workers="$VM_BLOCK_RESOLVE_WORKERS"
    budget="$VM_BLOCK_REFRESH_BUDGET"
    query_timeout="$VM_BLOCK_QUERY_TIMEOUT"
    failure_retry="$VM_BLOCK_FAILURE_RETRY"
    ttl="$VM_BLOCK_CACHE_TTL"
    finalize_reserve="$VM_BLOCK_FINALIZE_RESERVE"
    case "$workers" in ''|*[!0-9]*|0) workers=1 ;; esac
    case "$budget" in ''|*[!0-9]*|0) budget=25 ;; esac
    case "$query_timeout" in ''|*[!0-9]*|0) query_timeout=3 ;; esac
    case "$failure_retry" in ''|*[!0-9]*) failure_retry=60 ;; esac
    case "$ttl" in ''|*[!0-9]*) ttl=1800 ;; esac
    case "$finalize_reserve" in ''|*[!0-9]*) finalize_reserve=14 ;; esac
    [ "$budget" -gt "$finalize_reserve" ] || finalize_reserve=0
    # date has one-second resolution; the extra tick prevents a sub-second
    # planning pass which crosses a wall-clock boundary from losing all DNS work.
    deadline=$((refresh_started + budget + 1))
    dns_deadline=$((deadline - finalize_reserve))

    cache_v2="$VM_BLOCK_CACHE_DIR/v2-compact"
    work="$VM_STATE_DIR/block-build.$$"
    config_snapshot="$work/config.show"
    resolver_file="$work/resolvers"
    domain_file="$work/domains"
    active_file="$cache_v2/active.tsv"
    active_meta="$cache_v2/active.meta"
    active_raw="$work/active.raw"
    active_next="$active_file.next.$$"
    records="$cache_v2/records.tsv"
    updates="$work/updates"
    task_file="$work/tasks"
    ordered="$work/tasks.ordered"
    cursor_file="$cache_v2/cursor"
    aggregate4="$work/all-v4"
    aggregate6="$work/all-v6"
    sorted4="$work/all-v4.sorted"
    sorted6="$work/all-v6.sorted"
    aggregate_cache4="$cache_v2/aggregate4"
    aggregate_cache6="$cache_v2/aggregate6"
    aggregate_meta="$cache_v2/aggregate.meta"
    ip_generation_file="$cache_v2/records-ip-generation"
    output_tmp="$VM_NFT_BLOCK_FILE.$$"
    backlog_flag="$VM_STATE_DIR/block-backlog.pending"
    retry_file="$VM_STATE_DIR/block-retry-at"
    earliest_file="$work/earliest-retry"

    mkdir -p "$cache_v2" "$work"
    : > "$resolver_file"
    : > "$domain_file"
    : > "$updates"
    : > "$task_file"
    : > "$aggregate4"
    : > "$aggregate6"

    if ! vm_pbr_block_snapshot_config "$config_snapshot" "$resolver_file" "$domain_file"; then
        rm -rf "$work"
        vm_fail "unable to snapshot $VM_CFG for block refresh"
        return 1
    fi
    sort -u "$resolver_file" > "$resolver_file.sorted" && mv "$resolver_file.sorted" "$resolver_file"
    sort -u "$domain_file" > "$domain_file.sorted" && mv "$domain_file.sorted" "$domain_file"
    vm_pbr_block_trace_phase config

    config_key="$({ cat "$domain_file"; printf '%s\n' '# resolvers'; cat "$resolver_file"; } | sha256sum | awk '{print $1}')"
    if [ ! -f "$active_file" ] || ! vm_pbr_block_meta_matches "$active_meta" "$config_key"; then
        awk -F '|' -v resolvers="$resolver_file" -v OFS='|' '
            FILENAME == resolvers {
                resolver[++resolver_count]=$1
                next
            }
            $1 != "" {
                domain=$1
                mode=$2
                for (r=1; r<=resolver_count; r++)
                    print domain, mode, resolver[r]
            }
        ' "$resolver_file" "$domain_file" > "$active_raw"
        sort -u "$active_raw" > "$active_next"
        mv "$active_next" "$active_file"
        meta_next="$active_meta.next.$$"
        printf '%s\n' "$config_key" > "$meta_next"
        mv "$meta_next" "$active_meta"
    fi
    vm_pbr_block_trace_phase active

    now="$(date +%s)"
    records_source="$records"
    [ -f "$records_source" ] || records_source=/dev/null
    awk -F '|' -v OFS='|' -v records="$records_source" -v now="$now" \
        -v ttl="$ttl" -v earliest_file="$earliest_file" '
        function load_record() {
            if ((getline record_line < records) > 0) {
                split(record_line, record, FS)
                record_key=record[1] FS record[2] FS record[3]
                return 1
            }
            return 0
        }
        function hostname(domain, slot) {
            if (slot == 1) return domain
            if (slot == 2) return "www." domain
            if (slot == 3) return "api." domain
            if (slot == 4) return "cdn." domain
            if (slot == 5) return "m." domain
            if (slot == 6) return "static." domain
            if (slot == 7) return "assets." domain
            return "login." domain
        }
        BEGIN { have_record=load_record() }
        $1 != "" {
            key=$1 FS $2 FS $3
            while (have_record && record_key < key)
                have_record=load_record()
            slots=($2 == "exact" ? 1 : 8)
            for (slot=1; slot<=slots; slot++) {
                base=4 + ((slot - 1) * 4)
                success=0
                retry_after=0
                if (have_record && record_key == key) {
                    success=record[base]
                    retry_after=record[base + 3]
                }
                fresh=(success ~ /^[0-9]+$/ && now-success < ttl)
                cooling=(retry_after ~ /^[0-9]+$/ && retry_after > now)
                if (cooling && (earliest == 0 || retry_after < earliest))
                    earliest=retry_after
                if (!fresh && !cooling)
                    print $1, $2, $3, hostname($1, slot)
            }
        }
        END {
            close(records)
            print earliest + 0 > earliest_file
        }
    ' "$active_file" > "$task_file"
    sort -u "$task_file" > "$task_file.sorted" && mv "$task_file.sorted" "$task_file"
    VM_BLOCK_EARLIEST_RETRY=0
    if [ -s "$earliest_file" ]; then
        IFS= read -r VM_BLOCK_EARLIEST_RETRY < "$earliest_file" || VM_BLOCK_EARLIEST_RETRY=0
    fi
    vm_pbr_block_trace_phase tasks

    total="$(wc -l < "$task_file" | tr -d ' ')"
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    cursor="$(sed -n '1p' "$cursor_file" 2>/dev/null || true)"
    if [ -n "$cursor" ]; then
        awk -F '|' -v cursor="$cursor" '
            { key=$1 FS $2 FS $3 FS $4 }
            key > cursor { print }
        ' "$task_file" > "$ordered"
        awk -F '|' -v cursor="$cursor" '
            { key=$1 FS $2 FS $3 FS $4 }
            key <= cursor { print }
        ' "$task_file" >> "$ordered"
    else
        cp "$task_file" "$ordered"
    fi

    attempted=0
    last_cursor=""
    have_success=0
    exec 3< "$ordered"
    while [ "$attempted" -lt "$total" ]; do
        now="$(date +%s)"
        [ "$now" -lt "$dns_deadline" ] || break
        remaining=$((dns_deadline - now))
        wave_timeout="$query_timeout"
        [ "$wave_timeout" -le "$remaining" ] || wave_timeout="$remaining"
        [ "$wave_timeout" -ge 1 ] || break

        wave=0
        pids=""
        ids=""
        while [ "$wave" -lt "$workers" ] && IFS='|' read -r domain mode resolver name <&3; do
            id=$((attempted + wave + 1))
            output="$work/result.$id"
            printf '%s|%s|%s|%s\n' "$domain" "$mode" "$resolver" "$name" > "$work/task.$id"
            vm_pbr_block_resolve_one "$name" "$resolver" "$output" "$wave_timeout" &
            pids="$pids $!"
            ids="$ids $id"
            wave=$((wave + 1))
        done
        [ "$wave" -gt 0 ] || break

        for pid in $pids; do
            wait "$pid" 2>/dev/null || true
        done
        now="$(date +%s)"
        retry_after=$((now + failure_retry))
        for id in $ids; do
            IFS='|' read -r domain mode resolver name < "$work/task.$id"
            output="$work/result.$id"
            if [ -f "$output.ok" ]; then
                vm_pbr_block_update_success "$updates" "$domain" "$mode" "$resolver" "$name" "$output" "$now"
                have_success=1
            else
                vm_pbr_block_update_failure "$updates" "$domain" "$mode" "$resolver" "$name" "$retry_after"
                if [ "$VM_BLOCK_EARLIEST_RETRY" -eq 0 ] \
                    || [ "$retry_after" -lt "$VM_BLOCK_EARLIEST_RETRY" ]; then
                    VM_BLOCK_EARLIEST_RETRY="$retry_after"
                fi
            fi
            last_cursor="$domain|$mode|$resolver|$name"
        done
        attempted=$((attempted + wave))
    done
    exec 3<&-
    vm_pbr_block_trace_phase dns

    ip_generation=0
    if [ "$have_success" -eq 1 ]; then
        # Publish the new generation before records.tsv. A crash in between
        # forces aggregate regeneration from the previous LKG; the reverse
        # order could let an old aggregate meta validate newer records.
        ip_generation="$now.$$"
        printf '%s\n' "$ip_generation" > "$ip_generation_file.next.$$"
        mv "$ip_generation_file.next.$$" "$ip_generation_file"
    elif [ -f "$ip_generation_file" ]; then
        IFS= read -r ip_generation < "$ip_generation_file" || ip_generation=0
    fi
    vm_pbr_block_merge_updates "$records" "$updates"
    vm_pbr_block_trace_phase merge
    records_source="$records"
    [ -f "$records_source" ] || records_source=/dev/null

    if [ -n "$last_cursor" ]; then
        printf '%s\n' "$last_cursor" > "$cursor_file.next.$$"
        mv "$cursor_file.next.$$" "$cursor_file"
    fi
    backlog=0
    [ "$attempted" -ge "$total" ] || backlog=1

    aggregate_key="$config_key|$ip_generation"
    if [ -f "$aggregate_cache4" ] && [ -f "$aggregate_cache6" ] \
        && vm_pbr_block_meta_matches "$aggregate_meta" "$aggregate_key"; then
        cp "$aggregate_cache4" "$sorted4"
        cp "$aggregate_cache6" "$sorted6"
    else
        awk -F '|' -v records="$records_source" -v out4="$aggregate4" -v out6="$aggregate6" '
        function load_record() {
            if ((getline record_line < records) > 0) {
                split(record_line, record, FS)
                record_key=record[1] FS record[2] FS record[3]
                return 1
            }
            return 0
        }
        BEGIN { have_record=load_record() }
        $1 != "" {
            key=$1 FS $2 FS $3
            while (have_record && record_key < key)
                have_record=load_record()
            if (!have_record || record_key != key)
                next
            slots=($2 == "exact" ? 1 : 8)
            for (slot=1; slot<=slots; slot++) {
                base=4 + ((slot - 1) * 4)
                count=split(record[base + 1], ips, " ")
                for (i=1; i<=count; i++)
                    if (ips[i] != "") seen4[ips[i]]=1
                count=split(record[base + 2], ips, " ")
                for (i=1; i<=count; i++)
                    if (ips[i] != "") seen6[ips[i]]=1
            }
        }
        END {
            close(records)
            for (ip in seen4) print ip > out4
            for (ip in seen6) print ip > out6
        }
        ' "$active_file"

        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$aggregate4" \
            | grep -vE '^(0\.0\.0\.0|127\.|169\.254\.)' | sort -u > "$sorted4" || : > "$sorted4"
        grep -E '^[0-9a-fA-F:]+$' "$aggregate6" \
            | grep ':' | grep -vxE '::|::1' | sort -u > "$sorted6" || : > "$sorted6"

        cp "$sorted4" "$aggregate_cache4.next.$$"
        cp "$sorted6" "$aggregate_cache6.next.$$"
        mv "$aggregate_cache4.next.$$" "$aggregate_cache4"
        mv "$aggregate_cache6.next.$$" "$aggregate_cache6"
        printf '%s\n' "$aggregate_key" > "$aggregate_meta.next.$$"
        mv "$aggregate_meta.next.$$" "$aggregate_meta"
    fi
    vm_pbr_block_trace_phase aggregate

    {
        echo "table inet vpn_manager_block {"
        echo "    set blocked4 {"
        echo "        type ipv4_addr"
        if [ -s "$sorted4" ]; then
            printf '        elements = { '
            awk 'BEGIN { first=1 } { if (!first) printf ", "; printf "%s", $0; first=0 } END { print " }" }' "$sorted4"
        fi
        echo "    }"
        echo "    set blocked6 {"
        echo "        type ipv6_addr"
        if [ -s "$sorted6" ]; then
            printf '        elements = { '
            awk 'BEGIN { first=1 } { if (!first) printf ", "; printf "%s", $0; first=0 } END { print " }" }' "$sorted6"
        fi
        echo "    }"
        echo "    chain forward {"
        echo "        type filter hook forward priority -100; policy accept;"
        echo "        ip daddr @blocked4 drop"
        echo "        ip6 daddr @blocked6 drop"
        echo "    }"
        echo "}"
    } > "$output_tmp"
    mv "$output_tmp" "$VM_NFT_BLOCK_FILE"
    vm_pbr_block_trace_phase nft

    rm -rf "$work"
    if [ "$backlog" -eq 1 ]; then
        : > "$backlog_flag"
        vm_block_request "resolver backlog" || vm_log "warn" "unable to requeue resolver backlog"
    else
        rm -f "$backlog_flag"
    fi
    if [ "$VM_BLOCK_EARLIEST_RETRY" -gt 0 ]; then
        printf '%s\n' "$VM_BLOCK_EARLIEST_RETRY" > "$retry_file.next.$$"
        mv "$retry_file.next.$$" "$retry_file"
    else
        rm -f "$retry_file"
    fi
}

# Regenerate and swap only the block table (used by the periodic refresh so DNS
# rotations for blocked domains are picked up without a full reconcile).
vm_pbr_refresh_block() (
    local f="$VM_STATE_DIR/block-apply.$$"
    local config_file="${VM_CONFIG_FILE:-/etc/config/$VM_CFG}"
    local generation current_generation config_locked=0

    vm_init_dirs
    generation="$(sha256sum "$config_file" 2>/dev/null | awk '{print $1}')"
    vm_pbr_generate_block

    # DNS work intentionally runs without config.lock so CRUD stays instant.
    # Take the lock only for the final generation check and atomic nft swap;
    # a concurrent UCI commit discards this stale candidate and queues a retry.
    vm_config_lock || exit 75
    config_locked=1
    trap '[ "$config_locked" = "0" ] || vm_config_unlock' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    current_generation="$(sha256sum "$config_file" 2>/dev/null | awk '{print $1}')"
    [ -n "$generation" ] && [ "$generation" = "$current_generation" ] || exit 75

    if [ -s "$VM_NFT_BLOCK_FILE" ]; then
        nft -c -f "$VM_NFT_BLOCK_FILE" || return 1
    fi
    {
        echo "destroy table inet vpn_manager_block"
        [ -s "$VM_NFT_BLOCK_FILE" ] && cat "$VM_NFT_BLOCK_FILE"
    } > "$f"
    nft -f "$f" || {
        rm -f "$f"
        return 1
    }
    rm -f "$f"
    vm_config_unlock
    config_locked=0
)

vm_pbr_generate_nft() {
    vm_init_dirs
    vm_reconcile_manifest_require || return 1

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

    local sec target mac ip_addr dns_ip fwmark iface table_id target_exists ip_valid
    local wan_dns
    wan_dns="$(vm_pbr_wan_dns)"
    while IFS='|' read -r sec target mac ip_addr dns_ip fwmark iface table_id \
        target_exists ip_valid; do
        [ -n "$mac" ] || [ -n "$ip_addr" ] || continue
        [ "$target_exists" = "1" ] || continue
        [ "$dns_ip" != "@wan" ] || dns_ip="$wan_dns"

        if [ "$target" != "wan" ]; then
            # Strict anti-leak: VPN-targeted clients must not egress via non-VPN interfaces.
            if [ -n "$iface" ]; then
                [ -z "$mac" ] || echo "add rule inet vpn_manager_strict forward iifname \"br-lan\" ether saddr $mac oifname != \"$iface\" drop" >> "$VM_NFT_STRICT_FILE"
                [ "$ip_valid" != "1" ] || echo "add rule inet vpn_manager_strict forward iifname \"br-lan\" ip saddr $ip_addr oifname != \"$iface\" drop" >> "$VM_NFT_STRICT_FILE"
            fi

            # IPv4-only tunnels: hard-drop client IPv6 forwarding so a native IPv6
            # path can never leak the real address past the VPN.
            [ -z "$mac" ] || echo "add rule inet vpn_manager_strict forward iifname \"br-lan\" ether saddr $mac meta nfproto ipv6 drop" >> "$VM_NFT_STRICT_FILE"
        fi

        # Pin DNS of routed clients to the target DNS to avoid dnsmasq upstream leakage.
        if [ -n "$dns_ip" ]; then
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

            if [ "$ip_valid" = "1" ]; then
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
        [ -z "$mac" ] || echo "add rule inet vpn_manager prerouting_mark iifname \"br-lan\" ether saddr $mac meta mark set $fwmark" >> "$VM_NFT_FILE"
        [ "$ip_valid" != "1" ] || echo "add rule inet vpn_manager prerouting_mark iifname \"br-lan\" ip saddr $ip_addr meta mark set $fwmark" >> "$VM_NFT_FILE"
    done < "$VM_RECONCILE_POLICIES"

    local wifi_sec wifi_enabled wifi_target wifi_subnet_id wifi_subnet_cidr wifi_network
    while IFS='|' read -r wifi_sec wifi_enabled wifi_target wifi_subnet_id \
        wifi_subnet_cidr wifi_network dns_ip iface table_id target_exists; do
        [ "$wifi_enabled" = "1" ] || continue
        [ -n "$wifi_subnet_id" ] || continue
        [ "$target_exists" = "1" ] || continue
        [ -n "$iface" ] || continue
        [ "$dns_ip" != "@wan" ] || dns_ip="$wan_dns"

        echo "add rule inet vpn_manager_strict forward ip saddr $wifi_subnet_cidr oifname != \"$iface\" drop" >> "$VM_NFT_STRICT_FILE"
        echo "add rule inet vpn_manager_strict forward ip saddr $wifi_subnet_cidr oifname \"$iface\" accept" >> "$VM_NFT_STRICT_FILE"

        # IPv4-only tunnels: hard-drop all IPv6 from a VPN-bound SSID bridge so the
        # dedicated WiFi cannot leak a native IPv6 address around the tunnel.
        if [ "$wifi_target" != "wan" ]; then
            echo "add rule inet vpn_manager_strict forward iifname \"br-$wifi_network\" meta nfproto ipv6 drop" >> "$VM_NFT_STRICT_FILE"
        fi

        if [ -n "$dns_ip" ]; then
            echo "add rule ip vpn_manager_dns prerouting ip saddr $wifi_subnet_cidr udp dport 53 dnat to $dns_ip" >> "$VM_NFT_DNS_FILE"
            echo "add rule ip vpn_manager_dns prerouting ip saddr $wifi_subnet_cidr tcp dport 53 dnat to $dns_ip" >> "$VM_NFT_DNS_FILE"
            echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $wifi_subnet_cidr ip daddr $dns_ip udp dport 53 accept" >> "$VM_NFT_DNS_GUARD_FILE"
            echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $wifi_subnet_cidr ip daddr $dns_ip tcp dport 53 accept" >> "$VM_NFT_DNS_GUARD_FILE"
            echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $wifi_subnet_cidr udp dport 53 drop" >> "$VM_NFT_DNS_GUARD_FILE"
            echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $wifi_subnet_cidr tcp dport 53 drop" >> "$VM_NFT_DNS_GUARD_FILE"
            echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $wifi_subnet_cidr udp dport 853 drop" >> "$VM_NFT_DNS_GUARD_FILE"
            echo "add rule inet vpn_manager_dns_guard prerouting ip saddr $wifi_subnet_cidr tcp dport 853 drop" >> "$VM_NFT_DNS_GUARD_FILE"
        fi
    done < "$VM_RECONCILE_WIFI"

    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        echo "add rule ip vpn_manager_nat postrouting oifname \"$iface\" masquerade" >> "$VM_NFT_NAT_FILE"

        # MSS clamp to path MTU on TCP SYN crossing the tunnel. Runs in its own
        # base chain so it still applies to flows the strict chain terminally
        # accepts (e.g. dedicated WiFi). Avoids PMTUD black-holes and stops the
        # fixed WireGuard MTU from emitting oversized segments that fingerprint
        # the link as tunneled.
        #
        # Clamp BOTH directions to the egress iface MTU minus the IPv4+TCP header
        # (40B). `rt mtu` alone is wrong for the ingress (iifname) rule: a SYN-ACK
        # arriving from the tunnel is routed onward to the LAN, so `rt mtu`
        # resolves to the LAN route (1500) and advertises an MSS the client cannot
        # actually push back through the 1280B tunnel -> oversized client->server
        # segments get black-holed (HTTP/2 stalls, ERR_HTTP2_PROTOCOL_ERROR).
        local iface_mtu="" iface_mss
        [ ! -r "/sys/class/net/$iface/mtu" ] || IFS= read -r iface_mtu < "/sys/class/net/$iface/mtu"
        if [ -n "$iface_mtu" ] && [ "$iface_mtu" -ge 576 ]; then
            iface_mss=$((iface_mtu - 40))
            echo "add rule inet vpn_manager_strict mangle_mss oifname \"$iface\" tcp flags syn tcp option maxseg size set $iface_mss" >> "$VM_NFT_STRICT_FILE"
            echo "add rule inet vpn_manager_strict mangle_mss iifname \"$iface\" tcp flags syn tcp option maxseg size set $iface_mss" >> "$VM_NFT_STRICT_FILE"
        else
            echo "add rule inet vpn_manager_strict mangle_mss oifname \"$iface\" tcp flags syn tcp option maxseg size set rt mtu" >> "$VM_NFT_STRICT_FILE"
            echo "add rule inet vpn_manager_strict mangle_mss iifname \"$iface\" tcp flags syn tcp option maxseg size set rt mtu" >> "$VM_NFT_STRICT_FILE"
        fi
    done < "$VM_RECONCILE_NAT_IFACES"

    nft -c -f "$VM_NFT_STRICT_FILE" || vm_fail "nft strict validation failed"
    nft -c -f "$VM_NFT_FILE" || vm_fail "nft validation failed"
    nft -c -f "$VM_NFT_NAT_FILE" || vm_fail "nft nat validation failed"
    nft -c -f "$VM_NFT_DNS_FILE" || vm_fail "nft dns validation failed"
    nft -c -f "$VM_NFT_DNS_GUARD_FILE" || vm_fail "nft dns guard validation failed"

}

vm_pbr_apply_rules() (
    vm_reconcile_manifest_require || return 1

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

    # Build iproute2 batches in UCI order.  This turns hundreds of one-command
    # processes into a fixed number while retaining the same managed rules.
    local ip4_delete="$VM_STATE_DIR/ip4-delete.batch.$$"
    local ip6_delete="$VM_STATE_DIR/ip6-delete.batch.$$"
    local source_add="$VM_STATE_DIR/source-add.batch.$$"
    local ip4_rules="$VM_STATE_DIR/ip4-rules.batch.$$"
    local ip6_rules="$VM_STATE_DIR/ip6-rules.batch.$$"
    local ip4_routes="$VM_STATE_DIR/ip4-routes.batch.$$"
    local ip6_routes="$VM_STATE_DIR/ip6-routes.batch.$$"
    local active_profiles="$VM_STATE_DIR/active-profiles.$$"
    local fw4_snapshot="$VM_STATE_DIR/fw4-table.$$"
    local fw4_batch="$VM_STATE_DIR/fw4-insert.batch.$$"
    local fw4_one="$VM_STATE_DIR/fw4-insert.one.$$"
    local ip4_rule_snapshot="$VM_STATE_DIR/ip4-rules.snapshot.$$"
    local ip6_rule_snapshot="$VM_STATE_DIR/ip6-rules.snapshot.$$"
    local link_snapshot="$VM_STATE_DIR/links.snapshot.$$"
    local active_values="$VM_STATE_DIR/active-profile-values.$$"
    local missing_profiles="$VM_STATE_DIR/missing-profiles.$$"
    local source_state_next="$VM_SRC_RULES_FILE.next.$$"
    local src_prefix table_id
    : > "$ip4_delete"
    : > "$ip6_delete"
    : > "$source_add"
    : > "$ip4_rules"
    : > "$ip6_rules"
    : > "$ip4_routes"
    : > "$ip6_routes"
    : > "$active_profiles"
    : > "$active_values"
    : > "$missing_profiles"
    : > "$source_state_next"

    vm_pbr_apply_cleanup() {
        rm -f "$ip4_delete" "$ip6_delete" "$source_add" "$ip4_rules" \
            "$ip6_rules" "$ip4_routes" "$ip6_routes" "$active_profiles" \
            "$fw4_snapshot" "$fw4_batch" "$fw4_one" "$ip4_rule_snapshot" \
            "$ip6_rule_snapshot" "$link_snapshot" "$active_values" \
            "$missing_profiles" "$source_state_next"
    }
    trap vm_pbr_apply_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # Derive owned rules from the kernel at reserved priorities. This removes
    # stale rules after profile deletion/disable and remains correct even if a
    # previous worker died before publishing its state manifest.
    ip -4 rule show > "$ip4_rule_snapshot" || return 1
    ip -6 rule show > "$ip6_rule_snapshot" 2>/dev/null || : > "$ip6_rule_snapshot"
    if ! awk -v out4="$ip4_delete" -v out6="$ip6_delete" '
        function emit(line, output, include_source,    count, part, i, priority, source, mark, table) {
            sub(/^[[:space:]]+/, "", line)
            count=split(line, part, /[[:space:]]+/)
            priority=part[1]
            sub(/:$/, "", priority)
            source=""
            mark=""
            table=""
            for (i=2; i<=count; i++) {
                if (part[i] == "from" && i < count) source=part[i+1]
                else if (part[i] == "fwmark" && i < count) mark=part[i+1]
                else if ((part[i] == "lookup" || part[i] == "table") && i < count) table=part[i+1]
            }
            if (include_source && priority == "9990" && source != "" && table != "")
                print "rule del from " source " table " table " priority 9990" > output
            else if (priority == "10000" && mark != "" && table != "")
                print "rule del fwmark " mark " table " table " priority 10000" > output
        }
        FILENAME == ARGV[1] { emit($0, out4, 1); next }
        FILENAME == ARGV[2] { emit($0, out6, 0); next }
    ' "$ip4_rule_snapshot" "$ip6_rule_snapshot"; then
        return 1
    fi

    while IFS='|' read -r src_prefix table_id; do
        [ -n "$src_prefix" ] || continue
        [ -n "$table_id" ] || continue
        printf 'rule add from %s table %s priority 9990\n' "$src_prefix" "$table_id" >> "$source_add"
        printf '%s %s\n' "$src_prefix" "$table_id" >> "$source_state_next"
    done < "$VM_RECONCILE_SOURCE_RULES"

    # One link snapshot replaces one `ip link show` process per profile.
    ip -o link show > "$link_snapshot" || return 1
    if ! awk -F '|' -v active="$active_values" -v missing="$missing_profiles" '
        FILENAME == ARGV[1] {
            line=$0
            sub(/^[[:space:]]*[0-9]+:[[:space:]]*/, "", line)
            iface=line
            sub(/:.*/, "", iface)
            sub(/@.*/, "", iface)
            present[iface]=1
            next
        }
        $2 == "1" {
            if (present[$5]) print $1 "|" $3 "|" $4 "|" $5 "|" $6 > active
            else print $1 "|" $5 > missing
        }
    ' "$link_snapshot" "$VM_RECONCILE_PROFILES"; then
        return 1
    fi
    while IFS='|' read -r sec iface; do
        [ -n "$sec" ] || continue
        vm_log "warn" "skip pbr for $sec: iface $iface not found"
    done < "$missing_profiles"
    [ ! -s "$missing_profiles" ] || {
        vm_fail "one or more enabled VPN interfaces are missing"
        return 1
    }

    while IFS='|' read -r sec table fwmark iface dns_ip; do
        [ -n "$sec" ] || continue
        printf '%s|%s\n' "$sec" "$iface" >> "$active_profiles"
        printf 'rule add fwmark %s table %s priority 10000\n' "$fwmark" "$table" >> "$ip4_rules"
        printf 'rule add fwmark %s table %s priority 10000\n' "$fwmark" "$table" >> "$ip6_rules"
        printf 'route replace default dev %s scope link table %s\n' "$iface" "$table" >> "$ip4_routes"
        printf 'route replace default dev %s table %s\n' "$iface" "$table" >> "$ip6_routes"

        # Keep the router's own DNS lookups for this profile on the tunnel.
        [ -z "$dns_ip" ] || printf 'route replace %s/32 dev %s scope link\n' \
            "$dns_ip" "$iface" >> "$ip4_routes"
    done < "$active_values"

    # Routes must exist before rules point traffic at them; the nft transaction
    # is applied last so newly generated marks never target an unprepared table.
    if [ -s "$ip4_routes" ] && ! ip -4 -force -batch "$ip4_routes"; then return 1; fi
    if [ -s "$ip6_routes" ] && ! ip -6 -force -batch "$ip6_routes"; then return 1; fi
    [ ! -s "$ip4_delete" ] || ip -4 -force -batch "$ip4_delete" 2>/dev/null || true
    [ ! -s "$ip6_delete" ] || ip -6 -force -batch "$ip6_delete" 2>/dev/null || true
    if [ -s "$source_add" ] && ! ip -4 -batch "$source_add"; then return 1; fi
    if [ -s "$ip4_rules" ] && ! ip -4 -batch "$ip4_rules"; then return 1; fi
    if [ -s "$ip6_rules" ] && ! ip -6 -batch "$ip6_rules"; then return 1; fi

    # One-shot nft transaction avoids brief periods without strict anti-leak
    # rules and is deliberately last after all required route/rule batches.
    nft -f "$VM_NFT_APPLY_FILE" || {
        vm_fail "failed applying nft transaction"
        return 1
    }
    mv "$source_state_next" "$VM_SRC_RULES_FILE" || return 1

    # Cache fw4 once, parse its existing edges once, and emit missing insertions
    # in profile order.  WiFi bindings are linked by target in AWK, avoiding the
    # previous profile x WiFi nested scan and per-edge nft/grep processes.
    nft list table inet fw4 > "$fw4_snapshot" 2>/dev/null || : > "$fw4_snapshot"
    if ! awk -F '|' '
        function quoted_after(line, token,    start, rest, finish) {
            start = index(line, token)
            if (!start) return ""
            rest = substr(line, start + length(token))
            finish = index(rest, "\"")
            if (!finish) return ""
            return substr(rest, 1, finish - 1)
        }
        FILENAME == ARGV[1] {
            line = $0
            sub(/^[ \t]+/, "", line)
            if (line ~ /^chain [^ ]+ \{$/) {
                split(line, words, /[ \t]+/)
                chain = words[2]
                next
            }
            if (line == "}") {
                chain = ""
                next
            }
            if (chain == "") next
            iif = quoted_after(line, "iifname \"")
            oif = quoted_after(line, "oifname \"")
            if (oif != "") oif_edge[chain SUBSEP oif] = 1
            if (iif != "" && oif != "") {
                edge[chain SUBSEP iif SUBSEP oif] = 1
                if (index(line, "ct state established,related") != 0)
                    ct_edge[chain SUBSEP iif SUBSEP oif] = 1
            }
            next
        }
        FILENAME == ARGV[2] {
            if ($1 == "" || $2 !~ /^[A-Za-z0-9_-]+$/) next
            profile_section[++profile_count] = $1
            profile_iface[profile_count] = $2
            next
        }
        FILENAME == ARGV[3] {
            if ($2 != "1" || $3 == "" || $6 !~ /^[A-Za-z0-9_-]+$/) next
            wifi_index++
            wifi_network[wifi_index] = $6
            if (wifi_last[$3]) wifi_next[wifi_last[$3]] = wifi_index
            else wifi_first[$3] = wifi_index
            wifi_last[$3] = wifi_index
            next
        }
        END {
            for (i = 1; i <= profile_count; i++) {
                section = profile_section[i]
                iface = profile_iface[i]
                key = "forward" SUBSEP "br-lan" SUBSEP iface
                if (!edge[key]) {
                    print "insert rule inet fw4 forward iifname \"br-lan\" oifname \"" iface "\" counter accept"
                    edge[key] = 1
                }
                key = "forward" SUBSEP iface SUBSEP "br-lan"
                if (!ct_edge[key]) {
                    print "insert rule inet fw4 forward iifname \"" iface "\" oifname \"br-lan\" ct state established,related counter accept"
                    ct_edge[key] = 1
                }

                for (wifi = wifi_first[section]; wifi; wifi = wifi_next[wifi]) {
                    network = wifi_network[wifi]
                    chain_name = "forward_" network
                    key = chain_name SUBSEP iface
                    if (!oif_edge[key]) {
                        print "insert rule inet fw4 " chain_name " oifname \"" iface "\" counter accept"
                        oif_edge[key] = 1
                    }
                    key = "forward" SUBSEP iface SUBSEP "br-" network
                    if (!ct_edge[key]) {
                        print "insert rule inet fw4 forward iifname \"" iface "\" oifname \"br-" network "\" ct state established,related counter accept"
                        ct_edge[key] = 1
                    }
                }
            }
        }
    ' "$fw4_snapshot" "$active_profiles" "$VM_RECONCILE_WIFI" > "$fw4_batch"; then
        : > "$fw4_batch"
    fi

    if [ -s "$fw4_batch" ] && ! nft -f "$fw4_batch" 2>/dev/null; then
        # Preserve best-effort behavior if a chain changes between snapshot and
        # transaction: retry each controlled line so one missing WiFi chain does
        # not prevent unrelated profile forwarding rules.
        while IFS= read -r fw4_rule; do
            printf '%s\n' "$fw4_rule" > "$fw4_one"
            nft -f "$fw4_one" 2>/dev/null || true
        done < "$fw4_batch"
    fi

    # Clear route cache so new source rules and marks take effect immediately.
    ip -4 route flush cache 2>/dev/null || true

    vm_log "info" "pbr rules updated"
)
