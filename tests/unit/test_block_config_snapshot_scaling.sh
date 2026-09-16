#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$TEST_DIR/../lib/testlib.sh"

ROOT_DIR="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
TMP_ROOT="$(make_test_tmpdir)"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

FAKE_BIN="$TMP_ROOT/bin"
STATE_DIR="$TMP_ROOT/state"
UCI_DATA="$TMP_ROOT/uci-show.txt"
UCI_LOG="$TMP_ROOT/uci.log"
CONFIG_SNAPSHOT="$TMP_ROOT/config.show"
RESOLVERS="$TMP_ROOT/resolvers"
DOMAINS="$TMP_ROOT/domains"
mkdir -p "$STATE_DIR"
install_fake_openwrt_tools "$FAKE_BIN"

cat > "$FAKE_BIN/uci" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$BLOCK_PLAN_UCI_LOG"
case "$*" in
    '-q show vpn-manager') cat "$BLOCK_PLAN_UCI_DATA" ;;
    *) printf 'unexpected uci invocation: %s\n' "$*" >&2; exit 91 ;;
esac
EOF
chmod 0755 "$FAKE_BIN/uci"

: > "$UCI_DATA"
: > "$UCI_LOG"
i=1
while [ "$i" -le 100 ]; do
    {
        printf 'vpn-manager.profile%03d=profile\n' "$i"
        printf "vpn-manager.profile%03d.enabled='1'\n" "$i"
        printf "vpn-manager.profile%03d.dns='10.0.0.%s' '2001:db8::%s'\n" "$i" "$i" "$i"
        printf "vpn-manager.profile%03d.private_key='secret-%s'\n" "$i" "$i"
        printf 'vpn-manager.block%03d=blocked_domain\n' "$i"
        printf "vpn-manager.block%03d.enabled='1'\n" "$i"
        printf "vpn-manager.block%03d.domain='HTTPS://*.Example%03d.COM/path'\n" "$i" "$i"
        printf "vpn-manager.block%03d.mode='wildcard'\n" "$i"
    } >> "$UCI_DATA"
    i=$((i + 1))
done

export VM_STATE_DIR="$STATE_DIR"
export VM_AUDIT_LOG="$TMP_ROOT/audit.log"
export VM_LIB_DIR="$ROOT_DIR/src/lib/vpn-manager"
export BLOCK_PLAN_UCI_DATA="$UCI_DATA"
export BLOCK_PLAN_UCI_LOG="$UCI_LOG"
export PATH="$FAKE_BIN:$PATH"

. "$VM_LIB_DIR/pbr.sh"
vm_pbr_block_snapshot_config "$CONFIG_SNAPSHOT" "$RESOLVERS" "$DOMAINS" || fail "block config snapshot failed"

assert_eq 1 "$(wc -l < "$UCI_LOG" | tr -d ' ')" "block planning must take one UCI snapshot"
assert_eq 0 "$(awk '$0 ~ /(^| )get( |$)/ { count++ } END { print count+0 }' "$UCI_LOG")" "block planning used per-record UCI gets"
assert_eq 103 "$(sort -u "$RESOLVERS" | wc -l | tr -d ' ')" "profile DNS resolvers were not extracted"
assert_eq 100 "$(sort -u "$DOMAINS" | wc -l | tr -d ' ')" "blocked domains were not extracted"
assert_contains "$(sed -n '1p' "$DOMAINS")" 'example001.com|wildcard' "URL/domain normalization changed"

echo "block config snapshot scaling: ok"
