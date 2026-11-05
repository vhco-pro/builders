# Develop and verify builders

Read [the repository instructions](../AGENTS.md) before changing code. Feature scope and review
records live in [the feature documents](specs/README.md). PDS remains a standalone function library;
builders owns the selected [Ubuntu recipe](ubuntu/provisioning.md).

## Local checks

From the repository root, run `make init` once and `make check` with Packer, ShellCheck, Python 3, Zsh, jq and
`qemu-img` installed. Checks validate both builders and exercise refusal of occupied IDs and real
raw conversion using disposable files. They also check first-boot result handling, explicit config
inputs and refusal of accidental sealing. Packer validation fetches upstream checksum metadata and
needs network access. These checks also exercise package identity/trust refusals, default/custom
recipe selection, selected-call failures, SSH service observation and negative artifact fixtures.
They do not contact Proxmox or replace live image/clone tests. The read-only PR workflow runs the
same `make check` target and reports the real-build checks as skipped.

After a real build, inspect its unbooted disk with libguestfs installed:

```bash
make check-image IMAGE=/path/to/image.qcow2 RECIPE=default PDS_VERSION=0.20.0 PDS_SOURCE=signed-repository
```

Use the exact `pds_version` supplied to the build, `PDS_SOURCE=candidate` for an explicit candidate,
and `RECIPE=custom` for the committed custom example. The expected route must match the image's
provenance. This reads the disk without modifying it and checks identity/access cleanup, both build homes against an
explicit allowlist, package provenance and the selected policy's presence or absence.
It does not establish successful boot or authentication behavior. The original shipped image
must be inspected before creating writable instance disks from it.

Inside each owned fresh instance, logged in as the supplied Zsh user with its own key and sudo policy,
copy `check-instance.sh` and `check-user-shell.zsh` from `packer/ubuntu/scripts/` into the same
directory and run `bash check-instance.sh default` (or `custom`). It verifies both shell
startups and the selected tools/policy. First Zi startup needs network access. Retain full build and
service evidence, including actual plugin revisions; the bounded validation also requires distinct
machine IDs/host keys, real cron execution and positive/negative SSH authentication probes.

PDS has its own package check: `bash tests/check-package.sh` in the dependency checkout. That
builds a candidate with verified nFPM and runs real helper/service checks in disposable Ubuntu.
Neither local candidate tests nor a passing PR check proves installation from the signed repository.
Validate that route against the published package and inspect the resulting image's provenance.

The destructive sealing integration test needs a fresh disposable Ubuntu container with cloud-init
and OpenSSH server installed. It applies the real build seed, checks that password SSH was enabled,
runs the sealer, and verifies that build access and identity were removed. It refuses to run outside
Docker. From the repository root:

```bash
docker run --rm -v "$PWD:/work:ro" ubuntu:24.04 bash -c \
  'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y cloud-init openssh-server && bash /work/packer/ubuntu/tests/test_sealing.sh'
```

On Linux, repeat the sealing test with a public test ID bind-mounted read-only to reproduce an
uncommitted transient ID. Prepare the same disposable image with cloud-init and OpenSSH first,
then run the test with networking disabled. Use a tmpfs fixture such as `/dev/shm`:

```bash
fixture=$(mktemp /dev/shm/builders-machine-id.XXXXXX)
printf '0123456789abcdef0123456789abcdef\n' > "$fixture"
docker run --rm --network none --cap-add SYS_ADMIN \
  -v "$PWD:/work:ro" -v "$fixture:/etc/machine-id:ro" \
  YOUR_PREPARED_UBUNTU_TEST_IMAGE bash /work/packer/ubuntu/tests/test_sealing.sh
rm -- "$fixture"
```

`SYS_ADMIN` permits the systemd command to unmount that fixture inside the container. Mount only
the public fixture and repository as shown; no host devices or host machine ID are needed.

## Live checks

Local checks do not establish that an image boots or that a Proxmox clone has a new identity.
Use disposable artifacts and recorded unused VM IDs for live tests; preserve existing guests.
The [PDS integration validation](validation/0001-2026-11-05.md) records candidate attempts, the
published-release build and eight-instance matrix, and the independent review boundary. The
[earlier bootstrap/CPU validation](validation/0001-2026-11-04.md) records the preceding iteration.
