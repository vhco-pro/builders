"""Every advertised fresh-user probe must affect the Zsh check's exit status."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/check-user-shell.zsh'


class UserShell(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which('zsh'):
            raise RuntimeError('Install Zsh to run the fresh-user probe regression checks.')

    def probe(self, mode='default', change='', fail=''):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / '.p10k.zsh').write_text('# preset\n')
            log = home / 'calls'
            setup = '''zi() { :; }; p10k() { :; }
alias k=kubectl
__start_kubectl() { :; }
export KREW_ROOT=/usr/local/share/pds/krew
kubectl() {
  print -r -- "$*" >> "$TEST_CALLS"
  [[ "$*" != "$TEST_FAIL" ]]
}
'''
            command = setup + change + '\nsource ' + shlex.quote(str(SCRIPT)) + ' ' + mode
            result = subprocess.run(['zsh', '-dflic', command], text=True, capture_output=True,
                                    timeout=10, env={**os.environ, 'HOME': tmp,
                                                     'TEST_CALLS': str(log), 'TEST_FAIL': fail})
            return result, log.read_text().splitlines() if log.exists() else []

    def test_default_requires_every_shell_and_tool_probe(self):
        result, calls = self.probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ['version --client', 'krew list', 'neat --help',
                                 'view-secret --help', 'stern --version'])

    def test_earlier_missing_capabilities_fail_the_whole_check(self):
        for change in ('unfunction zi', 'unfunction p10k', 'unalias k',
                       'unfunction __start_kubectl', 'export KREW_ROOT=/wrong',
                       'rm "$HOME/.p10k.zsh"'):
            with self.subTest(change=change):
                result, _ = self.probe(change=change)
                self.assertNotEqual(result.returncode, 0)
        for fail in ('version --client', 'krew list', 'neat --help',
                     'view-secret --help', 'stern --version'):
            with self.subTest(fail=fail):
                result, _ = self.probe(fail=fail)
                self.assertNotEqual(result.returncode, 0)

    def test_custom_recipe_checks_its_selected_shell_only(self):
        result, calls = self.probe(mode='custom')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
