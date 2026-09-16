#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
. "$REPO_ROOT/tests/lib/testlib.sh"

tmp_dir="$(make_test_tmpdir)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

install_fake_openwrt_tools "$tmp_dir/bin"
expected_state="$tmp_dir/state"
VM_STATE_DIR="$expected_state"
VM_AUDIT_LOG="$tmp_dir/audit.log"
PATH="$tmp_dir/bin:$PATH"
export VM_STATE_DIR VM_AUDIT_LOG PATH

. "${VM_COMMON_SH:-$REPO_ROOT/src/lib/vpn-manager/common.sh}"
assert_state_override "$expected_state"

vm_apply_request full "profile saved"
vm_block_request "domain saved"
status_json="$(vm_apply_status_json)"

if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$status_json" | jq -e '
        .ok == true and
        (.core | has("job") and has("state") and has("updated_at") and has("detail")) and
        (.block | has("job") and has("state") and has("updated_at") and has("detail")) and
        .core.job == "full" and .core.detail == "profile saved" and
        .block.job == "block" and .block.detail == "domain saved" and
        (.pending | type == "boolean")
    ' >/dev/null || fail "vm_apply_status_json returned invalid JSON or omitted required fields"
else
    compact_json="$(printf '%s' "$status_json" | tr -d ' \t\r\n')"
    case "$compact_json" in
        \{*\}) ;;
        *) fail "status output is not a JSON object" ;;
    esac
    assert_contains "$compact_json" '"ok":true' "status is missing ok=true"
    assert_contains "$compact_json" '"core":{' "status is missing core object"
    assert_contains "$compact_json" '"block":{' "status is missing block object"
    assert_contains "$compact_json" '"job":' "status is missing job"
    assert_contains "$compact_json" '"state":' "status is missing state"
    assert_contains "$compact_json" '"updated_at":' "status is missing updated_at"
    assert_contains "$compact_json" '"detail":' "status is missing detail"
    assert_contains "$compact_json" '"job":"full"' "core status did not retain the requested job"
    assert_contains "$compact_json" '"detail":"profilesaved"' "core status did not retain the request reason"
    assert_contains "$compact_json" '"job":"block"' "block status did not retain its job"
    assert_contains "$compact_json" '"detail":"domainsaved"' "block status did not retain the request reason"
    case "$compact_json" in
        *'"pending":true'*|*'"pending":false'*) ;;
        *) fail "status is missing boolean pending" ;;
    esac
fi

echo "common apply status JSON: ok"
