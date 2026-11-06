"""Exercise the bootstrap's refusal paths with command stubs; never access Proxmox."""
import os
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/create-base-template.sh'


class BaseTemplateSafety(unittest.TestCase):
    def run_script(self, vmid=None, available=True, host='root@pve-test', image=None,
                   allocation='/var/tmp/builders-base.testing1', allocation_status=0,
                   upload_status=0, cleanup_status=0):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            calls = directory / 'calls'
            for command in ('qm', 'curl', 'virt-customize', 'pvesh', 'ssh'):
                stub = directory / command
                stub.write_text('#!/bin/bash\n'
                                'printf "%s %s\\n" "${0##*/}" "$*" >> "$CALLS"\n'
                                'if [[ "$*" == *--check* || "${0##*/}" == pvesh ]]; then exit "$AVAILABLE"; fi\n'
                                'if [[ "$*" == *mktemp* ]]; then printf "%s\\n" "$ALLOCATION"; exit "$ALLOCATION_STATUS"; fi\n'
                                'if [[ "$*" == *"cat >"* ]]; then exit "$UPLOAD_STATUS"; fi\n'
                                'if [[ "$*" == *"rm -rf"* ]]; then exit "$CLEANUP_STATUS"; fi\n')
                stub.chmod(0o755)
            env = {**os.environ, 'PATH': f'{directory}:/usr/bin:/bin',
                   'CALLS': str(calls), 'AVAILABLE': '0' if available else '1',
                   'ALLOCATION': allocation, 'ALLOCATION_STATUS': str(allocation_status),
                   'UPLOAD_STATUS': str(upload_status), 'CLEANUP_STATUS': str(cleanup_status)}
            env.pop('BASE_VMID', None)
            env.pop('PVE_HOST', None)
            env.pop('BASE_IMAGE_DIR', None)
            if host is not None:
                env['PVE_HOST'] = host
            if image is not None:
                env['BASE_IMAGE_DIR'] = str(image)
            if vmid is not None:
                env['BASE_VMID'] = str(vmid)
            result = subprocess.run(['bash', str(SCRIPT)], env=env,
                                    capture_output=True, text=True, timeout=10)
            return result, calls.read_text() if calls.exists() else ''

    def test_requires_explicit_id(self):
        result, calls = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, '')

    def test_rejects_invalid_id(self):
        for vmid in ('0', '99', 'not-an-id', '100; echo unsafe'):
            with self.subTest(vmid=vmid):
                result, calls = self.run_script(vmid)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, '')

    def test_refuses_used_id_without_download_or_delete(self):
        result, calls = self.run_script(100, available=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--check 100', calls)
        self.assertNotIn('qm ', calls)
        self.assertNotIn('curl ', calls)
        self.assertNotIn('virt-customize ', calls)

    def test_requires_remote_host(self):
        result, calls = self.run_script(9000, host=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PVE_HOST', result.stderr)
        self.assertEqual(calls, '')

    def test_rejects_corrupt_recovery_bundle_before_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / 'base.qcow2').write_bytes(b'changed image')
            (directory / 'base-image.sha256').write_text('0' * 64 + '  base.qcow2\n')
            result, calls = self.run_script(9000, image=directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('cat >', calls)
            self.assertNotIn('--import', calls)

    def test_reuses_verified_bundle_without_preparing_an_image(self):
        with tempfile.TemporaryDirectory(prefix='recovery bundle ') as tmp:
            directory = Path(tmp)
            image = b'verified recovery fixture'
            (directory / 'base.qcow2').write_bytes(image)
            (directory / 'base-image.sha256').write_text(
                hashlib.sha256(image).hexdigest() + '  base.qcow2\n')
            result, calls = self.run_script(9000, image=directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('--import 9000', calls)
            self.assertNotIn('virt-customize ', calls)
            self.assertNotIn('curl ', calls)

    def test_failed_allocation_never_cleans_an_unvalidated_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            image = b'verified fixture'
            (directory / 'base.qcow2').write_bytes(image)
            (directory / 'base-image.sha256').write_text(
                hashlib.sha256(image).hexdigest() + '  base.qcow2\n')
            result, calls = self.run_script(9000, image=directory,
                                            allocation='/untrusted-output', allocation_status=1)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('rm -rf', calls)
            self.assertNotIn('cat >', calls)

    def test_failed_upload_cleans_only_its_staging_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            image = b'verified fixture'
            (directory / 'base.qcow2').write_bytes(image)
            (directory / 'base-image.sha256').write_text(
                hashlib.sha256(image).hexdigest() + '  base.qcow2\n')
            result, calls = self.run_script(9000, image=directory, upload_status=1)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("rm -rf -- '/var/tmp/builders-base.testing1'", calls)
            self.assertNotIn('--import', calls)

    def test_reports_failed_cleanup_instead_of_succeeding(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            image = b'verified fixture'
            (directory / 'base.qcow2').write_bytes(image)
            (directory / 'base-image.sha256').write_text(
                hashlib.sha256(image).hexdigest() + '  base.qcow2\n')
            result, _ = self.run_script(9000, image=directory, cleanup_status=1)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('/var/tmp/builders-base.testing1', result.stderr)

    def test_refuses_a_partial_bundle_before_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / 'base.qcow2').write_bytes(b'incomplete preparation')
            result, calls = self.run_script(9000, image=directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('cat >', calls)
            self.assertNotIn('--import', calls)


class RemoteImportSafety(unittest.TestCase):
    def run_import(self, available=True, corrupt=False, disk_size='32G'):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            calls = directory / 'calls'
            subprocess.run(['qemu-img', 'create', '-f', 'qcow2',
                            str(directory / 'base.qcow2'), '4M'], check=True, capture_output=True)
            image = (directory / 'base.qcow2').read_bytes()
            digest = '0' * 64 if corrupt else hashlib.sha256(image).hexdigest()
            (directory / 'base-image.sha256').write_text(digest + '  base.qcow2\n')
            for command in ('pvesh', 'qm'):
                stub = directory / command
                stub.write_text('#!/bin/bash\n'
                                'printf "%s %s\\n" "${0##*/}" "$*" >> "$CALLS"\n'
                                'if [[ "${0##*/}" == pvesh ]]; then exit "$AVAILABLE"; fi\n'
                                'if [[ "$1" == config ]]; then echo "unused0: local-lvm:vm-9000-disk-0"; fi\n')
                stub.chmod(0o755)
            env = {**os.environ, 'PATH': f'{directory}:/usr/bin:/bin',
                   'CALLS': str(calls), 'AVAILABLE': '0' if available else '1'}
            result = subprocess.run(
                ['bash', str(SCRIPT.with_name('import-base-template.sh')), '--import',
                 '9000', str(directory), 'base-fixture', 'local-lvm', 'vmbr0', disk_size],
                env=env, capture_output=True, text=True, timeout=10,
            )
            return result, calls.read_text() if calls.exists() else ''

    def test_rechecks_id_before_creating_any_vm(self):
        result, calls = self.run_import(available=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('qm ', calls)

    def test_rejects_upload_corruption_before_creating_any_vm(self):
        result, calls = self.run_import(corrupt=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('qm ', calls)

    def test_imports_verified_disk_as_a_cloud_init_template(self):
        result, calls = self.run_import()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('qm create 9000', calls)
        self.assertIn('--ide2 local-lvm:cloudinit', calls)
        self.assertTrue(calls.endswith('qm template 9000\n'))
        self.assertNotIn('destroy', calls)

    def test_refuses_disk_shrink_before_creating_any_vm(self):
        result, calls = self.run_import(disk_size='1M')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('qm ', calls)


class BaseImagePreparationSafety(unittest.TestCase):
    def run_prepare(self, existing):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            target = directory / 'base bundle'
            calls = directory / 'calls'
            if existing:
                target.mkdir()
                (target / 'sentinel').write_text('keep existing artifact')
            curl = directory / 'curl'
            curl.write_text('''#!/bin/bash
printf 'curl\\n' >> "$CALLS"
url="${!#}"
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
done
if [[ "$url" == */SHA256SUMS ]]; then
    printf '%064d  noble-server-cloudimg-amd64.img\\n' 0 > "$output"
else
    printf 'download fixture' > "$output"
fi
''')
            curl.chmod(0o755)
            customize = directory / 'virt-customize'
            customize.write_text('#!/bin/bash\nprintf "customize\\n" >> "$CALLS"\n')
            customize.chmod(0o755)
            env = {**os.environ, 'PATH': f'{directory}:/usr/bin:/bin', 'CALLS': str(calls)}
            result = subprocess.run(
                ['bash', str(SCRIPT.with_name('prepare-base-image.sh')), str(target)],
                env=env, capture_output=True, text=True, timeout=10,
            )
            logged = calls.read_text() if calls.exists() else ''
            sentinel = (target / 'sentinel').read_text() if existing else None
            return result, logged, sentinel

    def test_existing_bundle_is_never_overwritten(self):
        result, calls, sentinel = self.run_prepare(existing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, '')
        self.assertEqual(sentinel, 'keep existing artifact')

    def test_upstream_checksum_failure_prevents_customization(self):
        result, calls, _ = self.run_prepare(existing=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('customize', calls)


if __name__ == '__main__':
    unittest.main(verbosity=2)
