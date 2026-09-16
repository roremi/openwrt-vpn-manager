#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
. "$REPO_ROOT/tests/lib/testlib.sh"

tmp_dir="$(make_test_tmpdir)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
install_fake_openwrt_tools "$tmp_dir/bin"

cat > "$tmp_dir/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
    "-q get vpn-manager.blk_test.enabled") echo 1 ;;
    "-q get vpn-manager.blk_test.domain") echo example.com ;;
    "-q get vpn-manager.blk_test.mode") echo exact ;;
    *) exit 1 ;;
esac
EOF

cat > "$tmp_dir/bin/nslookup" <<'EOF'
#!/bin/sh
printf '%s|%s\n' "$1" "$2" >> "$VM_TEST_NSLOOKUP_TRACE"
if [ -f "$VM_TEST_DNS_DIR/$2.fail" ]; then
    exec sleep 10
fi
answer="$(cat "$VM_TEST_DNS_DIR/$2.ip" 2>/dev/null || true)"
[ -n "$answer" ] || exit 1
cat <<OUT
Server: $2
Address 1: $2

Name: $1
Address 1: $answer
OUT
EOF
chmod 0755 "$tmp_dir/bin/uci" "$tmp_dir/bin/nslookup"

mkdir -p "$tmp_dir/dns"
printf '%s\n' 203.0.113.11 > "$tmp_dir/dns/1.1.1.1.ip"
printf '%s\n' 203.0.113.99 > "$tmp_dir/dns/9.9.9.9.ip"
: > "$tmp_dir/dns/8.8.8.8.fail"

VM_STATE_DIR="$tmp_dir/state"
VM_AUDIT_LOG="$tmp_dir/audit.log"
VM_LIB_DIR="$REPO_ROOT/src/lib/vpn-manager"
VM_BLOCK_QUERY_TIMEOUT=1
VM_BLOCK_RESOLVE_WORKERS=2
VM_BLOCK_CACHE_TTL=3600
VM_TEST_NSLOOKUP_TRACE="$tmp_dir/nslookup.trace"
VM_TEST_DNS_DIR="$tmp_dir/dns"
PATH="$tmp_dir/bin:$PATH"
export VM_STATE_DIR VM_AUDIT_LOG VM_LIB_DIR VM_BLOCK_QUERY_TIMEOUT
export VM_BLOCK_RESOLVE_WORKERS VM_BLOCK_CACHE_TTL VM_TEST_NSLOOKUP_TRACE
export VM_TEST_DNS_DIR PATH

. "$VM_LIB_DIR/pbr.sh"

TEST_BLOCK_DOMAIN=example.com
TEST_BLOCK_MODE=exact
TEST_BLOCK_RESOLVERS='1.1.1.1 8.8.8.8'
vm_pbr_block_snapshot_config() {
    : > "$1"
    printf '%s\n' $TEST_BLOCK_RESOLVERS > "$2"
    printf '%s|%s\n' "$TEST_BLOCK_DOMAIN" "$TEST_BLOCK_MODE" > "$3"
}

started="$(date +%s)"
vm_pbr_generate_block
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -le 4 ] || fail "resolver timeout was not bounded (elapsed=${elapsed}s)"

assert_eq "2" "$(wc -l < "$VM_TEST_NSLOOKUP_TRACE" | tr -d ' ')" "unexpected first-pass lookup count"
grep -q '203.0.113.11' "$VM_NFT_BLOCK_FILE" || fail "resolved IPv4 was not written to nft set"

vm_pbr_generate_block
assert_eq "2" "$(wc -l < "$VM_TEST_NSLOOKUP_TRACE" | tr -d ' ')" "fresh domain cache did not suppress duplicate lookups"

# Adding one resolver must not invalidate either existing pair. The timed-out
# resolver is also under a retry cooldown, so only the new resolver is queried.
TEST_BLOCK_RESOLVERS='1.1.1.1 8.8.8.8 9.9.9.9'
vm_pbr_generate_block
assert_eq "3" "$(wc -l < "$VM_TEST_NSLOOKUP_TRACE" | tr -d ' ')" "resolver-list growth invalidated existing pair caches"
assert_eq "example.com|9.9.9.9" "$(tail -n1 "$VM_TEST_NSLOOKUP_TRACE")" "new resolver was not the only lookup"
grep -q '203.0.113.11' "$VM_NFT_BLOCK_FILE" || fail "old active resolver cache disappeared"
grep -q '203.0.113.99' "$VM_NFT_BLOCK_FILE" || fail "new resolver answer was not aggregated"

# Cached files may remain for reuse, but nft must aggregate active resolvers
# only. Re-adding a still-fresh resolver should reuse its independent cache.
TEST_BLOCK_RESOLVERS='8.8.8.8 9.9.9.9'
vm_pbr_generate_block
grep -q '203.0.113.11' "$VM_NFT_BLOCK_FILE" && fail "inactive resolver leaked into nft aggregate"
grep -q '203.0.113.99' "$VM_NFT_BLOCK_FILE" || fail "active resolver disappeared from nft aggregate"

TEST_BLOCK_RESOLVERS='1.1.1.1 8.8.8.8 9.9.9.9'
vm_pbr_generate_block
assert_eq "3" "$(wc -l < "$VM_TEST_NSLOOKUP_TRACE" | tr -d ' ')" "re-added resolver did not reuse its pair cache"
grep -q '203.0.113.11' "$VM_NFT_BLOCK_FILE" || fail "re-added resolver cache was not restored"

# Expire successful records, then make one resolver time out. Its own LKG must
# survive while another resolver refreshes successfully.
VM_BLOCK_CACHE_TTL=0
: > "$tmp_dir/dns/1.1.1.1.fail"
vm_pbr_generate_block
assert_eq "5" "$(wc -l < "$VM_TEST_NSLOOKUP_TRACE" | tr -d ' ')" "unexpected expired-pair refresh count"
grep -q '203.0.113.11' "$VM_NFT_BLOCK_FILE" || fail "resolver timeout erased its last-known-good IP"
grep -q '203.0.113.99' "$VM_NFT_BLOCK_FILE" || fail "healthy resolver did not refresh beside timed-out resolver"

# Wildcard host state is compacted into one 35-field row per resolver (three
# identity fields plus eight success/v4/v6/retry slots), while all eight names
# retain independent freshness.
TEST_BLOCK_DOMAIN=wildcard.example
TEST_BLOCK_MODE=wildcard
TEST_BLOCK_RESOLVERS='9.9.9.9'
VM_BLOCK_CACHE_TTL=3600
before_wildcard="$(wc -l < "$VM_TEST_NSLOOKUP_TRACE" | tr -d ' ')"
vm_pbr_generate_block
after_wildcard="$(wc -l < "$VM_TEST_NSLOOKUP_TRACE" | tr -d ' ')"
assert_eq "8" "$((after_wildcard - before_wildcard))" "wildcard did not resolve each bounded hostname once"
assert_eq "35" "$(awk -F '|' '$1 == "wildcard.example" && $2 == "wildcard" && $3 == "9.9.9.9" { print NF }' "$VM_STATE_DIR/block-cache/v2-compact/records.tsv")" "wildcard cache was not compacted per pair"
vm_pbr_generate_block
assert_eq "$after_wildcard" "$(wc -l < "$VM_TEST_NSLOOKUP_TRACE" | tr -d ' ')" "fresh wildcard slots were queried again"

compact_dir="$VM_STATE_DIR/block-cache/v2-compact"
[ -s "$compact_dir/active.meta" ] || fail "active manifest generation was not published"
[ -s "$compact_dir/records-ip-generation" ] || fail "record IP generation was not published"
record_generation="$(sed -n '1p' "$compact_dir/records-ip-generation")"
aggregate_generation="$(sed -n '1p' "$compact_dir/aggregate.meta")"
case "$aggregate_generation" in
    *"|$record_generation") ;;
    *) fail "aggregate cache generation does not match records" ;;
esac
stale_publish="$(find "$compact_dir" -type f \( -name '*.next.*' -o -name '*.merge.*' \) -print | head -n1)"
[ -z "$stale_publish" ] || fail "atomic cache publish left a temporary file: $stale_publish"

echo "block resolver pair-cache/LKG: ok"
