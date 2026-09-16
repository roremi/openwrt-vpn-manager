#!/bin/sh
set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$TEST_DIR/../lib/testlib.sh"

ROOT_DIR="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
TMP_ROOT="$(make_test_tmpdir)"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

FAKE_BIN="$TMP_ROOT/bin"
STATE_DIR="$TMP_ROOT/state"
UCI_DATA="$TMP_ROOT/uci-show.txt"
NETWORK_DATA="$TMP_ROOT/network-show.txt"
UCI_LOG="$TMP_ROOT/uci.log"
UCI_BATCH_LOG="$TMP_ROOT/uci-batch.log"
NFT_LOG="$TMP_ROOT/nft.log"
IP_LOG="$TMP_ROOT/ip.log"
IP_BATCH_LOG="$TMP_ROOT/ip-batch.log"
RUNTIME_LOG="$TMP_ROOT/runtime.log"
ORDER_LOG="$TMP_ROOT/order.log"
mkdir -p "$STATE_DIR"
install_fake_openwrt_tools "$FAKE_BIN"

cat > "$FAKE_BIN/uci" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CORE_UCI_LOG"
case "$*" in
    '-q show vpn-manager')
        [ "${CORE_SHOW_FAIL:-0}" != "1" ] || exit 91
        cat "$CORE_UCI_DATA"
        ;;
    '-q show network')
        cat "$CORE_NETWORK_DATA"
        ;;
    'batch')
        {
            printf '%s\n' '--- batch ---'
            cat
        } >> "$CORE_UCI_BATCH_LOG"
        if [ "${CORE_BATCH_SOFT_FAIL:-0}" = "1" ]; then
            printf '%s\n' 'uci: simulated command failure' >&2
            exit 0
        fi
        [ "${CORE_BATCH_FAIL:-0}" != "1" ] || exit 92
        ;;
    '-q revert network') ;;
    'commit network')
        [ "${CORE_COMMIT_FAIL:-0}" != "1" ] || exit 94
        ;;
    'commit vpn-manager'|'commit firewall') ;;
    *)
        printf 'unexpected uci invocation: %s\n' "$*" >&2
        exit 93
        ;;
esac
EOF

cat > "$FAKE_BIN/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CORE_NFT_LOG"
case "$*" in
    'list table inet fw4')
        cat <<'RULES'
table inet fw4 {
    chain forward {
        iifname "br-lan" oifname "wg_p1" counter packets 1 bytes 1 accept
        iifname "wg_p1" oifname "br-lan" ct state established,related counter packets 1 bytes 1 accept
    }
}
RULES
        ;;
    *vpn-manager-apply.nft*)
        printf 'nft:%s\n' "$*" >> "$CORE_ORDER_LOG"
        [ "${CORE_NFT_APPLY_FAIL:-0}" != "1" ] || exit 96
        ;;
    *) ;;
esac
EOF

cat > "$FAKE_BIN/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CORE_IP_LOG"
case "$*" in
    '-o link show')
        awk 'BEGIN { for (i=1; i<=100; i++) printf "%d: wg_p%d: <POINTOPOINT,UP,LOWER_UP> mtu 1420 state UNKNOWN\n", i, i }'
        ;;
    '-4 rule show')
        printf '9990: from 192.0.2.7 lookup 777\n10000: from all fwmark 0xdead lookup 777\n'
        ;;
    '-6 rule show')
        printf '10000: from all fwmark 0xbeef lookup 778\n'
        ;;
    *' -batch '*)
        for arg in "$@"; do batch_file="$arg"; done
        printf 'ip-batch:%s\n' "$*" >> "$CORE_ORDER_LOG"
        {
            printf '%s\n' "--- $* ---"
            cat "$batch_file"
        } >> "$CORE_IP_BATCH_LOG"
        ;;
    'link show dev '*) exit 0 ;;
    *) ;;
esac
EOF

cat > "$FAKE_BIN/wg" <<'EOF'
#!/bin/sh
[ "${CORE_WG_FAIL:-0}" != "1" ] || exit 95
exit 0
EOF

chmod 0755 "$FAKE_BIN/uci" "$FAKE_BIN/nft" "$FAKE_BIN/ip" "$FAKE_BIN/wg"
: > "$UCI_DATA"
cat > "$NETWORK_DATA" <<'EOF'
network.lan=interface
network.lan.proto='static'
network.wg_orphan=interface
network.wg_orphan.proto='wireguard'
network.wg_orphan.vpn_manager='1'
network.wg_orphan_peer=wireguard_wg_orphan
network.vmd20=interface
network.vmd20.proto='static'
network.vmd20.vpn_manager='1'
network.vmd20_dev=device
network.vmd20_dev.vpn_manager='1'
EOF
: > "$UCI_DATA"
cat > "$UCI_DATA" <<'EOF'
vpn-manager.wifi_test=wifi_binding
vpn-manager.wifi_test.enabled='1'
vpn-manager.wifi_test.target='p1'
vpn-manager.wifi_test.subnet_id='20'
vpn-manager.wifi_test.network='vmd20'
EOF
: > "$UCI_LOG"
: > "$UCI_BATCH_LOG"
: > "$NFT_LOG"
: > "$IP_LOG"
: > "$IP_BATCH_LOG"
: > "$RUNTIME_LOG"
: > "$ORDER_LOG"

i=1
while [ "$i" -le 100 ]; do
    id="$i"
    enabled=1
    [ "$i" -ne 100 ] || enabled=0
    table_id=$((100 + i))
    fwmark="$table_id"
    host="vpn${id}.example.net"
    [ "$i" -ne 1 ] || host="vpn'edge.example"
    {
        printf 'vpn-manager.p%s=profile\n' "$id"
        printf "vpn-manager.p%s.enabled='%s'\n" "$id" "$enabled"
        printf "vpn-manager.p%s.table_id='%s'\n" "$id" "$table_id"
        printf "vpn-manager.p%s.fwmark='%s'\n" "$id" "$fwmark"
        printf "vpn-manager.p%s.iface='wg_p%s'\n" "$id" "$id"
        printf "vpn-manager.p%s.dns='10.0.%s.53'\n" "$id" "$i"
        printf "vpn-manager.p%s.private_key='private-%s'\n" "$id" "$id"
        printf "vpn-manager.p%s.address='10.200.%s.2/32'\n" "$id" "$i"
        printf "vpn-manager.p%s.mtu='1280'\n" "$id"
        printf "vpn-manager.p%s.public_key='public-%s'\n" "$id" "$id"
        printf "vpn-manager.p%s.preshared_key='psk-%s'\n" "$id" "$id"
        if [ "$i" -eq 1 ]; then
            escaped_host="'vpn'\\''edge.example'"
            printf 'vpn-manager.p%s.endpoint_host=%s\n' "$id" "$escaped_host"
        else
            printf "vpn-manager.p%s.endpoint_host='%s'\n" "$id" "$host"
        fi
        printf "vpn-manager.p%s.endpoint_port='51820'\n" "$id"
        printf "vpn-manager.p%s.allowed_ips='0.0.0.0/0' '::/0'\n" "$id"
        printf "vpn-manager.p%s.persistent_keepalive='25'\n" "$id"
    } >> "$UCI_DATA"
    i=$((i + 1))
done

i=1
while [ "$i" -le 500 ]; do
    id="$i"
    target_index=$(( (i - 1) % 99 + 1 ))
    target="p$target_index"
    subnet=$(( (i - 1) / 250 + 20 ))
    host_octet=$(( (i - 1) % 250 + 1 ))
    [ "$i" -ne 500 ] || target=wan
    {
        printf 'vpn-manager.policy%s=device_policy\n' "$id"
        printf "vpn-manager.policy%s.mac='AA:BB:%02X:%02X:%02X:%02X'\n" \
            "$id" "$subnet" "$host_octet" "$subnet" "$host_octet"
        printf "vpn-manager.policy%s.ip='192.168.%s.%s'\n" "$id" "$subnet" "$host_octet"
        printf "vpn-manager.policy%s.target='%s'\n" "$id" "$target"
    } >> "$UCI_DATA"
    i=$((i + 1))
done

export VM_STATE_DIR="$STATE_DIR"
export VM_AUDIT_LOG="$TMP_ROOT/audit.log"
export VM_LIB_DIR="$ROOT_DIR/src/lib/vpn-manager"
export CORE_UCI_DATA="$UCI_DATA"
export CORE_NETWORK_DATA="$NETWORK_DATA"
export CORE_UCI_LOG="$UCI_LOG"
export CORE_UCI_BATCH_LOG="$UCI_BATCH_LOG"
export CORE_NFT_LOG="$NFT_LOG"
export CORE_IP_LOG="$IP_LOG"
export CORE_IP_BATCH_LOG="$IP_BATCH_LOG"
export CORE_ORDER_LOG="$ORDER_LOG"
export PATH="$FAKE_BIN:$PATH"

. "$ROOT_DIR/src/lib/vpn-manager/pbr.sh"
vm_log() { :; }
vm_fail() { printf '%s\n' "$*" >&2; return 1; }
vm_pbr_wan_dns() { printf '9.9.9.9\n'; }

start="$(date +%s)"
vm_reconcile_manifest_prepare 1 || fail "checked reconcile snapshot failed"
vm_reconcile_manifest_validate_profiles || fail "profile manifest validation failed"
vm_pbr_generate_nft || fail "PBR generation failed for the 100/500 fixture"
vm_wireguard_sync_all || fail "batched WireGuard sync failed"
vm_commit_all || fail "checked network commit failed"

# A required WireGuard runtime command must not be hidden by a later successful
# `ip link set up` command when the function is called from an OR-list.
mkdir -p "$STATE_DIR/keys"
export CORE_WG_FAIL=1
if vm_wireguard_runtime_up_values p_fail wg_fail private '' 1420 public '' \
    vpn.example 51820 0.0.0.0/0 25 >/dev/null 2>&1; then
    fail "WireGuard runtime hid a required wg command failure"
fi
unset CORE_WG_FAIL
printf 'legacy-private\n' > "$STATE_DIR/keys/wg_legacy_key.key"

vm_wireguard_runtime_up_values() {
    printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$8" "${10}" >> "$RUNTIME_LOG"
}
vm_wireguard_runtime_up_all || fail "WireGuard runtime manifest walk failed"
vm_pbr_apply_rules || fail "PBR apply failed for the 100/500 fixture"
elapsed=$(( $(date +%s) - start ))

show_count="$(awk '$0 == "-q show vpn-manager" { count++ } END { print count+0 }' "$UCI_LOG")"
network_show_count="$(awk '$0 == "-q show network" { count++ } END { print count+0 }' "$UCI_LOG")"
get_count="$(awk '$0 ~ /(^| )get( |$)/ { count++ } END { print count+0 }' "$UCI_LOG")"
batch_count="$(awk '$0 == "batch" { count++ } END { print count+0 }' "$UCI_LOG")"
assert_eq 1 "$show_count" "core reconcile must use one checked vpn-manager snapshot"
assert_eq 1 "$network_show_count" "orphan cleanup must use one checked network snapshot"
assert_eq 0 "$get_count" "core reconcile must not use per-record UCI gets"
assert_eq 1 "$batch_count" "WireGuard network sync must use one UCI batch"
assert_eq 99 "$(wc -l < "$RUNTIME_LOG" | tr -d ' ')" "runtime walk did not consume every enabled profile manifest row"

nft_rules="$(cat "$VM_NFT_FILE")"
assert_contains "$nft_rules" 'ether saddr aa:bb:14:01:14:01 meta mark set 101' "first policy mark is wrong"
assert_contains "$nft_rules" 'ip saddr 192.168.20.1 meta mark set 101' "first policy IP mark is wrong"
assert_contains "$nft_rules" 'ip saddr 192.168.21.250 meta mark set 0x0' "WAN policy mark is wrong"
first_rule_line="$(awk '/ether saddr aa:bb:14:01:14:01/ { print NR; exit }' "$VM_NFT_FILE")"
second_rule_line="$(awk '/ether saddr aa:bb:14:02:14:02/ { print NR; exit }' "$VM_NFT_FILE")"
[ "$first_rule_line" -lt "$second_rule_line" ] || fail "policy manifest changed UCI output order"

assert_contains "$(cat "$VM_RECONCILE_SOURCE_RULES")" '192.168.20.1/32|101' "source-rule join is missing"
assert_contains "$(cat "$IP_BATCH_LOG")" 'rule add from 192.168.20.1/32 table 101 priority 9990' "source rules were not sent through ip batch"
assert_contains "$(cat "$IP_BATCH_LOG")" 'rule del from 192.0.2.7 table 777 priority 9990' "stale source rule was not reconciled from kernel state"
assert_contains "$(cat "$IP_BATCH_LOG")" 'rule del fwmark 0xdead table 777 priority 10000' "stale IPv4 fwmark rule was not removed"
assert_contains "$(cat "$IP_BATCH_LOG")" 'rule del fwmark 0xbeef table 778 priority 10000' "stale IPv6 fwmark rule was not removed"
assert_contains "$(cat "$IP_BATCH_LOG")" 'route replace default dev wg_p1 scope link table 101' "profile routes were not prepared"
endpoint_batch_line="$(awk '/endpoint_host/ { print; exit }' "$UCI_BATCH_LOG")"
assert_contains "$endpoint_batch_line" "endpoint_host='vpn'\\''edge.example'" "UCI batch quoting corrupted an apostrophe: $endpoint_batch_line"
assert_contains "$(cat "$UCI_BATCH_LOG")" 'delete network.wg_orphan' "managed orphan was not included in checked network batch"
if grep -Fq 'delete network.vmd20' "$UCI_BATCH_LOG" \
    || grep -Fq 'delete network.vmd20_dev' "$UCI_BATCH_LOG"; then
    fail "dedicated WiFi network was misclassified as a managed orphan"
fi
assert_contains "$(cat "$UCI_BATCH_LOG")" "add_list network.wg_p1_peer.allowed_ips='0.0.0.0/0'" "first AllowedIPs item was not preserved"
assert_contains "$(cat "$UCI_BATCH_LOG")" "add_list network.wg_p1_peer.allowed_ips='::/0'" "second AllowedIPs item was not preserved"
if grep -Fq "allowed_ips='0.0.0.0/0,::/0'" "$UCI_BATCH_LOG"; then
    fail "multiple AllowedIPs were collapsed into one UCI list item"
fi
assert_eq 99 "$(awk '/=interface$/ { count++ } END { print count+0 }' "$UCI_BATCH_LOG")" "disabled profile was configured instead of deleted"
assert_contains "$(cat "$RUNTIME_LOG")" "p1|wg_p1|private-1|vpn'edge.example" "runtime manifest fields were decoded incorrectly"
assert_contains "$(cat "$RUNTIME_LOG")" "|0.0.0.0/0,::/0" "runtime AllowedIPs were not normalized for wg"
assert_contains "$(cat "$IP_LOG")" 'link delete wg_orphan' "committed managed orphan was not removed from runtime"
assert_contains "$(cat "$IP_LOG")" 'link delete wg_legacy_key' "legacy key-owned runtime orphan was not removed"
[ ! -e "$STATE_DIR/keys/wg_legacy_key.key" ] || fail "legacy orphan key was not removed"
assert_eq 1 "$(awk '$0 ~ /^-o link show$/ { count++ } END { print count+0 }' "$IP_LOG")" "PBR apply did not use one link snapshot"
last_ip_batch_line="$(awk '/^ip-batch:/ { line=NR } END { print line+0 }' "$ORDER_LOG")"
nft_apply_line="$(awk '/^nft:.*vpn-manager-apply\.nft/ { print NR; exit }' "$ORDER_LOG")"
[ "$last_ip_batch_line" -gt 0 ] && [ "$nft_apply_line" -gt "$last_ip_batch_line" ] || fail "nft transaction ran before route/rule batches"

# Failure before the nft swap must not publish a partial ownership manifest.
printf 'sentinel source state\n' > "$VM_SRC_RULES_FILE"
export CORE_NFT_APPLY_FAIL=1
if vm_pbr_apply_rules >/dev/null 2>&1; then
    fail "PBR apply accepted a failed nft transaction"
fi
unset CORE_NFT_APPLY_FAIL
assert_eq 'sentinel source state' "$(cat "$VM_SRC_RULES_FILE")" "failed PBR apply replaced source-rule state"
[ ! -e "$VM_SRC_RULES_FILE.next.$$" ] || fail "failed PBR apply leaked next source-rule state"
vm_pbr_apply_rules || fail "PBR apply did not recover after nft failure"

# OpenWrt's uci batch command can return zero after one command failed. A
# non-empty diagnostic stream must still reject and revert the transaction.
: > "$UCI_LOG"
export CORE_BATCH_SOFT_FAIL=1
if vm_wireguard_sync_all >/dev/null 2>&1; then
    fail "WireGuard sync accepted a soft uci batch command failure"
fi
unset CORE_BATCH_SOFT_FAIL
assert_eq 1 "$(awk '$0 == "-q revert network" { count++ } END { print count+0 }' "$UCI_LOG")" "soft batch failure was not reverted"

# A successfully staged batch is still not authority to mutate runtime state:
# runtime_up_all must wait until vm_commit_all clears the pending marker.
: > "$IP_LOG"
vm_wireguard_sync_all || fail "second staged network batch failed"
if vm_wireguard_runtime_up_all >/dev/null 2>&1; then
    fail "runtime mutation was allowed before network commit"
fi
assert_eq 0 "$(wc -l < "$IP_LOG" | tr -d ' ')" "runtime commands ran before network commit"
vm_commit_all || fail "commit after runtime gate test failed"

# A commit fault also reverts staged network data and leaves runtime untouched.
: > "$IP_LOG"
vm_wireguard_sync_all || fail "commit-fault setup batch failed"
export CORE_COMMIT_FAIL=1
if vm_commit_all >/dev/null 2>&1; then
    fail "vm_commit_all accepted a failed network commit"
fi
unset CORE_COMMIT_FAIL
assert_eq 0 "$(wc -l < "$IP_LOG" | tr -d ' ')" "runtime commands ran after failed network commit"

# Fault path: a failed checked batch must revert staged network changes and must
# not delete disabled runtime interfaces or their key material.
: > "$IP_LOG"
: > "$UCI_LOG"
export CORE_BATCH_FAIL=1
if vm_wireguard_sync_all >/dev/null 2>&1; then
    fail "WireGuard sync accepted a failed network batch"
fi
unset CORE_BATCH_FAIL
if vm_wireguard_runtime_up_all >/dev/null 2>&1; then
    fail "runtime mutation was allowed after failed network batch"
fi
assert_eq 1 "$(awk '$0 == "-q revert network" { count++ } END { print count+0 }' "$UCI_LOG")" "failed network batch was not reverted"
assert_eq 0 "$(awk '$0 ~ /^link delete / { count++ } END { print count+0 }' "$IP_LOG")" "runtime interface was deleted after batch failure"

# Duplicate ownership must be rejected before a generated network batch can be
# staged. New interface names also keep the Linux 15-byte limit while using a
# sufficiently large hash suffix for same-prefix profile IDs.
cp "$VM_RECONCILE_PROFILES" "$VM_RECONCILE_PROFILES.saved"
first_profile="$(sed -n '1p' "$VM_RECONCILE_PROFILES.saved")"
printf '%s\n%s\n' "$first_profile" "$(printf '%s' "$first_profile" | sed 's/^p1|/collision|/')" > "$VM_RECONCILE_PROFILES"
if vm_reconcile_manifest_validate_profiles >/dev/null 2>&1; then
    fail "manifest validation accepted duplicate iface/table/fwmark ownership"
fi
mv "$VM_RECONCILE_PROFILES.saved" "$VM_RECONCILE_PROFILES"
iface_a="$(vm_iface_name_for_section profile_shared_prefix_001)"
iface_b="$(vm_iface_name_for_section profile_shared_prefix_002)"
[ "$iface_a" != "$iface_b" ] || fail "same-prefix profile IDs generated the same interface"
[ "${#iface_a}" -le 15 ] && [ "${#iface_b}" -le 15 ] || fail "generated interface exceeds IFNAMSIZ"

vm_reconcile_manifest_cleanup
for sensitive_file in \
    "$VM_RECONCILE_SNAPSHOT" "$VM_RECONCILE_NETWORK_SNAPSHOT" \
    "$VM_RECONCILE_PROFILES" "$VM_RECONCILE_NETWORK_BATCH"
do
    [ ! -e "$sensitive_file" ] || fail "sensitive reconcile material was not cleaned: $sensitive_file"
done
[ -e "$VM_RECONCILE_NETWORK_PENDING" ] || fail "cleanup removed the failed-transaction safety marker"

[ "$elapsed" -le "${CORE_SCALE_MAX_SECONDS:-30}" ] ||
    fail "100-profile/500-policy core reconcile exceeded budget (${elapsed}s)"
printf 'core reconcile scaling: ok profiles=100 policies=500 elapsed=%ss snapshots=1 batches=1\n' "$elapsed"
