#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
. "$REPO_ROOT/tests/lib/testlib.sh"

tmp_dir="$(make_test_tmpdir)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

install_fake_openwrt_tools "$tmp_dir/bin"
expected_state="$tmp_dir/state"
VM_STATE_DIR="$expected_state"
VM_AUDIT_LOG="$tmp_dir/audit.log"
PATH="$tmp_dir/bin:$PATH"
export VM_STATE_DIR VM_AUDIT_LOG PATH

. "${VM_COMMON_SH:-$REPO_ROOT/src/lib/vpn-manager/common.sh}"
assert_state_override "$expected_state"

vm_block_request "domain added"
vm_block_request "domain toggled"
vm_block_request "domain deleted"
assert_eq "block" "$(vm_block_take)" "block requests must coalesce into one block job"

extra_job="$(vm_block_take 2>/dev/null || true)"
assert_eq "" "$extra_job" "coalesced block work must be taken only once"

vm_block_request "later domain batch"
assert_eq "block" "$(vm_block_take)" "a later block batch was lost"

echo "common block queue: ok"
