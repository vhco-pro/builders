"""Negative image checks use read-only tool fixtures; never mount a real disk here."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'


class ArtifactChecks(unittest.TestCase):
    def check_image(self, *, mode='default', changed=None, present=(), missing=(),
                    residue=(), cache_entries=(), expected_source='candidate', launch_fails=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            image = root / 'image.qcow2'
            image.write_bytes(b'fixture')
            files = {
                '/etc/machine-id': '', '/etc/hostname': 'localhost\n',
                '/etc/shadow': 'ubuntu:*:0:0:99999:7:::\n',
                '/etc/skel/.zshrc': 'source /etc/zshrc\n',
                '/etc/skel/.p10k.zsh': '# shared preset\n',
                '/root/.sudo_as_admin_successful': '',
                '/root/.cache/motd.legal-displayed': '',
                '/var/lib/builders/pds.json': json.dumps(dict(package='pds', version='1.0.0', source='candidate')),
                '/etc/ssh/sshd_config.d/00-pds-security.conf':
                    'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nPermitRootLogin no\n',
                '/etc/cron.d/pds-update': '0 0 * * * root /usr/local/sbin/pds-update >> /var/log/pds-update.log 2>&1\n',
            }
            exists = ['/etc/update-motd.d/90-pds', *present]
            if mode == 'default':
                exists += ['/etc/ssh/sshd_config.d/00-pds-security.conf', '/etc/cron.d/pds-update']
            files.update(changed or {})
            for path in missing:
                files.pop(path, None)
            fixture = root / 'fixture.json'
            fixture.write_text(json.dumps(dict(files=files, exists=exists, residue=list(residue),
                                              cache_entries=list(cache_entries))))
            stub = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with Path(os.environ['TEST_TOOL_LOG']).open('a') as log: log.write(json.dumps(sys.argv) + '\\n')
fixture=json.loads(Path(os.environ['TEST_FIXTURE']).read_text())
name=Path(sys.argv[0]).name
if name == 'qemu-img': print('{"format":"qcow2"}')
elif name == 'guestfish':
    if '--listen' in sys.argv:
        if os.environ.get('TEST_LAUNCH_FAIL') == '1': sys.exit(74)
        print('GUESTFISH_PID=12345; export GUESTFISH_PID')
    elif sys.argv[-1] == 'exit': pass
    elif 'cat' in sys.argv:
        if sys.argv[-1] not in fixture['files']: sys.exit(1)
        print(fixture['files'][sys.argv[-1]], end='')
    elif 'ls' in sys.argv:
        values = fixture['residue'] if sys.argv[-1] == '/root' else fixture['cache_entries'] if sys.argv[-1] == '/root/.cache' else []
        print('\\n'.join(values))
    elif 'glob-expand' in sys.argv:
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
            result = subprocess.run(['bash', str(SCRIPTS / 'check-image.sh'), str(image), mode, '1.0.0', expected_source],
                                  text=True, capture_output=True, timeout=15,
                                  env={**os.environ, 'PATH': f'{root}:/usr/bin:/bin', 'TEST_FIXTURE': str(fixture),
                                       'TEST_TOOL_LOG': str(root / 'tool-calls'),
                                       'TEST_LAUNCH_FAIL': '1' if launch_fails else '0'})
            result.tool_calls = [json.loads(line) for line in (root / 'tool-calls').read_text().splitlines()]
            return result

    def test_default_and_custom_sealed_artifacts_pass(self):
        for mode in ('default', 'custom'):
            result = self.check_image(mode=mode)
            self.assertEqual(result.returncode, 0, result.stderr)
        result = self.check_image(residue=('.bashrc', '.profile', '.sudo_as_admin_successful', '.cache'),
                                  cache_entries=('motd.legal-displayed',))
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

    def test_cloud_init_network_and_instance_state_fail_offline_inspection(self):
        for path in ('/etc/netplan/50-cloud-init.yaml', '/var/lib/cloud/instance',
                     '/var/lib/cloud/instances'):
            with self.subTest(path=path):
                self.assertNotEqual(self.check_image(present=(path,)).returncode, 0)

    def test_wrong_policy_or_custom_policy_leak_fails(self):
        self.assertNotEqual(self.check_image(changed={
            '/etc/ssh/sshd_config.d/00-pds-security.conf': 'PasswordAuthentication yes\n'}).returncode, 0)
        self.assertNotEqual(self.check_image(mode='custom', present=('/etc/cron.d/pds-update',)).returncode, 0)

    def test_missing_identity_evidence_and_unexpected_home_state_fail(self):
        self.assertNotEqual(self.check_image(missing=('/etc/machine-id',)).returncode, 0)
        for residue in ('.config', '.kube', '.krew', '.zsh_history', '.gitconfig'):
            with self.subTest(residue=residue):
                self.assertNotEqual(self.check_image(residue=(residue,)).returncode, 0)
        self.assertNotEqual(self.check_image(residue=('.cache',), cache_entries=('private-build-cache',)).returncode, 0)

    def test_candidate_cannot_pass_a_signed_release_check(self):
        self.assertNotEqual(self.check_image(expected_source='signed-repository').returncode, 0)
        metadata = json.dumps(dict(package='pds', version='1.0.0', source='signed-repository'))
        result = self.check_image(expected_source='signed-repository', changed={
            '/var/lib/builders/pds.json': metadata})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_one_read_only_session_is_closed_on_success_and_failure(self):
        for changed in (None, {'/etc/machine-id': 'baked-id'}):
            result = self.check_image(changed=changed)
            calls = [call for call in result.tool_calls if Path(call[0]).name == 'guestfish']
            self.assertEqual(sum('--listen' in call for call in calls), 1)
            self.assertIn('--ro', calls[0])
            self.assertEqual(calls[-1][-1], 'exit')
            self.assertTrue(all('--remote=12345' in call for call in calls[1:]))
            self.assertFalse(any(Path(call[0]).name == 'virt-cat' for call in result.tool_calls))
        result = self.check_image(launch_fails=True)
        self.assertEqual(result.returncode, 74)
        self.assertFalse(any('--remote=12345' in call for call in result.tool_calls))

    def test_fresh_instance_check_exists_and_rejects_unknown_recipe(self):
        result = subprocess.run(['bash', str(SCRIPTS / 'check-instance.sh'), 'unknown'],
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == '__main__':
    unittest.main()
