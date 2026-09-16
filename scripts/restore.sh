#!/bin/sh
set -eu

umask 077

IN="${1:-}"
[ -n "$IN" ] || { echo "usage: restore.sh <backup.tgz>"; exit 1; }
[ -f "$IN" ] || { echo "backup file not found"; exit 1; }
case "$IN" in
    /*) : ;;
    *) IN="$(pwd)/$IN" ;;
esac

TMP_ROOT="${TMPDIR:-/tmp}"
TMP_DIR="$(mktemp -d "$TMP_ROOT/vpn-manager-restore.XXXXXX")" || {
    echo "unable to create restore staging directory" >&2
    exit 1
}
EXTRACT_DIR="$TMP_DIR/extract"
CURRENT_DIR="$TMP_DIR/current"
MEMBERS_FILE="$TMP_DIR/members"
RESTORE_APPLIED=0
SERVICE_STOPPED=0
APPLY_LOCKED=0
CONFIG_LOCKED=0

release_locks() {
    if [ "$CONFIG_LOCKED" = "1" ]; then
        lock -u /tmp/vpn-manager/config.lock 2>/dev/null || true
        CONFIG_LOCKED=0
    fi
    if [ "$APPLY_LOCKED" = "1" ]; then
        lock -u /tmp/vpn-manager/apply.lock 2>/dev/null || true
        APPLY_LOCKED=0
    fi
}

restore_current_configs() {
    for config_name in vpn-manager network firewall wireless dhcp; do
        if [ -f "$CURRENT_DIR/$config_name" ]; then
            cp "$CURRENT_DIR/$config_name" "/etc/config/.$config_name.restore.$$" 2>/dev/null || continue
            chmod 600 "/etc/config/.$config_name.restore.$$" 2>/dev/null || true
            mv -f "/etc/config/.$config_name.restore.$$" "/etc/config/$config_name" 2>/dev/null || true
        elif [ -f "$CURRENT_DIR/$config_name.absent" ]; then
            rm -f "/etc/config/$config_name" 2>/dev/null || true
        fi
    done
    /etc/init.d/network reload >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    /etc/init.d/odhcpd restart >/dev/null 2>&1 || true
}

cleanup() {
    rc="$1"
    trap - EXIT HUP INT TERM
    set +e
    if [ "$RESTORE_APPLIED" = "1" ]; then
        echo "restore failed; restoring pre-restore configuration" >&2
        restore_current_configs
    fi
    release_locks
    if [ "$SERVICE_STOPPED" = "1" ] && [ -x /etc/init.d/vpn-manager ]; then
        /etc/init.d/vpn-manager start >/dev/null 2>&1 || true
    fi
    case "$TMP_DIR" in
        "$TMP_ROOT"/vpn-manager-restore.*) rm -rf "$TMP_DIR" 2>/dev/null || true ;;
    esac
    exit "$rc"
}
trap 'cleanup $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$EXTRACT_DIR" "$CURRENT_DIR"

# Reject absolute paths and traversal before extraction. Only the fixed backup
# root produced by backup.sh is accepted; runtime/installed content is retained
# for diagnostics but is never restored automatically.
tar tzf "$IN" > "$MEMBERS_FILE" || {
    echo "invalid or unreadable backup archive" >&2
    exit 1
}
[ -s "$MEMBERS_FILE" ] || { echo "empty backup archive" >&2; exit 1; }
if ! while IFS= read -r member; do
    member="${member%/}"
    case "$member" in
        vpn-manager-backup|vpn-manager-backup/*) : ;;
        *) exit 1 ;;
    esac
    case "/$member/" in
        */../*|*/./*) exit 1 ;;
    esac
    case "$member" in
        *\\*) exit 1 ;;
    esac
done < "$MEMBERS_FILE"
then
    echo "backup archive contains an unsafe path" >&2
    exit 1
fi

SRC="$EXTRACT_DIR/vpn-manager-backup"
mkdir -p "$SRC"
for config_name in vpn-manager network firewall wireless dhcp; do
    archive_member="vpn-manager-backup/$config_name"
    grep -Fqx "$archive_member" "$MEMBERS_FILE" || continue
    tar xOzf "$IN" "$archive_member" > "$SRC/$config_name" || {
        echo "unable to extract backup config: $config_name" >&2
        exit 1
    }
done
[ -s "$SRC/vpn-manager" ] || {
    echo "backup does not contain a regular vpn-manager configuration" >&2
    exit 1
}

command -v uci >/dev/null 2>&1 || { echo "missing command: uci" >&2; exit 1; }
command -v lock >/dev/null 2>&1 || { echo "missing command: lock" >&2; exit 1; }

for config_name in vpn-manager network firewall wireless dhcp; do
    if [ -f "$SRC/$config_name" ]; then
        uci -c "$SRC" -q show "$config_name" >/dev/null 2>&1 || {
            echo "backup config failed UCI validation: $config_name" >&2
            exit 1
        }
    fi
done

if [ -x /etc/init.d/vpn-manager ]; then
    /etc/init.d/vpn-manager stop >/dev/null 2>&1 || true
    SERVICE_STOPPED=1
fi

mkdir -p /tmp/vpn-manager
chmod 700 /tmp/vpn-manager 2>/dev/null || true
lock -n /tmp/vpn-manager/apply.lock 2>/dev/null || {
    echo "vpn-manager apply is busy; retry restore" >&2
    exit 75
}
APPLY_LOCKED=1
lock -n /tmp/vpn-manager/config.lock 2>/dev/null || {
    echo "vpn-manager configuration is busy; retry restore" >&2
    exit 75
}
CONFIG_LOCKED=1

for config_name in vpn-manager network firewall wireless dhcp; do
    if [ -f "/etc/config/$config_name" ]; then
        cp -p "/etc/config/$config_name" "$CURRENT_DIR/$config_name"
    else
        : > "$CURRENT_DIR/$config_name.absent"
    fi
done

RESTORE_APPLIED=1
for config_name in vpn-manager network firewall wireless dhcp; do
    [ -f "$SRC/$config_name" ] || continue
    cp "$SRC/$config_name" "/etc/config/.$config_name.restore.$$"
    chmod 600 "/etc/config/.$config_name.restore.$$"
    mv -f "/etc/config/.$config_name.restore.$$" "/etc/config/$config_name"
done

/etc/init.d/network reload
/etc/init.d/firewall reload
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
/etc/init.d/odhcpd restart >/dev/null 2>&1 || true

RESTORE_APPLIED=0
release_locks
if [ "$SERVICE_STOPPED" = "1" ]; then
    /etc/init.d/vpn-manager restart >/dev/null 2>&1 || \
        /etc/init.d/vpn-manager start >/dev/null 2>&1
    SERVICE_STOPPED=0
fi

echo "restore completed"
