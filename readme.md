# builders

**Packer templates** for building golden VM images with the tooling already installed.

Build a native **Proxmox template** ready to clone, or a portable **qcow2/raw** image for bare metal or
another hypervisor. It's the same build either way, you pick the output format at build time. The images
ship **generic**, with no baked-in hostname, IP, or SSH keys, so cloud-init handles per-machine setup on
first boot wherever they run.

Provisioning is backed by **[PDS](https://github.com/michielvha/PDS)** (Portable Deploy Suite), a single
apt package of install and config functions, instead of copy-pasted scripts in every repo. Templates
**select and apply** the pieces they want, so images stay consistent and easy to maintain.

## Highlights

- **Batteries included**: tooling installed via the PDS package (zsh + Powerlevel10k, `kubectl`, SSH
  hardening, a custom MOTD, and more), instead of per-repo script sprawl.
- **One template, multiple outputs**: a native Proxmox template or a portable qcow2/raw for bare metal
  and other hypervisors, chosen at invocation.
- **Generic golden images**: identity (hostname, IP, SSH keys) is applied on first boot via cloud-init,
  never baked in.
- **Clean for cloning**: `machine-id` and cloud-init state are reset, so every machine boots fresh and
  unique.
- **Easy to extend**: add a new distro or role without reinventing the provisioning.

## Templates

| Path | What it builds |
| --- | --- |
| [`packer/ubuntu/`](packer/ubuntu/) | Ubuntu cloud image + PDS tooling, output as a Proxmox template or qcow2/raw. |
| [`armbian-build-framework/`](armbian-build-framework/) | ARM SBC images (Rock 5A, Raspberry Pi 4B). |

## Quick start

Prerequisites: [Packer](https://developer.hashicorp.com/packer), plus either a Proxmox host (for the
native template) or QEMU (for a local image).

```bash
cd packer/ubuntu
packer init .

# Build a clone-ready Proxmox template (cloud-init drive attached)
packer build -only='proxmox-clone.ubuntu' -var-file=variables.pkrvars.hcl .

# ...or build a portable qcow2/raw image
packer build -only='qemu.ubuntu' -var-file=variables.pkrvars.hcl .
```

For the Proxmox output, set your connection + storage variables first (see
[`packer/ubuntu/readme.md`](packer/ubuntu/readme.md)). **Never commit your Proxmox API token**, pass it
via an environment variable or an untracked vars file.

## How it fits together

From a build to a running machine:

1. **Packer** builds a generic golden image with all your tooling already installed.
2. **Deploy it**: clone the Proxmox template, or write the qcow2/raw image to a disk or another
   hypervisor.
3. **cloud-init** applies per-machine identity on first boot (hostname, IP, SSH keys).
4. *(optional)* **Terraform** ([bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest))
   automates the Proxmox clone path when you want it.

## Status

Ubuntu now, more distros to follow.

## License

GPLv3, see [LICENSE](LICENSE). Fork it, make it yours.

---

<sub>Design notes and rationale for contributors live in [`docs/`](docs/).</sub>
