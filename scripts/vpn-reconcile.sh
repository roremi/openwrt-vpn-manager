#!/bin/sh
set -eu

. /usr/libexec/vpn-manager/common.sh
. /usr/libexec/vpn-manager/uci.sh
. /usr/libexec/vpn-manager/pbr.sh

vm_lock
trap vm_unlock EXIT

vm_require_cmd uci
vm_require_cmd nft
vm_require_cmd ip

checkpoint="$(vm_checkpoint_create)"

for sec in $(vm_profile_list); do
    [ "$(uci -q get vpn-manager.$sec.enabled)" = "1" ] || continue
    vm_pbr_validate_profile "$sec"
done

vm_pbr_generate_nft
vm_wireguard_sync_all
vm_wireguard_runtime_up_all
vm_commit_all
vm_pbr_apply_rules

vm_log "info" "reconcile complete checkpoint=$checkpoint"
