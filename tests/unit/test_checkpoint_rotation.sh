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
case "${1:-}" in
    export)
        printf "package '%s'\n" "${2:-unknown}"
        ;;
    *)
        exit 64
        ;;
esac
EOF
cat > "$tmp_dir/bin/nft" <<'EOF'
#!/bin/sh
printf '%s\n' 'table inet test {}'
EOF
chmod 0755 "$tmp_dir/bin/uci" "$tmp_dir/bin/nft"

VM_STATE_DIR="$tmp_dir/state"
VM_AUDIT_LOG="$tmp_dir/audit.log"
VM_LIB_DIR="$REPO_ROOT/src/lib/vpn-manager"
PATH="$tmp_dir/bin:$PATH"
export VM_STATE_DIR VM_AUDIT_LOG VM_LIB_DIR PATH

. "$REPO_ROOT/src/lib/vpn-manager/uci.sh"

first="$(vm_checkpoint_create)"
vm_checkpoint_valid "$first" || fail "first checkpoint is invalid"
vm_checkpoint_prepare_rollback
assert_eq "$first" "$(cat "$VM_STATE_DIR/rollback.checkpoint")" "rollback pointer did not capture last applied state"

# The production reconcile creates one checkpoint per process. Sleeping here
# makes the unit test's two same-PID calls exercise distinct timestamp bases.
sleep 1
second="$(vm_checkpoint_create)"
vm_checkpoint_valid "$second" || fail "second checkpoint is invalid"
assert_eq "$second" "$(cat "$VM_STATE_DIR/latest.checkpoint")" "latest pointer was not published atomically"
assert_eq "$first" "$(cat "$VM_STATE_DIR/previous.checkpoint")" "previous pointer did not retain the prior applied state"
assert_eq "$first" "$(vm_checkpoint_last)" "rollback last must prefer the prepared last-known-good checkpoint"

case "$second" in
    "$VM_STATE_DIR"/checkpoint-*-*) ;;
    *) fail "checkpoint base is missing its PID collision suffix" ;;
esac

echo "checkpoint rotation/rollback pointer: ok"
