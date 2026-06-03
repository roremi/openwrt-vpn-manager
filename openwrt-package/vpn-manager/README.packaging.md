# Packaging Notes

Copy runtime files into:

- files/usr/libexec/vpn-manager/
- files/usr/libexec/rpcd/vpn-manager
- files/usr/share/rpcd/acl.d/vpn-manager.json
- files/usr/lib/lua/luci/controller/vpnmanager.lua
- files/usr/lib/lua/luci/view/vpnmanager/dashboard.htm
- files/etc/init.d/vpn-manager
- files/etc/config/vpn-manager

Then run package compile in OpenWrt SDK.
