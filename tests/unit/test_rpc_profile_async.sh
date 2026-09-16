#!/bin/sh
set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$TEST_DIR/../lib/testlib.sh"

ROOT_DIR="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
RPC_SCRIPT="$ROOT_DIR/src/rpcd/vpn-manager.sh"
TMP_ROOT="$(make_test_tmpdir)"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

FAKE_LIB="$TMP_ROOT/lib"
FAKE_BIN="$TMP_ROOT/bin"
STATE_DIR="$TMP_ROOT/state"
UCI_DATA="$TMP_ROOT/uci-show.txt"
UCI_LOG="$TMP_ROOT/uci.log"
UCI_BATCH_LOG="$TMP_ROOT/uci-batch.log"
QUEUE_LOG="$TMP_ROOT/queue.log"
SYNC_LOG="$TMP_ROOT/sync.log"
IP_LOG="$TMP_ROOT/ip.log"
PROFILE_LOG="$TMP_ROOT/profile.log"
mkdir -p "$FAKE_LIB" "$FAKE_BIN" "$STATE_DIR"

cat > "$FAKE_LIB/common.sh" <<'EOF'
VM_CFG=vpn-manager
VM_STATE_DIR="${VM_STATE_DIR:?}"
vm_config_lock() { return 0; }
vm_config_unlock() { return 0; }
vm_init_dirs() { mkdir -p "$VM_STATE_DIR"; }
vm_apply_request() { printf 'apply|%s|%s\n' "$1" "$2" >> "$RPC_QUEUE_LOG"; }
vm_block_request() { printf 'block|%s\n' "$1" >> "$RPC_QUEUE_LOG"; }
EOF

cat > "$FAKE_LIB/uci.sh" <<'EOF'
vm_profile_exists() { [ "${RPC_PROFILE_EXISTS:-1}" = "1" ]; }
vm_profile_add() { printf 'add|%s\n' "$1" >> "$RPC_PROFILE_LOG"; }
vm_profile_set() { printf 'set|%s|%s|%s\n' "$1" "$2" "$3" >> "$RPC_PROFILE_LOG"; }
vm_profile_delete() { printf 'delete|%s\n' "$1" >> "$RPC_PROFILE_LOG"; }
vm_iface_name_for_section() { printf 'wg_async_0001\n'; }
vm_profile_next_table_id() { printf '101\n'; }
vm_profile_fwmark_for_table() { printf '0x65\n'; }
vm_uci_batch_checked() {
    batch_error="$VM_STATE_DIR/test-batch-error.$$"
    uci batch < "$1" >/dev/null 2> "$batch_error"
    batch_rc=$?
    [ "$batch_rc" -eq 0 ] && [ ! -s "$batch_error" ]
    batch_rc=$?
    rm -f "$batch_error"
    return "$batch_rc"
}
vm_wireguard_sync_profile() {
    printf 'sync|%s\n' "$1" >> "$RPC_SYNC_LOG"
    return 0
}
EOF

cat > "$FAKE_LIB/health.sh" <<'EOF'
vm_profile_health() { printf 'healthy\n'; }
EOF

cat > "$FAKE_BIN/uci" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RPC_UCI_LOG"
case "$*" in
    '-q show vpn-manager')
        cat "$RPC_UCI_DATA"
        ;;
    'batch')
        batch_payload="$(cat)"
        printf '%s\n' "$batch_payload" >> "$RPC_UCI_BATCH_LOG"
        ;;
    'commit vpn-manager'|'commit wireless')
        ;;
    -q\ delete\ vpn-manager.*.allowed_ips)
        ;;
    add_list\ vpn-manager.*.allowed_ips=*)
        ;;
    *)
        printf 'unexpected uci invocation: %s\n' "$*" >&2
        exit 97
        ;;
esac
EOF

cat > "$FAKE_BIN/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$RPC_IP_LOG"
exit 0
EOF

chmod 0755 "$FAKE_BIN/uci" "$FAKE_BIN/ip"

export VM_LIB_DIR="$FAKE_LIB"
export VM_STATE_DIR="$STATE_DIR"
export RPC_UCI_DATA="$UCI_DATA"
export RPC_UCI_LOG="$UCI_LOG"
export RPC_UCI_BATCH_LOG="$UCI_BATCH_LOG"
export RPC_QUEUE_LOG="$QUEUE_LOG"
export RPC_SYNC_LOG="$SYNC_LOG"
export RPC_IP_LOG="$IP_LOG"
export RPC_PROFILE_LOG="$PROFILE_LOG"
export PATH="$FAKE_BIN:$PATH"

reset_traces() {
    : > "$UCI_LOG"
    : > "$UCI_BATCH_LOG"
    : > "$QUEUE_LOG"
    : > "$SYNC_LOG"
    : > "$IP_LOG"
    : > "$PROFILE_LOG"
}

assert_async_only() {
    operation="$1"
    expected_reason="$2"

    assert_eq 1 "$(awk '$0 == "commit vpn-manager" { count++ } END { print count+0 }' "$UCI_LOG")" "$operation must commit vpn-manager exactly once"
    assert_eq 0 "$(awk '$0 == "commit network" || $0 ~ /(^| )delete network\./ { count++ } END { print count+0 }' "$UCI_LOG")" "$operation mutated or committed network on the ACK path"
    assert_eq "" "$(cat "$SYNC_LOG")" "$operation synchronously invoked WireGuard sync"
    assert_eq "" "$(cat "$IP_LOG")" "$operation synchronously invoked ip"
    assert_eq "apply|full|$expected_reason
block|$expected_reason" "$(cat "$QUEUE_LOG")" "$operation did not enqueue full and block work"
}

# New profile creation must only persist the manager configuration and enqueue
# the dataplane work.
reset_traces
: > "$UCI_DATA"
export RPC_PROFILE_EXISTS=0
set_result="$(sh "$RPC_SCRIPT" set_profile async01 'Async profile' vpn.example 51820 public private 10.0.0.2/32 1.1.1.1 '0.0.0.0/0,::/0' 1420 25 1 preshared)"
assert_contains "$set_result" '"ok":true' "set_profile failed"
assert_contains "$set_result" '"queued":true' "set_profile did not ACK queued work"
assert_async_only set_profile profile-save

# A profile delete with WiFi references stages the reference updates, commits
# wireless once, and leaves managed network/interface/key orphan cleanup to the
# reconcile worker.
reset_traces
export RPC_PROFILE_EXISTS=1
cat > "$UCI_DATA" <<'EOF'
vpn-manager.async01=profile
vpn-manager.async01.iface='wg_async_0001'
vpn-manager.policy01=device_policy
vpn-manager.policy01.target='async01'
vpn-manager.wifi01=wifi_binding
vpn-manager.wifi01.target='async01'
vpn-manager.wifi01.enabled='1'
EOF
delete_result="$(sh "$RPC_SCRIPT" delete_profile async01)"
assert_contains "$delete_result" '"ok":true' "delete_profile failed"
assert_async_only delete_profile profile-delete
assert_eq 1 "$(awk '$0 == "commit wireless" { count++ } END { print count+0 }' "$UCI_LOG")" "delete_profile did not commit a changed wireless reference batch"
assert_contains "$(cat "$UCI_BATCH_LOG")" "set vpn-manager.policy01.target='wan'" "delete_profile omitted the policy reference update"
assert_contains "$(cat "$UCI_BATCH_LOG")" "set wireless.wifi01.disabled='1'" "delete_profile omitted the wireless reference update"
assert_eq 0 "$(awk '$0 ~ /(^| )get( |$)/ { count++ } END { print count+0 }' "$UCI_LOG")" "delete_profile still reads an interface for synchronous cleanup"

# No WiFi reference means there is no wireless commit in the request path.
reset_traces
cat > "$UCI_DATA" <<'EOF'
vpn-manager.async02=profile
vpn-manager.async02.iface='wg_async_0002'
vpn-manager.policy02=device_policy
vpn-manager.policy02.target='async02'
EOF
delete_no_wifi_result="$(sh "$RPC_SCRIPT" delete_profile async02)"
assert_contains "$delete_no_wifi_result" '"ok":true' "delete_profile without WiFi references failed"
assert_async_only delete_profile-without-wifi profile-delete
assert_eq 0 "$(awk '$0 == "commit wireless" { count++ } END { print count+0 }' "$UCI_LOG")" "delete_profile committed unchanged wireless configuration"

# WireGuard import follows the same fast ACK contract.
WG_CONF="$TMP_ROOT/import.conf"
cat > "$WG_CONF" <<'EOF'
[Interface]
PrivateKey = imported-private
Address = 10.20.0.2/32
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = imported-public
PresharedKey = imported-preshared
Endpoint = imported.example:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
reset_traces
import_result="$(sh "$RPC_SCRIPT" import_profile imported01 "$WG_CONF")"
assert_contains "$import_result" '"ok":true' "import_profile failed"
assert_contains "$import_result" '"queued":true' "import_profile did not ACK queued work"
assert_async_only import_profile profile-import
for leftover in "$STATE_DIR"/import-normalized-*.conf; do
    [ ! -e "$leftover" ] || fail "import_profile left sensitive normalized input behind"
done

# Guard every profile CRUD function, including the MultiEbay wrapper, against
# reintroducing synchronous dataplane cleanup.
profile_crud_source="$(sed -n '/^set_profile() {/,/^case "\$1" in/p' "$RPC_SCRIPT")"
for forbidden in 'vm_wireguard_sync_profile' 'uci commit network' 'ip link delete' 'VM_STATE_DIR/keys/'; do
    case "$profile_crud_source" in
        *"$forbidden"*) fail "profile CRUD contains forbidden synchronous operation: $forbidden" ;;
    esac
done

echo "RPC profile mutations use asynchronous full/block reconcile: ok"
