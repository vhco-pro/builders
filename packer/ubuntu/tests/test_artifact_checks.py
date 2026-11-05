"""Negative image checks use read-only tool fixtures; never mount a real disk here."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'


class ArtifactChecks(unittest.TestCase):
    def check_image(self, *, mode='default', changed=None, present=()):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            image = root / 'image.qcow2'
            image.write_bytes(b'fixture')
            files = {
                '/etc/machine-id': '', '/etc/hostname': 'localhost\n',
                '/etc/shadow': 'ubuntu:*:0:0:99999:7:::\n',
                '/etc/skel/.zshrc': 'source /etc/zshrc\n',
                '/etc/skel/.p10k.zsh': '# shared preset\n',
                '/var/lib/builders/pds.json': json.dumps(dict(package='pds', version='1.0.0', source='candidate')),
                '/etc/ssh/sshd_config.d/00-pds-security.conf':
                    'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nPermitRootLogin no\n',
                '/etc/cron.d/pds-update': '0 0 * * * root /usr/local/sbin/pds-update >> /var/log/pds-update.log 2>&1\n',
            }
            exists = ['/etc/update-motd.d/90-pds', *present]
            if mode == 'default':
                exists += ['/etc/ssh/sshd_config.d/00-pds-security.conf', '/etc/cron.d/pds-update']
            files.update(changed or {})
            fixture = root / 'fixture.json'
            fixture.write_text(json.dumps(dict(files=files, exists=exists)))
            stub = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
fixture=json.loads(Path(os.environ['TEST_FIXTURE']).read_text())
name=Path(sys.argv[0]).name
if name == 'qemu-img': print('{"format":"qcow2"}')
elif name == 'guestfish':
    if 'glob-expand' in sys.argv:
        print(' '.join(p for p in fixture['exists'] if p.startswith('/etc/ssh/ssh_host_')))
    else: print('true' if sys.argv[-1] in fixture['exists'] else 'false')
elif name == 'virt-cat':
    if sys.argv[-1] not in fixture['files']: sys.exit(1)
    print(fixture['files'][sys.argv[-1]], end='')
'''
            for name in ('qemu-img', 'guestfish', 'virt-cat'):
                command = root / name
                command.write_text(stub)
                command.chmod(0o755)
            return subprocess.run(['bash', str(SCRIPTS / 'check-image.sh'), str(image), mode, '1.0.0'],
                                  text=True, capture_output=True, timeout=15,
                                  env={**os.environ, 'PATH': f'{root}:/usr/bin:/bin', 'TEST_FIXTURE': str(fixture)})

    def test_default_and_custom_sealed_artifacts_pass(self):
        for mode in ('default', 'custom'):
            result = self.check_image(mode=mode)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_machine_identity_build_access_and_wrong_package_fail(self):
        for changed, present in [({'/etc/machine-id': 'baked-id'}, ()),
                                 ({'/etc/shadow': 'ubuntu:build-password:0:0:99999:7:::\n'}, ()),
                                 ({'/var/lib/builders/pds.json': '{"package":"pds","version":"wrong"}'}, ()),
                                 ({}, ('/root/.ssh/authorized_keys',)),
                                 ({}, ('/etc/ssh/ssh_host_ed25519_key',)),
                                 ({'/etc/skel/.zshrc': 'source /root/.zshrc'}, ()),
                                 ({}, ('/var/lib/cloud/seed',)),
                                 ({}, ('/etc/ssh/sshd_config.d/50-cloud-init.conf',))]:
            with self.subTest(changed=changed, present=present):
                self.assertNotEqual(self.check_image(changed=changed, present=present).returncode, 0)

    def test_wrong_policy_or_custom_policy_leak_fails(self):
        self.assertNotEqual(self.check_image(changed={
            '/etc/ssh/sshd_config.d/00-pds-security.conf': 'PasswordAuthentication yes\n'}).returncode, 0)
        self.assertNotEqual(self.check_image(mode='custom', present=('/etc/cron.d/pds-update',)).returncode, 0)

    def test_fresh_instance_check_exists_and_rejects_unknown_recipe(self):
        result = subprocess.run(['bash', str(SCRIPTS / 'check-instance.sh'), 'unknown'],
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == '__main__':
    unittest.main()
