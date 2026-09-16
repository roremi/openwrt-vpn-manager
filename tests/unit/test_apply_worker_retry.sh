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
    -n)
        [ "${2:-}" != "${VM_TEST_BUSY_LOCK:-}" ] || exit 1
        /bin/mkdir "${2}.held" 2>/dev/null
        ;;
    -u)
        rmdir "${2}.held" 2>/dev/null || true
        ;;
    *)
        /bin/mkdir "${1}.held" 2>/dev/null
        ;;
esac
EOF

cat > "$tmp_dir/reconcile.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$VM_TEST_RECONCILE_TRACE"
[ ! -d "$VM_STATE_DIR/apply.lock.held" ] || exit 98
[ ! -d "$VM_STATE_DIR/config.lock.held" ] || exit 99
if [ -n "${VM_TEST_INJECT_JOB:-}" ]; then
    . "$VM_COMMON_SH"
    vm_apply_request "$VM_TEST_INJECT_JOB" injected
fi
exit "${VM_TEST_RECONCILE_RC:-0}"
EOF
cat > "$tmp_dir/rollback.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$VM_TEST_ROLLBACK_TRACE"
exit "${VM_TEST_ROLLBACK_RC:-0}"
EOF
chmod 0755 "$tmp_dir/bin/lock" "$tmp_dir/reconcile.sh" "$tmp_dir/rollback.sh"

VM_STATE_DIR="$tmp_dir/state"
VM_AUDIT_LOG="$tmp_dir/audit.log"
VM_COMMON_SH="$REPO_ROOT/src/lib/vpn-manager/common.sh"
VM_RECONCILE_SH="$tmp_dir/reconcile.sh"
VM_ROLLBACK_SH="$tmp_dir/rollback.sh"
VM_WORKER_RETRY_DELAY=0
VM_WORKER_SOURCE_ONLY=1
VM_TEST_LOCK_TRACE="$tmp_dir/lock.trace"
VM_TEST_RECONCILE_TRACE="$tmp_dir/reconcile.trace"
VM_TEST_ROLLBACK_TRACE="$tmp_dir/rollback.trace"
PATH="$tmp_dir/bin:$PATH"
export VM_STATE_DIR VM_AUDIT_LOG VM_COMMON_SH VM_RECONCILE_SH VM_ROLLBACK_SH
export VM_WORKER_RETRY_DELAY VM_WORKER_SOURCE_ONLY VM_TEST_LOCK_TRACE
export VM_TEST_RECONCILE_TRACE VM_TEST_ROLLBACK_TRACE PATH

. "$REPO_ROOT/scripts/vpn-apply-worker.sh"

VM_TEST_RECONCILE_RC=75
VM_TEST_INJECT_JOB=full
export VM_TEST_RECONCILE_RC VM_TEST_INJECT_JOB
vm_apply_request pbr original
if vm_apply_worker_once 2>/dev/null; then
    fail "busy reconcile unexpectedly succeeded"
else
    rc=$?
fi
assert_eq "75" "$rc" "busy reconcile status was not preserved"
assert_eq "full" "$(vm_apply_take)" "retry did not coalesce with stronger concurrent job"

VM_TEST_RECONCILE_RC=42
VM_TEST_INJECT_JOB=""
export VM_TEST_RECONCILE_RC VM_TEST_INJECT_JOB
vm_apply_request full original
if vm_apply_worker_once; then
    fail "failed reconcile unexpectedly succeeded"
else
    rc=$?
fi
assert_eq "42" "$rc" "failed reconcile status was not preserved"
assert_eq "full" "$(vm_apply_take)" "failed full job was lost instead of requeued"

# A busy apply lock must prevent every network reload/reconcile, retain the
# network job, and avoid waiting in an OpenWrt lock process.
: > "$VM_TEST_LOCK_TRACE"
: > "$VM_TEST_RECONCILE_TRACE"
VM_TEST_RELOAD_TRACE="$tmp_dir/reload.trace"
VM_TEST_BUSY_LOCK="$VM_STATE_DIR/apply.lock"
VM_TEST_RECONCILE_RC=0
export VM_TEST_RELOAD_TRACE VM_TEST_BUSY_LOCK VM_TEST_RECONCILE_RC
vm_apply_network_reload() { printf '%s\n' reload >> "$VM_TEST_RELOAD_TRACE"; }
vm_apply_request network original
if vm_apply_worker_once 2>/dev/null; then
    fail "network job unexpectedly passed a busy apply lock"
else
    rc=$?
fi
assert_eq "75" "$rc" "busy network lock did not return retry status"
[ ! -s "$VM_TEST_RELOAD_TRACE" ] || fail "network daemons reloaded while apply lock was busy"
[ ! -s "$VM_TEST_RECONCILE_TRACE" ] || fail "reconcile ran while network prepare was busy"
assert_eq "network" "$(vm_apply_take)" "busy network job was lost"

# With free locks, network preparation must acquire apply then config, release
# config then apply, and only then call reconcile in full mode.
: > "$VM_TEST_LOCK_TRACE"
: > "$VM_TEST_RECONCILE_TRACE"
: > "$VM_TEST_RELOAD_TRACE"
VM_TEST_BUSY_LOCK=""
export VM_TEST_BUSY_LOCK
vm_apply_request network original
vm_apply_worker_once || fail "network job failed with free locks"
assert_eq "reload" "$(cat "$VM_TEST_RELOAD_TRACE")" "network daemons were not reloaded once"
assert_eq "full" "$(cat "$VM_TEST_RECONCILE_TRACE")" "network job did not reconcile in full mode"
expected_locks="-n $VM_STATE_DIR/apply.lock
-n $VM_STATE_DIR/config.lock
-u $VM_STATE_DIR/config.lock
-u $VM_STATE_DIR/apply.lock"
dataplane_locks="$(grep -E '/(apply|config)\.lock$' "$VM_TEST_LOCK_TRACE" || true)"
assert_eq "$expected_locks" "$dataplane_locks" "network lock order/release was incorrect"

# A reload failure after configuration was committed must restore the exact
# pre-change checkpoint instead of retrying the unsafe network job forever.
: > "$VM_TEST_ROLLBACK_TRACE"
: > "$VM_TEST_RECONCILE_TRACE"
printf '%s\n' "$tmp_dir/checkpoint-before-wifi" > "$VM_NETWORK_CHANGE_CHECKPOINT"
vm_apply_network_reload() { return 41; }
vm_apply_request network unsafe-change
if vm_apply_worker_once 2>/dev/null; then
    fail "unsafe network reload unexpectedly succeeded"
else
    rc=$?
fi
assert_eq "41" "$rc" "network reload failure status was not preserved"
assert_eq "$tmp_dir/checkpoint-before-wifi" "$(cat "$VM_TEST_ROLLBACK_TRACE")" "network reload failure did not roll back its checkpoint"
[ ! -e "$VM_NETWORK_CHANGE_CHECKPOINT" ] || fail "rollback marker survived successful automatic rollback"
[ ! -s "$VM_TEST_RECONCILE_TRACE" ] || fail "reconcile ran after an unsafe network reload"
[ ! -s "$VM_APPLY_QUEUE" ] || fail "unsafe network job was requeued after rollback"

# Reconcile can invalidate a network that was healthy immediately after reload.
# Recheck the dedicated interfaces before disarming the rollback checkpoint.
: > "$VM_TEST_ROLLBACK_TRACE"
: > "$VM_TEST_RECONCILE_TRACE"
printf '%s\n' "$tmp_dir/checkpoint-before-reconcile" > "$VM_NETWORK_CHANGE_CHECKPOINT"
vm_apply_network_reload() { return 0; }
vm_apply_dedicated_networks_ready() { return 1; }
VM_TEST_RECONCILE_RC=0
export VM_TEST_RECONCILE_RC
vm_apply_request network orphaned-after-reconcile
if vm_apply_worker_once 2>/dev/null; then
    fail "post-reconcile network loss unexpectedly succeeded"
else
    rc=$?
fi
assert_eq "43" "$rc" "post-reconcile network check status was not preserved"
assert_eq "full" "$(cat "$VM_TEST_RECONCILE_TRACE")" "network reconcile did not run before the final safety check"
assert_eq "$tmp_dir/checkpoint-before-reconcile" "$(cat "$VM_TEST_ROLLBACK_TRACE")" "post-reconcile network loss was not rolled back"
[ ! -e "$VM_NETWORK_CHANGE_CHECKPOINT" ] || fail "post-reconcile rollback marker was not cleared"

echo "apply worker retry/coalescing: ok"
