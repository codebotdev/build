# SPDX-License-Identifier: GPL-2.0-only
# IPQ5018 GMAC/DSA NSS runtime, imported from openwrt-nss-edma.
include $(TOPDIR)/rules.mk

PKG_NAME:=nss-tools
PKG_RELEASE:=22

include $(INCLUDE_DIR)/package.mk

define Package/nss-tools-dwmac
  SECTION:=net
  CATEGORY:=Network
  TITLE:=NSS DWMAC/DSA runtime for JDCloud AX3000
  DEPENDS:=@(TARGET_qualcommax_ipq50xx_DEVICE_jdcloud_ax3000) \
	+TARGET_qualcommax_ipq50xx:kmod-qca-dwmac-nss +kmod-qca-nss-drv \
	+kmod-qca-nss-ecm +kmod-qca-nss-drv-vlan-mgr \
	+TARGET_qualcommax_ipq50xx:kmod-qca-dsa-nss +ip-full
  CONFLICTS:=nss-tools
  PKGARCH:=all
endef

define Package/nss-tools-dwmac/description
 Configures the qca-8021q DSA tagger before netifd, then arms both
 IPQ5018 GMACs for NSS ownership once the live network is ready. Registers the switch VLANs with
 qca-dsa-nss and starts ECM after the topology is ready. Loads ath11k
 after the NSS core and packet buffers are ready. Includes status,
 probing and IRQ affinity.
 Disable offload through nss.general.enabled to use the host path.
endef

define Build/Compile
endef

define Package/nss-tools-dwmac/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/nss-dwmac-up $(1)/usr/sbin/nss-dwmac-up
	$(INSTALL_BIN) ./files/nss-irq-affinity $(1)/usr/sbin/nss-irq-affinity
	$(INSTALL_BIN) ./files/nss-dwmac-probe $(1)/usr/sbin/nss-dwmac-probe
	$(INSTALL_BIN) ./files/nss-status $(1)/usr/sbin/nss-status
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/nss-dwmac.init $(1)/etc/init.d/nss
	$(INSTALL_DIR) $(1)/lib/nss
	$(INSTALL_DATA) ./files/functions.sh $(1)/lib/nss/functions.sh
	$(INSTALL_DIR) $(1)/etc/sysctl.d
	$(INSTALL_DATA) ./files/nss.sysctl $(1)/etc/sysctl.d/12-nss-networking.conf
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DATA) ./files/nss-offload.defaults $(1)/etc/uci-defaults/98-nss-offload
	$(INSTALL_DATA) ./files/nss-dwmac.defaults $(1)/etc/uci-defaults/99-nss-topology-v2
endef

$(eval $(call BuildPackage,nss-tools-dwmac))
