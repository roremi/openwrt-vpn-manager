#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
. "$REPO_ROOT/tests/lib/testlib.sh"

tmp_dir="$(make_test_tmpdir)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
install_fake_openwrt_tools "$tmp_dir/bin"

cat > "$tmp_dir/block-refresh.sh" <<'EOF'
#!/bin/sh
if [ "${VM_TEST_INJECT_BLOCK:-0}" = "1" ]; then
    . "$VM_COMMON_SH"
    vm_block_request injected
fi
exit "${VM_TEST_BLOCK_RC:-0}"
EOF
chmod 0755 "$tmp_dir/block-refresh.sh"

VM_STATE_DIR="$tmp_dir/state"
VM_AUDIT_LOG="$tmp_dir/audit.log"
VM_COMMON_SH="$REPO_ROOT/src/lib/vpn-manager/common.sh"
VM_BLOCK_REFRESH_SH="$tmp_dir/block-refresh.sh"
VM_WORKER_RETRY_DELAY=0
VM_WORKER_SOURCE_ONLY=1
PATH="$tmp_dir/bin:$PATH"
export VM_STATE_DIR VM_AUDIT_LOG VM_COMMON_SH VM_BLOCK_REFRESH_SH
export VM_WORKER_RETRY_DELAY VM_WORKER_SOURCE_ONLY PATH

. "$REPO_ROOT/scripts/vpn-block-worker.sh"

VM_TEST_BLOCK_RC=75
VM_TEST_INJECT_BLOCK=1
export VM_TEST_BLOCK_RC VM_TEST_INJECT_BLOCK
vm_block_request original
if vm_block_worker_once; then
    fail "busy block refresh unexpectedly succeeded"
else
    rc=$?
fi
assert_eq "75" "$rc" "busy block status was not preserved"
assert_eq "block" "$(vm_block_take)" "busy block job was lost instead of coalesced"
[ -z "$(vm_block_take 2>/dev/null || true)" ] || fail "block retry created duplicate batches"

VM_TEST_BLOCK_RC=42
VM_TEST_INJECT_BLOCK=0
export VM_TEST_BLOCK_RC VM_TEST_INJECT_BLOCK
vm_block_request original
if vm_block_worker_once; then
    fail "failed block refresh unexpectedly succeeded"
else
    rc=$?
fi
assert_eq "42" "$rc" "failed block status was not preserved"
assert_eq "block" "$(vm_block_take)" "failed block job was lost instead of requeued"

echo "block worker retry/coalescing: ok"
