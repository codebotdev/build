"""Check the built AX3000 DTB, preinit naming and NSS failure behavior.

Run after building the firmware: python3 package/nss/nss-tools/tests/ax3000-boot.test.py
The shell cases use disposable sysfs fixtures and never run the host's ip/modprobe.
"""
from pathlib import Path
import os
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parents[4]
files = root / 'package/nss/nss-tools/files'
shell = os.environ.get('NSS_TEST_SH', 'sh')

with tempfile.TemporaryDirectory(prefix='ax3000-boot-') as directory:
    tmp = Path(directory)
    net = tmp / 'net'
    (net / 'eth0/device/of_node').mkdir(parents=True)
    (net / 'eth0/device/of_node/label').write_bytes(b'wan\0')
    (net / 'eth1').mkdir()
    (net / 'lo').mkdir()
    preinit = (root / 'target/linux/qualcommax/ipq50xx/base-files/lib/preinit/04_set_netdev_label').read_text()
    preinit = preinit.replace('/sys/class/net/', str(net) + '/')
    result = subprocess.run([shell, '-s'], input='boot_hook_add() { :; }\nip() { echo "$*"; }\n' + preinit + '\nset_netdev_labels\n', text=True, capture_output=True, check=True)
    assert result.stdout.splitlines() == ['link set eth0 name wan'], result
    print('PASS: preinit renames the physical WAN, preserving eth1 and lo')

    init = (files / 'nss-dwmac.init').read_text()
    init = init.replace('. "${IPKG_INSTROOT}/lib/functions.sh"', ':').replace('. /lib/nss/functions.sh', ':')
    init = init.replace('/sys/class/net/', str(net) + '/')
    tagging = net / 'eth1/dsa/tagging'
    for name, topology, has_dsa in [('deferred DSA', 'dsa', False),
                                     ('legacy topology', 'lan-trunk', True),
                                     ('tagger failure', 'dsa', True)]:
        if has_dsa:
            tagging.parent.mkdir(exist_ok=True)
            tagging.write_text('qca')
        else:
            tagging.unlink(missing_ok=True)
        stubs = '''
board_name() { echo jdcloud,ax3000; }
uci() { echo "$test_topology"; }
logger() { :; }
wifi_load() { echo "wifi $1"; }
switch_to_8021q() { echo tagger; return 1; }
modprobe() { echo UNEXPECTED_MODPROBE; }
'''
        result = subprocess.run([shell, '-s'], input=init + stubs + '\ntest_topology=' + topology + '\nstart_service\n', text=True, capture_output=True)
        assert result.returncode == 1, (name, result)
        assert 'wifi 0' in result.stdout and 'UNEXPECTED' not in result.stdout, (name, result)
        print('PASS:', name, 'leaves the switch bound and loads host Wi-Fi')

# Read the actual flattened tree: checking just the aliases or compatible
# strings missed the mandatory phy-mode consumed by stmmac_probe_config_dt().
dtb = Path(os.environ.get('AX3000_TEST_DTB', str(root / 'build_dir/target-aarch64_cortex-a53_musl/linux-qualcommax_ipq50xx/image-ipq5018-ax3000.dtb')))
data = dtb.read_bytes()
magic, total, off_struct, off_strings = struct.unpack_from('>4I', data)
assert magic == 0xd00dfeed and total <= len(data)
pos, stack, props = off_struct, [], {}
while True:
    token, = struct.unpack_from('>I', data, pos)
    pos += 4
    if token == 1:
        end = data.index(0, pos)
        stack.append(data[pos:end].decode())
        pos = (end + 4) & ~3
    elif token == 2:
        stack.pop()
    elif token == 3:
        length, nameoff = struct.unpack_from('>2I', data, pos)
        pos += 8
        end = data.index(0, off_strings + nameoff)
        name = data[off_strings + nameoff:end].decode()
        props.setdefault('/' + '/'.join(stack[1:]), {})[name] = data[pos:pos + length]
        pos = (pos + length + 3) & ~3
    elif token == 4:
        continue
    elif token == 9:
        break
    else:
        raise AssertionError(('invalid FDT token', token))

aliases = props['/aliases']
wan = aliases['ethernet0'].rstrip(b'\0').decode()
lan = aliases['ethernet1'].rstrip(b'\0').decode()
for node in (wan, lan):
    assert props[node].get('phy-mode') == b'sgmii\0', (node, 'missing stmmac phy-mode')
    assert props[node]['status'] == b'okay\0'
assert props[wan]['label'] == b'wan\0'
assert props[lan + '/fixed-link']['speed'] == struct.pack('>I', 1000)
assert any(p.get('ethernet') == props[lan]['phandle'] for p in props.values())
assert not any(b'qcom,nss-dp' in p.get('compatible', b'') for p in props.values())
pcs = (root / 'target/linux/qualcommax/files/drivers/net/pcs/pcs-qca-uniphy.c').read_text()
assert 'uniphy->port_pcs[i].pcs.neg_mode = true;' in pcs
print('PASS: final DTB supplies both stmmac PHY modes and the DSA conduit; 6.12 PCS negotiation is enabled')
