#!/bin/sh
set -u

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$TEST_DIR/../lib/testlib.sh"

ROOT_DIR="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
TMP_ROOT="$(make_test_tmpdir)"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM
HOST_JQ="$(command -v jq 2>/dev/null || true)"

FAKE_LIB="$TMP_ROOT/lib"
FAKE_BIN="$TMP_ROOT/bin"
STATE_DIR="$TMP_ROOT/state"
UCI_DATA="$TMP_ROOT/uci-show.txt"
UCI_LOG="$TMP_ROOT/uci.log"
UCI_BATCH="$TMP_ROOT/uci.batch"
mkdir -p "$FAKE_LIB" "$FAKE_BIN" "$STATE_DIR"

cat > "$FAKE_LIB/common.sh" <<'EOF'
VM_CFG=vpn-manager
VM_STATE_DIR="${VM_STATE_DIR:?}"
vm_config_lock() { return 0; }
vm_config_unlock() { return 0; }
vm_now() { printf '1700000000'; }
vm_apply_request() { return 0; }
vm_block_request() { return 0; }
vm_init_dirs() { mkdir -p "$VM_STATE_DIR"; }
EOF

cat > "$FAKE_LIB/uci.sh" <<'EOF'
vm_profile_exists() { return 0; }
vm_profile_set() { return 0; }
vm_profile_delete() { return 0; }
vm_policy_set_device_target() { return 0; }
vm_uci_batch_checked() {
    batch_error="$VM_STATE_DIR/test-batch-error.$$"
    uci batch < "$1" >/dev/null 2> "$batch_error"
    batch_rc=$?
    [ "$batch_rc" -eq 0 ] && [ ! -s "$batch_error" ]
    batch_rc=$?
    rm -f "$batch_error"
    return "$batch_rc"
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
        [ "${RPC_SHOW_FAIL:-0}" = "1" ] && exit 96
        cat "$RPC_UCI_DATA"
        ;;
    'batch')
        batch_payload="$(cat)"
        printf '%s\n' "$batch_payload" >> "$RPC_UCI_BATCH"
        [ "${RPC_BATCH_FAIL:-0}" = "1" ] && exit 95
        if [ "${RPC_OPTIONAL_BATCH_FAIL:-0}" = "1" ] && printf '%s\n' "$batch_payload" | grep -q '^set wireless\.'; then
            exit 94
        fi
        ;;
    '-q get vpn-manager.p001.iface')
        printf 'wg001\n'
        ;;
    'commit vpn-manager'|'commit network'|'commit wireless'|'-q delete network.wg001'|'-q delete network.wg001_peer'|'-q revert vpn-manager')
        ;;
    *)
        printf 'unexpected uci invocation: %s\n' "$*" >&2
        exit 97
        ;;
esac
EOF

cat > "$FAKE_BIN/ip" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$FAKE_BIN/lock" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/sh
[ "${RPC_CURL_INVALID:-0}" = "1" ] && {
    printf '<html>upstream failure</html>'
    exit 0
}
printf '{"success":true,"ip":"203.0.113.1"}'
EOF

cat > "$FAKE_BIN/jq" <<'EOF'
#!/bin/sh
for jq_arg in "$@"; do jq_file="$jq_arg"; done
[ -f "${jq_file:-}" ] || exit 1
grep -q '<html>' "$jq_file" && exit 1
grep -q '^{' "$jq_file" && grep -q '}$' "$jq_file"
EOF

chmod 0755 "$FAKE_BIN/uci" "$FAKE_BIN/ip" "$FAKE_BIN/lock" "$FAKE_BIN/curl" "$FAKE_BIN/jq"
: > "$UCI_DATA"
: > "$UCI_LOG"
: > "$UCI_BATCH"

i=1
while [ "$i" -le 250 ]; do
    id="$(printf '%03d' "$i")"
    octet_a=$((i / 250))
    octet_b=$((i % 250 + 1))
    case $((i % 3)) in
        0) health=healthy ;;
        1) health=down ;;
        *) health=unknown ;;
    esac

    {
        printf 'vpn-manager.p%s=profile\n' "$id"
        printf "vpn-manager.p%s.name='Profile %s'\n" "$id" "$id"
        if [ "$i" -lt 250 ]; then
            printf "vpn-manager.p%s.iface='wg%s'\n" "$id" "$id"
        fi
        printf "vpn-manager.p%s.endpoint_host='vpn%s.example.net'\n" "$id" "$id"
        printf "vpn-manager.p%s.endpoint_port='51820'\n" "$id"
        printf "vpn-manager.p%s.enabled='1'\n" "$id"
        printf "vpn-manager.p%s.address='10.10.%s.%s/32'\n" "$id" "$octet_a" "$octet_b"
        printf "vpn-manager.p%s.dns='1.1.1.1'\n" "$id"
        printf "vpn-manager.p%s.allowed_ips='0.0.0.0/0' '::/0'\n" "$id"
        printf "vpn-manager.p%s.mtu='1420'\n" "$id"
        printf "vpn-manager.p%s.persistent_keepalive='25'\n" "$id"
        printf "vpn-manager.p%s.public_key='key-%s'\n" "$id" "$id"

        printf 'vpn-manager.policy%s=device_policy\n' "$id"
        printf "vpn-manager.policy%s.hostname='Device %s'\n" "$id" "$id"
        printf "vpn-manager.policy%s.mac='02:00:00:00:%02x:%02x'\n" "$id" "$octet_a" "$octet_b"
        printf "vpn-manager.policy%s.ip='192.168.%s.%s'\n" "$id" "$octet_a" "$octet_b"
        printf "vpn-manager.policy%s.target='p001'\n" "$id"

        printf 'vpn-manager.block%s=blocked_domain\n' "$id"
        printf "vpn-manager.block%s.domain='domain%s.example'\n" "$id" "$id"
        printf "vpn-manager.block%s.mode='wildcard'\n" "$id"
        printf "vpn-manager.block%s.enabled='1'\n" "$id"
    } >> "$UCI_DATA"
    printf 'p%s|wg%s|%s|%s|1700000000\n' "$id" "$id" "$health" "$i" >> "$STATE_DIR/health-snapshot.txt"
    i=$((i + 1))
done

cat >> "$UCI_DATA" <<'EOF'
vpn-manager.p001.name='O'\''Reilly "east" \ lab'
vpn-manager.policy001.hostname='Desk "A" \ lab'
vpn-manager.duplicate_mac=device_policy
vpn-manager.duplicate_mac.hostname='Duplicate MAC'
vpn-manager.duplicate_mac.mac='02:00:00:00:00:02'
vpn-manager.duplicate_mac.ip='192.168.9.9'
vpn-manager.duplicate_mac.target='p001'
vpn-manager.duplicate_ip=device_policy
vpn-manager.duplicate_ip.hostname='Duplicate IP'
vpn-manager.duplicate_ip.mac='02:00:00:00:09:09'
vpn-manager.duplicate_ip.ip='192.168.0.2'
vpn-manager.duplicate_ip.target='p001'
vpn-manager.wifi001=wifi_binding
vpn-manager.wifi001.target='p001'
vpn-manager.wifi001.enabled='1'
EOF

export VM_LIB_DIR="$FAKE_LIB"
export VM_STATE_DIR="$STATE_DIR"
export RPC_UCI_DATA="$UCI_DATA"
export RPC_UCI_LOG="$UCI_LOG"
export RPC_UCI_BATCH="$UCI_BATCH"
export PATH="$FAKE_BIN:$PATH"

run_rpc() {
    : > "$UCI_LOG"
    sh "$ROOT_DIR/src/rpcd/vpn-manager.sh" "$@"
}

assert_one_snapshot() {
    snapshot_count="$(awk '$0 == "-q show vpn-manager" { count++ } END { print count+0 }' "$UCI_LOG")"
    assert_eq 1 "$snapshot_count" "$1 must use exactly one UCI snapshot"
    get_count="$(awk '$0 ~ /(^| )get( |$)/ { count++ } END { print count+0 }' "$UCI_LOG")"
    assert_eq 0 "$get_count" "$1 must not issue per-record uci get calls"
}

profiles_json="$(run_rpc list_profiles)"
assert_one_snapshot list_profiles
policies_json="$(run_rpc list_policies)"
assert_one_snapshot list_policies
domains_json="$(run_rpc list_blocked_domains)"
assert_one_snapshot list_blocked_domains
status_json="$(run_rpc status)"
assert_one_snapshot status

run_rpc refresh_route_status >/dev/null
assert_one_snapshot refresh_route_status

if [ -n "$HOST_JQ" ]; then
    printf '%s' "$profiles_json" | "$HOST_JQ" -e '
        (.profiles | length) == 250 and
        .profiles[0].id == "p001" and
        .profiles[0].name == "O'\''Reilly \"east\" \\ lab" and
        .profiles[0].allowed_ips == "0.0.0.0/0 ::/0" and
        .profiles[0].status == "down" and
        .profiles[249].handshake_age == "250"
    ' >/dev/null || fail "profile snapshot JSON is invalid or incomplete"
    printf '%s' "$policies_json" | "$HOST_JQ" -e '(.policies | length) == 252 and .policies[0].section == "policy001" and .policies[0].hostname == "Desk \"A\" \\ lab"' >/dev/null ||
        fail "policy snapshot JSON is invalid or incomplete"
    printf '%s' "$domains_json" | "$HOST_JQ" -e '(.ok == true) and ((.domains | length) == 250)' >/dev/null ||
        fail "blocked-domain snapshot JSON is invalid or incomplete"
    printf '%s' "$status_json" | "$HOST_JQ" -e '.up == 83 and .down == 84 and .unknown == 83 and .timestamp == "1700000000"' >/dev/null ||
        fail "status snapshot JSON is invalid or incomplete"
    "$HOST_JQ" -e '(.ok == true) and ((.profiles | length) == 249) and (.profiles[0].iface == "wg001") and (.profiles[0].ip.success == true)' \
        "$STATE_DIR/route-status-cache.json" >/dev/null || fail "route-status refresh did not use the profile manifest correctly"
else
    assert_contains "$profiles_json" '"id":"p001"' "profiles JSON omitted first profile"
    assert_contains "$profiles_json" '"allowed_ips":"0.0.0.0/0 ::/0"' "UCI list decoding failed"
    assert_contains "$status_json" '"up":83,"down":84,"unknown":83' "status counts are wrong"
    assert_contains "$(cat "$STATE_DIR/route-status-cache.json")" '"iface":"wg001"' "route manifest omitted the first profile"
fi

cache_before="$(cat "$STATE_DIR/route-status-cache.json")"
export RPC_CURL_INVALID=1
if run_rpc refresh_route_status >/dev/null 2>&1; then
    fail "refresh_route_status accepted a malformed upstream response"
fi
unset RPC_CURL_INVALID
assert_eq "$cache_before" "$(cat "$STATE_DIR/route-status-cache.json")" "malformed route refresh replaced the last valid cache"

export RPC_SHOW_FAIL=1
snapshot_error="$(run_rpc list_profiles)"
assert_contains "$snapshot_error" '"ok":false' "list_profiles hid a UCI snapshot failure"
: > "$UCI_BATCH"
dedupe_error="$(run_rpc set_policy policy001 02:00:00:00:00:02 192.168.0.2 'Device 001' wan)"
assert_contains "$dedupe_error" '"ok":false' "set_policy hid a UCI snapshot failure"
assert_eq 0 "$(awk '$0 == "commit vpn-manager" { count++ } END { print count+0 }' "$UCI_LOG")" "set_policy committed after a failed snapshot"
unset RPC_SHOW_FAIL

invalid_policy="$(run_rpc set_policy policy001 '02:00:00:00:00:02 add rule' 999.1.2.3 'Device 001' wan)"
assert_contains "$invalid_policy" '"ok":false' "set_policy accepted injectable MAC/invalid IPv4 input"
assert_eq 0 "$(wc -l < "$UCI_LOG" | tr -d ' ')" "invalid policy input reached UCI"

export RPC_BATCH_FAIL=1
batch_error="$(run_rpc set_policy policy001 02:00:00:00:00:02 192.168.0.2 'Device 001' wan)"
assert_contains "$batch_error" '"ok":false' "set_policy hid a required batch failure"
assert_eq 1 "$(awk '$0 == "-q revert vpn-manager" { count++ } END { print count+0 }' "$UCI_LOG")" "required batch failure did not revert staged UCI changes"
assert_eq 0 "$(awk '$0 == "commit vpn-manager" { count++ } END { print count+0 }' "$UCI_LOG")" "set_policy committed a partial failed batch"
unset RPC_BATCH_FAIL

: > "$UCI_BATCH"
policy_result="$(run_rpc set_policy policy001 02:00:00:00:00:02 192.168.0.2 'Device 001' wan)"
assert_contains "$policy_result" '"ok":true' "set_policy failed"
assert_eq 1 "$(awk '$0 == "-q show vpn-manager" { count++ } END { print count+0 }' "$UCI_LOG")" "policy dedupe must scan one snapshot"
assert_eq 0 "$(awk '$0 ~ /policy[0-9]+\.(mac|ip)/ && $0 ~ /get/ { count++ } END { print count+0 }' "$UCI_LOG")" "policy dedupe used per-policy gets"
assert_contains "$(cat "$UCI_BATCH")" 'delete vpn-manager.duplicate_mac' "MAC duplicate was not batched"
assert_contains "$(cat "$UCI_BATCH")" 'delete vpn-manager.duplicate_ip' "IP duplicate was not batched"

: > "$UCI_BATCH"
export RPC_OPTIONAL_BATCH_FAIL=1
delete_result="$(run_rpc delete_profile p001)"
unset RPC_OPTIONAL_BATCH_FAIL
assert_contains "$delete_result" '"ok":true' "delete_profile failed"
assert_eq 1 "$(awk '$0 == "-q show vpn-manager" { count++ } END { print count+0 }' "$UCI_LOG")" "profile reference cleanup must scan one snapshot"
assert_eq 0 "$(awk '$0 ~ /(^| )get( |$)/ { count++ } END { print count+0 }' "$UCI_LOG")" "delete_profile must leave interface discovery and cleanup to reconcile"
batch_text="$(cat "$UCI_BATCH")"
assert_contains "$batch_text" "set vpn-manager.policy001.target='wan'" "policy references were not retargeted in batch"
assert_contains "$batch_text" "set vpn-manager.wifi001.enabled='0'" "WiFi binding was not disabled in batch"
assert_contains "$batch_text" "set wireless.wifi001.disabled='1'" "wireless section was not disabled in batch"

echo "RPC snapshot scaling and batched reference updates: ok"
