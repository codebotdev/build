"""Execute the prepared kernel's real PCS config against a register model."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[4]
kernel = Path(os.environ.get('AX3000_TEST_KERNEL', str(root / 'build_dir/target-aarch64_cortex-a53_musl/linux-qualcommax_ipq50xx/linux-6.12.103')))
source = (kernel / 'drivers/net/dsa/qca/qca8k-8xxx.c').read_text()
start = source.index('static int qca8k_pcs_config(')
brace = source.index('{', start)
depth = 1
end = brace + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
function = source[start:end]
header = (kernel / 'drivers/net/dsa/qca/qca8k.h').read_text().replace('\\\n', '')
defines = {}
for line in header.splitlines():
    m = re.match(r'#define\s+(\w+)', line)
    if m:
        defines[m[1]] = line
needed = set(re.findall(r'\bQCA8K_\w+', function)) - {'QCA8K_CPU_PORT0', 'QCA8K_CPU_PORT6'}
previous = set()
while needed != previous:
    previous = needed.copy()
    for name in previous:
        if name in defines:
            needed.update(re.findall(r'\bQCA8K_\w+', defines[name]))
macros = '\n'.join(defines[name] for name in sorted(needed) if name in defines)
fixture = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
typedef uint32_t u32;
typedef int phy_interface_t;
#define BIT(n) (1U << (n))
#define GENMASK(h,l) ((~0U << (l)) & (~0U >> (31-(h))))
#define FIELD_PREP(mask,v) (((unsigned int)(v) << __builtin_ctz(mask)) & (mask))
#define WARN_ON(x) ((void)(x))
#define QCA8K_CPU_PORT0 0
#define QCA8K_CPU_PORT6 1
#define PHY_INTERFACE_MODE_SGMII 1
#define PHY_INTERFACE_MODE_1000BASEX 2
#define PHYLINK_PCS_NEG_OUTBAND BIT(5)
#define PHYLINK_PCS_NEG_INBAND_DISABLED BIT(6)
#define PHYLINK_PCS_NEG_INBAND_ENABLED (BIT(6)|BIT(4))
struct device { struct device *parent; const char *compatible; };
struct net_device { struct device dev; };
struct dsa_port { struct net_device *conduit; bool cpu; };
struct dsa_switch { struct dsa_port ports[7]; };
struct phylink_pcs { int dummy; };
struct qca8k_priv {
    struct dsa_switch *ds;
    struct { bool sgmii_enable_pll, sgmii_rx_clk_falling_edge, sgmii_tx_clk_falling_edge; } ports_config;
    int switch_id;
    u32 registers[1024];
};
struct qca8k_pcs { struct phylink_pcs pcs; struct qca8k_priv *priv; int port; };
static struct qca8k_pcs *pcs_to_qca8k_pcs(struct phylink_pcs *p) { return (void *)p; }
static struct dsa_port *dsa_to_port(struct dsa_switch *s, int p) { return &s->ports[p]; }
static bool dsa_is_cpu_port(struct dsa_switch *s, int p) { return s->ports[p].cpu; }
static struct device *dev_of_node(struct device *d) { return d; }
static bool of_device_is_compatible(struct device *d, const char *s) { return d && d->compatible && !strcmp(d->compatible, s); }
static int qca8k_read(struct qca8k_priv *p, u32 r, u32 *v) { *v=p->registers[r/4]; return 0; }
static int qca8k_write(struct qca8k_priv *p, u32 r, u32 v) { p->registers[r/4]=v; return 0; }
static int qca8k_rmw(struct qca8k_priv *p, u32 r, u32 mask, u32 v) { p->registers[r/4]=(p->registers[r/4]&~mask)|(v&mask); return 0; }
static void qca8k_mac_config_setup_internal_delay(struct qca8k_priv *p, int c, u32 r) { (void)p; (void)c; (void)r; }
'''
tests = r'''
static void check(int port, unsigned int mode, bool dwmac, int id, bool stale_force, bool cpu) {
    struct device parent = { .compatible=dwmac ? "qcom,ipq5018-gmac" : "qcom,nss-dp" };
    struct net_device conduit = { .dev={ .parent=&parent } };
    struct dsa_switch ds = {0};
    struct qca8k_priv priv = { .ds=&ds, .switch_id=id };
    struct qca8k_pcs pcs = { .priv=&priv, .port=port };
    unsigned int force=QCA8K_PORT_PAD_SGMII_FORCE_MODE;
    u32 pad=0x80 | (stale_force ? force : 0), pws=0x261320;
    ds.ports[port]=(struct dsa_port){ .conduit=&conduit, .cpu=cpu };
    priv.ports_config.sgmii_enable_pll=true;
    priv.registers[QCA8K_REG_PORT0_PAD_CTRL/4]=pad;
    priv.registers[QCA8K_REG_PWS/4]=pws;
    priv.registers[QCA8K_REG_SGMII_CTRL/4]=0xc74164de;
    assert(qca8k_pcs_config(&pcs.pcs, mode, PHY_INTERFACE_MODE_SGMII, NULL, false)==0);
    u32 expected_pws=pws | ((dwmac && cpu && mode!=PHYLINK_PCS_NEG_INBAND_ENABLED) ? QCA8K_PWS_SERDES_AEN_DIS : 0);
    assert(priv.registers[QCA8K_REG_PWS/4]==expected_pws);
    u32 expected_pad=pad;
    if (dwmac && cpu && id==QCA8K_ID_QCA8337)
        expected_pad=(pad&~force) | (mode==PHYLINK_PCS_NEG_OUTBAND ? force : 0);
    assert(priv.registers[QCA8K_REG_PORT0_PAD_CTRL/4]==expected_pad);
    assert(priv.registers[QCA8K_REG_PORT6_PAD_CTRL/4]==0);
}
int main(void) {
    const unsigned int modes[]={PHYLINK_PCS_NEG_OUTBAND, PHYLINK_PCS_NEG_INBAND_ENABLED, PHYLINK_PCS_NEG_INBAND_DISABLED};
    for (int p=0;p<=6;p+=6)
        for (unsigned int m=0;m<3;m++)
            for (int dw=0;dw<2;dw++)
                for (int id=0x12;id<=0x13;id++)
                    for (int stale=0;stale<2;stale++)
                        for (int cpu=0;cpu<2;cpu++)
                            check(p,modes[m],dw,id,stale,cpu);
    puts("PASS: real qca8k PCS fixed/in-band modes, CPU ports 0/6, stale force clearing, QCA8327 exclusion, legacy NSS-DP preservation (96 cases)");
}
'''
with tempfile.TemporaryDirectory(prefix='qca8k-sgmii-test-') as temp:
    c = Path(temp) / 'pcs.c'
    c.write_text(fixture + '\n' + macros + '\n' + function + '\n' + tests)
    binary = Path(temp) / 'pcs-test'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Wno-unused-parameter', str(c), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
