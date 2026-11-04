# Develop and verify builders

Read [the repository instructions](../AGENTS.md) before changing code. Feature scope and review
records live in [the feature documents](specs/README.md). PDS remains a standalone function library;
its package integration is separate from the current Ubuntu image provisioner.

## Local checks

From the repository root, run `make init` once and `make check` with Packer, ShellCheck, Python 3, jq and
`qemu-img` installed. Checks validate both builders and exercise refusal of occupied IDs and real
raw conversion using disposable files. They also check first-boot result handling, explicit config
inputs and refusal of accidental sealing. Packer validation fetches upstream checksum metadata and
needs network access. These checks do not contact Proxmox or replace live image/clone tests.

The destructive sealing integration test needs a fresh disposable Ubuntu container with cloud-init
and OpenSSH server installed. It applies the real build seed, checks that password SSH was enabled,
runs the sealer, and verifies that build access and identity were removed. It refuses to run outside
Docker. From the repository root:

```bash
docker run --rm -v "$PWD:/work:ro" ubuntu:24.04 bash -c \
  'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y cloud-init openssh-server && bash /work/packer/ubuntu/tests/test_sealing.sh'
```

## Live checks

Local checks do not establish that an image boots or that a Proxmox clone has a new identity.
Use disposable artifacts and recorded unused VM IDs for live tests; preserve existing guests.
The [validation summary](validation/0001-2026-11-04.md) separates observed build/clone results from
independent review and records the current verification limits.
