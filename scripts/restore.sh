#!/bin/sh
set -eu

IN="${1:-}"
[ -n "$IN" ] || { echo "usage: restore.sh <backup.tgz>"; exit 1; }
[ -f "$IN" ] || { echo "backup file not found"; exit 1; }

TMP_DIR="/tmp/vpn-manager-restore"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

tar xzf "$IN" -C "$TMP_DIR"
SRC="$(find "$TMP_DIR" -maxdepth 2 -type d -name 'vpn-manager-backup' | head -n1)"
[ -d "$SRC" ] || { echo "invalid backup"; exit 1; }

for f in vpn-manager network firewall; do
    if [ -f "$SRC/$f" ]; then
        cp "$SRC/$f" "/etc/config/$f"
    fi
done

/etc/init.d/network reload
/etc/init.d/firewall reload

echo "restore completed"
