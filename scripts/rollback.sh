#!/bin/sh
set -eu

. /usr/libexec/vpn-manager/common.sh
. /usr/libexec/vpn-manager/uci.sh

target="${1:-last}"

apply_locked=0
config_locked=0
cleanup() {
    [ "$config_locked" = "0" ] || vm_config_unlock
    [ "$apply_locked" = "0" ] || vm_unlock
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

vm_try_lock || exit 75
apply_locked=1
vm_config_lock || exit 75
config_locked=1

if [ "$target" = "last" ]; then
    vm_checkpoint_rollback
else
    vm_checkpoint_rollback "$target"
fi

# Let the single workers consume the follow-up jobs only after the rollback's
# runtime reload and both locks are complete.
vm_config_unlock
config_locked=0
vm_unlock
apply_locked=0

vm_apply_request full rollback || vm_fail "rollback restored config but could not queue core apply"
vm_block_request rollback || vm_fail "rollback restored config but could not queue domain refresh"
vm_log "warn" "manual rollback executed target=$target"
