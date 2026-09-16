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
VM_COMMON_SH="${VM_COMMON_SH:-$REPO_ROOT/src/lib/vpn-manager/common.sh}"
export VM_STATE_DIR VM_AUDIT_LOG VM_COMMON_SH PATH

. "$VM_COMMON_SH"
assert_state_override "$expected_state"

vm_apply_request pbr "policy changed"
vm_apply_request full "profile changed"
assert_eq "full" "$(vm_apply_take)" "full must coalesce over pbr"

vm_apply_request pbr "policy changed again"
vm_apply_request full "another profile changed"
vm_apply_request network "wifi changed"
assert_eq "network" "$(vm_apply_take)" "network must coalesce over full and pbr"

extra_job="$(vm_apply_take 2>/dev/null || true)"
assert_eq "" "$extra_job" "one coalesced batch must be taken only once"

# Start a second writer while take() still owns the short queue lock. The
# writer must wait until the batch move is complete, then append to the new
# public queue instead of the private batch inode.
vm_apply_request network "batch being taken"
VM_TEST_LATE_MARKER="$tmp_dir/later-request.injected"
VM_TEST_LATE_STARTED="$tmp_dir/later-request.started"
export VM_APPLY_QUEUE VM_TEST_LATE_MARKER VM_TEST_LATE_STARTED
cat > "$tmp_dir/bin/mv" <<'EOF'
#!/bin/sh
mv_rc=0
/bin/mv "$@" || mv_rc=$?
if [ "$mv_rc" -eq 0 ] && [ "${1:-}" = "$VM_APPLY_QUEUE" ] && [ ! -e "$VM_TEST_LATE_MARKER" ]; then
    (
        : > "$VM_TEST_LATE_STARTED"
        . "$VM_COMMON_SH"
        vm_apply_request pbr "later batch"
        : > "$VM_TEST_LATE_MARKER"
    ) &
fi
exit "$mv_rc"
EOF
chmod 0755 "$tmp_dir/bin/mv"
hash -r 2>/dev/null || true

assert_eq "network" "$(vm_apply_take)" "the batch selected before the injected request changed"
[ -f "$VM_TEST_LATE_STARTED" ] || fail "the concurrent writer did not start"
attempt=0
while [ ! -f "$VM_TEST_LATE_MARKER" ] && [ "$attempt" -lt 3 ]; do
    sleep 1
    attempt=$((attempt + 1))
done
[ -f "$VM_TEST_LATE_MARKER" ] || fail "the atomic-move race injection did not run"
assert_eq "pbr" "$(vm_apply_take)" "a request appended after the atomic move was lost"

echo "common apply queue: ok"
