# Build a local Ubuntu image with QEMU

This path produces a qcow2 disk, optionally with a raw export. It needs no Proxmox server, API token,
base template, Terraform or Stackweaver.

## Prerequisites

Install [Packer](https://developer.hashicorp.com/packer/install), `qemu-system-x86_64` (or the target architecture's equivalent), `qemu-img`,
and `genisoimage` or `xorriso`. The default amd64 build uses KVM; use TCG for software emulation when
KVM is unavailable. The guest needs access to Ubuntu/PDS package repositories and the selected
recipe's upstream downloads. This branch needs the pending PDS feature release or an explicit
[candidate package](../../packer/ubuntu/pds/readme.md); published PDS 0.19.0 lacks the new helpers.

Initialize the pinned plugins from the repository root. The template declares both plugins;
installing them does not require a Proxmox server or credentials.

```bash
cd packer/ubuntu
packer init .
```

## Build and locate the result

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

## Connect or inspect

The exported image has no usable build login. Supply a user and SSH key at deployment time before
connecting. The [SSH and debugging guide](ssh-and-debugging.md) covers temporary build access, VNC
tunnels and read-only inspection. [Image preparation](image-pipeline.md) explains the shared configuration
and sealing steps.
