#!/bin/sh
set -eu

# This test is intended to run on OpenWrt target with vpn-manager installed.

/usr/libexec/vpn-manager/reconcile.sh
/usr/libexec/vpn-manager/healthcheck.sh
/usr/libexec/vpn-manager/watchdog.sh

test -f /tmp/vpn-manager/latest.checkpoint

echo "integration reconcile flow: ok"
