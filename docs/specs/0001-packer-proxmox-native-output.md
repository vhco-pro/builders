---
status: draft
status_description: "Owner authorized commits and PR update; specification review is pending and feature completion is not claimed."
issue: https://github.com/vhco-pro/builders/issues/1
goal: "Build generic Ubuntu images as a native Proxmox template or portable qcow2/raw output selected at invocation."
covers:
  - packer/ubuntu/
  - Makefile
  - readme.md
branch: feat/0001-packer-proxmox-native
---

# Plan: Packer: Proxmox-native builder with selectable output formats

Build generic Ubuntu images as a native Proxmox template or portable qcow2/raw output selected at invocation.

## Context

Migration: this file now uses the pinned vh-adlc format in its existing location. Earlier checklist ticks are historical and are not imported as current acceptance. No review or owner-acceptance record has been invented.

At the start of this feature, `packer/ubuntu/ubuntu.pkr.hcl` used the `hashicorp/qemu` builder to produce a local qcow2/raw
artifact. Getting that onto Proxmox is a manual, out-of-band step (`qm importdisk` / upload, then
`qm template`) that lives outside Packer. That flow has three problems:

1. **Manual import.** The build stops at a local file; a human turns it into a Proxmox template.
2. **Baked-in identity.** `scripts/install.sh` sets the hostname, writes a static `netplan` config,
   creates the `sysadmin` user with a hardcoded SSH key, and hardens SSHD *at build time*. That makes
   the image machine-specific; the opposite of a golden image; and every clone inherits the same
   `machine-id` and host keys unless we're careful.
3. **One output shape.** The template only knows how to emit a local qcow2/raw.

We want to build **directly against the Proxmox API** using the native
[`hashicorp/proxmox`](https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox) plugin,
land the result as a template with a cloud-init drive attached, and keep it fully generic so
`bpg/proxmox` can clone it with per-VM init.

We also want to keep the local qcow2/raw path available; some workflows (ARM, offline, inspection,
non-Proxmox targets) still want a portable file. So the template must be able to emit **either** format,
**chosen at invocation**, from a single template.

### Primer; Proxmox concepts (new to this)

Short glossary so the rest of this spec reads cleanly:

- **Proxmox VE (PVE):** the hypervisor host. It exposes a **REST API** (`https://<host>:8006/api2/json`).
- **Packer builds *against* that API:** it's a program that logs into Proxmox, creates a VM, installs
  the OS, then converts the VM into a **template**. Authentication is via an **API token** (created in
  the PVE UI: a user like `packer@pve` + token id `packer` → a one-time secret). Tokens are revocable
  and need no interactive login. (This is separate from; but the same *kind* of thing as; the creds
  the `bpg/proxmox` **Terraform** provider will need later at clone time; that's out of scope here.)
- **Template:** a VM flagged read-only that you **clone** to make real VMs. `proxmox-clone` sets this
  flag automatically as its last step (it clones a base, customizes, then re-templates).
- **Cloud image, not an ISO install.** We start from Ubuntu's **prebuilt cloud image** (OS already
  installed) and *customize* it with Packer; no fresh install, no autoinstall/preseed. This is the
  modern, preferred approach and matches the current qemu flow's base.
- **Two different "cloud-inits"; do not conflate them:**
  - **Build-time (throwaway):** how Packer gets into the VM to *customize* it during the build. The
    `proxmox-clone` builder auto-generates a temporary SSH key and injects it via cloud-init so it can
    connect and run provisioners. Discarded when the template is sealed.
  - **Clone-time (the point of a golden image):** the **empty cloud-init drive** left on the *finished*
    template (`cloud_init = true`). Terraform fills it in per-VM (hostname, IP, SSH keys, `edgectl`
    user-data) when it clones. The image ships generic; identity arrives *here*.

  So Packer *prebuilds* the customized image from the cloud image; the clone-time drive is a separate,
  empty slot for consumers to populate.

### Live validation before the structure refactor (2026-11-03)

This section records an earlier candidate, not verification of the current source. The migrated
feature status remains `draft`; commit `deae257` contains the implementation, and `0b33ecf` incorporates
the latest main-branch specification changes. No completion is claimed.

- Packer 1.16.2, Proxmox plugin 1.2.4 and QEMU plugin 1.1.8; `make check` passed formatting,
  validation, ShellCheck and the eight tests available then. The refactor added further local regression cases.
  Portable-only validation also passed without
  Proxmox credentials.
- The full bootstrap created a new Ubuntu noble/amd64 base on Proxmox 9.1.7 with a checksum-verified
  image, installed guest agent, DHCP, `virtio-scsi-pci`, a 12 GiB test disk and `template: 1`. Offline
  image tools ran in a disposable container; guarded SSH transport ran `qm`/`pvesh` on the node.
  No packages were installed on the Proxmox host. The script's normal disk default remains 32G.
- A VM-scoped token built a native golden template with a fresh cloud-init volume and no retained
  build cloud-init credentials. Two full clones accepted distinct injected users/SSH keys, received
  their own hostnames, and had different machine IDs and SSH host keys. Baseline packages, locale,
  keyboard, timezone and the locked Ubuntu password were checked inside both clones.
- A complete portable KVM build ran in a separate temporary Proxmox guest. Its qcow2 and raw disks
  both have a 10 GiB virtual size and compare identically. Read-only inspection confirmed an empty
  machine-id, the D-Bus link, generic hostname, no build/host keys, no seed/instance cache, no static
  cloud-init netplan file, a locked Ubuntu password and the expected packages and OS settings.
- Live tests exposed duplicate machine IDs in the initial bootstrap, which made concurrent base
  clones share a DHCP client ID/IP. The corrected bootstrap clears machine-id after customization.
  Tests also caught Proxmox's deprecated cloud-init `user` string and a missing executable bit on
  the raw exporter. Both fixes have regression coverage. Only deprecation-only completed cloud-init
  results are accepted; other reported errors still fail provisioning.
- Early local TCG attempts hit a container memory cap and termination during conversion. The final
  portable result is from KVM. ARM/HVF, UEFI, other releases/storage backends and Terraform deployment
  remain unverified. PDS and the full automated image-test harness remain separate specs.

The test range was 990100–990105. All seven pre-existing guests' configuration hashes and runtime
statuses were checked throughout. Temporary API identities were removed after each native attempt.
The task retained raw logs, cleanup evidence and runtime file hashes privately. The committed
[validation summary](../validation/0001-2026-11-04.md) records the observed results and their limits.
These earlier-run results do not establish current independent acceptance. No credentials are committed.

### Structure refactor for owner review

The previously recorded live runs used the earlier two-script provisioner. The implementation makes
first-boot readiness, image configuration and sealing separate ordered Packer steps. The standalone
`wait-cloud-init.sh` parses cloud-init JSON with jq, `install.sh` accepts its cloud-config path as an
argument, and `seal-image.sh` requires `--image-build` before it changes the guest. Both builders use
the same steps. The Proxmox bootstrap and raw exporter retain their separate responsibilities.

PDS remains standalone and unchanged. Its pinned-package integration belongs in spec 0003; the
current `install.sh` applies the native Ubuntu settings and does not claim to install PDS yet.

Full image-build criteria are unchecked again pending validation of this updated Packer wiring.
The earlier live evidence remains useful history, not an exact-source acceptance of this refactor.

Current source: `packer/ubuntu/ubuntu.pkr.hcl:19` and `:49` define the two outputs;
`Makefile:3` defines the available local commands. The feature links were confirmed by reading
GitHub issues #1, #2 and #3 during this migration.

R-1 is an independent Opus 5.5 diagnostic of the uncommitted candidate. It established no criterion
as met and flagged a possible retained SSH password-authentication setting (F-01). That setting must
be checked in a newly built artifact before acceptance. Subsequent documentation corrections do not
clear R-1 or turn it into a current implementation review.

### Off-node candidate checks (2026-11-04)

The owner selected off-node preparation and initially withheld commits pending inspection. The owner
subsequently authorized the commits and PR update; the source is committed at `deae257`. These
observations do not change the draft status or tick any criterion. Current local checks pass Packer
formatting and validation, ShellCheck and 26 regression tests. A clean plugin directory installed
Proxmox 1.2.4 and QEMU 1.1.8 with Packer 1.16.2.

Base preparation passed in a fresh Ubuntu 24.04 amd64 environment, running as root with the documented
direct libguestfs backend and DHCP client. A separate non-root SSH-only client imported the retained
bundle, refused an occupied ID and preserved the seven original guests. No build packages were
installed on Proxmox. This is replacement-client evidence, not a completed Fedora system restore or
an already-configured off-host backup.

The earlier portable KVM build produced matching qcow2 and raw disks. Read-only inspection found no build
credentials or generated SSH override, and two fresh boots accepted their own keys with different
machine IDs and host keys. That earlier native run used `kvm64`. Its template build passed after increasing the API task timeout
from the plugin's one-minute default to the configurable ten-minute default. Both native fresh clones
then accepted distinct consumer users and keys, with different machine IDs and SSH host keys and
password authentication disabled. Read-only inspection of the stopped native template also passed
the sealing checks. The final audit confirms removal of all five owned test resources and temporary
API identities, with the seven original guest configurations and power states unchanged.
The native timeout addition does not change the portable source or shared provisioner scripts.

The retained test evidence is under `/tmp/builders-offnode/`, including `make-check-final2.log`,
`prepare-clean.log`, `import-final-results.json`, `portable-final-build.log`, `inspection-results.json`,
`portable-clone-results.json` and `native-results.json`. These local paths are review artifacts, not
durable public links. The committed [validation summary](../validation/0001-2026-11-04.md)
provides the portable record of these observations.

### Native host CPU follow-up (2026-11-04)

The owner selected configurable `host` after the earlier `kvm64` run. The follow-up native build
completed in 2 minutes 56 seconds. Its golden template and both fresh clones report `cpu: host`;
the clones expose the node's Xeon E5-2620 model, AES and AVX, accept separate consumer SSH keys and
have distinct machine IDs and host keys. Password authentication is disabled and the build password
is discarded. Read-only inspection of the stopped native disk passed the sealing checks.

The input guard was tightened after that build to reject surrounding whitespace. Only its condition
and error message changed; the selected valid `host` value, native CPU wiring, QEMU source and guest
scripts are unchanged. The guard-only diff and manifests record this boundary. Final Packer
validation, ShellCheck and all 26 regression tests passed again; exact-command records show a named
CPU override accepted locally and empty or padded names rejected. Alternate CPU model support on
the node is not established by local validation.

Evidence is under `/tmp/builders-hostcpu-20261104/`: `native-results.json`, `inspection-results.json`,
`cpu-validation-results.json`, `validation-guard-followup.patch`, `make-check-final.log` and
`final-audit.json`. All four owned test resources and temporary API identities were removed. The
seven original guests' configuration hashes and power states match the fresh preflight baseline.
The committed [validation summary](../validation/0001-2026-11-04.md) records these checks.
R-5 independently reran the local regression tests and read retained integration results. Its two
documentation nits were corrected here; it remains a dirty diagnostic, not current acceptance.

## Scope

- One Packer template for Ubuntu that can produce **either**:
  - a **Proxmox template** built natively via the Proxmox API (default, preferred), or
  - a **local qcow2/raw** artifact (the legacy portable path).
- The output format is **selected at build invocation**, not by editing the template.
- The Proxmox path lands a **template** (not just a VM) on the PVE host, with a **cloud-init drive**
  attached, ready for `bpg/proxmox` to clone.
- The image is **generic/unidentified**: no baked hostname, no static IP, no baked SSH host keys,
  fresh `machine-id` on every clone.

Out of scope:

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

`-only` is the selection mechanism; no template edits, no separate files. Both builders run the same
provisioners, so the *provisioning applied* is identical regardless of output shape (their base OS
differs; see the qemu note below).

> **Decided:** use `-only` (explicit, idiomatic, zero magic). No `build_target` variable.

### Required plugins

```hcl
packer {
  required_plugins {
    proxmox = {
      version = "= 1.2.4"
      source  = "github.com/hashicorp/proxmox"
    }
    qemu = {
      version = "= 1.1.8"
      source  = "github.com/hashicorp/qemu"
    }
  }
}
```

### Stage 0; base cloud-init template (bootstrap, once per Ubuntu release)

`proxmox-clone` clones an **existing** Proxmox template; it cannot download a cloud image itself. So we
first turn the official Ubuntu **cloud image** into a base cloud-init template on the PVE host. This is
**not** the per-build manual import we're eliminating; it runs *once per Ubuntu release*, and we commit
it as a repeatable script (`packer/ubuntu/scripts/create-base-template.sh`) rather than hand-clicking.

The owner selected off-node preparation on 2026-11-04. The independent Fedora bare-metal
workstation is the normal build host; a replacement Linux machine must be able to run the same
procedure without Stackweaver. Packer and image-preparation packages are not installed on Proxmox.

`packer/ubuntu/scripts/prepare-base-image.sh:1` creates a reusable bundle with a prepared disk,
its checksum, upstream checksum records and source/tool information. It installs the guest agent
and resets machine identity locally. `scripts/create-base-template.sh:1` checks an explicit unused
VM ID over SSH, verifies the local bundle and transfers it to a temporary node directory.
`scripts/import-base-template.sh:1` checks availability again and verifies the uploaded disk before
creating and configuring the new template with native Proxmox commands. Failed partial VMs remain
for inspection; these scripts contain no VM deletion path.

```bash
sudo bash scripts/prepare-base-image.sh /path/to/new/base-bundle
PVE_HOST=root@pve BASE_VMID=9000 BASE_IMAGE_DIR=/path/to/new/base-bundle \
  STORAGE=local-lvm BRIDGE=vmbr0 bash scripts/create-base-template.sh
```

The retained-bundle recovery path needs only Bash, OpenSSH and sha256sum on a replacement machine.
The from-source path also needs the documented libguestfs environment and upstream access.
`packer/ubuntu/recovery.md:1` describes both paths. Source downloads default to Ubuntu's moving
`current` directory and apt packages can change, so exact base reuse comes from the retained bundle,
not a promise that a later fresh build will be byte-identical.

### Stage 1; `source "proxmox-clone" "ubuntu"` (native Proxmox build, every build)

**Decided: `proxmox-clone` from the cloud-image base**; Packer clones the Stage-0 base, boots it,
customizes it with our provisioners, resets cloud-init state, and seals it as the golden template with
a fresh **empty** cloud-init drive. No per-build `qm importdisk`, no ISO install.

The following excerpt is abridged; `packer/ubuntu/ubuntu.pkr.hcl` is the executable configuration.

```hcl
source "proxmox-clone" "ubuntu" {
  # --- Proxmox API connection (Packer builds against this) ---
  proxmox_url              = var.proxmox_url            # https://pve.mvha.local:8006/api2/json
  username                 = var.proxmox_api_token_id   # e.g. "packer@pve!packer" (token id, not a login)
  token                    = var.proxmox_api_token      # API token secret (never committed)
  node                     = var.proxmox_node
  insecure_skip_tls_verify = var.proxmox_insecure       # false by default; explicit test-only opt-out
  task_timeout            = var.proxmox_task_timeout   # 10m API task wait; configurable for slower storage

  # --- base to clone (Stage 0) ---
  clone_vm      = var.base_template_name                # e.g. "ubuntu-noble-cloudimg"
  full_clone    = true
  cpu_type      = var.proxmox_cpu_type                  # host by default; configurable for migration requirements
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
- **No** hostname, static network config, or baked SSH host keys set here; the image stays generic.
  **Networking = DHCP** (decided); per-VM addressing is a clone-time concern.
- **Build-time SSH:** `proxmox-clone` generates a temporary SSH key and injects it via cloud-init.
  The username `ubuntu` and 20-minute SSH timeout are set explicitly; `qemu_agent = true` lets Proxmox report the VM's IP back to Packer.
- The builder finishes by **converting the VM back into a template**, so the output lands as a template,
  not a VM; no manual template step.

### Native CPU model

The owner resolved R-3 F-02 on 2026-11-04: use `host` as the native default and make it configurable.
`proxmox_cpu_type` feeds the native builder's `cpu_type`; it does not alter the portable QEMU source.
The single-node lab does not require live migration between different processors. A future cluster
needs a model supported by every target node. The follow-up native build and two fresh-clone checks
verified `cpu: host`, inherited configuration, guest AES/AVX features and the existing sealing checks,
as recorded in Context.
CPU model validation rejects blank and whitespace-padded values;
the target node remains responsible for rejecting unsupported model names.

### `source "qemu" "ubuntu"` (portable local artifact)

Retained (current builder, Ubuntu **cloud image** + `cidata` seed) for the portable qcow2/raw path and
fast local iteration. Same generic-image provisioners, so it no longer bakes identity either.

Both builders start from the same upstream Ubuntu release and share provisioners. Their starting
disks differ: the Proxmox bootstrap preinstalls the guest agent, clears machine-id and defaults to
32G, while QEMU boots the upstream image with a 10G disk. Local QEMU checks exercise shared image
provisioning; they do not establish native-builder correctness. Spec 0002 must test both paths.

### Provisioning changes (identity removal)

Both builders share the `build` block. Strip everything that makes the image machine-specific; that work
moves to cloud-init at clone time:

- **Remove** hostname assignment (`hostnamectl` / `/etc/hosts` / `hostname_vars.sh` reads).
- **Remove** the generated cloud-init `netplan`; clone-time cloud-init owns addressing. The selected
  design uses DHCP and leaves no builder-written fallback network file.
- **Remove** build-time creation of the `sysadmin` user + hardcoded `SSH_PUBLIC_KEY` and SSHD hardening.
  Users and keys are injected by cloud-init at clone time.
- **Reset cloud-init state before sealing** so every clone re-runs cloud-init as if first-booted
  (the classic template gotcha; otherwise clones skip clone-time init):
  ```bash
  cloud-init clean --logs --seed --configs ssh_config network
  ```
- **Regenerate machine-id on shutdown** so clones never collide:
  ```bash
  truncate -s 0 /etc/machine-id
  # ensure /var/lib/dbus/machine-id is a symlink to /etc/machine-id (or also truncated)
  ```
  `seal-image.sh` truncates `/etc/machine-id` and relinks the D-Bus machine-id to it.
- **Remove** any baked SSH host keys so each clone regenerates its own on first boot, and remove the
  temporary build SSH key Packer injected.

Native Ubuntu packages, locale, timezone and keyboard configuration are shared by both builders via
`cloud-init/build-config.yaml`. Shell customisations, MOTD and third-party tools remain the subject
of the separate PDS integration; this feature does not install PDS.

### Output

A Proxmox template (e.g. `template_name = "ubuntu-2404-k3s-base"`) sitting on the PVE host with a
cloud-init drive attached, generic and unidentified, ready for `bpg/proxmox` to clone with per-VM
initialization (hostname, IP, SSH keys, `edgectl` bootstrap user-data).

### Variables & secrets

New variables: `proxmox_url`, `proxmox_api_token_id`, `proxmox_api_token`, `proxmox_node`,
`proxmox_storage_pool`, `proxmox_cpu_type`, `proxmox_task_timeout`, `base_template_name`,
`proxmox_insecure`, `template_name`, `template_vmid`.

**Auth = API token** (decided). Create it once in the Proxmox UI (Datacenter → Permissions → API
Tokens): a user such as `packer@pve` with token id `packer` yields `proxmox_api_token_id =
"packer@pve!packer"` and a secret → `proxmox_api_token`. The secret must **not** be committed; supply
via `PKR_VAR_proxmox_api_token` (preferred) or an ignored `*.auto.pkrvars.hcl` file. The committed
`variables.pkrvars.hcl` contains non-secret values and requires an explicit `-var-file` argument.
Token authentication was verified with plugin 1.2.4. Use read permissions for discovery and scope
VM writes to the base and reserved output IDs, storage allocation to the target pool, and network
access to the selected bridge. A root API token is unnecessary. `template_vmid = 0` requests automatic
allocation; reserve an unused explicit ID when restricting the token to particular VM IDs.

### Earlier recorded decisions

- **Selection mechanism:** `-only` (explicit, idiomatic). No `build_target` variable.
- **Base:** the official Ubuntu **cloud image** (prebuilt OS + cloud-init), *not* an ISO install. No
  autoinstall/preseed.
- **Builder:** `proxmox-clone` from a cloud-image base template. The one-time base is created by a
  committed `create-base-template.sh` (Stage 0); Packer clones + customizes it every build (Stage 1).
- **Networking:** DHCP everywhere in the image; no static addressing baked in.
- **Auth:** Proxmox **API token** (for the Proxmox API that Packer builds against; a token created in
  the PVE UI, not the Terraform provider's creds).

### Current orchestration draft

`packer/ubuntu/ubuntu.pkr.hcl` uploads the image configuration, runs `scripts/wait-cloud-init.sh`, passes the config path to `scripts/install.sh`, and calls `scripts/seal-image.sh --image-build` last. The readiness provisioner has a 20-minute deadline. Both builders share that ordering. The disabled Ubuntu account and its standard sudo rule remain so the existing authenticated session can request shutdown. Clone-time inputs supply usable deployed access. PDS remains standalone; package-backed function selection belongs to feature 0003.

## Acceptance Criteria

- [ ] AC-01: A committed `create-base-template.sh` turns the official Ubuntu cloud image into a base cloud-init template on the PVE host (qemu-guest-agent embedded), repeatably; no hand-clicking.
- [ ] AC-02: `packer init .` installs both `hashicorp/proxmox` (`1.2.4`) and `hashicorp/qemu` plugins.
- [ ] AC-03: `packer build -only='proxmox-clone.ubuntu' …` clones the base and produces a **template** on the PVE node (verified via `qm config <vmid>` showing `template: 1`) with an **empty cloud-init drive** attached; no per-build `qm importdisk`/upload anywhere in the flow. The native CPU model defaults to `host` and is configurable; the template and two fresh clones use the selected default, and blank or whitespace-padded model names fail local validation.
- [ ] AC-04: `packer build -only='qemu.ubuntu' …` still produces the local qcow2/raw artifact.
- [ ] AC-05: The resulting image contains **no** baked hostname, static IP/netplan identity, or SSH host keys, and boots with a **fresh `machine-id`** (two clones get distinct ids).
- [ ] AC-06: The sealed image retains no build password, authorized keys or generated SSH policy override. The default Ubuntu account may remain only locked and keyless, with its standard sudo policy. Any usable deployed login and site-specific identity or SSH policy are supplied at clone time.
- [ ] AC-07: `packer/ubuntu/readme.md` documents the `-only` invocation for both formats and the required Proxmox variables/secrets.

## Test Plan

| Criterion | Proof |
| --- | --- |
| AC-01 | Run the off-node bootstrap from a clean supported environment on unused IDs; verify template, guest agent and reset identity. Import the saved bundle from a second minimal environment without Packer/libguestfs. Occupied-ID and corrupt-bundle attempts must leave all existing guests unchanged. |
| AC-02 | Run `make init`, then validate that both required plugin versions load. |
| AC-03 | Run the native Packer build with a scoped test token; inspect the output template flag, cloud-init volume and absence of temporary cloud-init credentials. Verify the native default and both fresh clones report `cpu: host` and expose node AES/AVX features; validate a CPU override and reject both an empty model and a whitespace-padded value such as `" host "`. |
| AC-04 | Run the QEMU builder with raw export enabled; inspect both formats and compare their disk contents. |
| AC-05 | Inspect a powered-off artifact, then boot two fresh instances with separate cloud-init inputs; compare machine IDs, host keys and applied identity. |
| AC-06 | Run the manual disposable-container `tests/test_sealing.sh` check with real cloud-init; verify sealing removes the temporary SSH password override and discards the build-password hash. `make check` lint-checks this script but does not execute its destructive guest changes. Inspect both sealed outputs and boot fresh instances with consumer-supplied users/keys; effective SSH policy must match clone-time inputs. |
| AC-07 | Follow the Ubuntu guide for both output selections and verify documented variables against the template. |

## Tasks

Delivery note: the post-approval changes in `deae257` are documentation only (AGENTS, the feature
record, README and recovery guide). The runtime and test files match the owner-reviewed manifest.
The merge from main adds its apt/PDS boundary to the migrated 0003 draft. No runtime feature changed.
R-7 observed AC-02 and AC-07 as met; live-build criteria remain not independently verified. Its full
criterion evidence is retained in the Review Log. No criterion is ticked while spec acceptance is pending.


Local worklist. The owner reviewed the implementation and authorized committing it, updating PR #4
and checking CI on 2026-11-04. No merge is authorized. No task or criterion is marked complete and no
formal specification acceptance is inferred from that delivery request.

- [ ] T1 `packer/ubuntu/tests/test_base_template.py` exercises remote refusal and retained-bundle recovery; observe missing-host and remote-preflight failures before implementing the transport (AC-01).
- [ ] T2 `packer/ubuntu/scripts/prepare-base-image.sh`, `create-base-template.sh`, `import-base-template.sh` implement off-node preparation, verified upload and guarded import; T1 and live replacement-environment checks pass (AC-01).
- [ ] T3 `packer/ubuntu/scripts/wait-cloud-init.sh`, `ubuntu.pkr.hcl` replace the Python adapter with strict Bash/jq checks; warning and malformed-result cases fail closed (AC-03, AC-04, AC-06).
- [ ] T4 `packer/ubuntu/scripts/seal-image.sh`, `tests/test_sealing.sh` remove generated SSH/network configuration and discard the build-password hash; the real cloud-init regression and final artifact checks pass (AC-05, AC-06).
- [ ] T5 `packer/ubuntu/recovery.md`, `readme.md` describe the tested bootstrap, recovery dependencies and both output commands (AC-01, AC-07).
- [ ] T6 `packer/ubuntu/ubuntu.pkr.hcl` is exercised by native and portable builds, sealed-artifact inspection and independent fresh clones; preserve existing Proxmox guests and clean only owned test resources (AC-02, AC-03, AC-04, AC-05, AC-06).
- [ ] T7 `packer/ubuntu/variables.pkr.hcl`, `ubuntu.pkr.hcl` and the example expose `proxmox_cpu_type` with default `host`; document the single-node decision, validate overrides and repeat the native build, CPU-feature and fresh-clone checks (AC-03, AC-05, AC-06, AC-07).

R-3 independently reran all 26 local tests and remained a dirty-tree diagnostic. Its retained
records below describe the evidence available during that review. The subsequent native clone and
disk-inspection results and final cleanup audit address the incomplete proof in F-01. The README now explains interrupted builds and inline preparation privileges (F-03/F-04),
and the recovery guide limits the moving URL claim to checksum identification (F-05). R-3 F-02
was resolved by the owner in the Native CPU model decision. None of these follow-ups makes R-3 current or establishes acceptance.

## Open Questions

### Q1: Should AC-05 explicitly require identity checks for both output paths?

**Recommendation:** A. Inspect both outputs and boot two fresh instances of each. The implementation
already received those checks, and this prevents verification of one base image from standing in for the other.

| Option | You get | It costs |
| --- | --- | --- |
| **A. Explicitly verify both outputs** | Native and portable identity behavior are both required. | Offline inspection and two fresh boots for each output in future acceptance runs. |
| **B. Keep the current wording** | The existing general image criterion remains. | Its proof can be read as accepting only one output. |

**Why this is yours:** It makes the required verification scope explicit in the definition of done.
The owner's current off-node and CPU-model decisions remain settled.


Off-node bootstrap is the owner's decision of 2026-11-04.
The Bash/jq adapter follows the request to avoid unnecessary Python and continue after that
recommendation. These implementation choices do not establish formal spec or feature acceptance.

The earlier R-1 F-02 assumed jq would need an extra installation. The actual noble/amd64 manifest
includes jq. The historic review is retained unchanged below. This draft also makes AC-06's
build-access exception explicit, so the current criterion requires a new review.

## Review Log

| Date | Review | Kind | Commit | Model | Isolation | Outcome |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-11-03 | R-1 | implementation | `dd92fec037e2338000f62471d1353e2d96cd5520+dirty` | claude-opus-5-5 | procedural | Diagnostic: one blocking finding; no criterion established as met. |
| 2026-11-04 | R-2 | implementation | `dd92fec037e2338000f62471d1353e2d96cd5520+dirty` | claude-opus-5-5 | procedural | Diagnostic: seven findings; integration verification was still running. |
| 2026-11-04 | R-3 | implementation | `dd92fec037e2338000f62471d1353e2d96cd5520+dirty` | claude-opus-5-5 | procedural | Diagnostic: five findings; 26 tests passed independently; live checks were still finishing. |
| 2026-11-04 | R-4 | implementation | `dd92fec037e2338000f62471d1353e2d96cd5520+dirty` | claude-opus-5-5 | procedural | Diagnostic of configurable host CPU; records retained below, live clone checks still running. |
| 2026-11-04 | R-5 | implementation | `dd92fec037e2338000f62471d1353e2d96cd5520+dirty` | claude-opus-5-5 | procedural | Final CPU diagnostic after R-4 repairs; no completion acceptance. |
| 2026-11-04 | R-6 | spec | `0b33ecf5dbcade3bb3042b1b0dc60d5cbad1e8d9` | claude-opus-5-5 | procedural | Six findings; factual corrections and one scope clarification. |
| 2026-11-04 | R-7 | implementation | `0b33ecf5dbcade3bb3042b1b0dc60d5cbad1e8d9` | claude-opus-5-5 | procedural | AC-02 and AC-07 met; remaining live criteria not independently verified. |

### R-1

```text
CRITERION: AC-01 A committed `create-base-template.sh` turns the official Ubuntu cloud image into a base cloud-init template on the PVE host (qemu-guest-agent embedded), repeatably; no hand-clicking.
VERDICT: not met
EVIDENCE: `git status --porcelain=v1` and `python3 -B -m unittest discover -s packer/ubuntu/tests -v`, dd92fec+dirty, the reviewed script shows as ` M packer/ubuntu/scripts/create-base-template.sh`, so the version under review is not committed; the 3 BaseTemplateSafety stub tests passed (missing ID, invalid IDs, occupied ID refused before any download or qm call), limitations: this review ran no bootstrap against Proxmox, the historical live run used an off-host container plus an SSH transport that is not in the repository (spec lines 77 to 78), and the committed HEAD version differs from the reviewed one.

CRITERION: AC-02 `packer init .` installs both `hashicorp/proxmox` (`1.2.4`) and `hashicorp/qemu` plugins.
VERDICT: not verified
EVIDENCE: `which packer` plus inspection of packer/ubuntu/ubuntu.pkr.hcl:1-12, dd92fec+dirty, packer is not installed on this host; the template pins proxmox `= 1.2.4` and qemu `= 1.1.8`, limitations: `make init` and `packer validate` were not executed in this review, and the historical Packer 1.16.2 run predates the three-stage refactor.

CRITERION: AC-03 `packer build -only='proxmox-clone.ubuntu' …` clones the base and produces a **template** on the PVE node (verified via `qm config <vmid>` showing `template: 1`) with an **empty cloud-init drive** attached; no per-build `qm importdisk`/upload anywhere in the flow.
VERDICT: not verified
EVIDENCE: inspection of packer/ubuntu/ubuntu.pkr.hcl:49-106, dd92fec+dirty, the proxmox-clone source sets full_clone, cloud_init = true and cloud_init_storage_pool, and the Packer flow has no importdisk or upload step (the single qm importdisk is in the once-per-release Stage 0 script), limitations: no native build ran in this review; the recorded live run predates the move of package installation from first-boot user-data to `cloud-init single` in install.sh.

CRITERION: AC-04 `packer build -only='qemu.ubuntu' …` still produces the local qcow2/raw artifact.
VERDICT: not verified
EVIDENCE: `python3 -B -m unittest discover -s packer/ubuntu/tests -v` (test_raw_export) plus inspection of ubuntu.pkr.hcl:19-40,108-115, dd92fec+dirty, export-raw.sh converted a disposable 2M qcow2 to raw, skipped conversion when disabled and refused to overwrite an existing raw, limitations: this is a subset; no QEMU Packer build ran, so the qcow2 artifact and the post-processor wiring were not observed.

CRITERION: AC-05 The resulting image contains **no** baked hostname, static IP/netplan identity, or SSH host keys, and boots with a **fresh `machine-id`** (two clones get distinct ids).
VERDICT: not verified
EVIDENCE: inspection of packer/ubuntu/scripts/seal-image.sh:10-21, dd92fec+dirty, sealing removes host keys, runs `cloud-init clean --logs --seed`, removes 50-cloud-init.yaml netplan, empties /etc/machine-id, relinks the D-Bus id and resets /etc/hostname to localhost; the only automated test of the sealer checks its argument guard, limitations: no artifact was inspected and no clones were booted in this review; the historical two-clone evidence predates the refactor.

CRITERION: AC-06 No hostname/user/SSH-key/SSHD-hardening provisioning runs at build time; those responsibilities are documented as belonging to clone-time cloud-init.
VERDICT: not verified
EVIDENCE: inspection of ubuntu.pkr.hcl:88-106, scripts/install.sh, cloud-init/build-config.yaml, cloud-init/user-data and packer/ubuntu/readme.md:13, dd92fec+dirty, the provisioners set no hostname, create no user and add no key or sshd hardening, and the readme assigns users, SSH access, hostname and networking to clone time; however the QEMU seed sets `ssh_pwauth: true` at build time, which changes sshd policy (see F-01), limitations: the Test Plan's boot of fresh instances with consumer-supplied users and keys was not executed.

CRITERION: AC-07 `packer/ubuntu/readme.md` documents the `-only` invocation for both formats and the required Proxmox variables/secrets.
VERDICT: not verified
EVIDENCE: inspection of packer/ubuntu/readme.md:81-130 against variables.pkr.hcl and proxmox.auto.pkrvars.hcl.example, dd92fec+dirty, the readme shows `-only='proxmox-clone.ubuntu'` and `-only='qemu.ubuntu'`, describes the token ID and secret, PKR_VAR_proxmox_api_token, proxmox_insecure, template_vmid and proxmox_storage_pool, and points to the example file for the remaining variables, limitations: the Test Plan proof is to follow the guide for both builds, which was not executed.

FINDING: F-01
KIND: factual
SEVERITY: blocking
WHERE: packer/ubuntu/cloud-init/user-data, packer/ubuntu/scripts/seal-image.sh
EVIDENCE: user-data:4 sets `ssh_pwauth: true`. On Ubuntu, cloud-init's set_passwords module then writes `PasswordAuthentication yes` to /etc/ssh/sshd_config.d/50-cloud-init.conf. That file sorts before the cloud image's 60-cloudimg-settings.conf, so its value wins. `cloud-init clean` does not remove it, and seal-image.sh:10-29 does not either. The portable artifact would therefore ship with password SSH enabled. This is inferred from cloud-init behaviour and was not observed in a built image here. The historical portable inspection (spec lines 83 to 86) did not check sshd drop-ins.
PROPOSAL: Remove the cloud-init sshd drop-in during sealing, or give the QEMU build key-based access, and add a sealed-artifact check that password authentication is disabled. Check whether Proxmox's generated build user-data has the same effect.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: packer/ubuntu/scripts/wait-cloud-init.py, Open Questions Q1
EVIDENCE: Dependency comparison. Python costs no extra guest dependency, because cloud-init is itself a Python program and every guest that has `cloud-init status` also has python3. Bash with jq adds a package that is not guaranteed in the Ubuntu cloud image. It would have to be present before the readiness parse on both paths: baked by virt-customize for the Proxmox base, and installed through the QEMU seed's first-boot apt run, which is the step this check waits on. That makes jq the costliest option. The refactor also changed what the check guards. Packages now install through `cloud-init single` in install.sh:11-13, which fails the build directly. First boot now only applies build access, and Packer's SSH connection already fails if that breaks. The JSON filter that rejects non-deprecation warnings was written for the earlier user-data package install. A short Bash step that runs `cloud-init status --wait` and accepts exit codes 0 and 2 needs no parser and no new dependency. Q1 offers only A and B and recommends jq.
PROPOSAL: Add a Bash-only option (accept 0 and 2, log `cloud-init status --long`) to Q1 and recommend it. If the owner wants to keep deprecation-only filtering, keeping Python is technically justified over jq. Either way, record the decision in Design and drop the jq recommendation.

FINDING: F-03
KIND: judgement
SEVERITY: nit
WHERE: packer/ubuntu/tests/, Makefile:11, AGENTS.md:18
EVIDENCE: All four test modules are Python, and they test Bash scripts through Python-written stubs. So `make check` requires Python 3 on the build host even if wait-cloud-init.py is removed. The test stubs for cloud-init are also Python scripts (test_cloud_init_status.py:18-25, test_image_steps.py:20-24).
PROPOSAL: If the owner wants a Python-free repository, plan a Bash test runner for the same refusal and conversion cases as a separate task. Otherwise state in AGENTS.md that Python is accepted for tests.

FINDING: F-04
KIND: factual
SEVERITY: should-fix
WHERE: Context
EVIDENCE: Line 69 says "Status remains `in-progress`", but the frontmatter says `status: draft`. Line 70 refers to a "bootstrap criterion above", but no criterion appears above it. Line 72 claims eight local tests; this review observed "Ran 10 tests". Lines 96 to 99 rest on "the task's retained validation report", which is not in the repository. Line 115 cites files without file:line, contrary to the standard's citation rule.
PROPOSAL: Make the status statements match the frontmatter, correct the test count, and either cite repository evidence or label the live run as uncited history.

FINDING: F-05
KIND: factual
SEVERITY: should-fix
WHERE: Design, Test Plan
EVIDENCE: Line 255 leaves a DHCP fallback "TBD in review", while lines 233 and 304 record DHCP as decided and seal-image.sh:15 removes the netplan file. Line 268 says "seal-image.sh already truncates ... make it authoritative", which describes the pre-change state. Lines 244 to 246 say both builders share the same base. In fact the Proxmox base has the guest agent preinstalled, machine-id cleared and a 32G disk (create-base-template.sh:17,41-49), while QEMU uses the raw image at 10G (ubuntu.pkr.hcl:25). Line 274 refers to "PR #4". The AC-01 Test Plan cell starts with a commit instruction rather than a proof.
PROPOSAL: Resolve or move the TBD into Open Questions, rewrite the stale sealing and same-base text to describe the current behaviour, and make the AC-01 proof a pass condition only.

FINDING: F-06
KIND: judgement
SEVERITY: should-fix
WHERE: packer/ubuntu/scripts/create-base-template.sh, packer/ubuntu/readme.md:61-65
EVIDENCE: The script requires qm, pvesh, curl, sha256sum and virt-customize on one host (lines 19 to 21), and `qm importdisk` reads a local path (line 55). The readme tells the user to install libguestfs-tools on the Proxmox node. The recorded validation instead ran the image tools in a disposable container and qm/pvesh over SSH, with "No packages were installed on the Proxmox host" (spec lines 77 to 78). That transport is not committed. The validated procedure therefore cannot be reproduced from the repository, and the documented one was not validated.
PROPOSAL: Choose the supported bootstrap shape (image preparation on the node, or off-node preparation followed by upload and qm on the node), commit it, and validate that exact path for AC-01.

FINDING: F-07
KIND: factual
SEVERITY: should-fix
WHERE: docs/specs/_template.md
EVIDENCE: `vh-adlc lint docs/specs/_template.md` returned `"result":"malformed"` with 11 findings. The file sits in the declared feature root and copies the central guides/feature-document-template.md. The onboarding guide says "Do not copy the central pages into every consumer."
PROPOSAL: Delete the local template and link the pinned central template from docs/specs/README.md.

FINDING: F-08
KIND: factual
SEVERITY: nit
WHERE: docs/specs/README.md:18
EVIDENCE: The README says "Start with `vh-adlc find`". Running `vh-adlc find --repo . --plugin-pin <pin>` returned "find takes exactly one of --issue and --slug".
PROPOSAL: Show the command with `--issue <n>` or `--slug <slug>`.

FINDING: F-09
KIND: judgement
SEVERITY: nit
WHERE: AGENTS.md, CLAUDE.md, .github/copilot-instructions.md
EVIDENCE: The pin is one full SHA and both bridges match the onboarding guide. AGENTS.md drops two lines from the guide's template: the route to guides/ pages for onboarding or bootstrapping, and "report a conflict instead of silently overriding either source". The onboarding files and the docs/specs migration fall outside the 0001 `covers` list but sit on the feature branch.
PROPOSAL: Restore the two lines, and commit the workflow migration separately from the feature 0001 implementation so the feature history and review target stay focused.

FINDING: F-10
KIND: judgement
SEVERITY: nit
WHERE: packer/ubuntu/scripts/seal-image.sh:11
EVIDENCE: `passwd -l ubuntu` keeps the hash of the known build password `ubuntu` (user-data:3) behind a reversible lock prefix in the shipped image.
PROPOSAL: Replace the hash as well, for example `usermod -p '*' ubuntu`, before or instead of locking.

FINDING: F-11
KIND: factual
SEVERITY: nit
WHERE: packer/ubuntu/ubuntu.pkr.hcl:16-17
EVIDENCE: The comment presents `-var 'arch=arm64' -var 'qemu_accelerator=hvf'` as the fast local path. The qemu source sets no qemu_binary, machine type or UEFI firmware for aarch64, and readme.md:137-138 says the configuration is unvalidated.
PROPOSAL: Mark the comment as unvalidated or remove it until arm64 is supported.

FINDING: F-12
KIND: factual
SEVERITY: nit
WHERE: packer/ubuntu/cloud-init/build-config.yaml:9, packer/ubuntu/ubuntu.pkr.hcl:21
EVIDENCE: `preserve_hostname: false` has no effect because install.sh:11 runs only package_update_upgrade_install, locale, timezone and keyboard. `cd_files = ["./cloud-init/*"]` also places build-config.yaml in the QEMU cidata seed, where NoCloud ignores it.
PROPOSAL: Drop the unused key and restrict cd_files to user-data and meta-data.

FINDING: F-13
KIND: factual
SEVERITY: nit
WHERE: readme.md:15
EVIDENCE: The covered root readme says "The native-builder draft is under review for PR #4." That text goes stale as soon as the PR closes.
PROPOSAL: Remove the transient PR status from the readme.

FINDING: F-14
KIND: judgement
SEVERITY: nit
WHERE: packer/ubuntu/scripts/create-base-template.sh:33-37, packer/ubuntu/ubuntu.pkr.hcl:27
EVIDENCE: Both paths fetch SHA256SUMS from the same HTTPS origin as the image and do not verify SHA256SUMS.gpg. This detects corruption but does not establish authenticity beyond TLS.
PROPOSAL: Decide whether TLS is enough. If not, verify the signed checksum file in the bootstrap.
```
### R-2

CRITERION: AC-01 A committed `create-base-template.sh` turns the official Ubuntu cloud image into a base cloud-init template on the PVE host (qemu-guest-agent embedded), repeatably; no hand-clicking.
VERDICT: not met
EVIDENCE: `git status --porcelain=v1`, `python3 -B -m unittest discover -s packer/ubuntu/tests -v` and inspection of scripts/prepare-base-image.sh, create-base-template.sh and import-base-template.sh, dd92fec037e2338000f62471d1353e2d96cd5520+dirty. The criterion asks for a committed script, but the tree shows ` M packer/ubuntu/scripts/create-base-template.sh` and `?? prepare-base-image.sh` and `?? import-base-template.sh`. That is the intended draft state, since the owner forbids commits. All 19 tests ran OK. They cover: missing ID, invalid IDs, missing host, an occupied ID refused before download or upload, a corrupt local bundle refused before upload, reuse of a verified bundle without preparation, a remote recheck and checksum refusal before any qm call, and an import sequence that ends with `qm template` and has no destroy. The tree was unchanged afterwards. Hashes in /tmp/builders-offnode/runtime-manifest.json match the current tree for all 20 listed files. Limitations: I did not run a preparation, upload or import against Proxmox. The retained /tmp/builders-offnode/prepare-base.log shows the first preparation failing apt with "Temporary failure resolving" and leaving a partial bundle with no base-image.sha256. prepare-clean.log has reached "Finishing off", but at 03:43 its bundle still held the unrenamed .img and no checksum record, so that run had not finished. No import-results.json exists, and the minimal-environment import and the occupied-ID and corrupt-bundle checks against live guests were not observed.

CRITERION: AC-02 `packer init .` installs both `hashicorp/proxmox` (`1.2.4`) and `hashicorp/qemu` plugins.
VERDICT: not verified
EVIDENCE: `/tmp/builders-pr4-tools/packer fmt -check -recursive .` and `PACKER_PLUGIN_PATH=/tmp/builders-offnode/fresh-plugins PKR_VAR_proxmox_api_token=validation-only-placeholder packer validate .` in packer/ubuntu, dd92fec+dirty, Packer v1.16.2. fmt exited 0 and validate printed "The configuration is valid.". fresh-plugins holds packer-plugin-proxmox_v1.2.4 and packer-plugin-qemu_v1.1.8. ubuntu.pkr.hcl:1-12 pins `= 1.2.4` and `= 1.1.8`. Limitations: I did not run `packer init` or `make init` myself. The only init evidence is the retained /tmp/builders-offnode/init-clean.log, which reports both plugins installed into an empty directory.

CRITERION: AC-03 `packer build -only='proxmox-clone.ubuntu' …` clones the base and produces a **template** on the PVE node (verified via `qm config <vmid>` showing `template: 1`) with an **empty cloud-init drive** attached; no per-build `qm importdisk`/upload anywhere in the flow.
VERDICT: not verified
EVIDENCE: inspection of packer/ubuntu/ubuntu.pkr.hcl:49-106 and a successful validate, dd92fec+dirty. The proxmox-clone source sets full_clone, cloud_init = true and cloud_init_storage_pool. The build has no import or upload step; the only `qm importdisk` is in the once-per-base import-base-template.sh:43. Limitations: no native build was run or observed and /tmp/builders-offnode/native-results.json does not exist. The output template flag, the cloud-init volume and removal of the build ciuser/sshkeys from the template configuration remain unobserved, and the repository has no code that clears them.

CRITERION: AC-04 `packer build -only='qemu.ubuntu' …` still produces the local qcow2/raw artifact.
VERDICT: not verified
EVIDENCE: unittest test_raw_export (ok) plus inspection of ubuntu.pkr.hcl:19-40,108-115 and scripts/export-raw.sh, dd92fec+dirty. The exporter converts only when enabled and refuses to overwrite. The retained /tmp/builders-offnode/portable-build.log (200 lines, RUNNING) shows the boot, a real cloud-init 26.1 status JSON accepted by wait-cloud-init.sh, and install.sh partway through apt upgrades. Limitations: the build had not finished. No qcow2 or raw artifact, no post-processor run and no format comparison was observed. The log is retained evidence I did not execute.

CRITERION: AC-05 The resulting image contains **no** baked hostname, static IP/netplan identity, or SSH host keys, and boots with a **fresh `machine-id`** (two clones get distinct ids).
VERDICT: not verified
EVIDENCE: inspection of scripts/seal-image.sh:13-22 and prepare-base-image.sh:33-42, dd92fec+dirty. Sealing removes host keys, runs `cloud-init clean --logs --seed --configs ssh_config network`, empties /etc/machine-id, relinks the D-Bus id, writes localhost to /etc/hostname and drops the 127.0.1.1 line. Preparation clears machine-id and host keys in the base. The retained /tmp/builders-sealing-tools/retained-regression.log reports the container sealing test passing. Limitations: that test ran in Docker with a test-only sed adapter for the bind-mounted /etc/hosts. No sealed artifact was inspected and no two-clone boot was observed. inspection-results.json does not exist.

CRITERION: AC-06 Only temporary build access is configured during image creation; the sealed image retains no build credentials or generated SSH policy override. Hostname, users, access keys and SSH policy for deployed machines are supplied at clone time.
VERDICT: not verified
EVIDENCE: inspection of cloud-init/user-data, scripts/seal-image.sh:10-16, ubuntu.pkr.hcl:75-77, and the retained /tmp/builders-sealing-tools/before.log, after.log and retained-regression.log, dd92fec+dirty. The current sealer replaces the ubuntu hash with `*`, removes authorized_keys and cleans the ssh_config and network configs. The retained logs show real cloud-init 26.2 reproducing `passwordauthentication yes` from the build seed, and then `passwordauthentication no` after the current sealer. Limitations: those logs are a container subset I did not execute. The build-created ubuntu account and its cloud-init sudoers drop-in survive sealing (F-01). Removal of the Proxmox-side build ciuser/sshkeys, inspection of both sealed outputs, and fresh clones with consumer-supplied users and keys were not observed.

CRITERION: AC-07 `packer/ubuntu/readme.md` documents the `-only` invocation for both formats and the required Proxmox variables/secrets.
VERDICT: not verified
EVIDENCE: inspection of packer/ubuntu/readme.md:160-269 against variables.pkr.hcl and proxmox.auto.pkrvars.hcl.example, dd92fec+dirty. The guide shows `-only='proxmox-clone.ubuntu'` and `-only='qemu.ubuntu'`, including the raw and tcg variants. It describes the token ID and secret, PKR_VAR_proxmox_api_token, proxmox_insecure, template_vmid and proxmox_storage_pool, and points to the example file for endpoint, node and base template name. The recovery.md anchor to Stage 1 resolves. Limitations: the Test Plan proof is to follow the guide for both outputs, and neither documented build was followed to completion.

FINDING: F-01
KIND: judgement
SEVERITY: should-fix
WHERE: packer/ubuntu/scripts/seal-image.sh:10-16, AC-06
EVIDENCE: On both builders the `ubuntu` account comes from build-time cloud-init. In the QEMU build the seed sets its password (user-data:3). In the Proxmox build, ubuntu.pkr.hcl:76 makes it the build user. Ubuntu's default_user also writes /etc/sudoers.d/90-cloud-init-users with NOPASSWD sudo. seal-image.sh locks the hash and deletes authorized_keys. It does not remove the account, its home directory or that sudoers file, and `cloud-init clean` does not remove them either. A clone whose clone-time config lists only its own users still gets a build-created `ubuntu` sudoer. AC-06 says users are supplied at clone time. This is inferred from cloud-init defaults. Neither test_sealing.sh nor any artifact check looked for it.
PROPOSAL: Either remove the build user and its cloud-init sudoers drop-in during sealing, or state in Design and AC-06 that a locked, keyless default account is an accepted residue. Add a sealed-artifact check for whichever is chosen.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: packer/ubuntu/recovery.md:56-83
EVIDENCE: The only measured from-source runs used the clean-tools Docker image as root (base-bundle files are owned by root). The first run failed DNS in the appliance (prepare-base.log). The clean run had not produced a final base-image.sha256 when last read. The recipe tells a user on a fresh Ubuntu 24.04 machine to install the packages with sudo and then run prepare-base-image.sh, with no statement about privileges. On Ubuntu hosts /boot/vmlinuz-* is mode 0600, and a non-root supermin appliance build usually cannot read it. This is inferred from known Ubuntu libguestfs behaviour and was not observed here.
PROPOSAL: State the privilege or kernel-readability requirement the measured run relied on. Keep the recipe labelled as a candidate until a completed run, outside any test-only network adaptation, produces an importable bundle.

FINDING: F-03
KIND: factual
SEVERITY: nit
WHERE: Context
EVIDENCE: Spec line 73 says "The refactored suite now has ten tests." This review observed "Ran 19 tests", and the retained make-check.log shows the same count.
PROPOSAL: Correct the count or drop it.

FINDING: F-04
KIND: judgement
SEVERITY: nit
WHERE: packer/ubuntu/scripts/create-base-template.sh:51-56, 30-37
EVIDENCE: `remote_dir` is the variable the EXIT trap passes to the remote `rm -rf -- '$remote_dir'`, and it is assigned from the ssh output before the regex check. If the remote command exits non-zero after printing (for example, rc-file output followed by a mktemp failure), set -e exits with an unvalidated string, and the trap interpolates it into a remote rm -rf. If the output fails validation, the variable is cleared and any directory that was created is left on the node without the "remove manually" message.
PROPOSAL: Capture into a local variable, validate it, and only then assign `remote_dir`. Report any unvalidated output instead of deleting it.

FINDING: F-05
KIND: judgement
SEVERITY: nit
WHERE: packer/ubuntu/tests/test_base_template.py, scripts/prepare-base-image.sh
EVIDENCE: There are no automated cases for prepare-base-image.sh refusing an existing output directory or an upstream checksum mismatch. Refusal of a partial bundle with no base-image.sha256 is not tested either; only inspection shows that `cat` fails under set -e at create-base-template.sh:47. The upload-failure and remote-cleanup paths are also untested, because the ssh stub never consumes stdin or fails. DISK_SIZE accepts values smaller than the prepared image, such as 1G, which pass validation and fail only at `qm resize` after `qm create`, leaving a partial VM (import-base-template.sh:41-49).
PROPOSAL: Add stubbed cases for these refusals and for cleanup after a failed upload. Consider rejecting DISK_SIZE values below the image's virtual size before creating the VM.

FINDING: F-06
KIND: judgement
SEVERITY: nit
WHERE: packer/ubuntu/scripts/wait-cloud-init.sh:8, ubuntu.pkr.hcl:93-96
EVIDENCE: `cloud-init status --wait` blocks until cloud-init finishes, and the shell provisioner sets no `timeout`, so a hung first-boot module stalls the build indefinitely rather than failing. The parsing itself fails closed: exit codes other than 0 and 2, non-JSON, multiple documents, a non-done status, non-array errors, non-object recoverable_errors and any category other than DEPRECATED are all rejected. The tests cover each of these, and the real cloud-init 26.1 JSON in portable-build.log matches the expected shape.
PROPOSAL: Set a provisioner timeout, or wrap the wait in `timeout`, so a stalled first boot fails the build.

FINDING: F-07
KIND: factual
SEVERITY: nit
WHERE: packer/ubuntu/readme.md:227
EVIDENCE: "Packer full-clones the base, applies provisioning, removes its temporary cloud-init credentials and converts the result to a template." No repository code clears the build ciuser/sshkeys from the Proxmox VM configuration, so the claim rests on Proxmox plugin behaviour, which only the pre-refactor live run observed (spec lines 80 to 81).
PROPOSAL: Mark the claim as plugin behaviour that the AC-03 template inspection must confirm, or cite the plugin documentation for it.

### R-3


CRITERION: AC-01 A committed `create-base-template.sh` turns the official Ubuntu cloud image into a base cloud-init template on the PVE host (qemu-guest-agent embedded), repeatably; no hand-clicking.
VERDICT: not met
EVIDENCE: `git status --porcelain=v1` before and after `python3 -B -m unittest discover -s packer/ubuntu/tests -v`, plus inspection of scripts/prepare-base-image.sh, create-base-template.sh and import-base-template.sh, at dd92fec037e2338000f62471d1353e2d96cd5520+dirty. create-base-template.sh is still ` M` and prepare-base-image.sh and import-base-template.sh are still `??`, so the criterion's committed script does not exist yet. The owner has deliberately forbidden commits, so this is expected. All 26 tests ran OK and the tree did not change. The stubs cover a missing or invalid ID, a missing host, an occupied ID refused before download, corrupt and partial bundles refused before upload, a refused remote allocation path that is never cleaned, cleanup of only the staging directory after a failed upload, reporting of a failed cleanup, a remote ID recheck, refusal of a shrink or upload corruption before `qm create`, and an import that ends in `qm template` with no destroy. On inspection, the remote command arguments are either validated against regexes or are the validated staging path. The upload directory is validated before it becomes the cleanup target. `qm create` refuses an ID taken after the check, and failures keep the partial VM. The current prepare-base-image.sh hash matches runtime-manifest.json, which was recorded before prepare-clean.log ran. The create and import hashes match runtime-manifest-final.json. Retained evidence I did not execute: prepare-clean.log ends with "Prepared base-image bundle", and base-bundle-clean holds base-image.sha256. import-final.log and import-final-results.json show non-root client "ubuntu" without Packer or libguestfs creating 990100 with `template: 1`, `agent: enabled=1`, scsi0, an ide2 cloud-init drive and `ipconfig0: ip=dhcp`, with occupied_id_refused true and protected_guests_unchanged true. refused-repeat-final.log shows "VM 990100 already exists". Limitations: I ran nothing against Proxmox. The Test Plan's corrupt-bundle attempt against live guests is not recorded; only stubbed corrupt-bundle cases exist. The guest agent inside the base was not inspected directly.

CRITERION: AC-02 `packer init .` installs both `hashicorp/proxmox` (`1.2.4`) and `hashicorp/qemu` plugins.
VERDICT: not verified
EVIDENCE: inspection of packer/ubuntu/ubuntu.pkr.hcl:1-12 and Makefile:4-5, dd92fec+dirty. The template pins proxmox `= 1.2.4` and qemu `= 1.1.8`, and `make init` runs `packer init .`. Retained /tmp/builders-offnode/init-clean.log reports both plugins installed into an empty plugin directory, and make-check-final2.log reports "The configuration is valid." Limitations: I did not run `packer init`, `make init` or `packer validate` in this review. The init log is retained evidence only.

CRITERION: AC-03 `packer build -only='proxmox-clone.ubuntu' …` clones the base and produces a **template** on the PVE node (verified via `qm config <vmid>` showing `template: 1`) with an **empty cloud-init drive** attached; no per-build `qm importdisk`/upload anywhere in the flow.
VERDICT: not verified
EVIDENCE: inspection of ubuntu.pkr.hcl:49-79 and 81-108, plus a hash comparison of the current tree against /tmp/builders-offnode/runtime-manifest-native-final.json, dd92fec+dirty. All 20 listed files match. The build has no import or upload step, and the only `qm importdisk` is in the once-per-base import-base-template.sh:46. Retained native-build.log ends with "A template was created: 990101" after 3 minutes 3 seconds. native-resume-snapshot.json shows 990101 with `template: 1`, `ide0: local-lvm:vm-990101-cloudinit` and no ciuser, sshkeys or cipassword. failed-native-task.json records the earlier one-minute timeout while the server-side clone finished. Limitations: no native build ran in this review. The template configuration comes from a retained snapshot I did not execute. native-results.json does not exist.

CRITERION: AC-04 `packer build -only='qemu.ubuntu' …` still produces the local qcow2/raw artifact.
VERDICT: not verified
EVIDENCE: unittest test_export_is_optional_and_does_not_overwrite (ok), inspection of ubuntu.pkr.hcl:19-40 and 110-117 and scripts/export-raw.sh, and a hash comparison against runtime-manifest-final.json, dd92fec+dirty. Only ubuntu.pkr.hcl, variables.pkr.hcl and proxmox.auto.pkrvars.hcl.example differ. portable-final-config-diff.patch limits the two .hcl changes to the native task_timeout and variable metadata. Retained inspect-portable-final.log and inspection-results.json report "Images are identical.", qcow2 format, a 10 GiB virtual size and qcow2_and_raw_identical true. Limitations: I did not run the QEMU build or inspect the artifacts. These are retained observations only.

CRITERION: AC-05 The resulting image contains **no** baked hostname, static IP/netplan identity, or SSH host keys, and boots with a **fresh `machine-id`** (two clones get distinct ids).
VERDICT: not verified
EVIDENCE: inspection of scripts/seal-image.sh:13-22 and prepare-base-image.sh:33-42, plus retained /tmp/builders-sealing-tools/retained-regression.log, inspection-results.json, portable-clone-results.json and native-resume logs, dd92fec+dirty. The sealer removes host keys, cleans cloud-init logs, seed, ssh_config and network, empties machine-id, relinks the D-Bus ID, sets localhost and drops the 127.0.1.1 line. On the portable side, the retained inspection reports generic_hostname, machine_id_empty, ssh_keys_absent and netplan_absent all true. Two portable boots report different machine IDs and host keys. On the native side, only clone 990102 exists in native-resume-snapshot.json. native-resume-before-ssh-order.log ends in a traceback ("Missing privilege separation directory: /run/sshd"), and native-resume.log records only VM states. No native offline inspection or second native clone is recorded. Limitations: I executed none of these checks. The native path, which starts from a different base, is not covered.

CRITERION: AC-06 The sealed image retains no build password, authorized keys or generated SSH policy override. The default Ubuntu account may remain only locked and keyless, with its standard sudo policy. Any usable deployed login and site-specific identity or SSH policy are supplied at clone time.
VERDICT: not verified
EVIDENCE: inspection of seal-image.sh:10-16, cloud-init/user-data, ubuntu.pkr.hcl:30-31 and 76-78, and tests/test_sealing.sh, plus retained before.log, after.log and retained-regression.log, dd92fec+dirty. The sealer sets the ubuntu hash to `*`, removes the ubuntu and root authorized_keys and runs `cloud-init clean --configs ssh_config network`. It leaves the account and its cloud-init sudoers drop-in, which the current wording permits. The retained container test with real cloud-init 26.2 shows `passwordauthentication yes` before sealing and `no` after it, with the hash `*` and 50-cloud-init.conf gone. The portable inspection reports build_keys_absent, build_ssh_override_absent and build_password_discarded true. Both portable boots show password_auth "no" and consumer_key_login true. The native template snapshot has no build ciuser or sshkeys, and clone 990102 carries consumer ciuser "probe1". Limitations: I executed none of these checks. The native clone's effective SSH policy check failed in the retained harness (empty `ssh_password_auth=`). Inspection of the native sealed disk is not recorded.

CRITERION: AC-07 `packer/ubuntu/readme.md` documents the `-only` invocation for both formats and the required Proxmox variables/secrets.
VERDICT: not verified
EVIDENCE: inspection of packer/ubuntu/readme.md:117-172 against variables.pkr.hcl and proxmox.auto.pkrvars.hcl.example, dd92fec+dirty. The guide shows `-only='proxmox-clone.ubuntu'` and `-only='qemu.ubuntu'`, including the raw and tcg variants. It covers the token ID and secret, PKR_VAR_proxmox_api_token, proxmox_insecure, template_vmid, proxmox_storage_pool and proxmox_task_timeout, and points to the example file for the endpoint, node and base name. The Stage 0 text at lines 100-112 matches the import code: the ID check runs before preparation, an ID repeat is refused, the uploaded copy is grown and shrinking is refused, and the inline bundle is removed. Limitations: the Test Plan proof is to follow the guide for both outputs. I did not follow it, and the retained build logs do not record which command line was used.

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Context, Uncommitted off-node candidate checks
EVIDENCE: Spec lines 142-143 say "Native clone checks, offline inspection and final resource cleanup are recorded separately in the owner review evidence." At 04:51 /tmp/builders-offnode had no native-results.json, no final-audit.json and no native entry in inspection-results.json. native-resume-before-ssh-order.log ends in a RuntimeError ("Missing privilege separation directory: /run/sshd", `ssh_password_auth=` empty). native-resume.log lists only states, with 990100, 990101, 990105 stopped and 990102 running. Only one of the intended clones (990102 and 990103 in native-attempt-intent.json) exists, and the test resources still exist.
PROPOSAL: Remove the claim, or replace it with the recorded native results once the second clone, the native disk inspection, the SSH policy check and cleanup have actually completed.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: packer/ubuntu/ubuntu.pkr.hcl:49-79
EVIDENCE: The retained native-resume-snapshot.json shows golden template 990101, and clone 990102 derived from it, with `cpu: kvm64`. The base template 990100 has no cpu key, so it uses the Proxmox default. The proxmox-clone source sets no cpu_type, so the plugin default kvm64 is written into the golden template and inherited by every clone. kvm64 does not expose AES-NI or x86-64-v2 features.
PROPOSAL: Set `cpu_type` explicitly, for example through a variable that defaults to `x86-64-v2-AES` or `host`. Add the CPU type to the native template inspection.

FINDING: F-03
KIND: judgement
SEVERITY: nit
WHERE: packer/ubuntu/readme.md:142-144
EVIDENCE: failed-native-task.json shows that after Packer's one-minute wait expired, the qmclone task finished with "OK" and left a full VM at the requested output ID (vm-990101-disk-0, 32G). The build log says "skipping cleanup". The readme explains the timeout but does not warn that an aborted build can leave that VM and block a retry with the same `template_vmid`.
PROPOSAL: State that a timed-out or aborted native build can leave a VM at the output ID, and that it must be inspected and removed, or a new ID chosen, before retrying.

FINDING: F-04
KIND: judgement
SEVERITY: nit
WHERE: packer/ubuntu/scripts/create-base-template.sh:43-46, readme.md:110-112
EVIDENCE: Without BASE_IMAGE_DIR, the script runs prepare-base-image.sh as the invoking user inside a mktemp work directory and deletes the bundle on exit. readme.md:74-75 and recovery.md:81-83 say preparation needs root, or a readable host kernel, on Ubuntu. Running the whole command under sudo switches the SSH identity and known_hosts to root's. The resulting base also cannot be reused for recovery. Neither of these combined paths appears in the retained live evidence.
PROPOSAL: Require BASE_IMAGE_DIR and keep preparation as a separate step, or state the privilege and SSH identity implications of the inline path.

FINDING: F-05
KIND: factual
SEVERITY: nit
WHERE: packer/ubuntu/recovery.md:91-93, scripts/prepare-base-image.sh:26-31
EVIDENCE: The retained base-bundle-clean/build-info.txt records `source_url=https://cloud-images.ubuntu.com/noble/current/...`, the architecture, the backend and the virt-customize version, but no dated image serial or preparation time. recovery.md says "the recorded upstream checksum and source URL explain the input used". After `current` moves, the checksum identifies the bytes but the URL no longer locates them.
PROPOSAL: Record the resolved dated serial and the preparation timestamp in build-info.txt, or reword the recovery text so it claims only checksum identification.

### R-4


```text
CRITERION: AC-01 A committed `create-base-template.sh` turns the official Ubuntu cloud image into a base cloud-init template on the PVE host (qemu-guest-agent embedded), repeatably; no hand-clicking.
VERDICT: not met
EVIDENCE: `git status --porcelain=v1` before and after `python3 -B -m unittest discover -s packer/ubuntu/tests -v`, plus a sha256 comparison of the tree against /tmp/builders-hostcpu-20261104/runtime-manifest.json, at dd92fec037e2338000f62471d1353e2d96cd5520+dirty. create-base-template.sh shows as ` M`, and prepare-base-image.sh and import-base-template.sh show as `??`. The criterion requires a committed script, and the owner's no-commit restriction means it cannot be met yet. All 26 tests ran OK. The status digest was identical before and after the run (1d65079f...). All 20 manifest entries match the current tree. Retained evidence I did not execute: base-import.log for the current run ends with "Base template created: test-builders-pr4-base-recovered (VM ID 990100)". base-ownership.json shows `template: 1`, `agent: enabled=1`, an ide2 cloud-init drive and `ipconfig0: ip=dhcp`. /tmp/builders-offnode/import-final-results.json records a non-root client without Packer or libguestfs, with occupied_id_refused true and protected_guests_unchanged true. Limitations: I ran nothing against Proxmox. A corrupt-bundle attempt against live guests is covered only by stubbed tests. The guest agent inside the base disk was not inspected directly.

CRITERION: AC-02 `packer init .` installs both `hashicorp/proxmox` (`1.2.4`) and `hashicorp/qemu` plugins.
VERDICT: not verified
EVIDENCE: inspection of packer/ubuntu/ubuntu.pkr.hcl:1-12, plus a listing of /tmp/builders-offnode/fresh-plugins and the retained init-clean.log, at dd92fec+dirty. The template pins proxmox `= 1.2.4` and qemu `= 1.1.8`. The plugin directory holds packer-plugin-proxmox_v1.2.4 and packer-plugin-qemu_v1.1.8 with their SHA256SUM files. init-clean.log reports both plugins installed by `packer init .`. The retained make-check.log reports "The configuration is valid." Limitations: I did not run `packer init`, `make init` or `packer validate`. All of this evidence is retained, not observed by me.

CRITERION: AC-03 `packer build -only='proxmox-clone.ubuntu' …` clones the base and produces a **template** on the PVE node (verified via `qm config <vmid>` showing `template: 1`) with an **empty cloud-init drive** attached; no per-build `qm importdisk`/upload anywhere in the flow.
VERDICT: not verified
EVIDENCE: inspection of ubuntu.pkr.hcl:49-80 and variables.pkr.hcl:67-76, plus a read (no execution) of /tmp/builders-hostcpu-20261104/run-native.py and the retained logs, at dd92fec+dirty. The native source sets `cpu_type = var.proxmox_cpu_type`. The variable defaults to `host` and rejects blank values. The qemu source has no reference to it. The build has no import or upload step. The current native-build.log reached "A template was created: 990101" after 2 minutes 56 seconds. controller.log then recorded "Native golden template and empty cloud-init configuration verified: 990101". template-ownership.json shows `cpu: host`, `template: 1`, `ide0: local-lvm:vm-990101-cloudinit,media=cdrom` and no ciuser, sshkeys or cipassword. Packer used the default because the controller sets no PKR_VAR_proxmox_cpu_type and refuses to run when an automatic vars file is present. validate-cpu-override.log shows "The configuration is valid." validate-empty-cpu.log shows the empty model refused by variables.pkr.hcl:72. Limitations: I executed none of this. When I last read the evidence, the controller had not started the clones. No clone ownership file existed, and no native-results.json, inspection-results.json or final-audit.json existed. The Test Plan's checks for inherited `cpu: host` in both clones and guest AES/AVX were therefore not yet recorded. The override log does not name the value tested.

CRITERION: AC-04 `packer build -only='qemu.ubuntu' …` still produces the local qcow2/raw artifact.
VERDICT: not verified
EVIDENCE: `diff -u` and `cmp` of the current packer/ubuntu sources against the portable-build snapshot /home/m/code/.cache/builders-offnode-20261104/portable-final/ubuntu, plus unittest test_export_is_optional_and_does_not_overwrite (ok), at dd92fec+dirty. All seven scripts and all three cloud-init files are byte-identical. ubuntu.pkr.hcl differs only by the native `task_timeout` and `cpu_type` lines. variables.pkr.hcl differs only by the arch description and the two native variables. The qemu source and the build block are unchanged. The new validation is evaluated in a qemu-only build as well, and the default value passes it. Retained /tmp/builders-offnode/inspection-results.json reports portable qcow2 with a 10 GiB virtual size and qcow2_and_raw_identical true. Limitations: I did not run the QEMU build or inspect its artifacts. This is retained evidence from that unchanged portable source.

CRITERION: AC-05 The resulting image contains **no** baked hostname, static IP/netplan identity, or SSH host keys, and boots with a **fresh `machine-id`** (two clones get distinct ids).
VERDICT: not verified
EVIDENCE: inspection of scripts/seal-image.sh:11-22, which matches the earlier tested snapshot byte for byte, plus the retained results in /tmp/builders-offnode and /tmp/builders-hostcpu-20261104, at dd92fec+dirty. The sealer removes host keys, cleans cloud-init logs, seed, ssh_config and network, empties machine-id, relinks the D-Bus id, writes localhost and drops the 127.0.1.1 line. The earlier inspection-results.json reports generic_hostname, machine_id_empty, ssh_keys_absent and netplan_absent true for both the portable and the earlier native disk. portable-clone-results.json and the earlier native-results.json each show two different machine IDs and host keys. Limitations: I executed none of these. That earlier native build used `cpu: kvm64` (final-audit.json, 990101). For the current host-CPU template, the two-clone boot and the offline disk inspection had not produced results when last read.

CRITERION: AC-06 The sealed image retains no build password, authorized keys or generated SSH policy override. The default Ubuntu account may remain only locked and keyless, with its standard sudo policy. Any usable deployed login and site-specific identity or SSH policy are supplied at clone time.
VERDICT: not verified
EVIDENCE: inspection of seal-image.sh:10-16, cloud-init/user-data and ubuntu.pkr.hcl:30-32 and 77-79 (all unchanged from the tested snapshot), plus run-native.py:155-191 read without execution and the retained results, at dd92fec+dirty. The sealer sets the ubuntu hash to `*`, removes the ubuntu and root authorized_keys and cleans the cloud-init ssh_config. The current native-build.log shows the plugin's own ephemeral-key removal reporting that those files are already absent. The earlier inspection-results.json reports build_keys_absent, build_ssh_override_absent and build_password_discarded true for both outputs. The earlier portable and kvm64 native clones report password authentication "no" and a locked ubuntu account, and the portable clones confirm consumer key login. The current template has no ciuser, sshkeys or cipassword. Limitations: I executed none of these. The current host-CPU clones' consumer SSH login, effective `passwordauthentication no` and locked-account checks, and the offline inspection of the current native disk, had not produced results when last read.

CRITERION: AC-07 `packer/ubuntu/readme.md` documents the `-only` invocation for both formats and the required Proxmox variables/secrets.
VERDICT: not verified
EVIDENCE: inspection of packer/ubuntu/readme.md:121-170 against variables.pkr.hcl and proxmox.auto.pkrvars.hcl.example, at dd92fec+dirty. The guide shows `-only='proxmox-clone.ubuntu'` and has a portable section for `-only='qemu.ubuntu'`. It covers the token ID and secret, PKR_VAR_proxmox_api_token, proxmox_insecure, template_vmid, proxmox_storage_pool and proxmox_task_timeout. Lines 154-160 state that proxmox_cpu_type defaults to `host`, that it refers to the hypervisor and not the Packer machine, that it must be overridden with a model shared by all nodes for cross-CPU migration, and how to override it, and that the portable builder is unaffected. The example file sets `proxmox_cpu_type = "host"` with the migration caveat. host-cpu.json (E5-2620, aes, avx, sse4_2, popcnt, no avx2) supports the README's statement that the x86-64-v2-AES example needs compatible hardware. Limitations: the Test Plan proof is to follow the guide for both outputs, and I did not follow it.

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Tasks (closing paragraph), Context "Uncommitted off-node candidate checks"
EVIDENCE: Spec lines 420-421 say "R-3 F-02 remains an owner question." That contradicts Design line 293 ("The owner resolved R-3 F-02 on 2026-11-04") and Open Questions line 425. Lines 141-146 report that the native template build and both native clones passed, but they do not say that this build predates `cpu_type`. The retained /tmp/builders-offnode/final-audit.json shows template 990101 and clone 990102 with `cpu: kvm64`.
PROPOSAL: Replace the "remains an owner question" sentence with a pointer to the Native CPU model decision. Label the 2026-11-04 native results as the earlier kvm64 build and keep them separate from the current host-CPU run.

FINDING: F-02
KIND: judgement
SEVERITY: nit
WHERE: Acceptance Criteria AC-03, Test Plan AC-03
EVIDENCE: The owner's CPU decision is checked only in the AC-03 Test Plan row ("report `cpu: host` and expose node AES/AVX features; validate a CPU override and reject an empty model"). The text of AC-03 and of every other criterion is silent on the CPU model, so a criterion record can be `met` without any CPU proof.
PROPOSAL: Add the native default CPU model and override behaviour to AC-03's text or a new criterion. That is a normative change and needs a new spec review.

FINDING: F-03
KIND: factual
SEVERITY: nit
WHERE: packer/ubuntu/variables.pkr.hcl:72-75, ubuntu.pkr.hcl:61
EVIDENCE: The validation checks `length(trimspace(var.proxmox_cpu_type)) > 0`, but the builder receives the untrimmed value. A value such as " host" or "host " passes validation and reaches the Proxmox API unchanged.
PROPOSAL: Also require `trimspace(var.proxmox_cpu_type) == var.proxmox_cpu_type`, or pass `trimspace(var.proxmox_cpu_type)` to `cpu_type`.

FINDING: F-04
KIND: factual
SEVERITY: nit
WHERE: /tmp/builders-hostcpu-20261104/validate-cpu-override.log
EVIDENCE: The log contains only "The configuration is valid." and records neither the command nor the override value. `packer validate` also does not ask the node whether the model is supported, so the log shows only that a non-empty override is accepted locally.
PROPOSAL: Record the exact command and value with the result. Describe the override proof as local validation, not as node support.
```

### R-5


CRITERION: AC-01 A committed `create-base-template.sh` turns the official Ubuntu cloud image into a base cloud-init template on the PVE host (qemu-guest-agent embedded), repeatably; no hand-clicking.
VERDICT: not met
EVIDENCE: I ran `git rev-parse HEAD` and took the sha256 of `git status --porcelain=v1` before and after `python3 -B -m unittest discover -s packer/ubuntu/tests -v`, at dd92fec037e2338000f62471d1353e2d96cd5520+dirty. HEAD is dd92fec. create-base-template.sh shows as ` M`. prepare-base-image.sh and import-base-template.sh show as `??`. The criterion requires a committed script, and the owner's no-commit restriction means this cannot be met at this target. The unittest run printed "Ran 26 tests" and "OK", and that includes the BaseTemplateSafety and RemoteImportSafety refusal, corrupt-bundle and reuse cases. The status digest was the same before and after (16a9e237...). Retained evidence I did not execute: /tmp/builders-hostcpu-20261104/controller.log reports "Disposable base imported from retained bundle." for this run, and /tmp/builders-offnode/import-final-results.json covers the earlier non-root recovery. Limitations: I ran nothing against Proxmox. I did not inspect the guest agent inside the base disk. Corrupt-bundle and occupied-ID refusal against a live node are retained or stubbed evidence only.

CRITERION: AC-02 `packer init .` installs both `hashicorp/proxmox` (`1.2.4`) and `hashicorp/qemu` plugins.
VERDICT: not verified
EVIDENCE: I inspected packer/ubuntu/ubuntu.pkr.hcl:1-12 and read the retained /tmp/builders-hostcpu-20261104/make-check-final.log, at dd92fec+dirty. The template pins proxmox `= 1.2.4` and qemu `= 1.1.8`. make-check-final.log shows `packer fmt -check`, `packer validate .` with "The configuration is valid.", ShellCheck and "Ran 26 tests ... OK", all run against the guarded source. The fresh-plugins link points to /tmp/builders-offnode/fresh-plugins, which R-4 listed as holding both pinned plugin binaries. Limitations: I did not run `packer init`, `make init` or `packer validate`. All of this evidence is retained, not executed by me.

CRITERION: AC-03 `packer build -only='proxmox-clone.ubuntu' …` clones the base and produces a **template** on the PVE node (verified via `qm config <vmid>` showing `template: 1`) with an **empty cloud-init drive** attached; no per-build `qm importdisk`/upload anywhere in the flow. The native CPU model defaults to `host` and is configurable; the template and two fresh clones use the selected default, and blank or whitespace-padded model names fail local validation.
VERDICT: not verified
EVIDENCE: Source inspection at dd92fec+dirty. ubuntu.pkr.hcl:61 sets `cpu_type = var.proxmox_cpu_type` in the proxmox-clone source only, and the qemu source has no CPU reference. variables.pkr.hcl:67-76 defaults to "host" and requires `length(trimspace(v)) > 0 && trimspace(v) == v`. Searching the repository finds `qm importdisk` only in the Stage 0 import-base-template.sh:46, and the build block has no import or upload step. I compared the current tree with runtime-manifest.json, and only packer/ubuntu/variables.pkr.hcl differs. I reversed the two lines of validation-guard-followup.patch in memory, and that reproduced the manifest hash da40255d... exactly. The build therefore used the same default, the same `cpu_type` wiring and the same provisioners as the current source. Read without execution: run-native.py sets no PKR_VAR_proxmox_cpu_type and refuses to run when an automatic vars file exists. Retained results I did not execute: native-build.log ends "A template was created: 990101" after "2 minutes 56 seconds". template-ownership.json and native-results.json show `template: 1`, `cpu: host` and `ide0: local-lvm:vm-990101-cloudinit,media=cdrom`, with no ciuser, sshkeys, cipassword or ipconfig. clone-990102-ownership.json and clone-990103-ownership.json both show `cpu: host`. native-results.json shows both clones with cpu_model "Intel(R) Xeon(R) CPU E5-2620 0 @ 2.00GHz" and aes_exposed and avx_exposed true. cpu-validation-results.json and the validate-*-cpu.log files record `packer validate -var proxmox_cpu_type=x86-64-v2-AES .` exiting 0, and `proxmox_cpu_type=` and `proxmox_cpu_type= host ` each exiting 1 with the variables.pkr.hcl validation message. Limitations: I executed no build, validate or clone step. The accepted override is local validation only, and its scope field says target-node support is not asserted. A whitespace-only value is rejected by inspection but was not executed.

CRITERION: AC-04 `packer build -only='qemu.ubuntu' …` still produces the local qcow2/raw artifact.
VERDICT: not verified
EVIDENCE: I ran `diff -u` and `cmp` of the current packer/ubuntu sources against the portable-build snapshot at /home/m/code/.cache/builders-offnode-20261104/portable-final/ubuntu, and ran unittest test_export_is_optional_and_does_not_overwrite (ok), at dd92fec+dirty. All seven scripts and all three cloud-init files are byte-identical. ubuntu.pkr.hcl differs only by the native `task_timeout` and `cpu_type` lines. variables.pkr.hcl differs only by the arch description and the two native-only variables, and the "host" default passes the new validation in a qemu-only run. The qemu source, the build block and the shell-local post-processor are unchanged. Retained /tmp/builders-offnode/inspection-results.json from that unchanged portable source reports qcow2_and_raw_identical true. Limitations: I did not run the QEMU build or inspect its artifacts.

CRITERION: AC-05 The resulting image contains **no** baked hostname, static IP/netplan identity, or SSH host keys, and boots with a **fresh `machine-id`** (two clones get distinct ids).
VERDICT: not verified
EVIDENCE: I ran `cmp` of scripts/seal-image.sh against the earlier tested snapshot (identical), read run-native.py:128-198 without executing it, and read the retained results, at dd92fec+dirty. In the current host-CPU native-results.json, clone 990102 has hostname test-builders-pr4-clone-1, machine_id 95a7e1d2... and host key SHA256:PbiVeJ..., and clone 990103 has test-builders-pr4-clone-2, 32b56175... and SHA256:fAmr6g.... Each hostname comes from its clone input. The controller checks that the SSH login host key matches the guest-agent fingerprint and that the two clones differ. The earlier /tmp/builders-offnode/inspection-results.json reports generic hostname, empty machine-id, absent host keys and absent netplan for the portable disk and the earlier kvm64 native disk. Limitations: I executed none of this. For the current host-CPU template, native-template.qcow2 exists under /home/m/code/.cache/builders-hostcpu-20261104, but no offline inspection result for it existed when I last read. No final-audit.json exists for this run, and the test resources 990100 to 990103 had not been audited as removed.

CRITERION: AC-06 The sealed image retains no build password, authorized keys or generated SSH policy override. The default Ubuntu account may remain only locked and keyless, with its standard sudo policy. Any usable deployed login and site-specific identity or SSH policy are supplied at clone time.
VERDICT: not verified
EVIDENCE: I inspected seal-image.sh, cloud-init/user-data and the shared provisioners (byte-identical to the earlier tested snapshot) and read run-native.py:158-192 without executing it, at dd92fec+dirty. Retained current results: both host-CPU clones report ubuntu_password "L" (the controller also asserts the shadow hash is `*`), ssh_password_auth "no" from `sshd -T`, and ssh_login_verified true. Each clone was logged into as its own clone-time user (probe1 or probe2) with a freshly generated key. The template config has no ciuser, sshkeys or cipassword. Earlier /tmp/builders-offnode/inspection-results.json reports build keys absent, SSH override absent and build password discarded for both earlier outputs. Limitations: I executed none of this. The current native sealed disk was exported but has no offline inspection result yet, so absence of authorized_keys and of the generated sshd drop-in in the current template disk is not shown directly.

CRITERION: AC-07 `packer/ubuntu/readme.md` documents the `-only` invocation for both formats and the required Proxmox variables/secrets.
VERDICT: not verified
EVIDENCE: I inspected packer/ubuntu/readme.md:121-176 against variables.pkr.hcl and proxmox.auto.pkrvars.hcl.example, at dd92fec+dirty. The guide shows `packer build -only='proxmox-clone.ubuntu' .` and a portable section for `-only='qemu.ubuntu'`. It covers the token ID and secret, PKR_VAR_proxmox_api_token, proxmox_insecure, template_vmid, proxmox_storage_pool and proxmox_task_timeout. Lines 154-160 explain the `host` default, that it means the hypervisor CPU and not the Packer machine, the shared-model guidance for migration, the override syntax, that the QEMU builder is unaffected, and the template and clone `cpu: host` check. The example sets `proxmox_cpu_type = "host"` with the migration caveat. The retained controller ran the same native `-only` command shape with environment variables. Limitations: the Test Plan proof is to follow the guide for both outputs, and I followed neither.

FINDING: F-01
KIND: factual
SEVERITY: nit
WHERE: Design, Variables & secrets
EVIDENCE: Spec lines 348-349 list "New variables: `proxmox_url`, `proxmox_api_token_id`, `proxmox_api_token`, `proxmox_node`, `proxmox_storage_pool`, `base_template_name`, `proxmox_insecure`, `template_name`, `template_vmid`." The current source adds `proxmox_cpu_type` (variables.pkr.hcl:67) and `proxmox_task_timeout` (variables.pkr.hcl:78), and both are used by the native source (ubuntu.pkr.hcl:56 and :61) and documented in the README and the example.
PROPOSAL: Add the two native variables to that list.

FINDING: F-02
KIND: factual
SEVERITY: nit
WHERE: Context, Native CPU model
EVIDENCE: Spec lines 296-297 still say another native build and two fresh-clone checks "must verify" `cpu: host`. The document names only /tmp/builders-offnode (lines 149-151) as the evidence location. /tmp/builders-hostcpu-20261104/native-results.json now records the host-CPU template and both clones passing. That same directory has no offline inspection result for native-template.qcow2 and no final-audit.json for removal of 990100 to 990103.
PROPOSAL: Record the host-CPU run's location and what it established. State that the current native disk inspection and the owned-resource cleanup audit are still pending until their outputs exist.

### R-6


FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Context, Test Plan AC-01
EVIDENCE: The target is the committed 0b33ecf, and `git status --porcelain=v1` is empty. deae257 committed the scripts and docs/validation/0001-2026-11-04.md. Several current-tense statements in the document still describe an uncommitted candidate with no durable evidence. Line 70 says "the current changes are uncommitted". Lines 99 to 101 say "That report is not in this repository, so the live results above are uncited history". Lines 105 and 126 use the labels "The current draft" and "Uncommitted off-node candidate checks". Lines 149 to 152 and 169 name only /tmp paths as "review artifacts, not durable public links". Searching the document finds no reference to docs/validation/0001-2026-11-04.md, even though packer/ubuntu/recovery.md:4 links to it. The AC-01 Test Plan cell still ends "Commit only after owner review." That is a process instruction, not a proof, and the commit it waits for has now happened. R-1 F-05 already flagged it.
PROPOSAL: Keep the dated 2026-11-03 and 2026-11-04 notes as history, but correct the present-tense commit-state statements and cite docs/validation/0001-2026-11-04.md as the committed evidence summary next to the /tmp paths. Remove the commit instruction from the AC-01 proof so the cell holds only a pass condition.

FINDING: F-02
KIND: factual
SEVERITY: should-fix
WHERE: Acceptance Criteria
EVIDENCE: Every criterion is unticked, yet each has an `Evidence:` line beneath it. The standard says a criterion is "ticked only with evidence beneath it, or left unticked with a residual". These lines also restate a diagnostic that is now stale. AC-01's line 403 says "R-5 returned `not met`: the owner prohibits committing this candidate before review". The owner has since authorized the commit, and create-base-template.sh, prepare-base-image.sh and import-base-template.sh are tracked at 0b33ecf. The other six lines cite R-5, a `dd92fec+dirty` diagnostic that `vh-adlc fresh` reports as stale with reason `dirty-target`.
PROPOSAL: Remove the Evidence lines from the unticked criteria and leave R-5's verdicts in the Review Log, where they already sit as history. Add evidence only when a current implementation review establishes a criterion.

FINDING: F-03
KIND: judgement
SEVERITY: should-fix
WHERE: Acceptance Criteria AC-05, Test Plan AC-05
EVIDENCE: Design lines 330 to 333 say the two builders start from different disks. The Proxmox base has the guest agent preinstalled, machine-id cleared and a 32G disk, while QEMU uses the upstream image at 10G. The same lines add that "Local QEMU checks ... do not establish native-builder correctness". AC-05 nonetheless speaks of "The resulting image" and "two clones", and its proof is "Inspect a powered-off artifact, then boot two fresh instances". One output alone can satisfy that proof. By contrast, the AC-06 proof says "Inspect both sealed outputs".
PROPOSAL: State in AC-05 and its Test Plan row that both the native template and the portable artifact are inspected offline, and that two fresh instances of each show distinct machine IDs and host keys. This is a normative revision.

FINDING: F-04
KIND: factual
SEVERITY: nit
WHERE: Test Plan AC-03
EVIDENCE: AC-03 requires that "blank or whitespace-padded model names fail local validation", and variables.pkr.hcl:192 enforces both cases. The AC-03 proof says only "validate a CPU override and reject an empty model". It sets no pass condition for a padded value.
PROPOSAL: Add rejection of a whitespace-padded `proxmox_cpu_type` (for example `" host "`) to the AC-03 proof.

FINDING: F-05
KIND: factual
SEVERITY: nit
WHERE: Design, Stage 1 and Native CPU model
EVIDENCE: Line 308 says "with no explicit communicator config, `proxmox-clone` generates an SSH key". However, ubuntu.pkr.hcl:78-79 sets `ssh_username = "ubuntu"` and `ssh_timeout = "20m"`. The HCL excerpt at lines 273 to 299 also omits `os`, `memory`, `cores` and `ssh_username` (ubuntu.pkr.hcl:64-66 and :78), and gives "ubuntu-2404-k3s-base" as the example template name, while variables.pkr.hcl:212 defaults to "ubuntu-2404-base". Lines 321 to 322 put delivery status ("authorized commits and the PR update ... Merging remains unauthorized") inside the normative Design section, so any later status update there counts as a revision.
PROPOSAL: Say that only the SSH key is generated, because the username and timeout are set explicitly. Either align the excerpt with the source or label it abridged. Move the delivery-authorization sentences to Context or Tasks.

FINDING: F-06
KIND: factual
SEVERITY: nit
WHERE: Sources
EVIDENCE: Line 859 lists "Legacy flow being replaced: `packer/ubuntu/ubuntu.pkr.hcl`, `scripts/install.sh`, `scripts/seal-image.sh`". deae257 deleted the legacy `scripts/cleanup.sh` and added seal-image.sh as a new file (`git show --stat HEAD~1`), so seal-image.sh is part of the replacement, not the legacy flow.
PROPOSAL: Replace `scripts/seal-image.sh` with the removed `scripts/cleanup.sh` in the legacy list, or point to deae257's parent for the legacy files.

### R-7


CRITERION: AC-01 A committed `create-base-template.sh` turns the official Ubuntu cloud image into a base cloud-init template on the PVE host (qemu-guest-agent embedded), repeatably; no hand-clicking.
VERDICT: not verified
EVIDENCE: `git ls-files`, `git status --short` and `python3 -B -m unittest discover -s packer/ubuntu/tests -v` at 0b33ecf5dbcade3bb3042b1b0dc60d5cbad1e8d9. The working tree is clean. create-base-template.sh, prepare-base-image.sh and import-base-template.sh are committed. The 16 base template tests passed. They cover a required remote host and explicit ID, refusal of a used ID, corrupt and partial bundles, upload corruption, the ID recheck, disk shrink refusal, reuse of a verified bundle and the qm sequence that creates a cloud-init template. In source, prepare-base-image.sh:34 installs qemu-guest-agent and clears machine-id and host keys, and import-base-template.sh:44-52 creates the VM, adds the cloud-init drive and runs qm template. I also read retained results in /tmp/builders-offnode/. import-final-results.json reports template 1, ide2 cloudinit, agent enabled=1 and a non-root client without Packer or libguestfs. refused-repeat-final.log shows the repeat refused. Limitations: I did not run the live preparation or import against Proxmox, so those results are the implementer's and I did not observe them. The local tests use stubs.

CRITERION: AC-02 `packer init .` installs both `hashicorp/proxmox` (`1.2.4`) and `hashicorp/qemu` plugins.
VERDICT: met
EVIDENCE: I ran `packer init .` in packer/ubuntu at 0b33ecf with Packer v1.16.2 (/tmp/builders-pr4-tools/packer), using an empty scratch PACKER_PLUGIN_PATH and config dir outside the repo. The output was "Installed plugin github.com/hashicorp/proxmox v1.2.4" and "Installed plugin github.com/hashicorp/qemu v1.1.8", with exit 0. A follow-up `packer validate .` with a placeholder token against those freshly installed plugins printed "The configuration is valid." Limitations: I ran the command directly rather than through `make init`, which runs the same command (Makefile:5). The run was on linux_amd64 only.

CRITERION: AC-03 `packer build -only='proxmox-clone.ubuntu' …` clones the base and produces a **template** on the PVE node (verified via `qm config <vmid>` showing `template: 1`) with an **empty cloud-init drive** attached; no per-build `qm importdisk`/upload anywhere in the flow. The native CPU model defaults to `host` and is configurable; the template and two fresh clones use the selected default, and blank or whitespace-padded model names fail local validation.
VERDICT: not verified
EVIDENCE: I ran `packer fmt -check -recursive .`, `packer validate .`, `packer validate -var 'proxmox_cpu_type=x86-64-v2-AES' .`, `packer validate -var 'proxmox_cpu_type=' .`, `packer validate -var 'proxmox_cpu_type= host' .` and `packer inspect .` in packer/ubuntu at 0b33ecf. fmt passed, the default and the override validated, empty and padded values exited 1 with the variables.pkr.hcl:72 rule message, and inspect shows proxmox_cpu_type "host". In source, ubuntu.pkr.hcl:49-79 sets full_clone, cpu_type = var.proxmox_cpu_type, cloud_init = true and cloud_init_storage_pool, and the Packer flow has no importdisk or upload. I also read retained results. /tmp/builders-hostcpu-20261104/native-results.json reports template 1, ide0 cloudinit and cpu host, and two clones with cpu host, the E5-2620 model, AES and AVX. I recomputed the hash after reversing validation-guard-followup.patch and it matches runtime-manifest.json (da40255d...). Of the 20 runtime files, only variables.pkr.hcl differs from the commit. Limitations: I did not observe the native build, the qm config check or the clones. Only the local validation part of this composite criterion ran in this review.

CRITERION: AC-04 `packer build -only='qemu.ubuntu' …` still produces the local qcow2/raw artifact.
VERDICT: not verified
EVIDENCE: `python3 -B -m unittest discover -s packer/ubuntu/tests -v` (test_raw_export) and `packer validate .` at 0b33ecf. The raw export test passed: export is optional, a real qemu-img conversion runs and an existing raw file is never overwritten. The qemu source and its export-raw.sh post-processor validate. I also read retained results. /tmp/builders-offnode/portable-final-build.log ends with qemu.ubuntu artifacts in output-noble-amd64, and inspection-results.json reports qcow2_and_raw_identical true at 10 GiB. Limitations: I ran no QEMU Packer build. The retained build predates the native CPU and timeout settings, which the manifests show leave the QEMU source unchanged.

CRITERION: AC-05 The resulting image contains **no** baked hostname, static IP/netplan identity, or SSH host keys, and boots with a **fresh `machine-id`** (two clones get distinct ids).
VERDICT: not verified
EVIDENCE: Inspection of seal-image.sh:13-22 at 0b33ecf. It removes ssh_host_*, runs `cloud-init clean --logs --seed --configs ssh_config network`, truncates /etc/machine-id, relinks the D-Bus id, sets /etc/hostname to localhost and drops the 127.0.1.1 hosts entry. I also read retained results. /tmp/builders-hostcpu-20261104/inspection-results.json reports native generic_hostname, machine_id_empty, ssh_keys_absent and netplan_absent all true. native-results.json shows two clones with distinct machine IDs and host keys. /tmp/builders-offnode/portable-clone-results.json shows the same for two portable boots. Limitations: I inspected no artifact and booted no instance. test_sealing.sh needs Docker, which this review may not run.

CRITERION: AC-06 The sealed image retains no build password, authorized keys or generated SSH policy override. The default Ubuntu account may remain only locked and keyless, with its standard sudo policy. Any usable deployed login and site-specific identity or SSH policy are supplied at clone time.
VERDICT: not verified
EVIDENCE: Inspection of seal-image.sh:11-16, cloud-init/user-data and ubuntu.pkr.hcl:30-31 and 76-78 at 0b33ecf. The sealer sets the ubuntu hash to `*`, removes the ubuntu and root authorized_keys and cleans the cloud-init ssh_config, which drops 50-cloud-init.conf. The account and its sudo drop-in remain, as the criterion allows. I also read retained results. The native and portable inspection-results.json files report build_keys_absent, build_ssh_override_absent and build_password_discarded true. Both native clones show ubuntu_password "L", ssh_password_auth "no" and ssh_login_verified true. final-audit.json shows clone 990102 configured with consumer ciuser probe1, and the template config in native-results.json has no ciuser or sshkeys. Limitations: I did not run test_sealing.sh (Docker is prohibited here, and make check does not run it). I observed no sealed disk and no fresh boot.

CRITERION: AC-07 `packer/ubuntu/readme.md` documents the `-only` invocation for both formats and the required Proxmox variables/secrets.
VERDICT: met
EVIDENCE: Read packer/ubuntu/readme.md and cross-checked every variable declared in variables.pkr.hcl against the readme and proxmox.auto.pkrvars.hcl.example at 0b33ecf. readme.md:130 gives `packer build -only='proxmox-clone.ubuntu' .`. readme.md:177-183 give the qemu forms, including output_raw=true. readme.md:123-145 tells the reader to copy the example file, which sets proxmox_url, proxmox_api_token_id, proxmox_node, proxmox_insecure, proxmox_storage_pool, proxmox_cpu_type, proxmox_task_timeout, base_template_name, template_name and template_vmid. The secret is supplied via a hidden-prompt PKR_VAR_proxmox_api_token, with a never-commit warning. Every Proxmox and template variable in the template appears in the readme or the example it references. Limitations: I did not follow the guide through either build. Several variable names appear only in the referenced example file, not in the readme prose.

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Context (Live validation before the structure refactor) and Acceptance Criteria AC-01 Evidence
EVIDENCE: docs/specs/0001-packer-proxmox-native-output.md:69-70 says "the current changes are uncommitted. AC-01 remains unchecked", and :403 says "R-5 returned `not met`: the owner prohibits committing this candidate before review." `git status --short` at 0b33ecf is clean, and all AC-01 scripts are tracked.
PROPOSAL: Update both passages to state that the candidate is committed at deae257 and merged in 0b33ecf, and that R-5 is a historical dirty diagnostic. Leave AC-01 unticked until a current review establishes it.

FINDING: F-02
KIND: judgement
SEVERITY: nit
WHERE: Delivery boundary (owner-approved candidate versus committed tree)
EVIDENCE: Comparing /tmp/builders-pr4-delivery-20261104/approved-manifest.json with `git show` blobs gives 50 paths checked. Four differ at deae257: AGENTS.md, the 0001 spec, packer/ubuntu/recovery.md and readme.md. 0b33ecf additionally differs in the 0003 spec from the merge. All runtime and test files match. recovery.md is within `covers`.
PROPOSAL: Record that the post-approval changes are documentation only, or regenerate the approval manifest from deae257, so the claim "committing the reviewed candidate" is exact.

FINDING: F-03
KIND: judgement
SEVERITY: nit
WHERE: Test Plan AC-06 and Makefile check target
EVIDENCE: Makefile:8-11 only runs ShellCheck on tests/test_sealing.sh. The unittest discovery runs 26 Python tests and none runs the sealer against real cloud-init. readme.md:207-215 documents a manual Docker run. The sealing behaviour behind AC-05 and AC-06 therefore has no automated local regression in `make check`.
PROPOSAL: Note in the Test Plan that test_sealing.sh is a manual container check, and have spec 0002 run it in CI.

## Sources

- [Packer `proxmox-clone` builder](https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox/latest/components/builder/clone)
- [Create Proxmox cloud-init templates for Packer (base bootstrap)](https://dev.to/mike1237/create-proxmox-cloud-init-templates-for-use-with-packer-193a)
- [kencx homelab: Packer proxmox-iso vs proxmox-clone](https://kencx.github.io/homelab/images/packer.html)
- [Building Ubuntu 24.04 Proxmox templates with Packer](https://thecomalley.github.io/packer-proxmox-ubuntu)
- [Packer `-only` / `-except`](https://developer.hashicorp.com/packer/docs/commands/build#only-foo-bar-baz)
- [`bpg/proxmox` Terraform provider](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
- Legacy flow before `deae257`: `packer/ubuntu/ubuntu.pkr.hcl`, `scripts/install.sh` and the removed `scripts/cleanup.sh`.
- [Feature-document standard](https://github.com/vhco-pro/docs/blob/0e52f51f01b84eda75a976763c42d8ec0a07b544/conventions/feature-documents.md): lifecycle, criteria, proof and review-record formats.

- [Committed validation summary](../validation/0001-2026-11-04.md): implementer-observed build, recovery, clone and cleanup checks, with their limits.
