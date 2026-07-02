# 0001 — Packer: Proxmox-native builder with selectable output formats

- **Status:** draft
- **Scope:** `packer/ubuntu/` only. Getting a generic template onto the Proxmox host correctly.
  **Out of scope:** any Terraform / clone-time logic, and the full PDS provisioning migration
  (tracked separately — this spec only stops *baking identity* into the image).

## Context

Today `packer/ubuntu/ubuntu.pkr.hcl` uses the `hashicorp/qemu` builder to produce a local qcow2/raw
artifact. Getting that onto Proxmox is a manual, out-of-band step (`qm importdisk` / upload, then
`qm template`) that lives outside Packer. That flow has three problems:

1. **Manual import.** The build stops at a local file; a human turns it into a Proxmox template.
2. **Baked-in identity.** `scripts/install.sh` sets the hostname, writes a static `netplan` config,
   creates the `sysadmin` user with a hardcoded SSH key, and hardens SSHD *at build time*. That makes
   the image machine-specific — the opposite of a golden image — and every clone inherits the same
   `machine-id` and host keys unless we're careful.
3. **One output shape.** The template only knows how to emit a local qcow2/raw.

We want to build **directly against the Proxmox API** using the native
[`hashicorp/proxmox`](https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox) plugin,
land the result as a template with a cloud-init drive attached, and keep it fully generic so
`bpg/proxmox` can clone it with per-VM init.

We also want to keep the local qcow2/raw path available — some workflows (ARM, offline, inspection,
non-Proxmox targets) still want a portable file. So the template must be able to emit **either** format,
**chosen at invocation**, from a single template.

## Goals

- One Packer template for Ubuntu that can produce **either**:
  - a **Proxmox template** built natively via the Proxmox API (default, preferred), or
  - a **local qcow2/raw** artifact (the legacy portable path).
- The output format is **selected at build invocation**, not by editing the template.
- The Proxmox path lands a **template** (not just a VM) on the PVE host, with a **cloud-init drive**
  attached, ready for `bpg/proxmox` to clone.
- The image is **generic/unidentified**: no baked hostname, no static IP, no baked SSH host keys,
  fresh `machine-id` on every clone.

## Non-goals

- Terraform / `bpg/proxmox` clone blocks and per-VM init (hostname, IP, SSH keys, `edgectl` user-data).
  That's the consumer of this template and is deliberately untouched here.
- Completing the "move all provisioning to PDS" migration. This spec removes *identity baking* and
  leaves the remaining provisioning as-is (or minimally adjusted); the PDS cutover is its own spec.

## Design

### Selecting output format at invocation

Packer supports multiple `source` blocks in one template and running a subset via `-only` / `-except`.
We define **two builders sharing one `build` block** (and therefore one set of provisioners), and pick
at the command line:

```bash
packer init .

# Proxmox-native template (default / preferred)
packer build -only='proxmox-iso.ubuntu' -var-file=variables.pkrvars.hcl .

# Legacy local qcow2/raw artifact
packer build -only='qemu.ubuntu' -var-file=variables.pkrvars.hcl .
```

`-only` is the selection mechanism — no template edits, no separate files. Both builders run the same
provisioners, so the *contents* of the image stay identical regardless of output shape.

> Decision to confirm in review: `-only` (explicit, zero magic) vs. a `build_target` variable that
> conditionally includes sources. `-only` is simpler and idiomatic; leaning that way.

### Required plugins

```hcl
packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.2"
      source  = "github.com/hashicorp/proxmox"
    }
    qemu = {
      version = "~> 1"
      source  = "github.com/hashicorp/qemu"
    }
  }
}
```

### `source "proxmox-iso" "ubuntu"` (native Proxmox build)

Builds against the Proxmox API and finishes as a template with a cloud-init drive. No local artifact,
no `qm importdisk`, no upload step.

```hcl
source "proxmox-iso" "ubuntu" {
  # --- API connection ---
  proxmox_url              = var.proxmox_url            # https://pve.mvha.local:8006/api2/json
  username                 = var.proxmox_username       # token or user@realm
  token                    = var.proxmox_token          # API token secret (never committed)
  node                     = var.proxmox_node
  insecure_skip_tls_verify = var.proxmox_insecure       # true for self-signed homelab certs

  # --- resulting template ---
  vm_id                = var.template_vmid
  template_name        = var.template_name              # e.g. "ubuntu-2404-k3s-base"
  template_description = "Generic Ubuntu ${var.ubuntu_version} golden image. Built by Packer. Do not clone identity."

  # --- cloud-init drive for clone-time init ---
  cloud_init              = true
  cloud_init_storage_pool = var.proxmox_storage_pool

  # --- hardware / disk / net (generic only — no static IP) ---
  # boot ISO, disks, network bridge, machine type, qemu-agent, etc.
  # network_adapters uses the bridge only; addressing is left to cloud-init at clone time.
}
```

Key points required by this spec:

- **`cloud_init = true`** and **`cloud_init_storage_pool = <our pool>`** so a cloud-init drive is attached.
- **No** `hostname`, no static network config, no baked SSH host keys set here — the image stays generic.
- The `proxmox-iso` builder **calls `qm template` implicitly as its last step**, so the output lands
  already flagged as a template, not a VM. We rely on that; we do not add a manual template step.
- **`proxmox-clone` alternative:** if we later prefer to base on an existing Proxmox cloud-init template
  rather than an ISO, swap `proxmox-iso` for `proxmox-clone` with a `clone_vm` / `clone_vm_id` source.
  For the ISO-from-scratch case here we use `proxmox-iso`.

### `source "qemu" "ubuntu"` (legacy local artifact)

Retained roughly as-is (the current builder) for the portable qcow2/raw path, but it inherits the same
generic-image provisioners below, so it no longer bakes identity either.

### Provisioning changes (identity removal)

Both builders share the `build` block. Strip everything that makes the image machine-specific; that work
moves to cloud-init at clone time:

- **Remove** hostname assignment (`hostnamectl` / `/etc/hosts` / `hostname_vars.sh` reads).
- **Remove** the baked static `netplan` — clone-time cloud-init owns addressing. (A generic DHCP-on-`en*`
  fallback may stay, TBD in review.)
- **Remove** build-time creation of the `sysadmin` user + hardcoded `SSH_PUBLIC_KEY` and SSHD hardening.
  Users and keys are injected by cloud-init at clone time.
- **Regenerate machine-id on shutdown** so clones never collide:
  ```bash
  truncate -s 0 /etc/machine-id
  # ensure /var/lib/dbus/machine-id is a symlink to /etc/machine-id (or also truncated)
  ```
  (`cleanup.sh` already truncates `/etc/machine-id`; make it authoritative and cover the dbus symlink.)
- **Remove** any baked SSH host keys so each clone regenerates its own on first boot.

Generic, non-identity provisioning (packages, shell/MOTD, kubectl, etc.) stays for now and is the subject
of the follow-up PDS-migration spec.

### Output

A Proxmox template (e.g. `template_name = "ubuntu-2404-k3s-base"`) sitting on the PVE host with a
cloud-init drive attached, generic and unidentified, ready for `bpg/proxmox` to clone with per-VM
initialization (hostname, IP, SSH keys, `edgectl` bootstrap user-data).

### Variables & secrets

New variables: `proxmox_url`, `proxmox_username`, `proxmox_token`, `proxmox_node`, `proxmox_storage_pool`,
`proxmox_insecure`, `template_name`, `template_vmid`. The API token secret must **not** be committed —
supply via `PKR_VAR_proxmox_token` env var or an untracked `*.auto.pkrvars.hcl`; `.gitignore` already
excludes `*.pkrvars.hcl` candidates (confirm).

## Acceptance criteria

- [ ] `packer init .` installs both `hashicorp/proxmox` (`>= 1.2.2`) and `hashicorp/qemu` plugins.
- [ ] `packer build -only='proxmox-iso.ubuntu' …` produces a **template** on the PVE node (verified via
      `qm config <vmid>` showing `template: 1`) with a **cloud-init drive** attached — no local qcow2 and
      no manual `qm importdisk`/upload anywhere in the flow.
- [ ] `packer build -only='qemu.ubuntu' …` still produces the local qcow2/raw artifact.
- [ ] The resulting image contains **no** baked hostname, static IP/netplan identity, or SSH host keys,
      and boots with a **fresh `machine-id`** (two clones get distinct ids).
- [ ] No hostname/user/SSH-key/SSHD-hardening provisioning runs at build time; those responsibilities are
      documented as belonging to clone-time cloud-init.
- [ ] `packer/ubuntu/readme.md` documents the `-only` invocation for both formats and the required
      Proxmox variables/secrets.

## Open questions

- **Selection mechanism:** `-only` (leaning this way) vs. a `build_target` variable. Decide in review.
- **`proxmox-iso` vs `proxmox-clone`:** ISO-from-scratch (this spec) vs cloning an existing PVE cloud-init
  template. Confirm we're building from ISO, not from an existing base template.
- **Boot/autoinstall:** how the `proxmox-iso` builder gets a non-interactive install — Ubuntu autoinstall
  via a `cidata` drive / `boot_command`, or an Ubuntu cloud image path. Needs a concrete answer.
- **Generic DHCP fallback:** keep a `match: en*` DHCP netplan in the image, or leave all networking to
  clone-time cloud-init?
- **Auth:** API token (preferred) vs `username`/`password`. Assuming token.

## References

- [Packer `proxmox-iso` builder](https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox/latest/components/builder/iso)
- [Packer `proxmox-clone` builder](https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox/latest/components/builder/clone)
- [Packer `-only` / `-except`](https://developer.hashicorp.com/packer/docs/commands/build#only-foo-bar-baz)
- [`bpg/proxmox` Terraform provider](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
- Legacy flow being replaced: `packer/ubuntu/ubuntu.pkr.hcl`, `scripts/install.sh`, `scripts/cleanup.sh`.
