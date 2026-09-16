#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
. "$REPO_ROOT/tests/lib/testlib.sh"

tmp_dir="$(make_test_tmpdir)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
install_fake_openwrt_tools "$tmp_dir/bin"

cat > "$tmp_dir/bin/lock" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$VM_TEST_LOCK_TRACE"
case "${1:-}" in
    -n) exit 1 ;;
    -u) exit 0 ;;
    *) exit 64 ;;
esac
EOF

cat > "$tmp_dir/bin/sleep" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$VM_TEST_SLEEP_TRACE"
exit 0
EOF

cat > "$tmp_dir/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod 0755 "$tmp_dir/bin/lock" "$tmp_dir/bin/sleep" "$tmp_dir/bin/logger"

expected_state="$tmp_dir/state"
VM_STATE_DIR="$expected_state"
VM_AUDIT_LOG="$tmp_dir/audit.log"
VM_TEST_LOCK_TRACE="$tmp_dir/lock.trace"
VM_TEST_SLEEP_TRACE="$tmp_dir/sleep.trace"
PATH="$tmp_dir/bin:$PATH"
export VM_STATE_DIR VM_AUDIT_LOG VM_TEST_LOCK_TRACE VM_TEST_SLEEP_TRACE PATH

. "${VM_COMMON_SH:-$REPO_ROOT/src/lib/vpn-manager/common.sh}"
assert_state_override "$expected_state"

if vm_lock >/dev/null 2>&1; then
    fail "vm_lock unexpectedly acquired a busy lock"
fi

lock_calls="$(wc -l < "$VM_TEST_LOCK_TRACE" | tr -d ' ')"
assert_eq "1" "$lock_calls" "vm_lock must attempt a busy lock only once"
assert_eq "-n $expected_state/apply.lock" "$(sed -n '1p' "$VM_TEST_LOCK_TRACE")" "vm_lock must use OpenWrt lock -n"
[ ! -s "$VM_TEST_SLEEP_TRACE" ] || fail "vm_lock slept while the lock was busy"

echo "common non-blocking lock: ok"
