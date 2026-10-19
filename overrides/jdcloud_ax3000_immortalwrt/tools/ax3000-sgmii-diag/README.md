# AX3000 SGMII read-only snapshot

An external module for the exact Linux tree that built the running AX3000
firmware. Reads UNIPHY mode/calibration/channel/reference-clock registers,
GMAC1 configuration/DMA status, and QCA8337 CPU-port/SGMII configuration
through the bound driver's regmap. No register writes, configuration changes,
resets, or background work. Refuses boards without jdcloud,ax3000 compatibility.

Build with the prepared firmware kernel tree and its matching cross compiler:

```
make -C "$KERNEL_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" M="$PWD/tools/ax3000-sgmii-diag" modules
```

Keep NSS disabled, LAN enabled and the computer attached. Upload the module to
`/tmp/ax3000_sgmii_diag.ko`, then run on the router:

```
insmod /tmp/ax3000_sgmii_diag.ko
dmesg | grep ax3000-sgmii
rmmod ax3000_sgmii_diag
```

The b4d6578b2e binary was built and linked against Linux 6.12.103 from the
firmware build. It has not been loaded on hardware. It is a diagnostic module,
not a datapath fix. Do not use it with a different kernel build.


The temporary register-fix module used during debugging has been removed.
The permanent fix is qualcommax patch 0752.
