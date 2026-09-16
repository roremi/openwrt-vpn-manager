#!/bin/sh
set -eu

VM_LIB_DIR="${VM_LIB_DIR:-/usr/libexec/vpn-manager}"
. "$VM_LIB_DIR/common.sh"
. "$VM_LIB_DIR/uci.sh"
. "$VM_LIB_DIR/health.sh"
. "$VM_LIB_DIR/pbr.sh"

vm_init_dirs
umask 077

needs_refresh=0
now_epoch="$(date +%s)"
reconnect_backoff="${VM_RECONNECT_BACKOFF:-120}"
reconnect_limit="${VM_RECONNECT_LIMIT:-4}"
reconnect_count=0
config_snapshot="$VM_STATE_DIR/watchdog-config.$$"
wifi_manifest="$VM_STATE_DIR/watchdog-wifi.$$"
fw4_snapshot="$VM_STATE_DIR/watchdog-fw4.$$"
trap 'rm -f "$config_snapshot" "$wifi_manifest" "$fw4_snapshot" 2>/dev/null || true' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

watchdog_reconnect() (
    vm_try_lock || exit 75
    trap vm_unlock EXIT
    trap 'exit 130' HUP INT TERM

    vm_config_lock || exit 75
    trap 'vm_config_unlock; vm_unlock' EXIT
    vm_profile_reconnect "$1"
)

while IFS='|' read -r sec iface state age checked_at; do
    [ -n "$sec" ] && [ -n "$iface" ] || continue
    if [ "$state" = "down" ]; then
        [ "$reconnect_count" -lt "$reconnect_limit" ] || break
        reconnect_stamp="$VM_STATE_DIR/reconnect-$sec"
        last_reconnect="$(date -r "$reconnect_stamp" +%s 2>/dev/null || echo 0)"
        if [ $((now_epoch - last_reconnect)) -ge "$reconnect_backoff" ]; then
            if watchdog_reconnect "$iface" "$sec"; then
                vm_log "warn" "watchdog reconnect profile=$sec iface=$iface"
                touch "$reconnect_stamp"
                reconnect_count=$((reconnect_count + 1))
            else
                rc=$?
                if [ "$rc" -eq 75 ]; then
                    break
                fi
                vm_log "error" "watchdog reconnect failed profile=$sec iface=$iface rc=$rc"
            fi
        fi
    else
        rm -f "$VM_STATE_DIR/reconnect-$sec" 2>/dev/null || true
    fi
done < "$VM_STATE_DIR/health-snapshot.txt"

# Build all enabled WiFi target checks from one UCI snapshot and inspect fw4
# once. Per-binding `uci get` and `nft list chain` calls were a major source of
# monitor latency on configurations with many SSIDs.
uci -q show "$VM_CFG" > "$config_snapshot" || vm_fail "unable to snapshot $VM_CFG for watchdog"
awk '
    function decode(value) {
        if (substr(value, 1, 1) == "\047" && substr(value, length(value), 1) == "\047") {
            return substr(value, 2, length(value) - 2)
        }
        return value
    }
    {
        line = $0
        sub(/^vpn-manager\./, "", line)
        equals = index(line, "=")
        if (!equals) next
        key = substr(line, 1, equals - 1)
        value = decode(substr(line, equals + 1))
        dot = index(key, ".")
        if (!dot) {
            section = key
            type[section] = value
            if (!(section in seen)) {
                seen[section] = 1
                order[++count] = section
            }
            next
        }
        section = substr(key, 1, dot - 1)
        option = substr(key, dot + 1)
        values[section SUBSEP option] = value
    }
    END {
        for (i = 1; i <= count; i++) {
            section = order[i]
            target = values[section SUBSEP "target"]
            network = values[section SUBSEP "network"]
            if (network == "") network = section
            iface = values[target SUBSEP "iface"]
            if (type[section] == "wifi_binding" && values[section SUBSEP "enabled"] == "1" &&
                    type[target] == "profile" && iface != "") {
                print "forward_" network "|" iface
            }
        }
    }
' "$config_snapshot" > "$wifi_manifest"

if [ -s "$wifi_manifest" ]; then
    nft list table inet fw4 > "$fw4_snapshot" 2>/dev/null || : > "$fw4_snapshot"
    if ! awk -F'|' '
        FILENAME == ARGV[1] {
            wanted[$1] = $2
            next
        }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (line ~ /^chain[[:space:]]/) {
                split(line, fields, /[[:space:]]+/)
                chain = fields[2]
                next
            }
            if ($0 ~ /^[[:space:]]*}/) {
                chain = ""
                next
            }
            if (chain in wanted) {
                needle = "oifname \"" wanted[chain] "\""
                if (index($0, needle)) found[chain] = 1
            }
        }
        END {
            for (chain in wanted) if (!found[chain]) exit 1
        }
    ' "$wifi_manifest" "$fw4_snapshot"; then
        needs_refresh=1
    fi
fi

if [ "$needs_refresh" = "1" ]; then
    vm_log "info" "wifi forward rule missing, queueing pbr refresh"
    vm_apply_request pbr watchdog
fi
