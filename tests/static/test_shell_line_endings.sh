#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
. "$REPO_ROOT/tests/lib/testlib.sh"

grep -Fqx '*.sh text eol=lf' "$REPO_ROOT/.gitattributes" ||
    fail ".gitattributes must force LF for every *.sh file"
grep -Fqx 'src/init.d/* text eol=lf' "$REPO_ROOT/.gitattributes" ||
    fail ".gitattributes must force LF for OpenWrt init scripts"

tmp_dir="$(make_test_tmpdir)"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
bad_files="$tmp_dir/crlf-files"
: > "$bad_files"

{
    find "$REPO_ROOT/scripts" "$REPO_ROOT/src" "$REPO_ROOT/tests" -type f -name '*.sh' -print
    find "$REPO_ROOT/src/init.d" -type f -print
} | sort -u |
while IFS= read -r shell_file; do
    if LC_ALL=C awk 'index($0, sprintf("%c", 13)) { found=1; exit } END { exit found ? 0 : 1 }' "$shell_file"; then
        printf '%s\n' "${shell_file#"$REPO_ROOT/"}" >> "$bad_files"
    fi
done

if [ -s "$bad_files" ]; then
    echo "shell files containing CR characters:" >&2
    sed 's/^/  /' "$bad_files" >&2
    fail "all *.sh files must use LF line endings"
fi

echo "shell line endings: ok"
