"""Verify the actual qemu-img export path with disposable tiny disk images."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/export-raw.sh'


class RawExport(unittest.TestCase):
    def test_export_is_optional_and_does_not_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            qcow = Path(tmp) / 'disk.qcow2'
            raw = qcow.with_suffix('.raw')
            subprocess.run(
                ['qemu-img', 'create', '-f', 'qcow2', str(qcow), '2M'],
                check=True, capture_output=True,
            )
            env = {
                **os.environ,
                'BUILD_QEMU_IMAGE': str(qcow),
                'BUILD_OUTPUT_RAW': 'false',
            }
            subprocess.run([str(SCRIPT)], env=env, check=True)
            self.assertFalse(raw.exists())

            env['BUILD_OUTPUT_RAW'] = 'true'
            subprocess.run([str(SCRIPT)], env=env, check=True)
            info = json.loads(subprocess.check_output(
                ['qemu-img', 'info', '--output=json', str(raw)],
            ))
            self.assertEqual(info['format'], 'raw')
            self.assertEqual(info['virtual-size'], 2 * 1024 * 1024)

            raw.write_bytes(b'preserve existing artifact')
            result = subprocess.run(
                [str(SCRIPT)], env=env, capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(raw.read_bytes(), b'preserve existing artifact')


if __name__ == '__main__':
    unittest.main(verbosity=2)
