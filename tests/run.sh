#!/bin/sh
set -u

TESTS_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

run_count=0
pass_count=0
fail_count=0

run_group() {
    for test_file in "$TESTS_DIR/$1"/test_*.sh; do
        [ -f "$test_file" ] || continue
        run_count=$((run_count + 1))
        printf 'TEST %s\n' "${test_file#"$TESTS_DIR/"}"
        if sh "$test_file"; then
            pass_count=$((pass_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done
}

case "${1:-}" in
    '') run_integration=0 ;;
    --integration) run_integration=1 ;;
    -h|--help)
        echo "usage: $0 [--integration]"
        echo "integration tests run against an installed OpenWrt target and are skipped by default"
        exit 0
        ;;
    *)
        echo "unknown option: $1" >&2
        exit 2
        ;;
esac

run_group unit
run_group static
[ "$run_integration" -eq 0 ] || run_group integration

printf 'RESULT total=%s passed=%s failed=%s\n' "$run_count" "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
