# Ubuntu images

Build a generic Ubuntu image from the official cloud image. Proxmox is optional; choose the output
that fits the target machine.

| Builder | Output | Procedure |
| --- | --- | --- |
| `qemu.ubuntu` | Local qcow2, optionally also raw. | [Build locally](../../docs/ubuntu/local-build.md) |
| `proxmox-clone.ubuntu` | Native Proxmox template with clone-time cloud-init. | [Build on Proxmox](../../docs/ubuntu/proxmox.md) |

## Build

With the [local prerequisites](../../docs/ubuntu/local-build.md#prerequisites) installed, start from the repository root:

```bash
cd packer/ubuntu
packer init .
packer build -only='qemu.ubuntu' .
```

For Proxmox, first follow the [base-template and API-token setup](../../docs/ubuntu/proxmox.md), then run:

```bash
packer build -only='proxmox-clone.ubuntu' .
```

Keep the API secret in `PKR_VAR_proxmox_api_token` or an ignored vars file.
The [example configuration](proxmox.auto.pkrvars.hcl.example) lists the native build inputs.

## Build flow

```mermaid
flowchart LR
    Build["Choose<br/>builder"] --> Prepare["Configure<br/>and seal"]
    Prepare --> Output["Disk or<br/>template"]
```

The [pipeline guide](../../docs/ubuntu/image-pipeline.md) explains configuration, sealing and script boundaries.

## Connect and recover

- [SSH and debugging](../../docs/ubuntu/ssh-and-debugging.md): connect during a build, forward VNC over SSH, or inspect an exported disk.
- [Recovery](../../docs/ubuntu/recovery.md): rebuild the Proxmox base from another machine if Fedora is unavailable.
- [Development checks](../../docs/development.md): verify changes locally.

Images are sealed before export. Supply deployed users and keys through cloud-init; the temporary
build login does not survive. PDS bootstrap is [planned with the image build](../../docs/specs/0001-packer-proxmox-native-output.md#pds-provisioning-and-package-identity).
