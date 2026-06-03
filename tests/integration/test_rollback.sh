#!/bin/sh
set -eu

/usr/libexec/vpn-manager/reconcile.sh
/usr/libexec/vpn-manager/rollback.sh last

echo "integration rollback: ok"
