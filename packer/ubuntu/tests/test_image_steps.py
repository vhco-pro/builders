"""Check image-step inputs and refusal of accidental sealing without host writes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'


class ImageSteps(unittest.TestCase):
    def test_install_uses_the_supplied_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            config = directory / 'selected image.yaml'
            config.write_text('#cloud-config\npackages: [git]\n')
            calls = directory / 'calls'
            stub = directory / 'cloud-init'
            stub.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_CALLS'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
''')
            stub.chmod(0o755)
            apt = directory / 'apt-get'
            apt.write_text('#!/bin/bash\nexit 0\n')
            apt.chmod(0o755)
            env = {**os.environ, 'PATH': f'{directory}:/usr/bin:/bin', 'TEST_CALLS': str(calls)}
            for args in ([], [str(directory / 'missing.yaml')]):
                with self.subTest(args=args):
                    result = subprocess.run(
                        ['bash', str(SCRIPTS / 'install.sh'), *args],
                        env=env, capture_output=True, timeout=10,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(calls.exists())
            subprocess.run(
                ['bash', str(SCRIPTS / 'install.sh'), str(config)],
                env=env, check=True, capture_output=True, timeout=10,
            )
            commands = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertTrue(commands)
            for command in commands:
                self.assertEqual(command[0], 'single')
                self.assertEqual(command[command.index('--file') + 1], str(config))

    def test_sealing_requires_an_explicit_image_build_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            calls = directory / 'calls'
            # If the guard regresses, intercept mutations and fail immediately.
            for name in ('usermod', 'rm', 'cloud-init', 'truncate', 'ln', 'sed', 'apt-get', 'find'):
                stub = directory / name
                stub.write_text('#!/bin/bash\nprintf "%s\\n" "$0" >> "$TEST_CALLS"\nexit 91\n')
                stub.chmod(0o755)
            env = {**os.environ, 'PATH': f'{directory}:/usr/bin:/bin', 'TEST_CALLS': str(calls)}
            for args in ([], ['--normal-install'], ['--image-build', 'unexpected']):
                with self.subTest(args=args):
                    result = subprocess.run(
                        ['bash', str(SCRIPTS / 'seal-image.sh'), *args],
                        env=env, capture_output=True, timeout=10,
                    )
                    self.assertEqual(result.returncode, 2)
                    self.assertFalse(calls.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
