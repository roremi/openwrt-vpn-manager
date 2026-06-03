include $(TOPDIR)/rules.mk

PKG_NAME:=vpn-manager
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

LUCI_TITLE:=LuCI VPN Multi-Manager
LUCI_DEPENDS:=+luci-base +rpcd +wireguard-tools +kmod-wireguard +nftables +ip-full +jq
PKG_LICENSE:=MIT


define Package/vpn-manager
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OpenWrt Multi WireGuard VPN Manager
  DEPENDS:=$(LUCI_DEPENDS)
endef

define Package/vpn-manager/description
  Multi-profile WireGuard manager with device policy routing, isolation, health-check and rollback.
endef

define Build/Compile
endef

define Package/vpn-manager/install
	$(INSTALL_DIR) $(1)/usr/libexec/vpn-manager
	$(INSTALL_BIN) ./files/usr/libexec/vpn-manager/* $(1)/usr/libexec/vpn-manager/

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/vpn-manager $(1)/usr/libexec/rpcd/

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/vpn-manager.json $(1)/usr/share/rpcd/acl.d/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/vpnmanager.lua $(1)/usr/lib/lua/luci/controller/

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/vpnmanager
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/view/vpnmanager/dashboard.htm $(1)/usr/lib/lua/luci/view/vpnmanager/

	$(INSTALL_DIR) $(1)/www
	$(INSTALL_DATA) ./files/www/vpnmanager-dashboard.html $(1)/www/

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/vpn-manager $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/vpn-manager $(1)/etc/config/vpn-manager
endef

$(eval $(call BuildPackage,vpn-manager))
