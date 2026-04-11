include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-netspeedcontrol
PKG_VERSION:=0.1.0
PKG_RELEASE:=27

LUCI_TITLE:=LuCI support for scheduled device network control
LUCI_DEPENDS:=+luci-base +luci-compat +nftables +firewall4
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
