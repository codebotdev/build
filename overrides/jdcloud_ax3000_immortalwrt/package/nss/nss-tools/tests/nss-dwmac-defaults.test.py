"""Run the first-boot board table against a disposable uci state."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

source = Path(__file__).resolve().parents[4]
shell = os.environ.get("NSS_TEST_SH", "sh")
defaults = source / 'package/nss/nss-tools/files/nss-dwmac.defaults'
text = defaults.read_text(encoding='utf-8')
subprocess.run([shell, '-n', str(defaults)], check=True)
assert text.count('. /lib/functions.sh') == 1

# uci over a flat JSON map: 'network.cfg1.name' -> 'wan'. Anonymous sections
# are named here the way config_load names them.
uci = r'''#!/usr/bin/env python3
import json, os, sys
path = os.environ['UCI_STATE']
state = json.load(open(path))
args = [a for a in sys.argv[1:] if a != '-q']
op, key = args[0], (args[1] if len(args) > 1 else '')
if op == 'get':
    if key not in state:
        sys.exit(1)
    print(state[key])
    sys.exit(0)
if op == 'set':
    key, value = key.split('=', 1)
    state[key] = value
elif op == 'delete':
    # A section's options go with it, as they do under the real uci.
    for k in [k for k in state if k == key or k.startswith(key + '.')]:
        del state[k]
elif op == 'add':
    # uci add <config> <type>: a new anonymous section, its name on stdout
    i = 1
    while '%s.new%d' % (key, i) in state:
        i += 1
    name = 'new%d' % i
    state['%s.%s' % (key, name)] = args[2]
    print(name)
elif op == 'add_list':
    key, value = key.split('=', 1)
    state[key] = (state.get(key, '') + ' ' + value).strip()
elif op == 'sections':
    print(' '.join(k.split('.')[1] for k, v in state.items()
                   if k.count('.') == 1 and k.startswith(key + '.') and v == args[2]))
    sys.exit(0)
elif op != 'commit':
    raise SystemExit('unexpected uci call: %r' % (args,))
json.dump(state, open(path, 'w'))
'''
functions = r'''
board_name() { printf '%s\n' "$TEST_BOARD"; }
logger() { :; }
config_load() { CONFIG_LOADED="$1"; }
config_get() { eval "$1=\$(uci -q get $CONFIG_LOADED.$2.$3)"; }
config_foreach() {
	_fn="$1"; _type="$2"
	for _s in $(uci sections "$CONFIG_LOADED" "$_type"); do "$_fn" "$_s"; done
}
'''


with tempfile.TemporaryDirectory(prefix='ax3000-defaults-') as directory:
    tmp = Path(directory)
    (tmp / 'uci').write_text(uci)
    (tmp / 'uci').chmod(0o755)
    script = tmp / 'defaults.sh'
    script.write_text(text.replace('. /lib/functions.sh', functions))

    def run(state, board='jdcloud,ax3000'):
        state_file = tmp / 'state.json'
        state_file.write_text(json.dumps(state))
        env = dict(os.environ, TEST_BOARD=board, UCI_STATE=str(state_file),
                   PATH=str(tmp) + ':' + os.environ['PATH'])
        subprocess.run([shell, str(script)], env=env, check=True,
                       capture_output=True, text=True)
        return json.loads(state_file.read_text())

    base = {
        'nss.general': 'nss',
        'network.lan': 'interface', 'network.lan.device': 'br-lan',
        'network.lan.ipaddr': '192.168.1.1/24',
        'network.cfg1': 'device', 'network.cfg1.name': 'br-lan',
        'network.cfg1.ports': 'lan1 lan2 lan3',
        'network.wan': 'interface', 'network.wan.device': 'wan',
    }
    for topology in (None, 'lan-trunk', 'vlan-trunk', 'dsa'):
        for ports in ('eth1', 'lan1 lan2 lan3', 'lan1 lan2'):
            state = dict(base, **{'network.cfg1.ports': ports})
            if topology:
                state['nss.general.topology'] = topology
            for option in ('trunk', 'trunk_if', 'extra_ports', 'fabric',
                           'switch_args', 'switch_dev', 'vtu'):
                state['nss.general.' + option] = 'obsolete'
            result = run(state)
            assert result['nss.general.topology'] == 'dsa'
            assert result['network.cfg1.ports'] == ('lan1 lan2 lan3' if ports == 'eth1' else ports)
            assert result['network.lan.ipaddr'] == base['network.lan.ipaddr']
            assert result['network.wan.device'] == 'wan'
            for option in ('trunk', 'trunk_if', 'extra_ports', 'fabric',
                           'switch_args', 'switch_dev', 'vtu'):
                assert 'nss.general.' + option not in result
            assert run(result) == result

    custom = dict(base, **{'network.cfg1.ports': 'lan1 lan2',
                          'network.wan.device': 'wan.35',
                          'nss.general.enabled': '0',
                          'nss.general.wifi_offload': '0',
                          'nss.general.fw_mask': '0x3'})
    result = run(custom)
    for key in ('network.cfg1.ports', 'network.wan.device',
                'nss.general.enabled', 'nss.general.wifi_offload', 'nss.general.fw_mask'):
        assert result[key] == custom[key]
    assert run(base, board='other,board') == base

print('PASS: AX3000 DSA defaults, all legacy topology markers, stale-option removal, '
      'eth1 bridge repair, custom ports/WAN VLAN, offload choices and idempotence')
