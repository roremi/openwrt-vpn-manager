#!/bin/sh

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    assert_expected="$1"
    assert_actual="$2"
    assert_message="${3:-values differ}"
    [ "$assert_expected" = "$assert_actual" ] ||
        fail "$assert_message (expected='$assert_expected' actual='$assert_actual')"
}

assert_contains() {
    assert_haystack="$1"
    assert_needle="$2"
    assert_message="${3:-missing expected text}"
    case "$assert_haystack" in
        *"$assert_needle"*) ;;
        *) fail "$assert_message (needle='$assert_needle')" ;;
    esac
}

make_test_tmpdir() {
    test_tmp_base="${TMPDIR:-/tmp}/vpn-manager-test.XXXXXX"
    mktemp -d "$test_tmp_base" || fail "unable to create temporary directory"
}

install_fake_openwrt_tools() {
    fake_bin="$1"
    mkdir -p "$fake_bin"

    cat > "$fake_bin/mkdir" <<'EOF'
#!/bin/sh
# common.sh creates the production audit directory as well as VM_STATE_DIR.
# Unit tests redirect all actual state and deliberately ignore that one
# production-only path so the suite also runs as an unprivileged CI user.
for mkdir_arg in "$@"; do
    case "$mkdir_arg" in
        -*) ;;
        /var/log/vpn-manager) ;;
        *) /bin/mkdir -p "$mkdir_arg" ;;
    esac
done
EOF

    cat > "$fake_bin/lock" <<'EOF'
#!/bin/sh
case "${1:-}" in
    /*)
        lock_path="$1"
        while ! /bin/mkdir "${lock_path}.held" 2>/dev/null; do
            sleep 1
        done
        ;;
    -n)
        lock_path="$2"
        /bin/mkdir "${lock_path}.held" 2>/dev/null
        ;;
    -u)
        rmdir "${2}.held" 2>/dev/null || true
        ;;
    *)
        # OpenWrt `lock FILE` waits and acquires; queue tests are single
        # process, so the mkdir model only needs to represent acquisition.
        /bin/mkdir "${1}.held" 2>/dev/null
        ;;
esac
EOF

    cat > "$fake_bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

    chmod 0755 "$fake_bin/mkdir" "$fake_bin/lock" "$fake_bin/logger"
}

assert_state_override() {
    override_expected="$1"
    assert_eq "$override_expected" "$VM_STATE_DIR" "common.sh must preserve VM_STATE_DIR supplied by the caller"
    case "$VM_STATE_DIR" in
        "$override_expected") ;;
        *) fail "refusing to run queue test outside its temporary state directory" ;;
    esac
}
