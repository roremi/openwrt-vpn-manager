#!/bin/sh
set -eu

VM_LIB_DIR="${VM_LIB_DIR:-/usr/libexec/vpn-manager}"
. "$VM_LIB_DIR/common.sh"
. "$VM_LIB_DIR/uci.sh"
. "$VM_LIB_DIR/pbr.sh"

mode="${1:-full}"
case "$mode" in
    full|pbr) : ;;
    *) vm_fail "unsupported reconcile mode: $mode" ;;
esac

apply_locked=0
config_locked=0
cleanup() {
    vm_reconcile_manifest_cleanup 2>/dev/null || true
    [ "$config_locked" = "0" ] || vm_config_unlock
    [ "$apply_locked" = "0" ] || vm_unlock
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

vm_lock || exit 75
apply_locked=1
vm_config_lock || exit 75
config_locked=1

vm_require_cmd uci
vm_require_cmd nft
vm_require_cmd ip

vm_checkpoint_prepare_rollback || vm_fail "unable to prepare rollback checkpoint"
vm_reconcile_manifest_prepare 1 || vm_fail "unable to prepare reconcile manifest"

if [ "$mode" = "full" ]; then
    vm_reconcile_manifest_validate_profiles || vm_fail "invalid profile configuration"

    vm_pbr_generate_nft
    vm_wireguard_sync_all
    vm_commit_all
    vm_wireguard_runtime_up_all
    vm_pbr_apply_rules

    checkpoint="$(vm_checkpoint_create)"
    vm_log "info" "reconcile complete mode=full checkpoint=$checkpoint"
else
    vm_pbr_generate_nft
    vm_pbr_apply_rules
    checkpoint="$(vm_checkpoint_create)"
    vm_log "info" "reconcile complete mode=pbr checkpoint=$checkpoint"
fi
