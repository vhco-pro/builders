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

## Primer — Proxmox concepts (new to this)

Short glossary so the rest of this spec reads cleanly:

- **Proxmox VE (PVE):** the hypervisor host. It exposes a **REST API** (`https://<host>:8006/api2/json`).
- **Packer builds *against* that API:** it's a program that logs into Proxmox, creates a VM, installs
  the OS, then converts the VM into a **template**. Authentication is via an **API token** (created in
  the PVE UI: a user like `packer@pve` + token id `packer` → a one-time secret). Tokens are revocable
  and need no interactive login. (This is separate from — but the same *kind* of thing as — the creds
  the `bpg/proxmox` **Terraform** provider will need later at clone time; that's out of scope here.)
- **Template:** a VM flagged read-only that you **clone** to make real VMs. `proxmox-clone` sets this
  flag automatically as its last step (it clones a base, customizes, then re-templates).
- **Cloud image, not an ISO install.** We start from Ubuntu's **prebuilt cloud image** (OS already
  installed) and *customize* it with Packer — no fresh install, no autoinstall/preseed. This is the
  modern, preferred approach and matches the current qemu flow's base.
- **Two different "cloud-inits" — do not conflate them:**
  - **Build-time (throwaway):** how Packer gets into the VM to *customize* it during the build. The
    `proxmox-clone` builder auto-generates a temporary SSH key and injects it via cloud-init so it can
    connect and run provisioners. Discarded when the template is sealed.
  - **Clone-time (the point of a golden image):** the **empty cloud-init drive** left on the *finished*
    template (`cloud_init = true`). Terraform fills it in per-VM (hostname, IP, SSH keys, `edgectl`
    user-data) when it clones. The image ships generic; identity arrives *here*.

  So Packer *prebuilds* the customized image from the cloud image; the clone-time drive is a separate,
  empty slot for consumers to populate.

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
packer build -only='proxmox-clone.ubuntu' -var-file=variables.pkrvars.hcl .

# Portable local qcow2/raw artifact
packer build -only='qemu.ubuntu' -var-file=variables.pkrvars.hcl .
```

`-only` is the selection mechanism — no template edits, no separate files. Both builders run the same
provisioners, so the *provisioning applied* is identical regardless of output shape (their base OS
differs — see the qemu note below).

> **Decided:** use `-only` (explicit, idiomatic, zero magic). No `build_target` variable.

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

### Stage 0 — base cloud-init template (bootstrap, once per Ubuntu release)

`proxmox-clone` clones an **existing** Proxmox template; it cannot download a cloud image itself. So we
first turn the official Ubuntu **cloud image** into a base cloud-init template on the PVE host. This is
**not** the per-build manual import we're eliminating — it runs *once per Ubuntu release*, and we commit
it as a repeatable script (`packer/ubuntu/scripts/create-base-template.sh`) rather than hand-clicking.

Sketch of what the bootstrap does (over SSH to the PVE host, using `qm`):

```bash
# download the official cloud image, embed qemu-guest-agent (needed so Packer/Proxmox
# can see the VM's IP after clone), then create + template it.
virt-customize -a ubuntu-24.04-cloudimg-amd64.img --install qemu-guest-agent
qm create $BASE_VMID --name ubuntu-2404-cloudimg --memory 2048 --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci
qm importdisk $BASE_VMID ubuntu-24.04-cloudimg-amd64.img $STORAGE
qm set $BASE_VMID --scsi0 $STORAGE:vm-$BASE_VMID-disk-0 --ide2 $STORAGE:cloudinit
qm set $BASE_VMID --boot c --bootdisk scsi0 --serial0 socket --vga serial0 --ipconfig0 ip=dhcp
qm template $BASE_VMID
```

Single source of truth = the upstream Ubuntu cloud image; the base is a thin, generic wrapper of it.

### Stage 1 — `source "proxmox-clone" "ubuntu"` (native Proxmox build, every build)

**Decided: `proxmox-clone` from the cloud-image base** — Packer clones the Stage-0 base, boots it,
customizes it with our provisioners, resets cloud-init state, and seals it as the golden template with
a fresh **empty** cloud-init drive. No per-build `qm importdisk`, no ISO install.

```hcl
source "proxmox-clone" "ubuntu" {
  # --- Proxmox API connection (Packer builds against this) ---
  proxmox_url              = var.proxmox_url            # https://pve.mvha.local:8006/api2/json
  username                 = var.proxmox_api_token_id   # e.g. "packer@pve!packer" (token id, not a login)
  token                    = var.proxmox_api_token      # API token secret (never committed)
  node                     = var.proxmox_node
  insecure_skip_tls_verify = var.proxmox_insecure       # true for self-signed homelab certs

  # --- base to clone (Stage 0) ---
  clone_vm      = var.base_template_name                # e.g. "ubuntu-2404-cloudimg"
  full_clone    = true
  scsi_controller = "virtio-scsi-pci"
  qemu_agent    = true                                  # base image has qemu-guest-agent embedded

  # --- resulting golden template ---
  vm_id                = var.template_vmid
  template_name        = var.template_name              # e.g. "ubuntu-2404-k3s-base"
  template_description = "Generic Ubuntu ${var.ubuntu_version} golden image. Built by Packer. No baked identity."

  # --- CLONE-time cloud-init drive (empty; the point of the golden image) ---
  cloud_init              = true
  cloud_init_storage_pool = var.proxmox_storage_pool

  # --- network: DHCP; Packer injects a temporary SSH key via cloud-init for the build ---
}
```

Key points required by this spec:

- **`cloud_init = true`** and **`cloud_init_storage_pool = <our pool>`** → the finished template carries
  an **empty** cloud-init drive for consumers to fill at clone time.
- **No** hostname, static network config, or baked SSH host keys set here — the image stays generic.
  **Networking = DHCP** (decided); per-VM addressing is a clone-time concern.
- **Build-time SSH:** with no explicit communicator config, `proxmox-clone` generates an SSH key and
  injects it via cloud-init; `qemu_agent = true` lets Proxmox report the VM's IP back to Packer.
- The builder finishes by **converting the VM back into a template**, so the output lands as a template,
  not a VM — no manual template step.

### `source "qemu" "ubuntu"` (portable local artifact)

Retained (current builder, Ubuntu **cloud image** + `cidata` seed) for the portable qcow2/raw path and
fast local iteration. Same generic-image provisioners, so it no longer bakes identity either.

> Both builders share the **same base** (the upstream Ubuntu cloud image) *and* the same provisioners,
> so the qemu path is a faithful fast check of what the Proxmox template will contain. That equivalence
> is what spec 0002's local/CI qemu loop leans on.

### Provisioning changes (identity removal)

Both builders share the `build` block. Strip everything that makes the image machine-specific; that work
moves to cloud-init at clone time:

- **Remove** hostname assignment (`hostnamectl` / `/etc/hosts` / `hostname_vars.sh` reads).
- **Remove** the baked static `netplan` — clone-time cloud-init owns addressing. (A generic DHCP-on-`en*`
  fallback may stay, TBD in review.)
- **Remove** build-time creation of the `sysadmin` user + hardcoded `SSH_PUBLIC_KEY` and SSHD hardening.
  Users and keys are injected by cloud-init at clone time.
- **Reset cloud-init state before sealing** so every clone re-runs cloud-init as if first-booted
  (the classic template gotcha — otherwise clones skip clone-time init):
  ```bash
  cloud-init clean --logs --seed
  ```
- **Regenerate machine-id on shutdown** so clones never collide:
  ```bash
  truncate -s 0 /etc/machine-id
  # ensure /var/lib/dbus/machine-id is a symlink to /etc/machine-id (or also truncated)
  ```
  (`cleanup.sh` already truncates `/etc/machine-id`; make it authoritative and cover the dbus symlink.)
- **Remove** any baked SSH host keys so each clone regenerates its own on first boot, and remove the
  temporary build SSH key Packer injected.

Generic, non-identity provisioning (packages, shell/MOTD, kubectl, etc.) stays for now and is the subject
of the follow-up PDS-migration spec.

### Output

A Proxmox template (e.g. `template_name = "ubuntu-2404-k3s-base"`) sitting on the PVE host with a
cloud-init drive attached, generic and unidentified, ready for `bpg/proxmox` to clone with per-VM
initialization (hostname, IP, SSH keys, `edgectl` bootstrap user-data).

### Variables & secrets

New variables: `proxmox_url`, `proxmox_api_token_id`, `proxmox_api_token`, `proxmox_node`,
`proxmox_storage_pool`, `base_template_name`, `proxmox_insecure`, `template_name`, `template_vmid`.

**Auth = API token** (decided). Create it once in the Proxmox UI (Datacenter → Permissions → API
Tokens): a user such as `packer@pve` with token id `packer` yields `proxmox_api_token_id =
"packer@pve!packer"` and a secret → `proxmox_api_token`. The secret must **not** be committed — supply
via `PKR_VAR_proxmox_api_token` env var (preferred, works cleanly in CI) or an untracked
`*.auto.pkrvars.hcl`; confirm `.gitignore` excludes `*.pkrvars.hcl`. The token needs privileges to
create VMs, use the target storage, and template VMs (a `PVEVMAdmin`-style role on `/`).

> Caveat to verify at implementation: some older `proxmox-clone` versions only supported
> `username`/`password` (not token) for the *clone* builder specifically. On plugin `>= 1.2.2` token
> auth should work; if not, fall back to a `packer@pve` password supplied the same secret-free way.

## Acceptance criteria

- [ ] A committed `create-base-template.sh` turns the official Ubuntu cloud image into a base cloud-init
      template on the PVE host (qemu-guest-agent embedded), repeatably — no hand-clicking.
- [ ] `packer init .` installs both `hashicorp/proxmox` (`>= 1.2.2`) and `hashicorp/qemu` plugins.
- [ ] `packer build -only='proxmox-clone.ubuntu' …` clones the base and produces a **template** on the
      PVE node (verified via `qm config <vmid>` showing `template: 1`) with an **empty cloud-init drive**
      attached — no per-build `qm importdisk`/upload anywhere in the flow.
- [ ] `packer build -only='qemu.ubuntu' …` still produces the local qcow2/raw artifact.
- [ ] The resulting image contains **no** baked hostname, static IP/netplan identity, or SSH host keys,
      and boots with a **fresh `machine-id`** (two clones get distinct ids).
- [ ] No hostname/user/SSH-key/SSHD-hardening provisioning runs at build time; those responsibilities are
      documented as belonging to clone-time cloud-init.
- [ ] `packer/ubuntu/readme.md` documents the `-only` invocation for both formats and the required
      Proxmox variables/secrets.

## Decisions (resolved)

- **Selection mechanism:** `-only` (explicit, idiomatic). No `build_target` variable.
- **Base:** the official Ubuntu **cloud image** (prebuilt OS + cloud-init), *not* an ISO install. No
  autoinstall/preseed.
- **Builder:** `proxmox-clone` from a cloud-image base template. The one-time base is created by a
  committed `create-base-template.sh` (Stage 0); Packer clones + customizes it every build (Stage 1).
- **Networking:** DHCP everywhere in the image; no static addressing baked in.
- **Auth:** Proxmox **API token** (for the Proxmox API that Packer builds against — a token created in
  the PVE UI, not the Terraform provider's creds).

## Open questions

- **Base-template automation:** keep `create-base-template.sh` as a hand-run bootstrap, or wrap it so
  it's idempotent / invoked from the Makefile? (It only reruns per Ubuntu release.)
- **Token vs password for `proxmox-clone`:** confirm token auth works on the pinned plugin version (see
  the caveat above); fall back to a secret-free `packer@pve` password if not.
- **Disk/storage details:** base disk size (`qm resize`), controller (`virtio-scsi-pci`), and the exact
  `proxmox_storage_pool` / `base_template_name` / vmid values on the homelab PVE (fill into the
  untracked vars file).
- **UEFI vs BIOS:** keep whatever the cloud-image base uses; confirm it matches how `bpg/proxmox` clones.

## References

- [Packer `proxmox-clone` builder](https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox/latest/components/builder/clone)
- [Create Proxmox cloud-init templates for Packer (base bootstrap)](https://dev.to/mike1237/create-proxmox-cloud-init-templates-for-use-with-packer-193a)
- [kencx homelab: Packer proxmox-iso vs proxmox-clone](https://kencx.github.io/homelab/images/packer.html)
- [Building Ubuntu 24.04 Proxmox templates with Packer](https://thecomalley.github.io/packer-proxmox-ubuntu)
- [Packer `-only` / `-except`](https://developer.hashicorp.com/packer/docs/commands/build#only-foo-bar-baz)
- [`bpg/proxmox` Terraform provider](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
- Legacy flow being replaced: `packer/ubuntu/ubuntu.pkr.hcl`, `scripts/install.sh`, `scripts/cleanup.sh`.
