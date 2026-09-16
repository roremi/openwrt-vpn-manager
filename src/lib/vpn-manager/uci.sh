#!/bin/sh

VM_LIB_DIR="${VM_LIB_DIR:-/usr/libexec/vpn-manager}"
. "$VM_LIB_DIR/common.sh"

# A reconcile reads vpn-manager exactly once.  The ordered manifests are small,
# shell-friendly joins of that checked snapshot and are shared by nft, routing,
# WireGuard UCI and WireGuard runtime reconciliation.
VM_RECONCILE_SNAPSHOT="${VM_RECONCILE_SNAPSHOT:-$VM_STATE_DIR/reconcile-vpn-manager.show}"
VM_RECONCILE_NETWORK_SNAPSHOT="${VM_RECONCILE_NETWORK_SNAPSHOT:-$VM_STATE_DIR/reconcile-network.show}"
VM_RECONCILE_PROFILES="${VM_RECONCILE_PROFILES:-$VM_STATE_DIR/reconcile-profiles.manifest}"
VM_RECONCILE_POLICIES="${VM_RECONCILE_POLICIES:-$VM_STATE_DIR/reconcile-policies.manifest}"
VM_RECONCILE_WIFI="${VM_RECONCILE_WIFI:-$VM_STATE_DIR/reconcile-wifi.manifest}"
VM_RECONCILE_SOURCE_RULES="${VM_RECONCILE_SOURCE_RULES:-$VM_STATE_DIR/reconcile-source-rules.manifest}"
VM_RECONCILE_NAT_IFACES="${VM_RECONCILE_NAT_IFACES:-$VM_STATE_DIR/reconcile-nat-ifaces.manifest}"
VM_RECONCILE_NETWORK_BATCH="${VM_RECONCILE_NETWORK_BATCH:-$VM_STATE_DIR/reconcile-network.batch}"
VM_RECONCILE_ORPHANS="${VM_RECONCILE_ORPHANS:-$VM_STATE_DIR/reconcile-orphans.manifest}"
VM_RECONCILE_NETWORK_PENDING="${VM_RECONCILE_NETWORK_PENDING:-$VM_STATE_DIR/reconcile-network.pending}"

vm_checkpoint_create() {
    vm_init_dirs
    local ts old_umask base pointer_tmp current
    ts="$(date +%s)"
    base="$VM_STATE_DIR/checkpoint-$ts-$$"
    old_umask="$(umask)"
    umask 077

    if ! uci export network > "$base.network.uci" 2>/dev/null \
        || ! uci export firewall > "$base.firewall.uci" 2>/dev/null; then
        rm -f "$base".*
        umask "$old_umask"
        return 1
    fi
    uci export wireless > "$base.wireless.uci" 2>/dev/null || true
    uci export dhcp > "$base.dhcp.uci" 2>/dev/null || true
    if ! uci export "$VM_CFG" > "$base.vpn-manager.uci" 2>/dev/null; then
        rm -f "$base".*
        umask "$old_umask"
        return 1
    fi
    nft list ruleset > "$base.ruleset.nft" 2>/dev/null || true

    if [ -s "$VM_STATE_DIR/latest.checkpoint" ]; then
        current="$(cat "$VM_STATE_DIR/latest.checkpoint" 2>/dev/null || true)"
        if vm_checkpoint_valid "$current"; then
            pointer_tmp="$VM_STATE_DIR/previous.checkpoint.$$"
            printf '%s\n' "$current" > "$pointer_tmp"
            mv "$pointer_tmp" "$VM_STATE_DIR/previous.checkpoint"
        fi
    fi

    pointer_tmp="$VM_STATE_DIR/latest.checkpoint.$$"
    printf '%s\n' "$base" > "$pointer_tmp"
    mv "$pointer_tmp" "$VM_STATE_DIR/latest.checkpoint"
    chmod 600 "$base".* "$VM_STATE_DIR"/*.checkpoint 2>/dev/null || true
    umask "$old_umask"
    vm_checkpoint_prune 5
    vm_log "info" "checkpoint created: $base"
    echo "$base"
}

vm_checkpoint_prune() {
    local keep="${1:-5}"
    local file base

    chmod 600 "$VM_STATE_DIR"/checkpoint-* "$VM_STATE_DIR"/*.checkpoint 2>/dev/null || true
    ls -1t "$VM_STATE_DIR"/checkpoint-*.vpn-manager.uci 2>/dev/null \
        | sed -n "$((keep + 1)),\$p" \
        | while IFS= read -r file; do
            base="${file%.vpn-manager.uci}"
            rm -f "$base".network.uci "$base".firewall.uci "$base".wireless.uci \
                "$base".dhcp.uci "$base".vpn-manager.uci "$base".ruleset.nft
        done
}

vm_checkpoint_valid() {
    local base="${1:-}"
    case "$base" in
        "$VM_STATE_DIR"/checkpoint-*) ;;
        *) return 1 ;;
    esac
    [ -f "$base.vpn-manager.uci" ] && [ -f "$base.network.uci" ] && [ -f "$base.firewall.uci" ]
}

vm_checkpoint_prepare_rollback() {
    local base pointer_tmp

    if [ ! -s "$VM_STATE_DIR/latest.checkpoint" ]; then
        rm -f "$VM_STATE_DIR/rollback.checkpoint"
        return 0
    fi

    base="$(cat "$VM_STATE_DIR/latest.checkpoint" 2>/dev/null || true)"
    vm_checkpoint_valid "$base" || return 1
    pointer_tmp="$VM_STATE_DIR/rollback.checkpoint.$$"
    printf '%s\n' "$base" > "$pointer_tmp"
    mv "$pointer_tmp" "$VM_STATE_DIR/rollback.checkpoint"
    chmod 600 "$VM_STATE_DIR/rollback.checkpoint" 2>/dev/null || true
}

vm_checkpoint_last() {
    local pointer base
    for pointer in rollback.checkpoint previous.checkpoint latest.checkpoint; do
        [ -s "$VM_STATE_DIR/$pointer" ] || continue
        base="$(cat "$VM_STATE_DIR/$pointer" 2>/dev/null || true)"
        vm_checkpoint_valid "$base" || continue
        printf '%s\n' "$base"
        return 0
    done
    return 1
}

vm_checkpoint_restore_config() {
    local base="$1"
    vm_checkpoint_valid "$base" || vm_fail "invalid checkpoint: $base"

    [ -f "$base.network.uci" ] && uci import network < "$base.network.uci"
    [ -f "$base.firewall.uci" ] && uci import firewall < "$base.firewall.uci"
    [ -f "$base.wireless.uci" ] && uci import wireless < "$base.wireless.uci"
    [ -f "$base.dhcp.uci" ] && uci import dhcp < "$base.dhcp.uci"
    [ -f "$base.vpn-manager.uci" ] && uci import "$VM_CFG" < "$base.vpn-manager.uci"

    uci commit network
    uci commit firewall
    uci commit wireless
    uci commit dhcp
    uci commit "$VM_CFG"
}

vm_checkpoint_rollback() {
    local base="${1:-$(vm_checkpoint_last)}"
    [ -n "$base" ] || vm_fail "no checkpoint available"
    vm_checkpoint_restore_config "$base"

    /etc/init.d/network reload
    /etc/init.d/firewall reload
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    wifi reload >/dev/null 2>&1 || true

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
    local compact suffix
    # Linux IFNAMSIZ leaves 15 visible bytes. Prefer a 28-bit hash over a long
    # shared slug so hundreds of similarly named profiles do not collide.
    compact="$(echo "$section" | sed 's/[^a-zA-Z0-9]//g' | tr 'A-Z' 'a-z' | cut -c1-4)"
    [ -n "$compact" ] || compact="auto"
    suffix="$(printf '%s' "$section" | sha256sum | cut -c1-7)"
    printf 'wg_%s_%s' "$compact" "$suffix"
}

vm_profile_next_table_id() {
    local id
    id="$(uci -q show "$VM_CFG" | awk -v package="$VM_CFG" '
        index($0, package ".") == 1 && $0 ~ /\.table_id=/ {
            value = $0
            sub(/^[^=]*=/, "", value)
            gsub(sprintf("%c", 39), "", value)
            if (value ~ /^[0-9]+$/) used[value] = 1
        }
        END {
            for (candidate = 101; candidate <= 32765; candidate++) {
                if (!used[candidate]) {
                    print candidate
                    break
                }
            }
        }
    ')"
    [ -n "$id" ] || {
        vm_fail "no free policy routing table id"
        return 1
    }
    printf '%s\n' "$id"
}

vm_profile_fwmark_for_table() {
    local table_id="$1"
    printf '0x%x' "$table_id"
}

vm_reconcile_manifest_prepare() {
    local force="${1:-0}"
    local snapshot_tmp network_snapshot_tmp profiles_tmp policies_tmp wifi_tmp
    local source_tmp nat_tmp batch_tmp orphans_tmp old_umask

    if [ "$force" != "1" ] \
        && [ "${VM_RECONCILE_MANIFEST_READY:-0}" = "1" ] \
        && [ -f "$VM_RECONCILE_SNAPSHOT" ] \
        && [ -f "$VM_RECONCILE_NETWORK_SNAPSHOT" ] \
        && [ -f "$VM_RECONCILE_PROFILES" ] \
        && [ -f "$VM_RECONCILE_POLICIES" ] \
        && [ -f "$VM_RECONCILE_WIFI" ] \
        && [ -f "$VM_RECONCILE_SOURCE_RULES" ] \
        && [ -f "$VM_RECONCILE_NAT_IFACES" ] \
        && [ -f "$VM_RECONCILE_NETWORK_BATCH" ] \
        && [ -f "$VM_RECONCILE_ORPHANS" ]; then
        return 0
    fi

    vm_init_dirs
    old_umask="$(umask)"
    umask 077
    snapshot_tmp="$VM_RECONCILE_SNAPSHOT.tmp.$$"
    network_snapshot_tmp="$VM_RECONCILE_NETWORK_SNAPSHOT.tmp.$$"
    profiles_tmp="$VM_RECONCILE_PROFILES.tmp.$$"
    policies_tmp="$VM_RECONCILE_POLICIES.tmp.$$"
    wifi_tmp="$VM_RECONCILE_WIFI.tmp.$$"
    source_tmp="$VM_RECONCILE_SOURCE_RULES.tmp.$$"
    nat_tmp="$VM_RECONCILE_NAT_IFACES.tmp.$$"
    batch_tmp="$VM_RECONCILE_NETWORK_BATCH.tmp.$$"
    orphans_tmp="$VM_RECONCILE_ORPHANS.tmp.$$"

    rm -f "$snapshot_tmp" "$network_snapshot_tmp" "$profiles_tmp" \
        "$policies_tmp" "$wifi_tmp" "$source_tmp" "$nat_tmp" "$batch_tmp" \
        "$orphans_tmp"
    if ! uci -q show "$VM_CFG" > "$snapshot_tmp"; then
        rm -f "$snapshot_tmp"
        umask "$old_umask"
        vm_fail "unable to snapshot $VM_CFG configuration"
        return 1
    fi
    if ! uci -q show network > "$network_snapshot_tmp"; then
        rm -f "$snapshot_tmp" "$network_snapshot_tmp"
        umask "$old_umask"
        vm_fail "unable to snapshot network configuration"
        return 1
    fi
    : > "$profiles_tmp"
    : > "$policies_tmp"
    : > "$wifi_tmp"
    : > "$source_tmp"
    : > "$nat_tmp"
    : > "$batch_tmp"
    : > "$orphans_tmp"

    if ! awk \
        -v package="$VM_CFG" \
        -v profiles_file="$profiles_tmp" \
        -v policies_file="$policies_tmp" \
        -v wifi_file="$wifi_tmp" \
        -v source_file="$source_tmp" \
        -v nat_file="$nat_tmp" \
        -v batch_file="$batch_tmp" \
        -v orphans_file="$orphans_tmp" '
        function decode(value,    out, i, c) {
            out = ""
            for (i = 1; i <= length(value); i++) {
                if (substr(value, i, 4) == sq bs sq sq) {
                    out = out sq
                    i += 3
                    continue
                }
                c = substr(value, i, 1)
                if (c != sq) out = out c
            }
            return out
        }
        function field(value) {
            if (index(value, "|") != 0) {
                print "vpn-manager manifest value contains reserved delimiter" > "/dev/stderr"
                bad = 1
            }
            return value
        }
        function opt(section, name) {
            return values[section SUBSEP name]
        }
        function ipv4(value,    count, octet, i) {
            count=split(value, octet, ".")
            if (count != 4) return 0
            for (i=1; i<=4; i++) {
                if (octet[i] !~ /^[0-9]+$/ || octet[i] + 0 > 255) return 0
            }
            return 1
        }
        function valid_mac(value) {
            return value ~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/
        }
        function first_ipv4(value,    normalized, count, parts, i) {
            normalized = value
            gsub(/,/, " ", normalized)
            count = split(normalized, parts, /[ \t]+/)
            for (i = 1; i <= count; i++) {
                if (ipv4(parts[i])) return parts[i]
            }
            return ""
        }
        function quoted(value,    out, i, c) {
            value = field(value)
            out = sq
            for (i = 1; i <= length(value); i++) {
                c = substr(value, i, 1)
                if (c == sq) out = out sq bs sq sq
                else out = out c
            }
            return out sq
        }
        function valid_iface(value) {
            return value ~ /^[A-Za-z0-9_-]+$/ && length(value) <= 15
        }
        function valid_bridge_network(value) {
            return value ~ /^[A-Za-z0-9_-]+$/ && length(value) <= 12
        }
        function batch_set(key, value) {
            print "set " key "=" quoted(value) > batch_file
        }
        function batch_add_list(key, value) {
            print "add_list " key "=" quoted(value) > batch_file
        }
        function nat_add(iface) {
            if (iface == "" || nat_seen[iface]++) return
            print field(iface) > nat_file
        }
        BEGIN {
            sq = sprintf("%c", 39)
            bs = sprintf("%c", 92)
            prefix = package "."
            network_prefix = "network."
        }
        {
            equals = index($0, "=")
            if (equals == 0) next

            if (FILENAME == ARGV[2]) {
                if (substr($0, 1, length(network_prefix)) != network_prefix) next
                path = substr($0, length(network_prefix) + 1, \
                    equals - length(network_prefix) - 1)
                raw = substr($0, equals + 1)
                dot = index(path, ".")
                if (dot == 0) {
                    section = path
                    if (!(section in network_section_seen)) {
                        network_section_order[++network_section_count] = section
                        network_section_seen[section] = 1
                    }
                    network_kinds[section] = decode(raw)
                    next
                }
                section = substr(path, 1, dot - 1)
                name = substr(path, dot + 1)
                network_values[section SUBSEP name] = decode(raw)
                next
            }

            if (substr($0, 1, length(prefix)) != prefix) next
            path = substr($0, length(prefix) + 1, equals - length(prefix) - 1)
            raw = substr($0, equals + 1)
            dot = index(path, ".")
            if (dot == 0) {
                section = path
                if (!(section in section_seen)) {
                    section_order[++section_count] = section
                    section_seen[section] = 1
                }
                kinds[section] = decode(raw)
                next
            }
            section = substr(path, 1, dot - 1)
            name = substr(path, dot + 1)
            values[section SUBSEP name] = decode(raw)
        }
        END {
            # Profiles retain UCI order.  This same pass emits the complete,
            # safely quoted network transaction used by sync_all.
            for (i = 1; i <= section_count; i++) {
                section = section_order[i]
                if (kinds[section] != "profile") continue
                enabled = opt(section, "enabled")
                table_id = opt(section, "table_id")
                fwmark = opt(section, "fwmark")
                iface = opt(section, "iface")
                dns = first_ipv4(opt(section, "dns"))
                private_key = opt(section, "private_key")
                address = opt(section, "address")
                mtu = opt(section, "mtu")
                public_key = opt(section, "public_key")
                preshared_key = opt(section, "preshared_key")
                endpoint_host = opt(section, "endpoint_host")
                endpoint_port = opt(section, "endpoint_port")
                allowed_ips = opt(section, "allowed_ips")
                # UCI renders list values as adjacent quoted tokens. The
                # manifest feeds `wg set`, which requires one comma-separated
                # argument, while the network batch below restores each CIDR
                # as its own UCI list item.
                gsub(/[ \t]+/, ",", allowed_ips)
                keepalive = opt(section, "persistent_keepalive")

                print field(section) "|" field(enabled) "|" field(table_id) "|" \
                    field(fwmark) "|" field(iface) "|" field(dns) "|" \
                    field(private_key) "|" field(address) "|" field(mtu) "|" \
                    field(public_key) "|" field(preshared_key) "|" \
                    field(endpoint_host) "|" field(endpoint_port) "|" \
                    field(allowed_ips) "|" field(keepalive) > profiles_file

                if (iface == "") continue
                profile_ifaces[iface] = 1
                if (!valid_iface(iface)) {
                    print "invalid WireGuard interface in profile " section > "/dev/stderr"
                    bad = 1
                    continue
                }
                if (network_kinds[iface] != "") print "delete network." iface > batch_file
                if (network_kinds[iface "_peer"] != "") print "delete network." iface "_peer" > batch_file
                if (enabled != "1") continue

                print "set network." iface "=interface" > batch_file
                batch_set("network." iface ".proto", "wireguard")
                batch_set("network." iface ".vpn_manager", "1")
                batch_set("network." iface ".defaultroute", "0")
                if (private_key != "") batch_set("network." iface ".private_key", private_key)
                if (mtu != "") batch_set("network." iface ".mtu", mtu)
                # Tunnel DNS intentionally stays out of network interface options.
                if (address != "") batch_add_list("network." iface ".addresses", address)
                print "set network." iface "_peer=wireguard_" iface > batch_file
                if (public_key != "") batch_set("network." iface "_peer.public_key", public_key)
                if (preshared_key != "") batch_set("network." iface "_peer.preshared_key", preshared_key)
                if (endpoint_host != "") batch_set("network." iface "_peer.endpoint_host", endpoint_host)
                if (endpoint_port != "") batch_set("network." iface "_peer.endpoint_port", endpoint_port)
                if (keepalive != "") batch_set("network." iface "_peer.persistent_keepalive", keepalive)
                allowed_count = split(allowed_ips, allowed_parts, /,/)
                for (allowed_index = 1; allowed_index <= allowed_count; allowed_index++) {
                    if (allowed_parts[allowed_index] != "") {
                        batch_add_list("network." iface "_peer.allowed_ips", allowed_parts[allowed_index])
                    }
                }
                batch_set("network." iface "_peer.route_allowed_ips", "0")
            }

            # Policies are already joined to their target section, avoiding all
            # per-policy uci get/profile-existence probes in nft and ip-rule code.
            for (i = 1; i <= section_count; i++) {
                section = section_order[i]
                if (kinds[section] != "device_policy") continue
                target = opt(section, "target")
                mac = tolower(opt(section, "mac"))
                ip_addr = opt(section, "ip")
                if (mac != "" && !valid_mac(mac)) {
                    print "invalid MAC in policy " section > "/dev/stderr"
                    bad = 1
                    continue
                }
                if (ip_addr != "" && !ipv4(ip_addr)) {
                    print "invalid IPv4 address in policy " section > "/dev/stderr"
                    bad = 1
                    continue
                }
                target_exists = (target == "wan" || kinds[target] == "profile")
                if (target == "wan") {
                    dns = "@wan"
                    fwmark = "0x0"
                    iface = ""
                    table_id = ""
                } else {
                    dns = first_ipv4(opt(target, "dns"))
                    fwmark = opt(target, "fwmark")
                    iface = opt(target, "iface")
                    table_id = opt(target, "table_id")
                }
                ip_valid = ipv4(ip_addr) ? 1 : 0
                print field(section) "|" field(target) "|" field(mac) "|" \
                    field(ip_addr) "|" field(dns) "|" field(fwmark) "|" \
                    field(iface) "|" field(table_id) "|" target_exists "|" \
                    ip_valid > policies_file

                if ((mac != "" || ip_addr != "") && target != "wan" \
                    && target_exists && iface != "") nat_add(iface)
                if (target != "wan" && target_exists && ip_valid && table_id != "")
                    print field(ip_addr) "/32|" field(table_id) > source_file
            }

            # WiFi bindings are likewise expanded once.  Their source rules stay
            # after device rules, matching the previous observable ordering.
            for (i = 1; i <= section_count; i++) {
                section = section_order[i]
                if (kinds[section] != "wifi_binding") continue
                enabled = opt(section, "enabled")
                target = opt(section, "target")
                subnet_id = opt(section, "subnet_id")
                network = opt(section, "network")
                if (network == "") network = section
                # Dedicated WiFi interfaces/devices are owned by vpn-manager
                # too, but they are not WireGuard profile interfaces. Keep
                # them out of the generic managed-network orphan sweep.
                wifi_networks[network] = 1
                wifi_networks[network "_dev"] = 1
                if (subnet_id !~ /^[0-9]+$/ || subnet_id + 0 < 20 || subnet_id + 0 > 250) {
                    print "invalid subnet_id in WiFi binding " section > "/dev/stderr"
                    bad = 1
                    continue
                }
                if (!valid_bridge_network(network)) {
                    print "invalid network in WiFi binding " section > "/dev/stderr"
                    bad = 1
                    continue
                }
                subnet_cidr = subnet_id == "" ? "" : "10.77." subnet_id ".0/24"
                target_exists = (target == "wan" || kinds[target] == "profile")
                if (target == "wan") {
                    dns = "@wan"
                    iface = "wan"
                    table_id = ""
                } else {
                    dns = first_ipv4(opt(target, "dns"))
                    iface = opt(target, "iface")
                    table_id = opt(target, "table_id")
                }
                print field(section) "|" field(enabled) "|" field(target) "|" \
                    field(subnet_id) "|" field(subnet_cidr) "|" field(network) "|" \
                    field(dns) "|" field(iface) "|" field(table_id) "|" \
                    target_exists > wifi_file

                if (enabled == "1" && subnet_id != "" && target_exists && iface != "")
                    nat_add(iface)
                if (enabled == "1" && target != "wan" && kinds[target] != "" \
                    && subnet_id != "" && table_id != "")
                    print field(subnet_cidr) "|" field(table_id) > source_file
            }

            # Any network interface previously created by vpn-manager but no
            # longer referenced by a profile is an orphan (deleted/renamed
            # profile).  Stage its UCI removal in the same checked transaction;
            # runtime cleanup consumes the ordered orphan manifest after commit.
            for (i = 1; i <= network_section_count; i++) {
                section = network_section_order[i]
                if (network_values[section SUBSEP "vpn_manager"] != "1") continue
                if (profile_ifaces[section] || wifi_networks[section]) continue
                if (!valid_iface(section)) continue
                print field(section) > orphans_file
                print "delete network." section > batch_file
                if (network_kinds[section "_peer"] != "") print "delete network." section "_peer" > batch_file
            }
            if (bad) exit 2
        }
    ' "$snapshot_tmp" "$network_snapshot_tmp"; then
        rm -f "$snapshot_tmp" "$network_snapshot_tmp" "$profiles_tmp" \
            "$policies_tmp" "$wifi_tmp" "$source_tmp" "$nat_tmp" \
            "$batch_tmp" "$orphans_tmp"
        umask "$old_umask"
        vm_fail "unable to build reconcile manifests"
        return 1
    fi

    chmod 600 "$snapshot_tmp" "$network_snapshot_tmp" "$profiles_tmp" \
        "$policies_tmp" "$wifi_tmp" "$source_tmp" "$nat_tmp" "$batch_tmp" \
        "$orphans_tmp" 2>/dev/null || true
    mv "$profiles_tmp" "$VM_RECONCILE_PROFILES"
    mv "$policies_tmp" "$VM_RECONCILE_POLICIES"
    mv "$wifi_tmp" "$VM_RECONCILE_WIFI"
    mv "$source_tmp" "$VM_RECONCILE_SOURCE_RULES"
    mv "$nat_tmp" "$VM_RECONCILE_NAT_IFACES"
    mv "$batch_tmp" "$VM_RECONCILE_NETWORK_BATCH"
    mv "$orphans_tmp" "$VM_RECONCILE_ORPHANS"
    mv "$network_snapshot_tmp" "$VM_RECONCILE_NETWORK_SNAPSHOT"
    mv "$snapshot_tmp" "$VM_RECONCILE_SNAPSHOT"
    VM_RECONCILE_MANIFEST_READY=1
    umask "$old_umask"
}

vm_reconcile_manifest_require() {
    vm_reconcile_manifest_prepare 0
}

vm_reconcile_manifest_cleanup() {
    # The snapshots, profile manifest and network batch contain WireGuard
    # private material. They are needed only for one serialized reconcile and
    # must not linger in tmp after success, failure, or worker termination.
    rm -f "$VM_RECONCILE_SNAPSHOT" "$VM_RECONCILE_NETWORK_SNAPSHOT" \
        "$VM_RECONCILE_PROFILES" "$VM_RECONCILE_POLICIES" \
        "$VM_RECONCILE_WIFI" "$VM_RECONCILE_SOURCE_RULES" \
        "$VM_RECONCILE_NAT_IFACES" "$VM_RECONCILE_NETWORK_BATCH" \
        "$VM_RECONCILE_ORPHANS" \
        "$VM_RECONCILE_SNAPSHOT.tmp.$$" "$VM_RECONCILE_NETWORK_SNAPSHOT.tmp.$$" \
        "$VM_RECONCILE_PROFILES.tmp.$$" "$VM_RECONCILE_POLICIES.tmp.$$" \
        "$VM_RECONCILE_WIFI.tmp.$$" "$VM_RECONCILE_SOURCE_RULES.tmp.$$" \
        "$VM_RECONCILE_NAT_IFACES.tmp.$$" "$VM_RECONCILE_NETWORK_BATCH.tmp.$$" \
        "$VM_RECONCILE_ORPHANS.tmp.$$" 2>/dev/null || true
    VM_RECONCILE_MANIFEST_READY=0
}

vm_reconcile_manifest_validate_profiles() {
    vm_reconcile_manifest_require || return 1
    if ! awk -F '|' '
        function reject(message) {
            print message > "/dev/stderr"
            invalid=1
        }
        {
            section=$1
            enabled=$2
            table_id=$3
            fwmark=$4
            iface=$5

            if (enabled == "1") {
                if (table_id == "") reject("profile " section " missing table_id")
                if (fwmark == "") reject("profile " section " missing fwmark")
                if (iface == "") reject("profile " section " missing iface")
            }
            if (table_id != "") {
                if (table_id !~ /^[0-9]+$/) reject("invalid table_id for " section)
                else if (table_id + 0 < 1 || table_id + 0 > 32765) reject("out-of-range table_id for " section)
                if ((table_id in table_owner) && table_owner[table_id] != section)
                    reject("duplicate table_id " table_id " in " table_owner[table_id] " and " section)
                table_owner[table_id]=section
            }
            if (fwmark != "") {
                if (fwmark !~ /^0[xX][0-9a-fA-F]+$/ && fwmark !~ /^[0-9]+$/)
                    reject("invalid fwmark for " section)
                if ((fwmark in mark_owner) && mark_owner[fwmark] != section)
                    reject("duplicate fwmark " fwmark " in " mark_owner[fwmark] " and " section)
                mark_owner[fwmark]=section
            }
            if (iface != "") {
                if (length(iface) > 15 || iface !~ /^[A-Za-z0-9_-]+$/)
                    reject("invalid WireGuard interface for " section)
                if ((iface in iface_owner) && iface_owner[iface] != section)
                    reject("duplicate WireGuard interface " iface " in " iface_owner[iface] " and " section)
                iface_owner[iface]=section
            }
        }
        END { exit invalid ? 1 : 0 }
    ' "$VM_RECONCILE_PROFILES"; then
        vm_fail "profile manifest validation failed"
        return 1
    fi
}

# Append one UCI single-quoted value without evaluating it as shell input.
vm_uci_batch_quote_append() {
    local file="$1"
    local value="$2"
    local first

    printf "'" >> "$file"
    while [ -n "$value" ]; do
        first="${value%"${value#?}"}"
        value="${value#?}"
        case "$first" in
            "'") printf "%s" "'\\''" >> "$file" ;;
            *) printf '%s' "$first" >> "$file" ;;
        esac
    done
    printf "'" >> "$file"
}

vm_uci_batch_set() {
    local file="$1"
    local command="$2"
    local key="$3"
    local value="$4"

    printf '%s %s=' "$command" "$key" >> "$file"
    vm_uci_batch_quote_append "$file" "$value"
    printf '\n' >> "$file"
}

vm_uci_batch_checked() {
    local input="$1"
    local error_file="$VM_STATE_DIR/uci-batch-error.$$"
    local old_umask rc=0

    vm_init_dirs
    old_umask="$(umask)"
    umask 077
    : > "$error_file"
    # `uci batch` can return success after an individual command failed. In
    # non-quiet mode each such failure emits a diagnostic, so require both a
    # zero process status and an empty stderr stream.
    uci batch < "$input" >/dev/null 2> "$error_file" || rc=$?
    umask "$old_umask"
    if [ "$rc" -ne 0 ] || [ -s "$error_file" ]; then
        rm -f "$error_file"
        return 1
    fi
    rm -f "$error_file"
}

vm_wireguard_sync_all() {
    local section enabled table_id fwmark iface dns private_key address mtu
    local public_key preshared_key endpoint_host endpoint_port allowed_ips keepalive

    vm_reconcile_manifest_require || return 1
    while IFS='|' read -r section enabled table_id fwmark iface dns private_key address mtu \
        public_key preshared_key endpoint_host endpoint_port allowed_ips keepalive; do
        [ "$enabled" = "1" ] || continue
        [ -n "$iface" ] || {
            vm_fail "profile $section missing iface"
            return 1
        }
    done < "$VM_RECONCILE_PROFILES"

    # The marker is created before staging and is cleared only after every
    # required commit succeeds.  Even a caller that accidentally ignores an
    # error therefore cannot proceed into destructive runtime reconciliation.
    : > "$VM_RECONCILE_NETWORK_PENDING"
    if ! vm_uci_batch_checked "$VM_RECONCILE_NETWORK_BATCH"; then
        uci -q revert network >/dev/null 2>&1 || true
        return 1
    fi
}

vm_wireguard_runtime_up_values() {
    local section="$1" iface="$2" private_key="$3" address="$4" mtu="$5"
    local public_key="$6" preshared_key="$7" endpoint_host="$8"
    local endpoint_port="$9"
    shift 9
    local allowed_ips="$1" keepalive="$2" existing_peers existing_peer
    local keyfile="$VM_STATE_DIR/keys/$iface.key"
    local pskfile="$VM_STATE_DIR/keys/$iface.psk"
    local endpoint="${endpoint_host}:${endpoint_port}"

    [ -n "$iface" ] || return 1
    if [ -n "$private_key" ]; then
        printf '%s\n' "$private_key" > "$keyfile" || return 1
    fi
    if [ -n "$preshared_key" ]; then
        printf '%s\n' "$preshared_key" > "$pskfile" || return 1
    else
        rm -f "$pskfile" 2>/dev/null || true
    fi

    if ! ip link show dev "$iface" >/dev/null 2>&1; then
        ip link add dev "$iface" type wireguard || return 1
    fi
    existing_peers="$(wg show "$iface" peers 2>/dev/null)" || return 1
    for existing_peer in $existing_peers; do
        wg set "$iface" peer "$existing_peer" remove || return 1
    done
    # `ip addr replace` only replaces an identical prefix; flush manager-owned
    # global addresses first so profile address changes cannot leave stale IPs.
    ip addr flush dev "$iface" scope global || return 1
    [ -z "$private_key" ] || wg set "$iface" private-key "$keyfile" || return 1
    [ -z "$mtu" ] || ip link set dev "$iface" mtu "$mtu" || true
    [ -z "$address" ] || ip addr replace "$address" dev "$iface" || return 1

    if [ -n "$public_key" ]; then
        if [ -n "$preshared_key" ]; then
            wg set "$iface" peer "$public_key" preshared-key "$pskfile" endpoint "$endpoint" \
                persistent-keepalive "$keepalive" allowed-ips "$allowed_ips" || return 1
        else
            wg set "$iface" peer "$public_key" endpoint "$endpoint" \
                persistent-keepalive "$keepalive" allowed-ips "$allowed_ips" || return 1
        fi
    fi
    ip link set dev "$iface" up || return 1
}

vm_wireguard_runtime_up_profile() {
    local wanted="$1"
    local section enabled table_id fwmark iface dns private_key address mtu
    local public_key preshared_key endpoint_host endpoint_port allowed_ips keepalive
    local found=0 old_umask rc=0

    vm_reconcile_manifest_require || return 1
    mkdir -p "$VM_STATE_DIR/keys"
    old_umask="$(umask)"
    umask 077
    while IFS='|' read -r section enabled table_id fwmark iface dns private_key address mtu \
        public_key preshared_key endpoint_host endpoint_port allowed_ips keepalive; do
        [ "$section" = "$wanted" ] || continue
        found=1
        vm_wireguard_runtime_up_values "$section" "$iface" "$private_key" "$address" \
            "$mtu" "$public_key" "$preshared_key" "$endpoint_host" "$endpoint_port" \
            "$allowed_ips" "$keepalive" || rc=$?
        break
    done < "$VM_RECONCILE_PROFILES"
    umask "$old_umask"
    [ "$found" = "1" ] || return 1
    chmod 600 "$VM_STATE_DIR/keys/$iface.key" "$VM_STATE_DIR/keys/$iface.psk" 2>/dev/null || true
    return "$rc"
}

vm_wireguard_runtime_up_all() {
    local section enabled table_id fwmark iface dns private_key address mtu
    local public_key preshared_key endpoint_host endpoint_port allowed_ips keepalive
    local orphan_iface key_path key_iface old_umask rc=0
    local key_ifaces="$VM_STATE_DIR/runtime-key-ifaces.$$"
    local key_orphans="$VM_STATE_DIR/runtime-key-orphans.$$"

    vm_reconcile_manifest_require || return 1
    [ ! -e "$VM_RECONCILE_NETWORK_PENDING" ] || {
        vm_fail "WireGuard runtime requested before network commit"
        return 1
    }
    mkdir -p "$VM_STATE_DIR/keys"

    # Upgrade cleanup: older vpn-manager versions could leave runtime links
    # after their network sections disappeared. A private key inside our own
    # state directory is authoritative ownership evidence, so reconcile those
    # names against the current profile manifest in one AWK join.
    : > "$key_ifaces"
    for key_path in "$VM_STATE_DIR"/keys/*.key; do
        [ -f "$key_path" ] || continue
        key_iface="${key_path##*/}"
        key_iface="${key_iface%.key}"
        case "$key_iface" in
            ''|*[!A-Za-z0-9_-]*) continue ;;
        esac
        printf '%s\n' "$key_iface" >> "$key_ifaces"
    done
    awk -F '|' '
        FILENAME == ARGV[1] { if ($5 != "") current[$5]=1; next }
        $1 != "" && !current[$1] { print $1 }
    ' "$VM_RECONCILE_PROFILES" "$key_ifaces" > "$key_orphans" || {
        rm -f "$key_ifaces" "$key_orphans"
        return 1
    }

    while IFS= read -r orphan_iface; do
        [ -n "$orphan_iface" ] || continue
        ip link delete "$orphan_iface" 2>/dev/null || true
        rm -f "$VM_STATE_DIR/keys/$orphan_iface.key" \
            "$VM_STATE_DIR/keys/$orphan_iface.psk" 2>/dev/null || true
    done < "$VM_RECONCILE_ORPHANS"
    while IFS= read -r orphan_iface; do
        [ -n "$orphan_iface" ] || continue
        ip link delete "$orphan_iface" 2>/dev/null || true
        rm -f "$VM_STATE_DIR/keys/$orphan_iface.key" \
            "$VM_STATE_DIR/keys/$orphan_iface.psk" 2>/dev/null || true
    done < "$key_orphans"

    old_umask="$(umask)"
    umask 077
    while IFS='|' read -r section enabled table_id fwmark iface dns private_key address mtu \
        public_key preshared_key endpoint_host endpoint_port allowed_ips keepalive; do
        if [ "$enabled" != "1" ]; then
            # runtime_up_all is invoked only after the checked network batch has
            # been committed.  Disabled tunnel teardown therefore cannot occur
            # on a batch/commit fault and cannot destroy the last working state.
            [ -z "$iface" ] || ip link delete "$iface" 2>/dev/null || true
            [ -z "$iface" ] || rm -f "$VM_STATE_DIR/keys/$iface.key" \
                "$VM_STATE_DIR/keys/$iface.psk" 2>/dev/null || true
            continue
        fi
        vm_wireguard_runtime_up_values "$section" "$iface" "$private_key" "$address" \
            "$mtu" "$public_key" "$preshared_key" "$endpoint_host" "$endpoint_port" \
            "$allowed_ips" "$keepalive" || {
                rc=$?
                break
            }
    done < "$VM_RECONCILE_PROFILES"
    umask "$old_umask"
    rm -f "$key_ifaces" "$key_orphans"
    chmod 600 "$VM_STATE_DIR"/keys/*.key "$VM_STATE_DIR"/keys/*.psk 2>/dev/null || true
    return "$rc"
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

vm_wifi_binding_list() {
    uci -q show "$VM_CFG" | sed -n 's/^vpn-manager\.\([^.=]*\)=wifi_binding$/\1/p'
}

vm_blocked_domain_list() {
    uci -q show "$VM_CFG" | sed -n 's/^vpn-manager\.\([^.=]*\)=blocked_domain$/\1/p'
}

vm_blocked_domain_exists() {
    [ "$(uci -q get "$VM_CFG.$1")" = "blocked_domain" ]
}

vm_blocked_url_list() {
    uci -q show "$VM_CFG" | sed -n 's/^vpn-manager\.\([^.=]*\)=blocked_url$/\1/p'
}

vm_blocked_url_exists() {
    [ "$(uci -q get "$VM_CFG.$1")" = "blocked_url" ]
}

vm_http_debug_client_list() {
    uci -q show "$VM_CFG" | sed -n 's/^vpn-manager\.\([^.=]*\)=http_debug_client$/\1/p'
}

vm_http_debug_client_exists() {
    [ "$(uci -q get "$VM_CFG.$1")" = "http_debug_client" ]
}

vm_wifi_binding_exists() {
    uci -q get "$VM_CFG.$1" >/dev/null 2>&1
}

vm_wifi_binding_next_subnet_id() {
    local used id
    used="$(uci -q show "$VM_CFG" | sed -n 's/^vpn-manager\.[^.]*\.subnet_id=\(.*\)$/\1/p' | tr -d "'")"
    id=20
    while [ "$id" -le 250 ]; do
        if ! echo "$used" | grep -qx "$id" \
            && ! uci -q get "network.vmd$id" >/dev/null 2>&1 \
            && ! uci -q get "network.vmd${id}_dev" >/dev/null 2>&1 \
            && ! uci -q get "wireless.vmw$id" >/dev/null 2>&1 \
            && ! uci -q get "dhcp.vmd$id" >/dev/null 2>&1 \
            && ! uci -q get "firewall.vmd$id" >/dev/null 2>&1; then
            echo "$id"
            return 0
        fi
        id=$((id + 1))
    done
    return 1
}

vm_wifi_binding_network_name() {
    printf 'vmd%s' "$1"
}

vm_wifi_binding_wireless_section() {
    printf 'vmw%s' "$1"
}

vm_wifi_binding_gateway() {
    local subnet_id="$1"
    printf '10.77.%s.1' "$subnet_id"
}

vm_wifi_binding_subnet_cidr() {
    local subnet_id="$1"
    printf '10.77.%s.0/24' "$subnet_id"
}

vm_wifi_binding_target_profile() {
    local target="$1"

    [ -n "$target" ] || return 1
    vm_profile_exists "$target" && {
        echo "$target"
        return 0
    }

    local mapped_target
    mapped_target="$(vm_profile_by_iface "$target" 2>/dev/null || true)"
    [ -n "$mapped_target" ] || return 1
    echo "$mapped_target"
}

vm_commit_all() {
    [ -e "$VM_RECONCILE_NETWORK_PENDING" ] || {
        vm_fail "network commit requested without a staged reconcile batch"
        return 1
    }
    if ! uci commit network; then
        uci -q revert network >/dev/null 2>&1 || true
        return 1
    fi
    uci commit "$VM_CFG" || return 1
    uci commit firewall || return 1
    rm -f "$VM_RECONCILE_NETWORK_PENDING"
}
