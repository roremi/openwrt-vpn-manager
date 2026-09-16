#!/bin/sh
set -eu

TEST_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$TEST_DIR/../.." && pwd)"
. "$REPO_ROOT/tests/lib/testlib.sh"

backup_file="$REPO_ROOT/scripts/backup.sh"
restore_file="$REPO_ROOT/scripts/restore.sh"
install_file="$REPO_ROOT/scripts/install.sh"
common_file="$REPO_ROOT/src/lib/vpn-manager/common.sh"
controller_file="$REPO_ROOT/src/luci/controller/vpnmanager.lua"
rpc_file="$REPO_ROOT/src/rpcd/vpn-manager.sh"

grep -Fq 'umask 077' "$backup_file" || fail "backup must use a private umask"
grep -Fq 'mktemp -d "$TMP_ROOT/vpn-manager-backup.XXXXXX"' "$backup_file" ||
    fail "backup staging directory must be created exclusively"
grep -Fq 'chmod 600 "$ARCHIVE_TMP"' "$backup_file" ||
    fail "backup archive must be private before publication"
grep -Fq 'mv -f "$ARCHIVE_TMP" "$OUT"' "$backup_file" ||
    fail "backup archive must be published atomically"

grep -Fq 'tar xOzf "$IN" "$archive_member"' "$restore_file" ||
    fail "restore must extract only fixed configuration members"
if grep -Fq 'tar xzf "$IN" -C' "$restore_file"; then
    fail "restore must not extract an entire untrusted archive"
fi
grep -Fq 'uci -c "$SRC" -q show "$config_name"' "$restore_file" ||
    fail "restore must validate staged UCI files"
apply_lock_line="$(grep -nF 'lock -n /tmp/vpn-manager/apply.lock' "$restore_file" | head -n1 | cut -d: -f1)"
config_lock_line="$(grep -nF 'lock -n /tmp/vpn-manager/config.lock' "$restore_file" | head -n1 | cut -d: -f1)"
[ -n "$apply_lock_line" ] && [ -n "$config_lock_line" ] && \
    [ "$apply_lock_line" -lt "$config_lock_line" ] ||
    fail "restore locks must follow apply -> config order"

grep -Fq 'install -m 0600 "$BASE_DIR/etc/config/vpn-manager"' "$install_file" ||
    fail "installer must protect the VPN configuration"
backup_line="$(grep -nF 'sh "$BASE_DIR/scripts/backup.sh" "$PREINSTALL_BACKUP"' "$install_file" | head -n1 | cut -d: -f1)"
pause_line="$(grep -n '^SERVICES_PAUSED=1$' "$install_file" | head -n1 | cut -d: -f1)"
[ -n "$backup_line" ] && [ -n "$pause_line" ] && [ "$backup_line" -lt "$pause_line" ] ||
    fail "installer must finish its persistent backup before pausing services"

grep -Fq 'chmod 700 "$VM_STATE_DIR"' "$common_file" ||
    fail "runtime directory must be root-only"
grep -Fq 'chmod 600 "$VM_AUDIT_LOG"' "$common_file" ||
    fail "audit log must be root-only"
grep -Fq 'logger -t vpn-manager "[$level] $safe_msg"' "$common_file" ||
    fail "system log must receive redacted text"

. "$common_file"
redacted="$(printf '%s\n' \
    'PrivateKey = private-one' \
    'PresharedKey = preshared-two' \
    "private_key='private-three'" \
    '"preshared_key":"preshared-four"' | vm_redact)"
for secret in private-one preshared-two private-three preshared-four; do
    case "$redacted" in
        *"$secret"*) fail "redaction leaked $secret" ;;
    esac
done

grep -Fq 'mktemp /tmp/vpnmanager-import.XXXXXX' "$controller_file" ||
    fail "LuCI import must create an exclusive temporary file"
grep -Fq 'nixio.open(tmp, "w", "600")' "$controller_file" ||
    fail "LuCI import temporary file must use mode 0600"
grep -Fq 'nixio.fs.unlink(tmp)' "$controller_file" ||
    fail "LuCI import temporary file must be removed"
grep -Fq 'umask 077' "$rpc_file" ||
    fail "RPC temporary files must use a private umask"

echo "deployment safety guards: ok"
