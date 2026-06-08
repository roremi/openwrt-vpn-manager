#!/bin/sh
set -eu

BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

mkdir -p /usr/libexec/vpn-manager /usr/libexec/rpcd /usr/share/rpcd/acl.d \
    /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/vpnmanager \
    /usr/lib/lua/luci/model/cbi/vpnmanager /etc/init.d /etc/config /var/log/vpn-manager

install -m 0755 "$BASE_DIR/src/lib/vpn-manager/common.sh" /usr/libexec/vpn-manager/common.sh
install -m 0755 "$BASE_DIR/src/lib/vpn-manager/uci.sh" /usr/libexec/vpn-manager/uci.sh
install -m 0755 "$BASE_DIR/src/lib/vpn-manager/pbr.sh" /usr/libexec/vpn-manager/pbr.sh
install -m 0755 "$BASE_DIR/src/lib/vpn-manager/health.sh" /usr/libexec/vpn-manager/health.sh
install -m 0755 "$BASE_DIR/scripts/vpn-reconcile.sh" /usr/libexec/vpn-manager/reconcile.sh
install -m 0755 "$BASE_DIR/scripts/vpn-watchdog.sh" /usr/libexec/vpn-manager/watchdog.sh
install -m 0755 "$BASE_DIR/scripts/vpn-healthcheck.sh" /usr/libexec/vpn-manager/healthcheck.sh
install -m 0755 "$BASE_DIR/scripts/rollback.sh" /usr/libexec/vpn-manager/rollback.sh
install -m 0755 "$BASE_DIR/scripts/backup.sh" /usr/libexec/vpn-manager/backup.sh
install -m 0755 "$BASE_DIR/scripts/restore.sh" /usr/libexec/vpn-manager/restore.sh

install -m 0644 "$BASE_DIR/src/rpcd/vpn-manager.json" /usr/share/rpcd/acl.d/vpn-manager.json
install -m 0755 "$BASE_DIR/src/rpcd/vpn-manager.sh" /usr/libexec/rpcd/vpn-manager

install -m 0644 "$BASE_DIR/src/luci/controller/vpnmanager.lua" /usr/lib/lua/luci/controller/vpnmanager.lua
install -m 0644 "$BASE_DIR/src/luci/view/vpnmanager/dashboard.htm" /usr/lib/lua/luci/view/vpnmanager/dashboard.htm
install -m 0644 "$BASE_DIR/src/www/vpnmanager-dashboard.html" /www/vpnmanager-dashboard.html

install -m 0755 "$BASE_DIR/src/init.d/vpn-manager" /etc/init.d/vpn-manager

# Normalize CRLF line endings from Windows checkouts so ash can execute scripts reliably.
for f in \
    /usr/libexec/rpcd/vpn-manager \
    /usr/libexec/vpn-manager/common.sh \
    /usr/libexec/vpn-manager/uci.sh \
    /usr/libexec/vpn-manager/pbr.sh \
    /usr/libexec/vpn-manager/health.sh \
    /usr/libexec/vpn-manager/reconcile.sh \
    /usr/libexec/vpn-manager/watchdog.sh \
    /usr/libexec/vpn-manager/healthcheck.sh \
    /usr/libexec/vpn-manager/rollback.sh \
    /usr/libexec/vpn-manager/backup.sh \
    /usr/libexec/vpn-manager/restore.sh \
    /etc/init.d/vpn-manager
do
    [ -f "$f" ] || continue
    sed -i 's/\r$//' "$f"
done

if [ ! -f /etc/config/vpn-manager ]; then
    install -m 0644 "$BASE_DIR/etc/config/vpn-manager" /etc/config/vpn-manager
fi

if uci -q get dhcp.@dnsmasq[0].filter_aaaa >/dev/null 2>&1; then
    uci set dhcp.@dnsmasq[0].filter_aaaa='1'
    uci commit dhcp
fi

/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

echo "vpn-manager installed"
