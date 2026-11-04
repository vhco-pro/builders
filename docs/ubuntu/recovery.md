# Recover image building when Fedora is unavailable

Base preparation passed in a fresh Ubuntu environment, and importing the retained bundle passed
from a separate, unprivileged SSH-only client. See the [validation record](../validation/0001-2026-11-04.md)
for the measured environment and verification limits.
A completed Fedora system recovery has not been demonstrated.

The normal management plane is a separate bare-metal Fedora workstation. This procedure restores
builders' ability to create a Proxmox base template from another Linux machine. It does not depend
on Stackweaver or on restoring Fedora first. Restoring the Fedora system itself is a separate task.

## Keep the recovery inputs outside the workstation

Retain a reviewed builders revision or source archive and the base-image bundle produced by
`scripts/prepare-base-image.sh`. The bundle contains `base.qcow2`, `base-image.sha256`, upstream
checksum records, `build-info.txt` and `prepare.log`. Save it in backup storage that remains
accessible when Fedora is down, alongside the recorded Proxmox endpoint, storage, bridge and
template names. Keep access credentials in their approved secret store, separate from the repository.

Independent access to Proxmox must work without the missing workstation. The recovery machine
needs the network route and SSH identity required for node administration. An existing healthy
template can still be used directly in Proxmox; rebuild it only if it is missing or needs refreshing.

## Import a retained base bundle

Use a Linux machine with Bash, OpenSSH client and sha256sum. Packer, libguestfs and the Fedora user
configuration are not needed for this path. Retrieve the saved source revision and bundle, verify
the Proxmox SSH host key through the trusted recovery record, and configure the recovered SSH
identity using normal OpenSSH configuration. Do not disable host-key checking.

From the recovered repository:

```bash
cd packer/ubuntu
BASE_IMAGE_DIR=/path/to/restored/base-bundle
(cd "$BASE_IMAGE_DIR" && sha256sum -c base-image.sha256)
PVE_HOST=root@pve BASE_VMID=9000 BASE_NAME=ubuntu-noble-recovered \
  BASE_IMAGE_DIR="$BASE_IMAGE_DIR" STORAGE=local-lvm BRIDGE=vmbr0 \
  bash scripts/create-base-template.sh
```

Replace the example node, unused ID, name, storage and bridge with the recorded recovery values.
The script refuses occupied IDs, checks the uploaded disk again on Proxmox, and uses native node
commands to create the template. It removes its temporary upload directory and never deletes a VM.
If import fails after VM creation, inspect that partial new VM before deciding how to recover it.
If upload cleanup fails, the command reports the exact temporary directory requiring attention.

Check the result through Proxmox:

```bash
ssh root@pve qm config 9000
```

Expect `template: 1`, the imported `scsi0` disk, a cloud-init drive, the recorded bridge and the guest
agent enabled. A later disposable clone must boot and report a distinct machine ID before relying
on the restored template. Keep pre-existing VM IDs out of the recovery test.

## Rebuild when the bundle is also lost

The reference replacement environment is Ubuntu 24.04 on amd64. Rebuilding additionally needs curl,
virt-customize and a working libguestfs appliance with access to Ubuntu's package repositories.
The following prerequisite set completed preparation in a fresh Ubuntu container:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  bash ca-certificates curl openssh-client libguestfs-tools \
  linux-image-virtual isc-dhcp-client
```

The DHCP client is explicit because the appliance must configure its own network before it can
install packages. For a different distribution, use its supported libguestfs packages and verify
appliance networking. Fedora 43 packages virt-customize in `guestfs-tools`; that package mapping
alone is not evidence that a particular Fedora installation has passed the recovery test.

Prepare a new bundle, then import it with the earlier command:

```bash
sudo bash scripts/prepare-base-image.sh /path/to/new/base-bundle
```

The measured preparation ran as root inside that disposable environment. A fresh Ubuntu host can
restrict reading `/boot/vmlinuz-*` to root, so the command above uses sudo. An unprivileged run needs
readable host kernel files and permission to use the selected libguestfs backend. Importing a saved
bundle does not need these local privileges or image-preparation tools.

The output directory must not exist. A failed preparation is retained for inspection and cannot
be imported without a valid final checksum record. Hardware virtualization makes preparation
faster; software emulation depends on the build host's libguestfs backend and available resources.
The script defaults to the direct backend and does not require a libvirt daemon.

Rebuilding against `current` and the current apt repositories can change package contents. The
recorded upstream checksum identifies the downloaded bytes. The source URL records the download
location, but its moving `current` path will not locate the same bytes indefinitely. Retaining the
completed bundle preserves the exact prepared base. This procedure does not promise byte-identical rebuilds
from moving upstream repositories or operation without those repositories being reachable.

## Resume golden-image builds

Install [Packer](https://developer.hashicorp.com/packer/install) on the replacement build machine
and run `packer init .` against the recovered source to install its declared plugins. Follow the
[native build procedure](proxmox.md#stage-1-build-a-golden-template), supplying a scoped API token and
the recovered base-template name. The build machine must reach both the Proxmox API and the build
guest's SSH address; node SSH access alone does not establish that path.

The new golden template needs the same artifact and fresh-clone checks as a normal build. Restore
Stackweaver's own configuration, state and credentials through their documented recovery procedure
before resuming infrastructure applies. Generating an image does not restore workload data.
