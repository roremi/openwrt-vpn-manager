#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$TEST_DIR/../lib/testlib.sh"

ROOT_DIR="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
TMP_ROOT="$(make_test_tmpdir)"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

LIB_DIR="$TMP_ROOT/lib"
ORDER_LOG="$TMP_ROOT/order.log"
mkdir -p "$LIB_DIR"

cat > "$LIB_DIR/common.sh" <<'EOF'
#!/bin/sh
VM_CFG=vpn-manager
VM_STATE_DIR="${VM_STATE_DIR:?}"
order() { printf '%s\n' "$1" >> "$ORDER_LOG"; }
vm_lock() { order lock; }
vm_unlock() { order unlock; }
vm_config_lock() { order config-lock; }
vm_config_unlock() { order config-unlock; }
vm_require_cmd() { :; }
vm_fail() { printf '%s\n' "$*" >&2; return 1; }
vm_log() { :; }
EOF

cat > "$LIB_DIR/uci.sh" <<'EOF'
#!/bin/sh
vm_checkpoint_prepare_rollback() { order checkpoint-prepare; }
vm_reconcile_manifest_prepare() { order "manifest-prepare:$1"; }
vm_reconcile_manifest_validate_profiles() { order validate; }
vm_wireguard_sync_all() { order sync; }
vm_commit_all() { order commit; }
vm_wireguard_runtime_up_all() { order runtime; }
vm_checkpoint_create() { order checkpoint-create; printf 'checkpoint\n'; }
vm_reconcile_manifest_cleanup() { order manifest-cleanup; }
EOF

cat > "$LIB_DIR/pbr.sh" <<'EOF'
#!/bin/sh
vm_pbr_generate_nft() { order generate; }
vm_pbr_apply_rules() { order apply; }
EOF

export VM_LIB_DIR="$LIB_DIR"
export VM_STATE_DIR="$TMP_ROOT/state"
export ORDER_LOG

: > "$ORDER_LOG"
sh "$ROOT_DIR/scripts/vpn-reconcile.sh" full
full_order="$(cat "$ORDER_LOG")"
expected_full='lock
config-lock
checkpoint-prepare
manifest-prepare:1
validate
generate
sync
commit
runtime
apply
checkpoint-create
manifest-cleanup
config-unlock
unlock'
assert_eq "$expected_full" "$full_order" "full reconcile transaction order is unsafe"

: > "$ORDER_LOG"
sh "$ROOT_DIR/scripts/vpn-reconcile.sh" pbr
pbr_order="$(cat "$ORDER_LOG")"
expected_pbr='lock
config-lock
checkpoint-prepare
manifest-prepare:1
generate
apply
checkpoint-create
manifest-cleanup
config-unlock
unlock'
assert_eq "$expected_pbr" "$pbr_order" "PBR reconcile transaction order is wrong"

if grep -Eq 'uci[[:space:]]+-q[[:space:]]+show' "$ROOT_DIR/scripts/vpn-reconcile.sh"; then
    fail "reconcile performs an extra UCI snapshot before manifest preparation"
fi

echo "reconcile ordering: ok"
