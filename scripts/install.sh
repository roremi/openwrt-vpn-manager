#!/bin/sh
set -eu

umask 077

BASE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

[ "$(id -u)" = "0" ] || { echo "install.sh must run as root" >&2; exit 1; }
for required_command in install sed uci ip tar mktemp squid openssl conntrack; do
    command -v "$required_command" >/dev/null 2>&1 || {
        echo "missing command: $required_command" >&2
        exit 1
    }
done

for source_path in \
    src/lib/vpn-manager/common.sh \
    src/lib/vpn-manager/uci.sh \
    src/lib/vpn-manager/pbr.sh \
    src/lib/vpn-manager/health.sh \
    scripts/vpn-reconcile.sh \
    scripts/vpn-watchdog.sh \
    scripts/vpn-healthcheck.sh \
    scripts/vpn-block-refresh.sh \
    scripts/vpn-apply-worker.sh \
    scripts/vpn-block-worker.sh \
    scripts/vpn-route-status-worker.sh \
    scripts/vpn-http-debug.sh \
    scripts/rollback.sh \
    scripts/backup.sh \
    scripts/restore.sh \
    src/rpcd/vpn-manager.json \
    src/rpcd/vpn-manager.sh \
    src/luci/controller/vpnmanager.lua \
    src/luci/view/vpnmanager/dashboard.htm \
    src/www/vpnmanager-dashboard.html \
    src/www/vpnmanager-api-docs.html \
    src/init.d/vpn-manager \
    etc/config/vpn-manager
do
    [ -f "$BASE_DIR/$source_path" ] || {
        echo "missing install source: $source_path" >&2
        exit 1
    }
done

for shell_source in \
    src/lib/vpn-manager/common.sh \
    src/lib/vpn-manager/uci.sh \
    src/lib/vpn-manager/pbr.sh \
    src/lib/vpn-manager/health.sh \
    scripts/vpn-reconcile.sh \
    scripts/vpn-watchdog.sh \
    scripts/vpn-healthcheck.sh \
    scripts/vpn-block-refresh.sh \
    scripts/vpn-apply-worker.sh \
    scripts/vpn-block-worker.sh \
    scripts/vpn-route-status-worker.sh \
    scripts/vpn-http-debug.sh \
    scripts/rollback.sh \
    scripts/backup.sh \
    scripts/restore.sh \
    src/rpcd/vpn-manager.sh \
    src/init.d/vpn-manager
do
    sh -n "$BASE_DIR/$shell_source" || {
        echo "shell syntax check failed: $shell_source" >&2
        exit 1
    }
done
[ -x /usr/lib/squid/security_file_certgen ] || {
    echo "missing Squid certificate generator" >&2
    exit 1
}

if command -v jsonfilter >/dev/null 2>&1; then
    jsonfilter -i "$BASE_DIR/src/rpcd/vpn-manager.json" -e '@' >/dev/null || {
        echo "invalid rpcd ACL JSON" >&2
        exit 1
    }
elif command -v jq >/dev/null 2>&1; then
    jq -e . "$BASE_DIR/src/rpcd/vpn-manager.json" >/dev/null || {
        echo "invalid rpcd ACL JSON" >&2
        exit 1
    }
fi

PREINSTALL_BACKUP=""
if [ -f /etc/config/vpn-manager ] || [ -d /usr/libexec/vpn-manager ]; then
    backup_dir="/root/vpn-manager-backups"
    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir" 2>/dev/null || true
    PREINSTALL_BACKUP="$backup_dir/preinstall-$(date +%Y%m%d-%H%M%S)-$$.tgz"
    sh "$BASE_DIR/scripts/backup.sh" "$PREINSTALL_BACKUP" || {
        echo "pre-install backup failed; installation aborted" >&2
        exit 1
    }
fi

SERVICES_PAUSED=0
FILES_REPLACED=0
resume_services_on_failure() {
    rc="$1"
    trap - EXIT HUP INT TERM
    if [ "$SERVICES_PAUSED" = "1" ]; then
        /etc/init.d/rpcd restart >/dev/null 2>&1 || true
        /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
        if [ "$FILES_REPLACED" = "0" ] && [ -x /etc/init.d/vpn-manager ]; then
            /etc/init.d/vpn-manager start >/dev/null 2>&1 || true
        else
            echo "vpn-manager left stopped because installation was incomplete" >&2
        fi
    fi
    [ -z "$PREINSTALL_BACKUP" ] || \
        echo "pre-install backup retained at $PREINSTALL_BACKUP" >&2
    exit "$rc"
}
trap 'resume_services_on_failure $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Pause request handling and every previous process model before files are
# replaced. This prevents an old in-memory worker or concurrent RPC mutation
# from consuming queues while the installation is only partially updated.
SERVICES_PAUSED=1
/etc/init.d/uhttpd stop >/dev/null 2>&1 || true
/etc/init.d/rpcd stop >/dev/null 2>&1 || true
if [ -x /etc/init.d/vpn-manager ]; then
    /etc/init.d/vpn-manager stop >/dev/null 2>&1 || true
fi

[ ! -L /var/log/vpn-manager ] || rm -f /var/log/vpn-manager
mkdir -p /usr/libexec/vpn-manager /usr/libexec/rpcd /usr/share/rpcd/acl.d \
    /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/vpnmanager \
    /usr/lib/lua/luci/model/cbi/vpnmanager /etc/init.d /etc/config /var/log/vpn-manager
chmod 755 /usr/libexec/vpn-manager /usr/libexec/rpcd /usr/share/rpcd/acl.d \
    /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/vpnmanager \
    /usr/lib/lua/luci/model/cbi/vpnmanager /etc/init.d
chmod 700 /var/log/vpn-manager 2>/dev/null || true
[ ! -f /var/log/vpn-manager/audit.log ] || \
    chmod 600 /var/log/vpn-manager/audit.log 2>/dev/null || true

FILES_REPLACED=1
install -m 0755 "$BASE_DIR/src/lib/vpn-manager/common.sh" /usr/libexec/vpn-manager/common.sh
install -m 0755 "$BASE_DIR/src/lib/vpn-manager/uci.sh" /usr/libexec/vpn-manager/uci.sh
install -m 0755 "$BASE_DIR/src/lib/vpn-manager/pbr.sh" /usr/libexec/vpn-manager/pbr.sh
install -m 0755 "$BASE_DIR/src/lib/vpn-manager/health.sh" /usr/libexec/vpn-manager/health.sh
install -m 0755 "$BASE_DIR/scripts/vpn-reconcile.sh" /usr/libexec/vpn-manager/reconcile.sh
install -m 0755 "$BASE_DIR/scripts/vpn-watchdog.sh" /usr/libexec/vpn-manager/watchdog.sh
install -m 0755 "$BASE_DIR/scripts/vpn-healthcheck.sh" /usr/libexec/vpn-manager/healthcheck.sh
install -m 0755 "$BASE_DIR/scripts/vpn-block-refresh.sh" /usr/libexec/vpn-manager/block-refresh.sh
install -m 0755 "$BASE_DIR/scripts/vpn-apply-worker.sh" /usr/libexec/vpn-manager/apply-worker.sh
install -m 0755 "$BASE_DIR/scripts/vpn-block-worker.sh" /usr/libexec/vpn-manager/block-worker.sh
install -m 0755 "$BASE_DIR/scripts/vpn-route-status-worker.sh" /usr/libexec/vpn-manager/route-status-worker.sh
install -m 0755 "$BASE_DIR/scripts/vpn-http-debug.sh" /usr/libexec/vpn-manager/http-debug.sh
install -m 0755 "$BASE_DIR/scripts/rollback.sh" /usr/libexec/vpn-manager/rollback.sh
install -m 0755 "$BASE_DIR/scripts/backup.sh" /usr/libexec/vpn-manager/backup.sh
install -m 0755 "$BASE_DIR/scripts/restore.sh" /usr/libexec/vpn-manager/restore.sh

install -m 0644 "$BASE_DIR/src/rpcd/vpn-manager.json" /usr/share/rpcd/acl.d/vpn-manager.json
install -m 0755 "$BASE_DIR/src/rpcd/vpn-manager.sh" /usr/libexec/rpcd/vpn-manager

install -m 0644 "$BASE_DIR/src/luci/controller/vpnmanager.lua" /usr/lib/lua/luci/controller/vpnmanager.lua
install -m 0644 "$BASE_DIR/src/luci/view/vpnmanager/dashboard.htm" /usr/lib/lua/luci/view/vpnmanager/dashboard.htm
install -m 0644 "$BASE_DIR/src/www/vpnmanager-dashboard.html" /www/vpnmanager-dashboard.html
install -m 0644 "$BASE_DIR/src/www/vpnmanager-api-docs.html" /www/vpnmanager-api-docs.html

install -m 0755 "$BASE_DIR/src/init.d/vpn-manager" /etc/init.d/vpn-manager
rm -f /usr/libexec/vpn-manager/go-mitmproxy

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
    /usr/libexec/vpn-manager/block-refresh.sh \
    /usr/libexec/vpn-manager/apply-worker.sh \
    /usr/libexec/vpn-manager/block-worker.sh \
    /usr/libexec/vpn-manager/route-status-worker.sh \
    /usr/libexec/vpn-manager/http-debug.sh \
    /usr/libexec/vpn-manager/rollback.sh \
    /usr/libexec/vpn-manager/backup.sh \
    /usr/libexec/vpn-manager/restore.sh \
    /etc/init.d/vpn-manager
do
    [ -f "$f" ] || continue
    sed -i 's/\r$//' "$f"
done

if [ ! -f /etc/config/vpn-manager ]; then
    install -m 0600 "$BASE_DIR/etc/config/vpn-manager" /etc/config/vpn-manager
fi
chmod 600 /etc/config/vpn-manager /etc/config/network /etc/config/wireless 2>/dev/null || true

# Suppress IPv6 for LAN clients when the router has no IPv6 upstream. Otherwise
# clients receive AAAA records / an RA default route and attempt IPv6 first, but
# the packets black-hole (no egress) so every page with an AAAA record stalls on
# a Happy-Eyeballs timeout before falling back to IPv4 (e.g. browserleaks.com).
# filter_aaaa strips AAAA answers from dnsmasq so clients never try IPv6.
uci set dhcp.@dnsmasq[0].filter_aaaa='1'
uci commit dhcp

if [ -z "$(ip -6 route show default 2>/dev/null)" ]; then
    ra_changed=0
    for s in $(uci show dhcp 2>/dev/null | grep "\.ra='server'" | sed "s/^dhcp\.//; s/\.ra=.*//"); do
        uci set "dhcp.$s.ra=disabled"
        uci set "dhcp.$s.dhcpv6=disabled"
        uci -q delete "dhcp.$s.ra_slaac"
        uci -q delete "dhcp.$s.ra_flags"
        ra_changed=1
    done
    [ "$ra_changed" = "1" ] && uci commit dhcp
fi

/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
/etc/init.d/odhcpd restart >/dev/null 2>&1 || true
/etc/init.d/squid stop >/dev/null 2>&1 || true
/etc/init.d/squid disable >/dev/null 2>&1 || true

/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
/etc/init.d/vpn-manager enable >/dev/null 2>&1
/etc/init.d/vpn-manager restart >/dev/null 2>&1 || /etc/init.d/vpn-manager start >/dev/null 2>&1

SERVICES_PAUSED=0
trap - EXIT HUP INT TERM
[ -z "$PREINSTALL_BACKUP" ] || echo "pre-install backup: $PREINSTALL_BACKUP"
echo "vpn-manager installed"
