"""Do not confuse datasource deprecations with a failed first boot."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/wait-cloud-init.sh'


class CloudInitReadiness(unittest.TestCase):
    def wait(self, code, state, raw=False):
        with tempfile.TemporaryDirectory() as tmp:
            stub = Path(tmp) / 'cloud-init'
            calls = Path(tmp) / 'calls'
            stub.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_CALLS'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1] == 'status':
    print(os.environ['TEST_STATE'])
    sys.exit(int(os.environ['TEST_CODE']))
''')
            stub.chmod(0o755)
            env = {
                **os.environ,
                'PATH': f'{tmp}:/usr/bin:/bin',
                'TEST_CALLS': str(calls),
                'TEST_STATE': state if raw else json.dumps(state),
                'TEST_CODE': str(code),
            }
            result = subprocess.run(
                ['bash', str(SCRIPT)], env=env, capture_output=True,
                text=True, timeout=10,
            )
            commands = [json.loads(line) for line in calls.read_text().splitlines()]
            return result, commands

    def test_accepts_clean_boot(self):
        result, calls = self.wait(0, {
            'status': 'done', 'errors': [], 'recoverable_errors': {},
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)

    def test_accepts_deprecation_only_boot(self):
        result, calls = self.wait(2, {
            'status': 'done', 'errors': [],
            'recoverable_errors': {'DEPRECATED': ["Use 'users' list instead."]},
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn('deprecation', result.stdout.lower())

    def test_rejects_other_recoverable_errors(self):
        for errors in (
            {'WARNING': ['Package installation failed.']},
            {'DEPRECATED': ['Old input.'], 'WARNING': ['Package installation failed.']},
            {},
        ):
            with self.subTest(errors=errors):
                result, calls = self.wait(2, {
                    'status': 'done', 'errors': [], 'recoverable_errors': errors,
                })
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)

    def test_rejects_fatal_boot_error(self):
        result, calls = self.wait(1, {
            'status': 'error', 'errors': ['Failed to configure the guest.'],
            'recoverable_errors': {},
        })
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)

    def test_rejects_warnings_even_with_success_exit_code(self):
        result, calls = self.wait(0, {
            'status': 'done', 'errors': [],
            'recoverable_errors': {'WARNING': ['Incomplete configuration.']},
        })
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)

    def test_rejects_incomplete_or_invalid_result(self):
        for state in (
            {'status': 'done'},
            {'status': 'running', 'errors': [], 'recoverable_errors': {}},
            {'status': 'done', 'errors': {}, 'recoverable_errors': {}},
            {'status': 'done', 'errors': [], 'recoverable_errors': []},
            'invalid result',
        ):
            with self.subTest(state=state):
                result, calls = self.wait(0, state)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)

    def test_rejects_multiple_status_results(self):
        state = {'status': 'done', 'errors': [], 'recoverable_errors': {}}
        result, calls = self.wait(0, json.dumps(state) + '\n' + json.dumps(state), raw=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
