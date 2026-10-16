#!/usr/bin/env python3
"""Offline integration tests; no downloads, builds, credentials or uploads."""
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
MOCK_MAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args=sys.argv[1:]
with open(os.environ['MOCK_CALLS'], 'a') as f:
    f.write(json.dumps(args)+'\n')
if 'val.BOARD' in args:
    print('qualcommax\nipq50xx\nstaging_dir/target\naarch64_cortex-a53')
elif 'print-build-metadata' in args:
    print('SNAPSHOT\n'+os.environ.get('MOCK_DISTRIB','OpenWrt'))
elif 'image' in args or 'manifest' in args:
    values=dict(a.split('=',1) for a in args if '=' in a)
    packages={p for p in values['PACKAGES'].split() if not p.startswith('-')}
    packages.update(['base-files','libc','kernel'])
    if os.environ.get('MOCK_RESOLVED_EQUAL'):
        packages.discard('luci-app-demo')
        packages.discard('luci-i18n-demo-zh-cn')
    manifest=''.join(p+' - 1.0\n' for p in sorted(packages))
    if 'manifest' in args:
        print(manifest,end='')
    else:
        target=pathlib.Path(values['BIN_DIR'])
        target.mkdir(parents=True,exist_ok=True)
        extra=values.get('EXTRA_IMAGE_NAME','')
        name='openwrt-'+(extra+'-' if extra else '')+'jdcloud_ax3000'
        (target/(name+'.bin')).write_bytes(b'firmware')
        (target/(name+'.manifest')).write_text(manifest)
'''
MOCK_AWS = r'''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['MOCK_UPLOADS'],'a') as f:
    f.write(json.dumps(sys.argv[1:])+'\n')
'''


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.ib = self.root / 'imagebuilder'
        self.upload = self.root / 'upload'
        self.calls = self.root / 'calls.jsonl'
        self.uploads = self.root / 'uploads.jsonl'
        self.source.mkdir()
        self.bin = self.root / 'mock-bin'
        self.bin.mkdir()
        for name, text in [('make', MOCK_MAKE), ('aws', MOCK_AWS)]:
            path = self.bin / name
            path.write_text(text)
            path.chmod(0o755)
        scripts = self.source / 'scripts'
        scripts.mkdir()
        (scripts / 'feeds').write_text('#!/bin/sh\nexit 0\n')
        (scripts / 'feeds').chmod(0o755)
        self.env = os.environ | {
            'PATH': str(self.bin) + ':' + os.environ['PATH'],
            'SOURCE_DIR': str(self.source),
            'IMAGEBUILDER_DIR': str(self.ib),
            'UPLOAD_DIR': str(self.upload),
            'MOCK_CALLS': str(self.calls),
            'MOCK_UPLOADS': str(self.uploads),
            'GITHUB_OUTPUT': str(self.root / 'outputs'),
            'JOBS': '2',
        }
        self.target = self.source / 'bin/targets/qualcommax/ipq50xx'
        self.target.mkdir(parents=True)
        (self.target / 'openwrt-jdcloud_ax3000.manifest').write_text(
            'base-files - 1.0\nlibc - 1.0\nkernel - 1.0\nluci - 1.0\n')
        self.config = (
            'CONFIG_TARGET_qualcommax_ipq50xx_DEVICE_jdcloud_ax3000=y\n'
            'CONFIG_IB=y\nCONFIG_IB_STANDALONE=y\nCONFIG_PACKAGE_luci=y\n'
            '# CONFIG_PACKAGE_dnsmasq is not set\n')
        (self.source / 'kmods.config').write_text('CONFIG_PACKAGE_luci=m\nCONFIG_PACKAGE_dnsmasq=y\n')
        with tarfile.open(self.target / 'openwrt-imagebuilder.tar.gz', 'w:gz') as archive:
            files = {
                'Makefile': '# fixture\n',
                '.packageinfo': 'Package: luci\nPackage: luci-app-demo\nPackage: luci-i18n-demo-zh-cn\nPackage: dnsmasq\n',
                'packages/demo.apk': 'package fixture',
            }
            for name, text in files.items():
                content = text.encode()
                info = tarfile.TarInfo('imagebuilder/' + name)
                info.size = len(content)
                archive.addfile(info, io.BytesIO(content))

    def run_script(self, name, success=True):
        result = subprocess.run(['bash', str(PROJECT / 'scripts' / name)], env=self.env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def build(self, module=False):
        config = self.config
        if module:
            config += 'CONFIG_PACKAGE_luci-app-demo=m\nCONFIG_PACKAGE_FAKE_OPTION=m\n'
        (self.source / 'jdcloud_ax3000.config').write_text(config)
        return self.run_script('build_openwrt.sh')

    def images(self):
        return [c for c in map(json.loads, self.calls.read_text().splitlines()) if 'image' in c]

    def test_different_package_sets_produce_mini_and_full(self):
        self.build(module=True)
        images = self.images()
        self.assertEqual(len(images), 2)
        self.assertIn('EXTRA_IMAGE_NAME=mini', images[0])
        self.assertIn('EXTRA_IMAGE_NAME=', images[1])
        self.assertNotIn('luci-app-demo', (self.ib / 'mini.packages').read_text())
        self.assertIn('luci-app-demo', (self.ib / 'full.packages').read_text())
        self.assertIn('luci-i18n-demo-zh-cn', (self.ib / 'full.packages').read_text())
        self.assertNotIn('FAKE_OPTION', (self.ib / 'full.packages').read_text())
        self.assertTrue(any('-dnsmasq' in arg for arg in images[0]))
        merged = (self.source / '.config').read_text()
        self.assertNotIn('CONFIG_PACKAGE_luci=m', merged)
        self.assertNotIn('CONFIG_PACKAGE_dnsmasq=y', merged)
        self.assertEqual(len(list(self.upload.glob('*.bin'))), 2)
        checks = subprocess.run(['sha256sum', '-c', 'sha256sums'], cwd=self.upload,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(checks.returncode, 0, checks.stdout)
        calls = list(map(json.loads, self.calls.read_text().splitlines()))
        self.assertLess(next(i for i, c in enumerate(calls) if 'world' in c),
                        next(i for i, c in enumerate(calls) if 'target/imagebuilder/compile' in c))
        self.assertIn('distribution=openwrt', (self.root / 'outputs').read_text())

    def test_identical_lists_produce_only_unnamed_full(self):
        self.build()
        self.assertEqual(len(self.images()), 1)
        self.assertIn('EXTRA_IMAGE_NAME=', self.images()[0])
        self.assertFalse(any('mini' in p.name for p in self.upload.iterdir()))

    def test_identical_resolved_sets_produce_only_unnamed_full(self):
        self.env['MOCK_RESOLVED_EQUAL'] = '1'
        self.build(module=True)
        self.assertEqual(len(self.images()), 1)
        calls = list(map(json.loads, self.calls.read_text().splitlines()))
        self.assertEqual(sum('manifest' in c for c in calls), 2)

    def test_optional_extra_config(self):
        self.env['EXTRA_CONFIG_NAME'] = ''
        (self.source / 'kmods.config').unlink()
        self.build()
        self.assertEqual(len(self.images()), 1)

    def test_missing_config_fails_before_build(self):
        self.env['CONFIG_NAME'] = 'missing.config'
        self.run_script('build_openwrt.sh', success=False)
        self.assertFalse(self.calls.exists())

    def test_multiple_devices_fail(self):
        self.config += 'CONFIG_TARGET_qualcommax_ipq50xx_DEVICE_other=y\n'
        (self.source / 'jdcloud_ax3000.config').write_text(self.config)
        self.run_script('build_openwrt.sh', success=False)
        self.assertEqual(self.images(), [])

    def prepare_upload(self, distribution, apk=True):
        self.upload.mkdir()
        (self.upload / 'image.bin').write_bytes(b'firmware')
        self.env.update(MOCK_DISTRIB=distribution, REPO_BUCKET_NAME='test-bucket',
                        REPO_ACCOUNT_ID='test-account', REPO_ACCESS_KEY_ID='fake-key',
                        REPO_SECRET_ACCESS_KEY='fake-secret')
        kmods = self.target / 'packages'
        kmods.mkdir()
        index = 'packages.adb' if apk else 'Packages.gz'
        (kmods / index).touch()
        staging = self.source / 'staging_dir/target'
        staging.mkdir(parents=True)
        (staging / 'kernel.version').write_text('6.18.55~deadbeef-r1\n')
        extra = self.source / 'bin/packages/aarch64_cortex-a53/extra'
        extra.mkdir(parents=True)
        (extra / index).touch()

    def test_r2_distribution_and_kernel_abi_paths(self):
        for distribution in ['OpenWrt', 'ImmortalWrt']:
            with self.subTest(distribution=distribution):
                if not self.upload.exists():
                    self.prepare_upload(distribution)
                self.env['MOCK_DISTRIB'] = distribution
                self.uploads.write_text('')
                self.run_script('upload_openwrt.sh')
                calls = list(map(json.loads, self.uploads.read_text().splitlines()))
                destinations = [c[3] for c in calls]
                prefix = f's3://test-bucket/{distribution.lower()}/SNAPSHOT'
                self.assertEqual(destinations, [
                    prefix+'/targets/qualcommax/ipq50xx/',
                    prefix+'/targets/qualcommax/ipq50xx/kmods/6.18.55-1-deadbeef/',
                    prefix+'/packages/aarch64_cortex-a53/extra/'])
                self.assertTrue(all('--delete' not in c for c in calls))

    def test_opkg_target_repository_path(self):
        self.prepare_upload('OpenWrt', apk=False)
        self.run_script('upload_openwrt.sh')
        calls = list(map(json.loads, self.uploads.read_text().splitlines()))
        self.assertTrue(calls[1][3].endswith('/targets/qualcommax/ipq50xx/packages/'))

    def test_invalid_patch_set_fails(self):
        self.env['PATCHES_NAME'] = '../escape'
        self.run_script('apply-openwrt-patches.sh', success=False)


if __name__ == '__main__':
    unittest.main(verbosity=2)
