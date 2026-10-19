// SPDX-License-Identifier: GPL-2.0-only
/* Read-only snapshots for the AX3000 IPQ5018 <-> QCA8337 CPU link. */
#include <linux/device.h>
#include <linux/io.h>
#include <linux/phy.h>
#include <linux/module.h>
#include <linux/regmap.h>
#include <linux/of.h>

struct diag_reg {
	u32 offset;
	const char *name;
};

static void snapshot_mmio(phys_addr_t addr, size_t size,
			  const struct diag_reg *regs, size_t count)
{
	void __iomem *base = ioremap(addr, size);
	size_t i;

	if (!base) {
		pr_err("ax3000-sgmii: cannot map %pa\n", &addr);
		return;
	}
	for (i = 0; i < count; i++)
		pr_info("ax3000-sgmii: %s [%pa+0x%03x] = 0x%08x\n",
			regs[i].name, &addr, regs[i].offset,
			readl(base + regs[i].offset));
	iounmap(base);
}

static int __init ax3000_diag_init(void)
{
	static const struct diag_reg uniphy[] = {
		{0x074, "uniphy.refclk"},
		{0x1e0, "uniphy.calibration"},
		{0x218, "uniphy.misc2"},
		{0x46c, "uniphy.mode"},
		{0x480, "uniphy.ch0_ctrl"},
		{0x488, "uniphy.ch0_status"},
		{0x780, "uniphy.pll_reset"},
	};
	static const struct diag_reg gmac[] = {
		{0x0000, "gmac1.config"},
		{0x0004, "gmac1.frame_filter"},
		{0x0018, "gmac1.flow_control"},
		{0x1000, "gmac1.dma_bus_mode"},
		{0x1014, "gmac1.dma_status"},
		{0x1018, "gmac1.dma_operation"},
	};
	static const struct diag_reg sw[] = {
		{0x000, "switch.id"}, {0x004, "switch.pad0"},
		{0x008, "switch.pad5"}, {0x00c, "switch.pad6"},
		{0x010, "switch.pws"}, {0x07c, "switch.port0_status"},
		{0x084, "switch.port2_status"}, {0x09c, "switch.port0_header"},
		{0x0e0, "switch.sgmii"}, {0x620, "switch.forward0"},
		{0x624, "switch.forward1"}, {0x660, "switch.port0_lookup"},
		{0x678, "switch.port2_lookup"},
	};
	struct device *dev;
	struct regmap *map;
	unsigned int val;
	size_t i;
	int ret;

	if (!of_machine_is_compatible("jdcloud,ax3000"))
		return -ENODEV;
	pr_info("ax3000-sgmii: begin read-only snapshot v1\n");
	snapshot_mmio(0x98000, 0x800, uniphy, ARRAY_SIZE(uniphy));
	snapshot_mmio(0x39d00000, 0x2000, gmac, ARRAY_SIZE(gmac));
	dev = bus_find_device_by_name(&mdio_bus_type, NULL, "90000.mdio-1:11");
	if (!dev) {
		pr_err("ax3000-sgmii: switch MDIO device not found\n");
		return 0;
	}
	map = dev_get_regmap(dev, NULL);
	if (map) {
		for (i = 0; i < ARRAY_SIZE(sw); i++) {
			ret = regmap_read(map, sw[i].offset, &val);
			if (ret)
				pr_err("ax3000-sgmii: %s read failed: %d\n", sw[i].name, ret);
			else
				pr_info("ax3000-sgmii: %s [0x%03x] = 0x%08x\n",
					sw[i].name, sw[i].offset, val);
		}
	} else {
		pr_err("ax3000-sgmii: switch regmap not found\n");
	}
	put_device(dev);
	pr_info("ax3000-sgmii: snapshot complete; no registers modified\n");
	return 0;
}

static void __exit ax3000_diag_exit(void) {}
module_init(ax3000_diag_init);
module_exit(ax3000_diag_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Read-only IPQ5018 AX3000 SGMII snapshot");
MODULE_VERSION("1");
