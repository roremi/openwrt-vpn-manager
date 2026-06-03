# Deployment Guide

## Requirements

- OpenWrt 23.05+
- Package manager: apk or opkg

## Method A: Direct install on router (simplest)

1. Upload repository to /root/vpn-manager.
2. Run one command:

sh /root/vpn-manager/scripts/bootstrap-openwrt.sh

What it does:
- Detects apk or opkg automatically
- Installs required dependencies
- Runs installer
- Enables and starts service

3. Open LuCI page: Services > VPN Manager.

## Method A.1: If you already installed dependencies

Run:

sh /root/vpn-manager/scripts/install.sh

## Method B: Build ipk in OpenWrt SDK

1. Copy openwrt-package/vpn-manager into package/.
2. Ensure payload files are mapped in package Makefile.
3. Build package:

make package/vpn-manager/compile V=s

4. Install generated ipk.

## Post-Install Validation

- ubus list | grep vpn-manager
- nft list ruleset | grep vpn_manager
- wg show
- logread | grep vpn-manager

## Rollback

- Manual rollback command:

/usr/libexec/vpn-manager/rollback.sh last

- Auto rollback happens if post-apply health checks fail.
