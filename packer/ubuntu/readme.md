# Ubuntu template

Build a generic Ubuntu image from the official cloud image. Choose one output at invocation:

| Builder | Output |
| --- | --- |
| `proxmox-clone.ubuntu` | Native Proxmox template with a cloud-init drive for each clone's configuration. |
| `qemu.ubuntu` | Local qcow2, with an optional raw export. |

Both apply the packages, locale, keyboard and timezone in
[`cloud-init/build-config.yaml`](cloud-init/build-config.yaml). The final cleanup locks the temporary
`ubuntu` build password, removes build keys, generated SSH policy and SSH host keys, and resets machine-id and cloud-init.
Configure users, SSH access, hostname and networking when deploying each clone. PDS tooling is a
separate integration tracked in [spec 0003](../../docs/specs/0003-pds-provisioning-migration.md).

## How the pieces fit together

```text
Packer: QEMU or Proxmox
  -> upload cloud-init/build-config.yaml
  -> wait-cloud-init.sh                 wait for first boot and check its result
  -> install.sh <cloud-config-file>     apply this image's Ubuntu settings
  -> seal-image.sh --image-build        remove build access and machine identity
  -> selected output                   Proxmox template or qcow2/optional raw
```

`install.sh` is an image provisioner. It stays a short Bash entrypoint with an explicit config input.
PDS remains the standalone Bash function library; its future package installation and selected
function calls belong in that provisioning step (spec 0003).

`wait-cloud-init.sh` uses Bash and `jq`, shared by both builders. It accepts a completed boot with
deprecation notices only; warnings, malformed results and other failures stop the build. The current
noble/amd64 [package manifest](https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.manifest)
includes jq. Recheck that prerequisite when changing the source image. Python is used for the local
regression tests, not for guest provisioning.

`seal-image.sh` is destructive image preparation. Its explicit `--image-build` argument prevents an
accidental invocation from immediately removing keys or resetting identity. Run it only inside a
fresh disposable image-build guest. Packer supplies that argument in a separate final provisioner.
The default Ubuntu account remains with an unusable password and no authorized keys. Its standard
cloud-init sudo policy remains too, allowing the authenticated build session to request shutdown.
Clone-time configuration must supply any usable deployed login; the image does not retain the
build password or key. The account is disabled, not deleted.

`prepare-base-image.sh` customizes a disk on the build host. `create-base-template.sh` transfers a
verified bundle over SSH and runs `import-base-template.sh` on Proxmox using its native tools.
`export-raw.sh` runs on
the build host after a QEMU build when raw output is requested. These scripts are not part of PDS.

## Prepare the build host

Install Packer, then initialise the pinned Proxmox and QEMU plugins:

```bash
cd packer/ubuntu
packer init .
```

The build host must reach the Proxmox API **and the guest's SSH address** for a native build.
Guests need DHCP and access to the Ubuntu package repositories during provisioning. Local builds
need `qemu-system-x86_64` (or the target architecture's equivalent), `qemu-img`, and `xorriso` or
`genisoimage`. KVM is the default; `tcg` permits software emulation at a substantial speed cost.

## Native Proxmox output

### Stage 0: create a base template

Run image preparation on the management/build machine. Proxmox needs SSH access and its existing
`qm`, `pvesh` and `qemu-img` commands; Packer and libguestfs stay off the hypervisor. Preparation needs Bash,
curl, sha256sum and virt-customize with working appliance networking. Ubuntu/Debian package the
tools as `libguestfs-tools`; Fedora 43 provides virt-customize in
[`guestfs-tools`](https://packages.fedoraproject.org/pkgs/guestfs-tools/guestfs-tools/fedora-43.html).
Preparation defaults to libguestfs' direct backend, so it does not need a libvirt daemon.
The build account must be able to read the host kernel. The tested Ubuntu preparation uses sudo;
see the recovery guide for the reference environment and privilege requirements.

Create a reusable bundle first so it can be backed up independently of the Fedora workstation:

```bash
mkdir -p "$HOME/builders-artifacts"
sudo bash scripts/prepare-base-image.sh "$HOME/builders-artifacts/ubuntu-noble-amd64"
```

Preparation downloads Ubuntu, verifies the published SHA-256, installs the guest agent and clears
machine-id and SSH host keys. The bundle contains the prepared disk, its checksum, the upstream
checksum records, source information and preparation log. Existing output directories are refused.
The source defaults to the Ubuntu `current` directory; `UBUNTU_IMAGE_RELEASE` selects a dated image
directory when available. Retain the bundle for exact base-disk reuse; fetching `current` and apt
packages again is not a byte-identical rebuild.

Verify the Proxmox SSH host key through a trusted route, then use normal SSH configuration for your
identity and any non-default port. Choose an **unused** ID and a name unique to this base:

```bash
PVE_HOST=root@pve BASE_VMID=9000 BASE_NAME=ubuntu-noble-cloudimg \
  BASE_IMAGE_DIR="$HOME/builders-artifacts/ubuntu-noble-amd64" \
  STORAGE=local-lvm BRIDGE=vmbr0 bash scripts/create-base-template.sh
```

The importer verifies the bundle locally and after upload, creates the VM and cloud-init drive,
then converts the new VM to a template. Clearing the base identity prevents concurrent builds from
sharing a DHCP client ID. Strict SSH host-key checking remains enabled.
The temporary uploaded disk is grown to `DISK_SIZE` before VM creation; shrinking is refused.
The saved local bundle is left unchanged.

There is no default ID. An occupied ID or failed availability check stops the script before any
preparation or upload. The node checks again immediately before creating the VM. Existing VMs are
never replaced. If a later step fails, inspect the partial new VM before
removing it or choosing another unused ID. Repeating the command against the same ID is refused.
The default disk size is 32G; override `DISK_SIZE` when needed. Set `UBUNTU_VERSION` and `ARCH` when
preparing another release or architecture. Omitting `BASE_IMAGE_DIR` lets the creation command
prepare a temporary bundle itself, but that bundle is removed afterward.
That inline path needs the invoking user to have a working libguestfs environment and readable host
kernel. Running the whole command with sudo also changes the SSH identity and known_hosts to root's.
Prefer the separate preparation and import steps above, which retain the bundle and keep those
privilege requirements separate. Only that retained-bundle workflow has passed the live recovery test.

If Fedora is unavailable, follow [recovery from another machine](recovery.md). Restoring a saved
bundle needs only Bash, OpenSSH and sha256sum on that machine, without Stackweaver, Packer or libguestfs.

### Stage 1: build a golden template

Copy the example and set the endpoint, node, storage and base template name:

```bash
cp proxmox.auto.pkrvars.hcl.example proxmox.auto.pkrvars.hcl
# Edit this ignored file for your host.
read -rs -p 'Proxmox API token: ' PKR_VAR_proxmox_api_token; echo
export PKR_VAR_proxmox_api_token
packer build -only='proxmox-clone.ubuntu' .
unset PKR_VAR_proxmox_api_token
```

Authentication uses a token ID such as `packer@pve!packer` and its separate secret. Never commit the
secret. Certificate verification is enabled by default. Trust your host's CA; explicitly setting
`proxmox_insecure = true` skips verification for a controlled test host.

`template_vmid = 0` lets Proxmox choose a free ID. You can instead reserve an unused ID explicitly.
Packer full-clones the base and applies provisioning. Its Proxmox plugin removes the temporary
cloud-init credentials and converts the result to a template. Check `qm config <output-id>` for
`template: 1`, a cloud-init volume and no retained build `ciuser`, `cipassword` or `sshkeys`.
For a token restricted to particular VM IDs, choose an unused `template_vmid` covered by its
permissions. The base template is retained for future builds. The OS disk inherits the base
template's storage;
`proxmox_storage_pool` selects the final cloud-init volume's storage.

`proxmox_task_timeout` defaults to `10m` for Proxmox API tasks such as a full clone. The tested
plugin's one-minute default expired before a successful clone finished on this node. Increase the
value for slower storage; it bounds the API wait, not the complete build or SSH readiness wait.
An expired wait or aborted build can leave a VM at the output ID while the server-side task continues.
Inspect the task and VM before retrying. Remove only a confirmed disposable build VM after its task
has stopped, or choose another unused ID; the bootstrap scripts never delete VMs for you.

`proxmox_cpu_type` defaults to `host`, exposing the Proxmox node's CPU features to the native build
and its template. It refers to the hypervisor CPU, not the off-node Packer machine. For a cluster
requiring live migration between different processors, choose a CPU model supported by every target
node. Override it in the vars file or with `-var 'proxmox_cpu_type=x86-64-v2-AES'`; that example still
requires compatible hardware. The portable QEMU builder keeps its separate CPU configuration.
Check `cpu: host` in the template and each fresh clone when using the default, and verify the expected
CPU features inside the guest. A clone's deployment configuration can select a different supported model.

Some Proxmox releases generate the deprecated cloud-init `user` string. cloud-init reports a
completed boot with deprecation notices as exit code 2. The readiness adapter logs those notices and
continues only when `DEPRECATED` is the sole recoverable-error category; other errors stop the build.
The Proxmox generator will need to use the supported `users` list before cloud-init removes that
legacy input. Per-clone cloud-init can report the same notices until the host generator is updated.

Use a dedicated build identity. It needs read access for node/template discovery, VM clone and
configuration permissions on the base and output VM IDs, allocation permissions on the target
storage, and access to the selected bridge. Scope write permissions to these resources; a root API
token is unnecessary. The exact role requirements depend on the Proxmox version and storage setup.

## Portable qcow2 and raw output

```bash
# Local qcow2 only
packer build -only='qemu.ubuntu' .

# Keep the qcow2 and also export a raw disk
packer build -only='qemu.ubuntu' -var 'output_raw=true' .

# Software emulation when KVM is unavailable
packer build -only='qemu.ubuntu' -var 'qemu_accelerator=tcg' .
```

`*.auto.pkrvars.hcl` files load automatically. To use the committed non-secret
`variables.pkrvars.hcl` file, add `-var-file=variables.pkrvars.hcl`; editing it alone does not change
a build. CLI `-var` flags provide individual overrides.

Artifacts land in `output-<codename>-<arch>/`. Raw export performs an actual `qemu-img convert`; it
refuses to overwrite an existing raw artifact. Packer also refuses an existing output directory.
The QEMU seed uses a temporary `ubuntu`/`ubuntu` login on the isolated build guest; cleanup discards
that password hash, removes cloud-init's SSH password override and deletes the seed before export.
Keep build networking private.

For same-architecture emulation on Apple Silicon, select `-var 'arch=arm64'` and
`-var 'qemu_accelerator=hvf'`. This configuration needs separate runtime validation.

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
