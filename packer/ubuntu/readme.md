# Ubuntu template

Builds a generic Ubuntu golden image from the official cloud image. One template, two builders,
selected at invocation with `-only`:

- `proxmox-clone.ubuntu` -> a native Proxmox template, clone-ready, with an empty cloud-init drive.
- `qemu.ubuntu` -> a portable local qcow2 for bare metal or any other hypervisor.

Both share the same provisioning. The image ships **generic**: no baked hostname, IP, or SSH keys, and
`machine-id` plus cloud-init state are reset so every clone boots fresh. Per-VM identity is injected at
clone time via cloud-init (for example by Terraform `bpg/proxmox`).

## Build

```bash
cd packer/ubuntu
packer init .

# Native Proxmox template
packer build -only='proxmox-clone.ubuntu' .

# Portable local qcow2 (lands in output-<version>-<arch>/)
packer build -only='qemu.ubuntu' .
```

### Proxmox output (`proxmox-clone`)

`proxmox-clone` clones an existing base cloud-init template, so create that once per Ubuntu release:

```bash
# on the Proxmox host (needs qm, wget, libguestfs-tools)
STORAGE=local-lvm BRIDGE=vmbr0 ./scripts/create-base-template.sh
```

Then set your homelab values and build:

```bash
cp proxmox.auto.pkrvars.hcl.example proxmox.auto.pkrvars.hcl   # git-ignored, edit it
export PKR_VAR_proxmox_api_token='xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
packer build -only='proxmox-clone.ubuntu' .
```

The build ends by flagging the VM as a template (verify with `qm config <vmid>` showing `template: 1`).

**Auth:** create an API token in the Proxmox UI (Datacenter -> Permissions -> API Tokens), e.g. user
`packer@pve`, token id `packer`, which gives `proxmox_api_token_id = "packer@pve!packer"`. Supply the
secret via `PKR_VAR_proxmox_api_token` or an untracked `*.auto.pkrvars.hcl`. **Never commit the token.**

### Local qcow2 output (`qemu`)

The `qemu` builder is the fast local check. On Apple Silicon, build the arm64 variant so QEMU uses HVF
(amd64 falls back to slow TCG emulation):

```bash
packer build -only='qemu.ubuntu' -var 'arch=arm64' -var 'qemu_accelerator=hvf' .
```

## Variables

Defaults live in [`variables.pkr.hcl`](variables.pkr.hcl). Non-secret build values are in
[`variables.pkrvars.hcl`](variables.pkrvars.hcl); Proxmox connection + token go in an untracked
`proxmox.auto.pkrvars.hcl` (see the `.example`).

## Scope

This image is intentionally generic and minimal. Tooling (zsh + Powerlevel10k, kubectl, SSH hardening,
MOTD) is provisioned via the [PDS](https://github.com/michielvha/PDS) package and is tracked separately
in issue #3, so it is not installed here yet.
