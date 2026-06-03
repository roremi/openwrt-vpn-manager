#!/bin/sh
set -eu

OUT="${1:-/tmp/vpn-manager-backup.tgz}"
TMP_DIR="/tmp/vpn-manager-backup"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

cp /etc/config/vpn-manager "$TMP_DIR/" 2>/dev/null || true
cp /etc/config/network "$TMP_DIR/" 2>/dev/null || true
cp /etc/config/firewall "$TMP_DIR/" 2>/dev/null || true
cp -a /tmp/vpn-manager "$TMP_DIR/" 2>/dev/null || true

( cd /tmp && tar czf "$OUT" "$(basename "$TMP_DIR")" )
echo "backup saved to $OUT"
