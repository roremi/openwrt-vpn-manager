#!/bin/sh
set -eu

. /usr/libexec/vpn-manager/common.sh
. /usr/libexec/vpn-manager/uci.sh

target="${1:-last}"

if [ "$target" = "last" ]; then
    vm_checkpoint_rollback
else
    vm_checkpoint_rollback "$target"
fi

vm_log "warn" "manual rollback executed target=$target"
