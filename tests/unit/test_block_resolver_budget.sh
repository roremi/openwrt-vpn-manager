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
    "-q get vpn-manager.blk_budget.enabled") echo 1 ;;
    "-q get vpn-manager.blk_budget.domain") echo budget.example ;;
    "-q get vpn-manager.blk_budget.mode") echo exact ;;
    *) exit 1 ;;
esac
EOF

cat > "$tmp_dir/bin/nslookup" <<'EOF'
#!/bin/sh
printf '%s|%s\n' "$1" "$2" >> "$VM_TEST_NSLOOKUP_TRACE"
exec sleep 10
EOF
chmod 0755 "$tmp_dir/bin/uci" "$tmp_dir/bin/nslookup"

VM_STATE_DIR="$tmp_dir/state"
VM_AUDIT_LOG="$tmp_dir/audit.log"
VM_LIB_DIR="$REPO_ROOT/src/lib/vpn-manager"
VM_BLOCK_QUERY_TIMEOUT=5
VM_BLOCK_RESOLVE_WORKERS=2
VM_BLOCK_REFRESH_BUDGET=1
VM_BLOCK_FAILURE_RETRY=60
VM_BLOCK_CACHE_TTL=3600
VM_TEST_NSLOOKUP_TRACE="$tmp_dir/nslookup.trace"
PATH="$tmp_dir/bin:$PATH"
export VM_STATE_DIR VM_AUDIT_LOG VM_LIB_DIR VM_BLOCK_QUERY_TIMEOUT
export VM_BLOCK_RESOLVE_WORKERS VM_BLOCK_REFRESH_BUDGET VM_BLOCK_FAILURE_RETRY
export VM_BLOCK_CACHE_TTL VM_TEST_NSLOOKUP_TRACE PATH

. "$VM_LIB_DIR/pbr.sh"

vm_pbr_block_snapshot_config() {
    : > "$1"
    printf '1.0.0.1\n1.0.0.2\n1.0.0.3\n1.0.0.4\n1.0.0.5\n' > "$2"
    printf 'budget.example|exact\n' > "$3"
}

started="$(date +%s)"
vm_pbr_generate_block
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -le 3 ] || fail "refresh exceeded hard DNS budget (elapsed=${elapsed}s)"
assert_eq "2" "$(wc -l < "$VM_TEST_NSLOOKUP_TRACE" | tr -d ' ')" "first fixed wave exceeded worker limit"
[ -s "$VM_BLOCK_QUEUE" ] || fail "unfinished resolver backlog was not requeued"

# The persistent cursor plus per-record cooldown must move on to new resolver
# pairs instead of retrying the first timed-out wave immediately.
vm_pbr_generate_block
assert_eq "4" "$(wc -l < "$VM_TEST_NSLOOKUP_TRACE" | tr -d ' ')" "second refresh did not advance fairly"
assert_eq "4" "$(cut -d '|' -f2 "$VM_TEST_NSLOOKUP_TRACE" | sort -u | wc -l | tr -d ' ')" "resolver cursor retried an earlier pair"

vm_pbr_generate_block
assert_eq "5" "$(wc -l < "$VM_TEST_NSLOOKUP_TRACE" | tr -d ' ')" "final backlog item was not processed"
assert_eq "5" "$(cut -d '|' -f2 "$VM_TEST_NSLOOKUP_TRACE" | sort -u | wc -l | tr -d ' ')" "not every resolver received a fair attempt"

echo "block resolver budget/cursor: ok"
