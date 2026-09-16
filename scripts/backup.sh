#!/bin/sh
set -eu

umask 077

OUT="${1:-/tmp/vpn-manager-backup.tgz}"
case "$OUT" in
    /*) : ;;
    *) OUT="$(pwd)/$OUT" ;;
esac

out_dir="$(dirname "$OUT")"
out_name="$(basename "$OUT")"
[ -d "$out_dir" ] || {
    echo "backup destination directory does not exist: $out_dir" >&2
    exit 1
}

TMP_ROOT="${TMPDIR:-/tmp}"
TMP_DIR="$(mktemp -d "$TMP_ROOT/vpn-manager-backup.XXXXXX")" || {
    echo "unable to create backup staging directory" >&2
    exit 1
}
ARCHIVE_TMP=""

cleanup() {
    [ -z "$ARCHIVE_TMP" ] || rm -f "$ARCHIVE_TMP" 2>/dev/null || true
    case "$TMP_DIR" in
        "$TMP_ROOT"/vpn-manager-backup.*) rm -rf "$TMP_DIR" 2>/dev/null || true ;;
    esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

BACKUP_ROOT="$TMP_DIR/vpn-manager-backup"
mkdir -p "$BACKUP_ROOT" "$BACKUP_ROOT/runtime" "$BACKUP_ROOT/installed" \
    "$BACKUP_ROOT/diagnostics"
printf '%s\n' 'vpn-manager-backup-v2' > "$BACKUP_ROOT/.format"

for config_name in vpn-manager network firewall wireless dhcp; do
    config_path="/etc/config/$config_name"
    [ ! -f "$config_path" ] || cp -p "$config_path" "$BACKUP_ROOT/$config_name"
done
chmod 600 "$BACKUP_ROOT"/vpn-manager "$BACKUP_ROOT"/network \
    "$BACKUP_ROOT"/firewall "$BACKUP_ROOT"/wireless "$BACKUP_ROOT"/dhcp \
    2>/dev/null || true

# Runtime state is diagnostic only. restore.sh intentionally does not replay
# queues, locks, cached DNS, or checkpoints from an earlier boot.
[ ! -d /tmp/vpn-manager ] || \
    cp -a /tmp/vpn-manager "$BACKUP_ROOT/runtime/" 2>/dev/null || true

copy_installed_path() {
    source_path="$1"
    [ -e "$source_path" ] || return 0
    relative_path="${source_path#/}"
    destination="$BACKUP_ROOT/installed/$relative_path"
    mkdir -p "$(dirname "$destination")"
    cp -a "$source_path" "$destination"
}

for installed_path in \
    /usr/libexec/vpn-manager \
    /usr/libexec/rpcd/vpn-manager \
    /usr/share/rpcd/acl.d/vpn-manager.json \
    /usr/lib/lua/luci/controller/vpnmanager.lua \
    /usr/lib/lua/luci/view/vpnmanager \
    /www/vpnmanager-dashboard.html \
    /www/vpnmanager-api-docs.html \
    /etc/init.d/vpn-manager
do
    copy_installed_path "$installed_path"
done

command -v nft >/dev/null 2>&1 && \
    nft list ruleset > "$BACKUP_ROOT/diagnostics/nft-ruleset.txt" 2>&1 || true
command -v ip >/dev/null 2>&1 && \
    ip rule show > "$BACKUP_ROOT/diagnostics/ip-rules.txt" 2>&1 || true
command -v ip >/dev/null 2>&1 && \
    ip route show table all > "$BACKUP_ROOT/diagnostics/ip-routes.txt" 2>&1 || true
command -v wg >/dev/null 2>&1 && \
    wg show > "$BACKUP_ROOT/diagnostics/wireguard-status.txt" 2>&1 || true

ARCHIVE_TMP="$(mktemp "$out_dir/.${out_name}.tmp.XXXXXX")" || {
    echo "unable to create backup archive in $out_dir" >&2
    exit 1
}
( cd "$TMP_DIR" && tar czf "$ARCHIVE_TMP" vpn-manager-backup )
chmod 600 "$ARCHIVE_TMP"
mv -f "$ARCHIVE_TMP" "$OUT"
ARCHIVE_TMP=""
echo "backup saved to $OUT"
