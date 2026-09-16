#!/bin/sh
set -eu

VM_LIB_DIR="${VM_LIB_DIR:-/usr/libexec/vpn-manager}"
. "$VM_LIB_DIR/common.sh"
. "$VM_LIB_DIR/uci.sh"
. "$VM_LIB_DIR/health.sh"

vm_init_dirs
umask 077

snapshot="$VM_STATE_DIR/health-snapshot.txt"
next_snapshot="$VM_STATE_DIR/health-snapshot.next.$$"
health_log="$VM_STATE_DIR/health.log"
config_snapshot="$VM_STATE_DIR/health-config.$$"
profiles="$VM_STATE_DIR/health-profiles.$$"
links="$VM_STATE_DIR/health-links.$$"
handshakes="$VM_STATE_DIR/health-handshakes.$$"
changes="$VM_STATE_DIR/health-changes.$$"
trap 'rm -f "$next_snapshot" "$config_snapshot" "$profiles" "$links" "$handshakes" "$changes" 2>/dev/null || true' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
: > "$next_snapshot"
[ -f "$snapshot" ] || : > "$snapshot"
vm_log_trim "$health_log" 262144 1000

# Take each source once, then join the complete set in one awk process. This
# keeps a 500-profile health sweep close to constant process count instead of
# spawning uci/wg/ip/awk for every profile.
uci -q show "$VM_CFG" > "$config_snapshot" || vm_fail "unable to snapshot $VM_CFG for health check"
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
            iface = values[section SUBSEP "iface"]
            if (type[section] == "profile" && values[section SUBSEP "enabled"] == "1" && iface != "") {
                print section "|" iface
            }
        }
    }
' "$config_snapshot" > "$profiles"

ip -o link show > "$links" 2>/dev/null || : > "$links"
wg show all latest-handshakes > "$handshakes" 2>/dev/null || : > "$handshakes"
now_epoch="$(date +%s)"

awk -F'|' -v now="$now_epoch" -v output="$next_snapshot" '
    FILENAME == ARGV[1] {
        profile[++profile_count] = $1
        profile_iface[profile_count] = $2
        next
    }
    FILENAME == ARGV[2] {
        line = $0
        sub(/^[[:space:]]*[0-9]+:[[:space:]]*/, "", line)
        iface = line
        sub(/:.*/, "", iface)
        sub(/@.*/, "", iface)
        present[iface] = 1
        if (line ~ /<[^>]*UP([,>])/) up[iface] = 1
        next
    }
    FILENAME == ARGV[3] {
        split($0, fields, /[[:space:]]+/)
        iface = fields[1]
        timestamp = fields[3] + 0
        if (timestamp > latest[iface]) latest[iface] = timestamp
        next
    }
    FILENAME == ARGV[4] {
        old_state[$1] = $3
        next
    }
    END {
        for (i = 1; i <= profile_count; i++) {
            section = profile[i]
            iface = profile_iface[i]
            age = 999999
            if (latest[iface] > 0) {
                age = now - latest[iface]
                if (age < 0) age = 0
            }
            state = "down"
            if (present[iface] && up[iface] && age <= 180) state = "healthy"
            print section "|" iface "|" state "|" age "|" now > output
            previous = old_state[section]
            if (previous == "") previous = "unknown"
            if (previous != state) print section "|" iface "|" state "|" previous
        }
    }
' "$profiles" "$links" "$handshakes" "$snapshot" > "$changes"

event_time="$(vm_now)"
while IFS='|' read -r sec iface state old_state; do
    [ -n "$sec" ] || continue
    printf '%s profile=%s iface=%s state=%s previous=%s\n' \
        "$event_time" "$sec" "$iface" "$state" "$old_state" >> "$health_log"
    if [ "$state" = "down" ]; then
        vm_log "warn" "health down profile=$sec iface=$iface"
    else
        vm_log "info" "health state profile=$sec iface=$iface state=$state"
    fi
done < "$changes"

mv "$next_snapshot" "$snapshot"
next_snapshot=""
