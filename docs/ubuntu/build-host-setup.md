# Set up a Packer build host

These Ubuntu/Debian commands retain the host setup from the original Packer README. Install build
tools on the workstation or a disposable build VM. Proxmox itself only needs its native import tools.

## Install Packer

Add [HashiCorp's apt repository](https://developer.hashicorp.com/packer/install):

```bash
sudo apt-get update
sudo apt-get install -y wget curl gnupg ca-certificates lsb-release
wget -qO- https://apt.releases.hashicorp.com/gpg |
  sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
printf 'deb [arch=%s signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com %s main\n' \
  "$(dpkg --print-architecture)" "$(lsb_release -cs)" |
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update
sudo apt-get install -y packer
packer version
```

The package command installs the repository's available version. To reproduce a dated validation,
select its recorded Packer version from `apt-cache madison packer`, then install that exact apt
version. The [CI workflow](../../.github/workflows/check.yaml) records the reference version used by checks.

## Install QEMU and local check tools

For an amd64 build host:

```bash
sudo apt-get install -y qemu-system-x86 qemu-utils genisoimage shellcheck jq python3 zsh
```

For an ARM64 build host, the corresponding emulators are:

```bash
sudo apt-get install -y qemu-system-arm qemu-system-aarch64 qemu-utils genisoimage shellcheck jq python3 zsh
```

The current live validation covers Ubuntu amd64. Installing ARM emulators does not establish that
an ARM image boots; keep the [legacy ARM recipes](../legacy/armbian-qemu.md) separate from that result.

KVM requires access to `/dev/kvm`. Check it as the user who will run Packer:

```bash
test -r /dev/kvm && test -w /dev/kvm
```

If access is missing, configure the host's KVM group membership and start a new login session.
The [local build guide](local-build.md) also shows software emulation with TCG.

## Optional libvirt desktop tools

These tools from the old setup are useful for managing local guests through libvirt or Virt Manager.
The Packer QEMU builder invokes QEMU directly and does not need a libvirt daemon.

```bash
sudo apt-get install -y libvirt-daemon-system libvirt-clients bridge-utils virtinst virt-manager
```

For libguestfs inspection and off-node base preparation, use the additional prerequisites in the
[recovery guide](recovery.md#rebuild-when-the-bundle-is-also-lost). They include a readable kernel and
the appliance DHCP client.

## Initialize the project's plugins

From the repository root:

```bash
cd packer/ubuntu
packer init .
```

Run initialization and builds as the same user so they share the plugin cache. The template selects
the plugin versions; this replaces the old manual `sudo packer plugins install github.com/hashicorp/qemu`
step. Continue with the [local build](local-build.md) or [optional Proxmox build](proxmox.md).
