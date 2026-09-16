#!/bin/sh
set -eu

. /usr/libexec/vpn-manager/common.sh
. /usr/libexec/vpn-manager/uci.sh
. /usr/libexec/vpn-manager/pbr.sh

if [ "${1:-}" != "--run" ]; then
    vm_block_request "${1:-manual}"
    exit 0
fi

# The block table is independent from the core VPN tables, but still has one
# single writer. A busy worker fails immediately instead of adding a process
# that waits behind a long DNS refresh.
vm_init_dirs
lock -n "$VM_STATE_DIR/block.lock" 2>/dev/null || exit 75
trap 'lock -u "$VM_STATE_DIR/block.lock" 2>/dev/null || true; rm -rf "$VM_STATE_DIR/block-build.$$"; rm -f "$VM_STATE_DIR/block-apply.$$" "$VM_NFT_BLOCK_FILE.$$"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

vm_require_cmd uci
vm_require_cmd nft
vm_require_cmd sha256sum
uci -q show "$VM_CFG" >/dev/null 2>&1 || vm_fail "unable to read $VM_CFG configuration"

vm_pbr_refresh_block
