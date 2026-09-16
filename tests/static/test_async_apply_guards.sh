#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
. "$REPO_ROOT/tests/lib/testlib.sh"

rpc_file="$REPO_ROOT/src/rpcd/vpn-manager.sh"
dashboard_file="$REPO_ROOT/src/www/vpnmanager-dashboard.html"

if grep -n 'reconcile\.sh' "$rpc_file" >&2; then
    fail "RPC mutations must enqueue work and must not invoke reconcile.sh directly"
fi

if grep -n 'block-all-\|block-apply\.\|\.next\.\*' "$REPO_ROOT/scripts/vpn-reconcile.sh" >&2; then
    fail "core reconcile must not delete temporary files owned by independent workers"
fi

if grep -n 'applyIfNeeded' "$dashboard_file" >&2; then
    fail "CRUD handlers must not request a second apply after the RPC already enqueued it"
fi

manual_apply_calls="$(grep -c "apiPost('/apply'" "$dashboard_file" || true)"
assert_eq "1" "$manual_apply_calls" "dashboard must keep exactly one explicit /apply call for the manual Apply button"

echo "async apply static guards: ok"
