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
LINK_DATA="$TMP_ROOT/links.txt"
WG_DATA="$TMP_ROOT/handshakes.txt"
FW4_DATA="$TMP_ROOT/fw4.txt"
UCI_LOG="$TMP_ROOT/uci.log"
IP_LOG="$TMP_ROOT/ip.log"
WG_LOG="$TMP_ROOT/wg.log"
NFT_LOG="$TMP_ROOT/nft.log"
mkdir -p "$STATE_DIR"
install_fake_openwrt_tools "$FAKE_BIN"

cat > "$FAKE_BIN/uci" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MONITOR_UCI_LOG"
case "$*" in
    '-q show vpn-manager') cat "$MONITOR_UCI_DATA" ;;
    *) printf 'unexpected uci invocation: %s\n' "$*" >&2; exit 91 ;;
esac
EOF

cat > "$FAKE_BIN/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MONITOR_IP_LOG"
case "$*" in
    '-o link show') cat "$MONITOR_LINK_DATA" ;;
    *) printf 'unexpected ip invocation: %s\n' "$*" >&2; exit 92 ;;
esac
EOF

cat > "$FAKE_BIN/wg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MONITOR_WG_LOG"
case "$*" in
    'show all latest-handshakes') cat "$MONITOR_WG_DATA" ;;
    *) printf 'unexpected wg invocation: %s\n' "$*" >&2; exit 93 ;;
esac
EOF

cat > "$FAKE_BIN/nft" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MONITOR_NFT_LOG"
case "$*" in
    'list table inet fw4') cat "$MONITOR_FW4_DATA" ;;
    *) printf 'unexpected nft invocation: %s\n' "$*" >&2; exit 94 ;;
esac
EOF

chmod 0755 "$FAKE_BIN/uci" "$FAKE_BIN/ip" "$FAKE_BIN/wg" "$FAKE_BIN/nft"
: > "$UCI_DATA"
: > "$LINK_DATA"
: > "$WG_DATA"
: > "$UCI_LOG"
: > "$IP_LOG"
: > "$WG_LOG"
: > "$NFT_LOG"
: > "$STATE_DIR/health-snapshot.txt"

i=1
while [ "$i" -le 500 ]; do
    {
        printf 'vpn-manager.p%s=profile\n' "$i"
        printf "vpn-manager.p%s.enabled='1'\n" "$i"
        printf "vpn-manager.p%s.iface='wg_p%s'\n" "$i" "$i"
        printf "vpn-manager.p%s.private_key='secret-%s'\n" "$i" "$i"
    } >> "$UCI_DATA"
    printf '%s: wg_p%s: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 state UNKNOWN\n' "$i" "$i" >> "$LINK_DATA"
    printf 'wg_p%s peer-%s 2000000000\n' "$i" "$i" >> "$WG_DATA"
    printf 'p%s|wg_p%s|healthy|0|2000000000\n' "$i" "$i" >> "$STATE_DIR/health-snapshot.txt"
    i=$((i + 1))
done

{
    printf 'table inet fw4 {\n'
    i=1
    while [ "$i" -le 100 ]; do
        {
            printf 'vpn-manager.wifi%s=wifi_binding\n' "$i"
            printf "vpn-manager.wifi%s.enabled='1'\n" "$i"
            printf "vpn-manager.wifi%s.target='p%s'\n" "$i" "$i"
            printf "vpn-manager.wifi%s.network='wifi%s'\n" "$i" "$i"
        } >> "$UCI_DATA"
        printf '    chain forward_wifi%s {\n' "$i"
        printf '        oifname "wg_p%s" accept\n' "$i"
        printf '    }\n'
        i=$((i + 1))
    done
    printf '}\n'
} > "$FW4_DATA"

export VM_STATE_DIR="$STATE_DIR"
export VM_AUDIT_LOG="$TMP_ROOT/audit.log"
export VM_LIB_DIR="$ROOT_DIR/src/lib/vpn-manager"
export MONITOR_UCI_DATA="$UCI_DATA"
export MONITOR_LINK_DATA="$LINK_DATA"
export MONITOR_WG_DATA="$WG_DATA"
export MONITOR_FW4_DATA="$FW4_DATA"
export MONITOR_UCI_LOG="$UCI_LOG"
export MONITOR_IP_LOG="$IP_LOG"
export MONITOR_WG_LOG="$WG_LOG"
export MONITOR_NFT_LOG="$NFT_LOG"
export PATH="$FAKE_BIN:$PATH"

sh "$ROOT_DIR/scripts/vpn-healthcheck.sh"

assert_eq 500 "$(wc -l < "$STATE_DIR/health-snapshot.txt" | tr -d ' ')" "health snapshot lost profiles"
assert_eq 500 "$(awk -F'|' '$3 == "healthy" { count++ } END { print count+0 }' "$STATE_DIR/health-snapshot.txt")" "healthy profiles were misclassified"
assert_eq 1 "$(wc -l < "$UCI_LOG" | tr -d ' ')" "health sweep must read UCI once"
assert_eq 1 "$(wc -l < "$IP_LOG" | tr -d ' ')" "health sweep must list links once"
assert_eq 1 "$(wc -l < "$WG_LOG" | tr -d ' ')" "health sweep must read handshakes once"
assert_eq 0 "$(awk '$0 ~ /(^| )get( |$)/ { count++ } END { print count+0 }' "$UCI_LOG")" "health sweep used per-profile UCI gets"

: > "$UCI_LOG"
sh "$ROOT_DIR/scripts/vpn-watchdog.sh"

assert_eq 1 "$(wc -l < "$UCI_LOG" | tr -d ' ')" "watchdog must read UCI once"
assert_eq 1 "$(wc -l < "$NFT_LOG" | tr -d ' ')" "watchdog must inspect fw4 once"
assert_eq 0 "$(awk '$0 ~ /(^| )get( |$)/ { count++ } END { print count+0 }' "$UCI_LOG")" "watchdog used per-record UCI gets"
[ ! -s "$STATE_DIR/apply.queue" ] || fail "valid WiFi forwarding rules queued an unnecessary refresh"

echo "monitor snapshot scaling: ok"
