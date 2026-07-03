#!/bin/sh
set -eu

. /usr/libexec/vpn-manager/common.sh
. /usr/libexec/vpn-manager/uci.sh
. /usr/libexec/vpn-manager/pbr.sh

# Lightweight periodic refresh of the domain-block nftables set so DNS
# rotations for blocked domains are re-resolved without a full reconcile.
vm_pbr_refresh_block
