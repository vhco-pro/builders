# builders

Golden-image builders for the homelab. Spec-driven, PDS-backed, Proxmox-native.

This repo produces reusable, **generic/unidentified** base images (golden images) that
[Terraform `bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest) clones
into per-VM instances. All per-machine identity (hostname, static IP, SSH keys, the `edgectl`
bootstrap user-data) is applied at **clone time via cloud-init**, never baked into the image.

## Principles

- **Spec-driven, not copy-paste.** Every change starts as a spec in [`docs/specs/`](docs/specs/).
  We design the behaviour, agree on it, then implement. No more inline drift.
- **Provisioning lives in [PDS](https://github.com/michielvha/PDS).** Builders should *select and
  apply* PDS functions, not carry their own inline install/config scripts. Inline scripts are a
  migration smell to be removed.
- **Images stay generic.** No baked-in hostname, static network config, or SSH host keys.
  `machine-id` is regenerated on shutdown so clones never collide.
- **Proxmox-native output.** Prefer building templates directly against the Proxmox API
  (`hashicorp/proxmox` plugin) over building a local qcow2 and manually importing it. The build
  format is selectable at invocation so one template can emit multiple artifact types.

## Layout

| Path | Purpose |
| --- | --- |
| [`docs/specs/`](docs/specs/) | Specifications — the source of truth for what we build and why. |
| [`packer/`](packer/) | Packer templates (currently `ubuntu/`). |
| [`armbian-build-framework/`](armbian-build-framework/) | ARM SBC (Rock 5A, RPi 4B) Armbian image builds. |

## Status

Migrating off the legacy qcow2 + `qm importdisk` flow toward the native Proxmox builder and PDS-based
provisioning. See [`docs/specs/`](docs/specs/) for active work.
