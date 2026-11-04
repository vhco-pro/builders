# Build an Ubuntu template on Proxmox

This is the optional native Proxmox path. For a local disk image without Proxmox, use the
[QEMU guide](local-build.md).

Install Packer on the build machine and initialize the pinned plugins. The build machine needs
access to the Proxmox API and the build guest's SSH address. Guests need DHCP and access to Ubuntu's
package repositories. These commands start from the repository root:

```bash
cd packer/ubuntu
packer init .
```

## Stage 0: create a base template

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

## Stage 1: build a golden template

Building an image does not deploy a production workload. A consumer such as Terraform with the
`bpg/proxmox` provider clones the resulting template and supplies per-clone cloud-init settings.

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
