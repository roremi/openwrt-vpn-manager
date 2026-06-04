#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

install_with_apk() {
    apk update
    apk add \
        curl \
        wireguard-tools \
        kmod-wireguard \
        nftables \
        ip-full \
        jq \
        rpcd \
        ucode \
        luci-base \
        ca-certificates \
        openssh-sftp-server \
        coreutils-install
}

install_with_opkg() {
    opkg update
    opkg install \
        curl \
        ca-bundle \
        wireguard-tools \
        kmod-wireguard \
        nftables \
        ip-full \
        jq \
        rpcd \
        ucode \
        luci-base
}

if need_cmd apk; then
    echo "Detected package manager: apk"
    install_with_apk
elif need_cmd opkg; then
    echo "Detected package manager: opkg"
    install_with_opkg
else
    echo "No supported package manager found (apk/opkg)."
    exit 1
fi

if [ ! -x "$ROOT_DIR/scripts/install.sh" ]; then
    chmod +x "$ROOT_DIR/scripts/install.sh"
fi

sh "$ROOT_DIR/scripts/install.sh"

/etc/init.d/vpn-manager enable >/dev/null 2>&1 || true
/etc/init.d/vpn-manager restart >/dev/null 2>&1 || /etc/init.d/vpn-manager start >/dev/null 2>&1 || true

echo "bootstrap completed"