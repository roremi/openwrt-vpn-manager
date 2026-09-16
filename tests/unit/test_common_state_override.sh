#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
. "$REPO_ROOT/tests/lib/testlib.sh"

tmp_dir="$(make_test_tmpdir)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

expected_state="$tmp_dir/custom-state"
VM_STATE_DIR="$expected_state"
VM_AUDIT_LOG="$tmp_dir/audit.log"
install_fake_openwrt_tools "$tmp_dir/bin"
PATH="$tmp_dir/bin:$PATH"
export VM_STATE_DIR VM_AUDIT_LOG PATH

. "${VM_COMMON_SH:-$REPO_ROOT/src/lib/vpn-manager/common.sh}"

assert_state_override "$expected_state"
vm_init_dirs
[ -d "$expected_state" ] || fail "vm_init_dirs did not create the overridden state directory"

echo "common state override: ok"
