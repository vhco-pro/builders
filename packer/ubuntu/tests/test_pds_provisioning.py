"""Exercise package refusals and recipe execution without host or VM mutations."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

UBUNTU = Path(__file__).resolve().parents[1]
SCRIPTS = UBUNTU / 'scripts'
FINGERPRINT = '37C7D029C0FE4DB0E66E5F72AFA1101D94CBF301'


class PdsProvisioning(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.calls = self.root / 'calls'
        self.settings = self.root / 'settings.json'
        self.inputs = self.root / 'inputs'
        self.inputs.mkdir()
        (self.inputs / 'repository-key.asc').write_text('fixture-public-key\n')
        (self.inputs / 'candidate.deb').write_bytes(b'fixture-deb')
        self.values = dict(version='1.0.0', repository='https://example.test/apt/',
                           key_fingerprint=FINGERPRINT,
                           candidate_sha256=hashlib.sha256(b'fixture-deb').hexdigest(),
                           motd_preset='vhco', kubectl_channel='1.37')
        self.lib = self.root / 'init.sh'
        self.lib.write_text('''record() { printf '%s\\n' "$*" >> "$TEST_CALLS"; }
install_zi() { record zi; }
configure_zsh() { record zsh; }
setup_motd_preset() { record "motd $*"; }
install_gh() { record gh; }
install_kubectl() { record "kubectl $*"; }
update_system_cron_entry() { record updates; }
restricted_ssh_security_profile() { pds_before_ssh_policy; record ssh; }
''')
        self.env = {**os.environ, 'PATH': f'{self.root}:/usr/bin:/bin',
                    'TEST_CALLS': str(self.calls), 'TEST_FINGERPRINT': FINGERPRINT,
                    'TEST_PACKAGE': 'pds', 'TEST_VERSION': '1.0.0',
                    'TEST_INSTALLED_VERSION': '1.0.0', 'TEST_PID': '123'}
        self.stub('apt-get', 'printf "apt %s\\n" "$*" >> "$TEST_CALLS"')
        self.stub('dpkg', 'echo amd64')
        self.stub('install', 'printf "install %s\\n" "$*" >> "$TEST_CALLS"')
        self.stub('dpkg-deb', '''case "${@: -1}" in
Package) echo "$TEST_PACKAGE";; Version) echo "$TEST_VERSION";; Architecture) echo all;; esac''')
        self.stub('dpkg-query', '''printf 'install ok installed\\t%s\\tall\\n' "$TEST_INSTALLED_VERSION"''')
        self.stub('gpg', '''if [[ "$*" == *--show-keys* ]]; then
printf 'pub::::::::::\\nfpr:::::::::%s:\\n' "$TEST_FINGERPRINT"
else while [[ $# -gt 0 ]]; do
if [[ "$1" == --output ]]; then touch "$2"; break; fi; shift
done; fi''')
        self.stub('systemctl', '''if [[ "$1" == is-active ]]; then exit 0; fi
printf 'MainPID=%s\\nActiveEnterTimestampMonotonic=100\\nExecMainStartTimestampMonotonic=99\\n' "$TEST_PID"''')
        self.stub('journalctl', '''if [[ "$*" == *--show-cursor* ]]; then echo '-- cursor: fixture-cursor'
else printf '%s' "${TEST_JOURNAL:-}"; fi''')

    def stub(self, name, body):
        file = self.root / name
        file.write_text('#!/bin/bash\nset -euo pipefail\n' + body + '\n')
        file.chmod(0o755)

    def run_script(self, name, *args, env=None):
        self.settings.write_text(json.dumps(self.values))
        return subprocess.run(['bash', str(SCRIPTS / name), *map(str, args)],
                              env={**self.env, **(env or {})}, text=True,
                              capture_output=True, timeout=15)

    def package(self, env=None):
        return self.run_script('install-pds.sh', self.settings, self.inputs, env=env)

    def recipe(self, path, env=None):
        return self.run_script('run-recipe.sh', self.settings, self.lib, path,
                               self.root / 'runtime', env=env)

    def test_candidate_identity_and_retained_signed_source(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text()
        self.assertIn(str(self.inputs / 'candidate.deb'), calls)
        self.assertIn('/etc/apt/sources.list.d/pds.list', calls)
        self.assertIn('candidate', result.stdout.lower())

    def test_wrong_checksum_name_version_and_installed_identity_fail(self):
        self.values['candidate_sha256'] = '0' * 64
        self.assertNotEqual(self.package().returncode, 0)
        self.assertFalse(self.calls.exists())
        self.values['candidate_sha256'] = hashlib.sha256(b'fixture-deb').hexdigest()
        for variable, value in [('TEST_PACKAGE', 'other'), ('TEST_VERSION', '2.0.0'),
                                ('TEST_INSTALLED_VERSION', '2.0.0')]:
            with self.subTest(variable=variable):
                self.assertNotEqual(self.package(env={variable: value}).returncode, 0)

    def test_trust_failure_and_missing_candidate_have_no_install_fallback(self):
        result = self.package(env={'TEST_FINGERPRINT': '0' * 40})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())
        (self.inputs / 'candidate.deb').unlink()
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_repository_route_requests_exact_version(self):
        self.values['candidate_sha256'] = ''
        (self.inputs / 'candidate.deb').unlink()
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('pds=1.0.0', self.calls.read_text())
        self.assertIn('signed-repository', result.stdout)

    def test_default_and_custom_recipe_select_different_functions(self):
        default = self.recipe(UBUNTU / 'recipes/default.sh')
        self.assertEqual(default.returncode, 0, default.stderr)
        self.assertEqual(self.calls.read_text().splitlines(),
                         ['zi', 'zsh', 'motd vhco', 'gh', 'kubectl 1.37 --system', 'updates', 'ssh'])
        self.calls.unlink()
        custom = self.recipe(UBUNTU / 'recipes/custom.example.sh')
        self.assertEqual(custom.returncode, 0, custom.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ['zi', 'zsh', 'motd vhco'])
        self.assertFalse((self.root / 'runtime/ssh-policy.json').exists())

    def test_missing_recipe_library_and_selected_call_fail(self):
        result = self.recipe(self.root / 'missing')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())
        self.lib.write_text('return 7\n')
        self.assertNotEqual(self.recipe(UBUNTU / 'recipes/default.sh').returncode, 0)
        self.lib.write_text('install_zi() { return 43; }; configure_zsh() { touch "$TEST_CALLS"; }\n')
        self.assertNotEqual(self.recipe(UBUNTU / 'recipes/default.sh').returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_custom_recipe_cannot_hide_later_ssh_restart_or_reload(self):
        recipe = self.root / 'late-service-operation.sh'
        for action in ('export TEST_PID=456', "export TEST_JOURNAL='Reloaded OpenBSD Secure Shell server.'"):
            recipe.write_text(f'restricted_ssh_security_profile\n{action}\nrestricted_ssh_security_profile\n')
            self.assertNotEqual(self.recipe(recipe).returncode, 0)


if __name__ == '__main__':
    unittest.main()
