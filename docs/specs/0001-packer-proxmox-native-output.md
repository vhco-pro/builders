---
status: in-progress
status_description: "Implementing the approved PDS package and recipe tasks; no merges or releases authorized."
issue: https://github.com/vhco-pro/builders/issues/1
goal: "Build customizable Ubuntu images with PDS bootstrap and opinionated update/SSH defaults, as optional Proxmox templates or standalone qcow2/raw disks."
covers:
  - packer/ubuntu/
  - Makefile
  - readme.md
  - packer/readme.md
  - docs/ubuntu/
  - docs/development.md
  - .github/workflows/
  - renovate.json5
branch: feat/0001-packer-proxmox-native
---

# Plan: Ubuntu baseline images with PDS, updates and restricted SSH

Build reusable Ubuntu images with a builders default recipe calling PDS for nightly updates and restricted SSH;
operators may select a custom recipe with different choices.
Select a standalone disk or optional native Proxmox template; supply deployment identity through
cloud-init.

## Context

The owner explicitly accepted the default-recipe/customization contract and requested continuation
on 2026-11-05 after the owner-facing explanation. That approval covers implementing and testing this
scope, including the PDS dependency; it does not authorize merging or publishing the homelab guides.
R-17 retains two non-blocking notes for the implementation: observe selected SSH-policy application
inside custom recipes, and distinguish the builders recipe from the PDS function library. No new
product policy was inferred from that review.


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
The task retained raw logs, cleanup evidence and runtime file hashes privately. These early troubleshooting details remain history recorded only in private artifacts. The committed
[validation summary](../validation/0001-2026-11-04.md) covers the later off-node preparation,
portable build and host-CPU run; it does not reproduce every earlier experiment.
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
covers the later host-CPU run and the portable checks. The earlier `kvm64` timeout/retry and
five-resource cleanup details above remain history in private artifacts.

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

### Settled decisions and earlier review notes

Automatic updates and restricted SSH are core baked-image requirements, confirmed by the owner on
2026-11-04. Keep the earlier nightly midnight update policy and require public-key SSH with password
and root logins disabled. Deployment supplies machine identity and authorized users/keys; it does
not have to recreate this baseline policy.


The owner selected Zi's existing per-user first-login plugin downloads on 2026-11-04, preserving
the current configuration instead of introducing image-specific prefetching and cache maintenance.
The bootstrap guide must state the first-login network requirement and plugin-version variability.


Off-node bootstrap is the owner's decision of 2026-11-04.
The Bash/jq adapter follows the request to avoid unnecessary Python and continue after that
recommendation. These implementation choices do not establish formal spec or feature acceptance.

The earlier R-1 F-02 assumed jq would need an extra installation. The retained `/tmp/builders-offnode/portable-final-build.log` shows `wait-cloud-init.sh`
using jq to parse real cloud-init status in the tested noble/amd64 build. The historic review is retained unchanged below. This draft also makes AC-06's
build-access exception explicit, so the current criterion requires a new review.

### Combined PR preparation (2026-11-04)

The owner selected one builders PR for the native/portable outputs, the PDS provisioning replacement,
its required image checks and the README restructure. The dependent shared-library work stays in
`michielvha/PDS`. PR #4 remains open; merging either repository requires the owner's final review.
The wider multi-OS/macOS harness stays in feature 0002.

At preparation time, `scripts/install.sh:11-13` only invokes four native cloud-init modules and
`ubuntu.pkr.hcl:88-109` does not install PDS. The earlier
`origin/main:packer/ubuntu/scripts/install.sh` supplied MOTD at lines 65-115, Zi/shell setup at 133-137, SSH restrictions at 151, user/sudo setup at 153-169, nightly updates at 183 and
kubectl at 190, while also editing bootloaders. GitHub CLI was in
`origin/main:packer/ubuntu/cloud-init/user-data:42`. This revised scope replaces the useful shared
bootstrap without restoring baked users, keys or network identity. Earlier statements that PDS was a separate delivery describe the prior scope.

The existing candidate at `/home/m/code/PDS-image-provisioning`, based on PDS `04c8dee` with
uncommitted changes, supplies packaged shell assets, unattended loading and MOTD. Its package
`pds_1.0.0_all.deb` has SHA-256
`378a2ef2d1277c54fd4524abfe160d0648cd501e98d7cd26b716de240a495991`.
The existing package suite passed nine tests against a read-only source snapshot in a disposable
network-isolated container. Those tests use a Zi stub and do not establish real plugin installation,
GitHub CLI/kubectl installation or a bootable PDS image. Preparation evidence is retained privately
under `/tmp/builders-pds-prep-20261104/`.

`gh api repos/michielvha/PDS/releases/latest` reported release `0.19.0` and asset
`pds_0.19.0_all.deb`; `gh api repos/michielvha/PDS/commits/main` returned `04c8dee`.
The local `1.0.0` label is a placeholder, identified here by the package checksum; it is not a
published replacement version or a prediction of the CI-assigned release number. The PDS pull-request
list contained only unrelated Cloudflare-host PR #34, which remains outside this work.

Two inspected library gaps affect image use. `bash/debian/software/install_kubectl.sh:21-57` writes
completion into the invoking user's home; lines 59-104 install user-local Krew/plugins and tolerate
failures. `bash/common/shell/zsh.sh:16` clones Zi without a revision pin, while the packaged zshrc
selects plugins that may download on first shell startup. A passing package loader test does not
prove that a newly deployed user receives functional, self-contained tooling.

This is a normative scope revision. All criteria remain unchecked; earlier reviews below are history
for their recorded targets and do not accept the combined scope. No implementation or final image
validation is claimed by this preparation.

## Scope

- One Ubuntu Packer template with shared provisioning for a standalone qcow2/raw disk and an optional
  native Proxmox template. Both outputs are selected explicitly with `-only`.
- Off-node base preparation and retained-bundle recovery. Packer and libguestfs stay off Proxmox.
- Native Ubuntu packages/settings through cloud-init, plus an exact PDS package and a readable
  select-and-apply bootstrap for Zi/Powerlevel10k, MOTD, GitHub CLI and kubectl.
- The default recipe applies nightly package updates and restricted SSH through PDS to both outputs.
  Custom recipes may deliberately change or omit those policy selections.
- Shared configuration available to users created after sealing. No fixed admin user or key is baked in.
- Package verification, static/local regression checks, real amd64 builds, offline inspection and two
  independently initialized boots for each output. Test resources have recorded ownership.
- Short READMEs linking build, bootstrap, SSH/debugging, recovery and validation procedures under docs/.

Out of scope:

- Deploying Stackweaver, production workloads or consumer Terraform configurations.
- Merging, releasing PDS, publishing homelab articles or modifying pre-existing Proxmox guests.
- The wider feature 0002 matrix: Apple Silicon/HVF acceptance, another OS/template and a permanent
  self-hosted runner. Its absence cannot excuse missing checks for this Ubuntu amd64 delivery.
- Changes to the unrelated PDS Cloudflare-host feature or other installers beyond shared bootstrap
  dependencies needed here. PDS remains independently usable for ordinary host setup.

## Design

### Selecting output format at invocation

Packer supports multiple `source` blocks in one template and running a subset via `-only` / `-except`.
We define **two builders sharing one `build` block** (and therefore one set of provisioners), and pick
at the command line:

```bash
packer init .

# Optional Proxmox-native template
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
provisioning; they do not establish native-builder correctness. This feature tests both Ubuntu amd64 paths; spec 0002 covers the wider OS/macOS matrix.

### Provisioning changes (identity removal)

The QEMU seed grants temporary password SSH access for the build. Sealing replaces that password
hash with `*` and removes cloud-init's generated SSH policy override. The native builder instead
injects a temporary SSH key; both paths discard their build access before export.

Both builders share the `build` block. Strip everything that makes the image machine-specific; that work
moves to cloud-init at clone time:

- **Remove** hostname assignment (`hostnamectl` / `/etc/hosts` / `hostname_vars.sh` reads).
- **Remove** the generated cloud-init `netplan`; clone-time cloud-init owns addressing. The selected
  design uses DHCP and leaves no builder-written fallback network file.
- **Remove** build-time creation of the fixed `sysadmin` user and hardcoded `SSH_PUBLIC_KEY`.
  Users and keys are injected by cloud-init at clone time. When selected by the recipe, generic SSH restrictions are supplied by
  PDS at build time and retained in the finished image.
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
`cloud-init/build-config.yaml`. Shell customisations, MOTD and selected third-party tools are supplied by the package-backed PDS
step described below. The current executable baseline does not implement that step yet.

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

`packer/ubuntu/ubuntu.pkr.hcl` uploads the image configuration, runs `scripts/wait-cloud-init.sh`, passes the config path to `scripts/install.sh`, and calls `scripts/seal-image.sh --image-build` last. The readiness provisioner has a 20-minute deadline. Both builders share that ordering. The disabled Ubuntu account and its standard sudo rule remain so the existing authenticated session can request shutdown. Clone-time inputs supply usable deployed access. The expanded design adds the package-backed PDS step between native Ubuntu configuration and sealing. PDS remains standalone.

### Default recipe and explicit customization

The owner approved this contract on 2026-11-05: builders is a readable image recipe using shared PDS
functions. The supplied default selects Zi/Powerlevel10k, the chosen MOTD, tooling, nightly updates
and restricted SSH. Those selected defaults must be applied reliably and tested. They are not a
mandatory policy for every custom image built with this repository.

Keep the default function sequence in `packer/ubuntu/recipes/default.sh`. Packer's
`provisioning_recipe` input defaults to that file. An operator can select another readable Bash recipe
at build time, without changing the default recipe or PDS. Builders uploads the selected recipe,
loads the installed PDS library, and runs that recipe as trusted image-build code; it never evaluates
a string of function names. Missing recipe files and failed selected calls stop the build.
The committed `recipes/custom.example.sh` selects Zi/configuration and a MOTD while omitting the
update and SSH-policy calls. No profile
framework or duplicated policy implementation is needed.

Builders exports `BUILD_MOTD_PRESET` and `BUILD_KUBECTL_CHANNEL` to the selected recipe. The default
recipe consumes them; a custom recipe explicitly controls whether to use or ignore those inputs.

Skipping a policy call means builders does not apply that PDS policy. It does not reverse policy
inherited from the Ubuntu source or a customized parent image, and does not itself enable password
login. A custom recipe must explicitly configure any different behavior it wants. Tests check the
default recipe's strong settings and a custom recipe's actual selections separately.

Native Ubuntu configuration, PDS package identity checks and image sealing remain builder steps.
Custom recipes do not disable removal of temporary build credentials or reset of machine identity.
The default and custom paths both leave real users, public keys, hostname and addressing to deployment.
A PDS helper can still configure a normal host's user/key; cloud-init is the default VM-deployment
entry point and does not become a dependency of standalone PDS.

### PDS provisioning and package identity

Builders installs an exact PDS version, sources `/usr/share/pds/init.sh` explicitly in non-interactive
Bash and calls named shared functions. Native Ubuntu apt packages remain in
`cloud-init/build-config.yaml`; reusable software installers and configuration stay in PDS.
`install.sh` keeps its explicit cloud-config input and short orchestration role. Sealing and base
preparation remain separate scripts; PDS does not acquire Proxmox or sealing responsibilities.

Normal builds obtain the selected version from the signed PDS APT repository. Version and trust
inputs are explicit, updater-discoverable build configuration. Missing versions, trust failures,
missing functions and failed selected installers stop the build. No fallback to `latest`, the default
branch, a local source directory or a different installed version is allowed.

Before PDS is merged/released, an explicit candidate-package input may upload a locally built `.deb`
for integration tests. It requires the expected package name, version and SHA-256; the installed
package must match them. The build records candidate provenance and must not label this route as
published-release validation. The normal signed-repository route must also pass before final delivery.
No PDS release or merge is triggered by preparing this builders PR.

The owner first reviews the dependent PDS PR. Only after separate owner authorization may that PR
be merged and its existing release pipeline run. Record the actual CI-assigned version and published
package identity in builders, replacing the candidate test input, then repeat signed-repository
builds and fresh-user checks for both outputs. Until then the builders PR is a candidate integration;
it cannot receive final implementation acceptance from local-package tests alone. The agent does not merge or
trigger a release through this handoff.

Only the needed PDS libraries and packaging receive dependent repairs. Both installed-package and
standalone checkout/raw-bootstrap usage are checked; loading the library defines functions without
running installers, changing shell options or downloading anything. No Proxmox dependency is added.

The exact PDS version identifies the built image at seal time. Keep the signed PDS source/trust key
and selected third-party APT repositories in the sealed image. With the default recipe, the nightly all-package update policy
therefore upgrades PDS and GitHub CLI as new versions appear, and kubectl within its configured APT
channel. Record the installed versions and retained repositories in build evidence. There is no
package hold or promise that a running instance remains at the build-time versions; copied shell
configuration is not automatically regenerated merely because the PDS library package upgrades.

### Bootstrap preservation map

| Earlier capability | Planned home and observable result |
| --- | --- |
| Ubuntu packages, locale, keyboard and timezone | Native cloud-init settings shared by both outputs. |
| Zi and Powerlevel10k | PDS `install_zi` and `configure_zsh`, preserving the existing preset, plugin set and Zi workflow. The owner selected the existing Zi per-user first-login downloads, keeping the current preset and plugin configuration. First shell startup needs internet access. |
| MOTD | PDS supplies file-based VHCO, Stackweaver and legacy EdgeForge presets. Builders defaults to VHCO; a shared helper selects a preset or accepts an operator banner file, preserving other MOTD scripts. |
| GitHub CLI | PDS `install_gh`; verify the binary in a built image without configuring an account or token. |
| kubectl, alias and completion | PDS supplies system tooling and shared shell configuration, usable by a new deployment user rather than only the build account. The version/channel input is explicit. |
| Krew, stern, view-secret and neat | Preserve Krew and all three plugins for a fresh deployment user through supported PDS image/user setup. Failed downloads cannot be logged as successful provisioning; no empty plugin selection satisfies this scope. |
| Hostname, users, SSH keys, login shell, sudo and network identity | Clone-time cloud-init inputs. A documented example selects Zsh and sudo for the deployed user; no hardcoded `sysadmin` or personal key is retained. |
| Automatic updates and restrictive SSH policy | PDS configures the nightly midnight update job and a retained public-key SSH baseline with password and root logins disabled. The default recipe bakes both into each output; custom recipes may omit those calls. |
| Manual GRUB rewrites | The official cloud image provides its boot chain. Retain the boot test, not an unverified architecture-specific reinstall command. Firmware modes beyond the tested configuration remain unclaimed. |

The PDS candidate's user-local kubectl/Krew setup must be corrected upstream, keeping its ordinary
workstation entry point compatible. Builders selects the image behavior; it does not copy the
installer. The owner selected the existing Zi first-login workflow on 2026-11-04. PDS supplies
Zi, the shared zshrc and the existing Powerlevel10k preset; Zi downloads the selected plugins and
snippets into each user's home when first needed. Powerlevel10k may also fetch its supporting
binary. First shell startup therefore needs internet access, and upstream plugin revisions can
change between users or deployments.

Keep the current Zi configuration and standalone installation behavior. For Zi shell plugins, this scope adds no
image-specific cache, shared prefetched asset tree or plugin lockfile. Pinning the PDS
package fixes its functions and configuration; it does not freeze first-login plugin contents.
Record that reproducibility limit in the bootstrap guide and validation results.

Krew and its required neat/view-secret/stern plugins are system tooling installed during the image
build, independently of Zi's shell-plugin downloads. PDS supplies an explicit system-install mode
that preserves its ordinary per-user workstation behavior. Image mode installs a root-owned Krew
tree under `/usr/local/share/pds/krew`, exposes its `bin` directory and `KREW_ROOT` to deployed Bash
and Zsh users, and requires each selected plugin installation to succeed. Deployed users can execute
these tools without referring to `/root/.krew`; updating that shared tree is an administrator task.
A user can explicitly select a private Krew root for their own plugin changes. Test both fresh-user
execution and the retained standalone per-user installer. No build-user credentials or home state
are copied to make this work.

The package's interactive auto-loader and login message remain PDS behavior during this preparation.
AC-11's strict error-reporting contract applies to explicit non-interactive loading; it makes no
claim that the existing interactive loader stops suppressing errors. Inspect both `/root` and
`/home/ubuntu` for build residue, regardless of which HOME `sudo` supplies. Shared assets belong in
system/skel locations; build-user homes must not become deployment-user paths.

Native validation supplies a complete deployment cloud-config through a `cicustom` user snippet;
this makes the chosen user's shell and sudo policy explicit. It needs snippet-capable storage,
access to the owned snippet and permission to reference it from the owned clone. Preflight checks
these prerequisites; it does not silently change storage settings. The same config is delivered by
NoCloud seed for the portable path. Assert the user's actual login shell and sudo policy, not merely
that a manual Zsh command runs. Proxmox's source generator and custom-snippet reader establish this
mechanism; the installed node's behavior still requires the planned live test.

The PDS dependency includes package-test CI and trigger coverage for packaged `bash/config/` assets
and tests. Relevant ShellCheck failures must not be swallowed by the existing broad lint recipe.
The PDS default checkout contains an earlier APT-workflow edit; preserve it and assess any needed
transfer independently, without overwriting it. Do not pull the unrelated Cloudflare feature in.

### Baked update and SSH policy

With the default recipe, both outputs receive the same automatic-update and SSH baseline through
named PDS functions. Selecting a different recipe is the explicit build-time opt-out; builders does
not reapply omitted policy outside that recipe.
`update_system_cron_entry` selects the existing nightly `00:00` update policy, using the image's
configured timezone. Its exact managed command uses `apt-get` with
`DEBIAN_FRONTEND=noninteractive` and explicit dpkg `--force-confdef`/`--force-confold` handling, so
modified configuration files cannot leave the job waiting for input. It updates APT metadata and
upgrades available packages, not only security packages. Native Ubuntu package configuration provides the scheduler, and its enabled state must
survive into each fresh instance. Repeated provisioning creates one managed job. The managed command waits or retries for APT lists and dpkg locks within a bounded five-minute
budget, then returns a visible failure if contention persists. Keep Ubuntu's existing apt-daily and
unattended-upgrades timers; coexistence must be tested rather than assuming midnight is idle.
This scope adds no automatic reboot policy.

`restricted_ssh_security_profile` supplies a retained managed OpenSSH configuration: password and
keyboard-interactive login disabled, public-key authentication enabled, and root SSH login disabled.
Store the baseline in `/etc/ssh/sshd_config.d/00-pds-security.conf`, ordered before generated
`50-cloud-init.conf` and distribution `60-cloudimg-settings.conf`. It enforces key-only, non-root
SSH even when a deployment input requests `ssh_pwauth: true`; changing that baseline is an explicit
operator configuration change. Verify the actual include precedence with `sshd -T`, including any
existing main-file settings, rather than relying only on the filename.
The current PDS function only rewrites a few default lines with sed; the dependent PDS repair must
make the intended effective settings reliable and repeatable without duplicating the logic in builders.
The helper writes and validates the configuration with `sshd -t` but does not reload the daemon.
Ordinary-host documentation provides an explicit distribution-appropriate reload step after the
operator verifies key access; the image build never invokes that step. Check both the no-reload
helper contract and the ordinary-host validation/reload procedure.
Verify configuration syntax and effective settings, including after clone-time cloud-init runs.

Keep temporary Packer access usable until provisioning and sealing finish. The QEMU path initially
uses password access, while the native path uses a temporary key. Finish package operations capable of restarting services before installing the final policy.
Record ssh.service's MainPID and activation timestamp immediately before policy installation and
again before sealing; require them to match, and inspect the guest journal for intervening restarts.
Apply the policy without sshd reload/restart during that interval, then remove the temporary build password/key and generated policy during
sealing. The retained PDS policy must survive cleanup and fresh cloud-init initialization. A finished
instance accepts its injected non-root user's key, rejects password login and rejects root SSH.
Any recipe selecting `restricted_ssh_security_profile` must call it last, after installers capable
of restarting services. The guest PID/activation check applies whenever that policy is selected,
including in a custom recipe. This is separate from resetting SSH host keys and machine identity.

### File-based MOTD presets

The owner uses VHCO for current branding and wants EdgeForge retained for possible future use.
Provide three bundled text banners under PDS `bash/config/motd/`: `vhco.txt`, `stackweaver.txt` and
`edgeforge.txt`. The existing nFPM `bash/config` mapping packages them under
`/usr/share/pds/config/motd/`. Preserve the legacy EdgeForge banner from
`origin/main:packer/ubuntu/scripts/install.sh` rather than replacing it with the new brand.
The original MOTD block and draft banner text were retained privately for comparison; the new VHCO
and Stackweaver assets are plain title drafts pending their visual treatment. The EdgeForge
comparison target is the rendered text of the original plain echo lines, ignoring trailing whitespace.
Keep one plain banner, with the optional information-tool argument controlling system information;
the duplicated coloured output and unconditional neofetch invocation are historical behavior.

Keep `setup_motd <banner-file> [none|fastfetch|neofetch]` compatible with the existing candidate.
Add `setup_motd_preset <vhco|stackweaver|edgeforge> [none|fastfetch|neofetch]` as a small selector
that resolves a bundled file and delegates to that helper. Resolve assets from the installed package
or a complete standalone checkout. Reject unknown preset names and missing assets before changing
the active MOTD. Text files are read as data, never sourced or evaluated as shell code.

Builders selects `vhco` by default through an explicit configurable MOTD-preset input. Other images
can select `stackweaver` or `edgeforge`; operators can continue supplying a custom file to the base
helper. A selection installs one active banner, not all presets at login. The helper manages only its
own `/etc/update-motd.d/90-pds` entry and copied banner under `/etc/pds`, leaving distribution and
operator scripts intact. Dynamic system information remains optional and separate from branding.
Changing a preset requires no duplicated shell function. These are image/host banners, with no
claim about where Stackweaver or any workload is deployed.

### Bounded image checks and delivery order

Keep `make check` available without Proxmox credentials or KVM. Add bounded host-side checks for the
PDS version/origin and required functions, provisioning failure propagation, packaged assets, offline
identity invariants and first-boot behavior. New behavioral tests run failing before their repairs.
Do not substitute a mocked function-call test for real package or image validation.

The standalone amd64 path builds qcow2 plus raw, compares their contents, inspects the sealed disk
read-only and boots two instances with different NoCloud users/keys. Each must finish cloud-init,
accept SSH with its supplied key and expose the selected tooling to that new user. Compare machine
IDs and host keys, and check removal of build credentials. The native path repeats those assertions
on the resulting Proxmox template and two owned clones, with the selected `host` CPU default.

PR checks run static/regression and package checks without homelab credentials. Image build/boot jobs
check KVM availability and report missing acceleration explicitly; a skipped job is not image proof.
Native validation stays an explicit owned-resource operation. Final acceptance requires observed
image results for both outputs even if a hosted runner cannot perform them.

Preparation proceeds through the PDS package/standalone contract, shared installer repairs, builders
package selection, bounded image checks, documentation and final source review. Publication describes
one builders PR and its separate PDS dependency. The issue links remain open until their implemented
scope is verified and merged by the owner. Feature 0002 remains open for its wider matrix.

## Acceptance Criteria

- [ ] AC-01: A committed `create-base-template.sh` turns the official Ubuntu cloud image into a base cloud-init template on the PVE host (qemu-guest-agent embedded), repeatably; no hand-clicking.
- [ ] AC-02: `packer init .` installs both `hashicorp/proxmox` (`1.2.4`) and `hashicorp/qemu` plugins.
- [ ] AC-03: `packer build -only='proxmox-clone.ubuntu' …` clones the base and produces a **template** on the PVE node (verified via `qm config <vmid>` showing `template: 1`) with an **empty cloud-init drive** attached; no per-build `qm importdisk`/upload anywhere in the flow. The native CPU model defaults to `host` and is configurable; the template and two fresh clones use the selected default, and blank or whitespace-padded model names fail local validation.
- [ ] AC-04: `packer build -only='qemu.ubuntu' …` still produces the local qcow2/raw artifact.
- [ ] AC-05: Both native and portable sealed outputs contain no site-specific hostname, static IP/netplan identity or SSH host keys; two independently initialized instances of each output receive distinct machine IDs and host keys and apply their supplied identities.
- [ ] AC-06: The sealed image retains no build password, authorized keys or generated SSH policy override. The default Ubuntu account may remain only locked and keyless, with its standard sudo policy. Usable deployed users, keys and site-specific identity are supplied at clone time; the default recipe's PDS SSH baseline remains effective after fresh cloud-init initialization.
- [ ] AC-07: Short root and Ubuntu READMEs link canonical procedures for both output selections, PDS bootstrap, SSH/debugging and recovery; small flow diagrams use Mermaid and Proxmox is explicitly optional.
- [ ] AC-08: Both builders install the exact selected PDS package, verify its identity and provenance, and fail on missing, mismatched or untrusted inputs; candidate-package testing is distinguished from a verified signed-repository release build.
- [ ] AC-09: The shared provisioner applies native Ubuntu settings and the default recipe's explicit PDS function selection for Zi/Powerlevel10k, MOTD, GitHub CLI, kubectl, Krew, neat/view-secret/stern, nightly package updates and restricted SSH; reusable implementations live in the standalone PDS package, and selected-function failures stop provisioning.
- [ ] AC-10: A new deployment user of a default-recipe image receives working Zsh/Powerlevel10k, the kubectl alias/completion, Krew and the neat, view-secret and stern plugins from either output, with its configured Zsh login shell and sudo policy and without inheriting build credentials or build-home paths. Zi populates the existing plugin set on first shell startup with network access; no image-prefetched plugin cache is required.
- [ ] AC-11: The PDS package loads non-interactively without installer/network side effects, preserves the caller's shell state and reports library failures; its supported standalone setup preserves Zi, the preset and the existing plugin set. Error-reporting assertions cover explicit non-interactive loading; interactive auto-loading is documented separately.
- [ ] AC-12: Repository checks exercise package-backed provisioning, failure paths, sealed-artifact assertions and two fresh boots of each Ubuntu amd64 output; CI reports executed versus skipped checks, and native checks preserve all pre-existing guests.

- [ ] AC-13: PDS bundles selectable VHCO, Stackweaver and preserved EdgeForge MOTD text presets; builders defaults to configurable VHCO, custom-file usage remains supported, and invalid selections leave the active MOTD and other MOTD scripts unchanged.

- [ ] AC-14: Both image outputs built with the default recipe retain one configured nightly midnight package-update job that runs non-interactively with an enabled scheduler and effective SSH settings that allow injected non-root public-key login while disabling password, keyboard-interactive and root login; repeated provisioning is safe and temporary Packer access is removed only after it is no longer needed.

- [ ] AC-15: An operator can select a readable custom Bash recipe at invocation for either output without editing the default recipe or PDS; omitted PDS update/SSH policies are not applied elsewhere, missing recipes and failed calls stop the build, and generic-image cleanup still runs.

## Test Plan

| Criterion | Proof |
| --- | --- |
| AC-01 | Run the off-node bootstrap from a clean supported environment on unused IDs; verify template, guest agent and reset identity. Import the saved bundle from a second minimal environment without Packer/libguestfs. Repeat import of the same verified bundle on another unused ID must produce the requested fixed configuration; generated IDs/MACs may differ. The same occupied ID must be refused, and corrupt-bundle attempts must leave existing guests unchanged. Moving upstream downloads are not a byte-identical rebuild guarantee. |
| AC-02 | Run `make init`, then validate that both required plugin versions load. |
| AC-03 | Run the native Packer build with a scoped test token; inspect the output template flag, cloud-init volume and absence of temporary cloud-init credentials. Inspect the native source and build log to confirm there is no disk-import or disk-upload step after Stage 0. Verify the native default and both fresh clones report `cpu: host` and expose node AES/AVX features; validate a CPU override and reject both an empty model and a whitespace-padded value such as `" host "`. |
| AC-04 | Run the QEMU builder with raw export enabled; inspect both formats and compare their disk contents. |
| AC-05 | Inspect each native and portable sealed artifact read-only, then boot two fresh instances of each with separate cloud-init inputs; compare machine IDs, host keys and applied identity. The qcow2/raw disks must compare identically. |
| AC-06 | Run the manual disposable-container `tests/test_sealing.sh` check with real cloud-init; verify sealing removes the temporary SSH password override and discards the build-password hash. `make check` lint-checks this script but does not execute its destructive guest changes. Inspect both default-recipe sealed outputs and boot fresh instances with consumer-supplied users/keys; effective SSH policy must retain the selected baked restrictions while accepting the supplied non-root user's key. |
| AC-07 | Follow linked task guides for both outputs and a temporary SSH/VNC session; check local links, examples and variables against source. Render both Mermaid diagrams and verify the standalone quick start needs no Proxmox credentials. |
| AC-08 | Exercise exact-version repository installation and explicit candidate upload; reject wrong version, package name, checksum, trust and missing-function inputs. Inspect dpkg metadata, provenance, APT source files and keyrings in each built output; record exact build-time versions and the retained signed repositories. Final validation includes the signed-repository route; the baked updater is expected to advance running-package versions later. |
| AC-09 | Inspect the selected PDS functions and their installed-package origins; execute real provisioning and verify tools/settings in the image. Inject a failing selected function and require the provisioner to fail before sealing. |
| AC-10 | Log into each fresh instance as its supplied new user; check the actual Zsh login shell and documented sudo policy, preset, kubectl alias/completion, Krew and neat/view-secret/stern commands. Exercise actual Zi first-login downloads with network access, then verify the preset/plugins work on a subsequent shell startup; record the downloaded revisions and network requirement. Verify Krew and neat/view-secret/stern execute from the shared system tree as the new user without a Krew download, and retain standalone per-user coverage. Inspect /root and /home/ubuntu in each sealed filesystem for build-user paths, keys, tokens and history; use a complete native cicustom snippet and equivalent portable NoCloud seed. |
| AC-11 | Install the built PDS package in disposable Ubuntu and run its strict-load, missing-library, Zi/preset, MOTD, sudoers and standalone-path tests. Add real selected-installer/new-user coverage; existing Zi stubs do not prove actual downloads or plugin startup. |
| AC-12 | Execute documented Make targets and PR checks, including negative artifact fixtures; retain per-output build/offline/boot results and explicit skips. For Proxmox, snapshot original guest configurations/power states, reserve unused owned IDs, and audit ownership-limited cleanup afterward. |
| AC-13 | Inspect the built package for all three banner files and compare EdgeForge with the preserved legacy banner. Exercise each preset and custom-file usage in disposable Ubuntu, including standalone-checkout resolution, repeated application, preset switching, unknown names and missing files; verify unchanged operator scripts and no changes after invalid selection. Check the configured banner in both image outputs. |
| AC-14 | Apply the PDS helpers twice in disposable Ubuntu; require one midnight job, scheduler enablement, sshd syntax/effective settings and successful non-interactive updates, including an upgrade of a deliberately modified conffile. Exercise held APT-list and dpkg locks, requiring bounded recovery and visible timeout failure. In a fresh instance of each output, execute the installed job's exact command under cron PATH with stdin /dev/null and require exit 0. Guest-side ssh.service PID/activation timestamp and journal evidence must establish no reload/restart between policy installation and sealing; a quiet Packer log is insufficient. For one owned instance per output, supply ssh_pwauth: true, disable_root: false, a temporary known non-root password and a temporary root key. Add a lower-precedence 10-test-permissive.conf enabling password, keyboard-interactive and root login; require the baked 00-pds-security.conf settings to win. Use a permissive control in the owned fixture to establish the credentials and authentication methods work without the PDS restriction, then restore the baseline and require non-root key success, password/keyboard-interactive/root-key refusal at authentication, only publickey offered, and matching sshd -T values. Root refusal must be authentication denial, not a cloud-init forced-command banner. Redact/discard test credentials and retain per-output results. Inspect the retained policy offline and check the scheduler/baseline in both fresh instances of each output. |
| AC-15 | Validate inputs for both builders and reject an unreadable/missing recipe before building. Exercise the shared provisioner with the default and committed recipes/custom.example.sh; check exported inputs, selected call order and propagated failure. Build that custom example for both native and portable outputs from clean bases. Inspect each sealed disk for absent 00-pds-security.conf and PDS-managed update job, present example selections, and AC-06 credential/identity cleanup. Boot two fresh instances of each custom output with independent identities and verify AC-05 separation and the selected tools/MOTD. No custom-image assertion requires enabling password login or undoing vendor/inherited policy. |

## Tasks

T1-T7 were the earlier unchecked worklist; their source, reviews and delivery history remain in Git.
This unchecked tail is replanned for the accepted combined scope without inventing completion ticks.
PDS paths below refer to the existing `michielvha/PDS` dependency branch
`feat/image-provisioning-pds`; builders stays on its existing owning feature branch. Each task is one
local commit. No branch push, merge or release is implied by a task tick.

- [x] T8 `PDS/AGENTS.md`, `PDS/CLAUDE.md`, `PDS/.github/copilot-instructions.md` adopt the pinned shared conventions while preserving existing code and independent standalone use; instruction links and local command references check cleanly (AC-11).
      Evidence: PDS commits 12acd56 and b198f47 adopt the pin and retain all prior Copilot instruction bytes in AGENTS.md; the initial accidental replacement was corrected locally without rewriting history. The existing code was untouched.
- [x] T9 `PDS/packaging/`, `PDS/bash/common/`, `PDS/bash/debian/`, `PDS/bash/config/zshrc`, `PDS/tests/image_provisioning_test.py` retain and commit the inherited image-provisioning candidate after its nine package tests, changed-shell lint and source/package comparison pass; record that these tests predate this continuation rather than inventing a failing-first history (AC-11).
      Evidence: PDS commit 08ce2d7; re-ran the existing package in a disposable network-isolated container against matching source: nine tests passed. Earlier source/package comparison covered 79 files and changed-shell lint passed. This inherited implementation predates this continuation, so no new failing-first history is claimed.
- [x] T10 `PDS/tests/test_motd_presets.py` adds packaged-preset, switching, invalid-input and standalone/custom-file checks; observe missing helper/assets fail against T9 (AC-13).
      Evidence: PDS commit 96e34cd; docker test run in /tmp/builders-recipe-20261105/motd-red.log failed with missing preset files and setup_motd_preset exit 127 before implementation.
- [x] T11 `PDS/bash/debian/admin/setup_motd.sh`, `PDS/bash/config/motd/`, `PDS/packaging/README.md` implement the file selector, three banners and documented compatibility; T10 and existing package tests pass (AC-13).
      Evidence: PDS commit 416550f; rebuilt package SHA256 48d43f7f5bac39e9e59d235b7d30a7fc3c68464f19aaf0b8400e56894bb24e7c. ShellCheck and all 13 package tests passed in disposable network-isolated Ubuntu; motd-final.log retains the results. Builders preset wiring and complete AC-13 image proof remain pending.
- [ ] T12 `PDS/tests/test_image_baseline.py` adds real OpenSSH configuration/authentication and noninteractive updater/lock/conffile checks in disposable Ubuntu; observe the current helpers fail these checks (AC-14).
- [ ] T13 `PDS/bash/common/admin/sysadmin.sh`, `PDS/bash/debian/admin/`, `PDS/bash/config/`, `PDS/packaging/README.md` implement the repeatable updater and validated no-reload SSH policy, with observer support for selected image policy; T12 and standalone helper checks pass (AC-11, AC-14).
- [ ] T14 `PDS/tests/test_kubectl_image.py` exercises strict noninteractive execution, system-wide tool availability and propagated plugin failures; observe current user-local/warning behavior fail (AC-09, AC-10).
- [ ] T15 `PDS/bash/debian/software/install_kubectl.sh`, `PDS/bash/config/`, `PDS/packaging/` add explicit system-image mode and verified Krew inputs while preserving ordinary per-user installation; T14 and package regression tests pass (AC-09, AC-10, AC-11).
- [ ] T16 `packer/ubuntu/tests/test_pds_provisioning.py` adds package-identity, default/custom recipe, selected-call failure and SSH-order observation checks; observe the missing integration fail (AC-08, AC-09, AC-15).
- [ ] T17 `packer/ubuntu/scripts/`, `packer/ubuntu/recipes/`, `packer/ubuntu/ubuntu.pkr.hcl`, `packer/ubuntu/variables.pkr.hcl`, `packer/ubuntu/pds/` implement the thin package bootstrap and recipe selection, move package operations ahead of final policy, and retain sealing outside recipes; T16, Packer validation and existing local checks pass (AC-06, AC-08, AC-09, AC-15).
- [ ] T18 `packer/ubuntu/tests/`, `Makefile` add failing negative artifact and fresh-user checks for the bounded Ubuntu image validation, including real cron environment and preserved journal evidence (AC-05, AC-06, AC-10, AC-12, AC-14).
- [ ] T19 `packer/ubuntu/tests/`, `Makefile`, `.github/workflows/`, `renovate.json5` implement the bounded shared check targets and secret-free PR checks, report skips explicitly, and expose pinned inputs to the updater; T18 and local CI-equivalent checks pass (AC-08, AC-12).
- [ ] T20 `docs/validation/` records executed default/custom native and portable builds, sealed inspection, two fresh boots per recipe/output, scheduler/authentication/tool checks and ownership-limited cleanup; all pre-existing guests remain unchanged. Candidate-package proof is labelled separately from the later signed-release route (AC-01, AC-02, AC-03, AC-04, AC-05, AC-06, AC-08, AC-10, AC-12, AC-13, AC-14, AC-15).
- [ ] T21 `readme.md`, `packer/ubuntu/readme.md`, `docs/ubuntu/`, `docs/development.md` align the short entry points and task guides with observed commands, recipes, branded MOTDs and validation limits; links/examples check cleanly and independent final implementation review targets the committed source (AC-07, AC-13, AC-15).

## Open Questions

None.

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
| 2026-11-04 | R-8 | spec | `edcdb0a169316f22d98854d9f44f8fab18459edf` | claude-opus-5-5 | procedural | Five non-blocking findings; Q1 remains pending. |
| 2026-11-04 | R-9 | implementation | `edcdb0a169316f22d98854d9f44f8fab18459edf` | claude-opus-5-5 | procedural | AC-02 and AC-07 met; live execution remains not independently verified. |
| 2026-11-04 | R-10 | spec | `1dcd2c59a5a01cc2301f63e41ab1516cbe6d88f1` | claude-opus-5-5 | procedural | One delivery-note nit; Q1 remains pending. |
| 2026-11-04 | R-11 | implementation | `1dcd2c59a5a01cc2301f63e41ab1516cbe6d88f1` | claude-opus-5-5 | procedural | No implementation findings; AC-02 and AC-07 met, remaining criteria not independently verified. |
| 2026-11-04 | R-12 | spec | `4bf428f9cb2e4e4ce20eb8e6c5619af23d0a3209+dirty` | claude-opus-5-5 | procedural | Diagnostic of expanded PDS scope; six findings, no acceptance. |
| 2026-11-04 | R-13 | spec | `7b818c9e3e98d402d3b72710c6542bdb5315de9d` | claude-opus-5-5 | procedural | Six non-blocking findings about update execution, SSH proof, shared Krew and package lifecycle. |
| 2026-11-04 | R-14 | spec | `fa4b1b5d446447ac37c4990ad81a9b08f9865446` | claude-opus-5-5 | procedural | Five non-blocking findings about control probes, reload evidence, APT locks and a stale harness reference. |
| 2026-11-04 | R-15 | spec | `eb38755c4218f7d315a32951f53cf589115630e0` | claude-opus-5-5 | procedural | Two implementation/testing nits; no blocking findings. |
| 2026-11-05 | R-16 | spec | `59928bc110dedec4c6f91cbbd7c18c384cee2f65` | claude-opus-5-5 | procedural | Four non-blocking consistency/proof findings for custom recipe behavior. |
| 2026-11-05 | R-17 | spec | `08f056d8dea3b5cba1702cc03242a9ea43650be6` | claude-opus-5-5 | procedural | Two non-blocking implementation/wording nits; no blocking findings. |
| 2026-11-05 | R-17 | spec | `08f056d8dea3b5cba1702cc03242a9ea43650be6` | n/a | n/a | accepted by owner |

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

### R-8


FINDING: F-01
KIND: factual
SEVERITY: nit
WHERE: Context, Live validation before the structure refactor and Off-node candidate checks
EVIDENCE: Spec line 101 says the committed validation summary "records the observed results and their limits". That sentence follows the 2026-11-03 section, which reports the 12 GiB test disk, the duplicate machine ID and shared DHCP client ID defect, the deprecated cloud-init `user` string, the missing executable bit on the raw exporter, the early TCG memory-cap failures and the 990100 to 990105 test range (lines 77 to 98). docs/validation/0001-2026-11-04.md mentions none of these. Lines 154 to 155 say the summary "provides the portable record of these observations". Those observations include the earlier `kvm64` native template build, the build failure that led to raising the task timeout, the `kvm64` native fresh clones and the audit of five removed resources (lines 143 to 148). The summary describes only the later `host` CPU native run and its four removed resources (summary lines 33 to 42). It mentions the timeout only as a setting that leaves the QEMU source unchanged (line 56).
PROPOSAL: Narrow both citations to what the summary contains. Either label the 2026-11-03 notes and the earlier `kvm64` native run as history recorded only in private artifacts, or add those observations to the validation summary.

FINDING: F-02
KIND: judgement
SEVERITY: nit
WHERE: Design, Provisioning changes, and Context, Primer
EVIDENCE: The Design describes build access only for the native builder: "`proxmox-clone` generates a temporary SSH key" (line 314) and "remove the temporary build SSH key Packer injected" (line 362). The Primer gives the same native-only description (lines 57 to 59). The portable builder actually logs in with a password. ubuntu.pkr.hcl:31 sets `ssh_password = "ubuntu"`, and cloud-init/user-data:3-4 sets `password: ubuntu` and `ssh_pwauth: true`. The AC-06 Test Plan row checks that sealing "removes the temporary SSH password override and discards the build-password hash". seal-image.sh:11 and :16 do this with `usermod --password '*'` and `--configs ssh_config`. The Design never introduces this password access or the step that removes it, so the AC-06 proof relies on behaviour the Design does not describe.
PROPOSAL: Add one Design sentence: the QEMU seed grants temporary password SSH access, and sealing replaces the password hash with `*` and removes cloud-init's SSH policy drop-in.

FINDING: F-03
KIND: judgement
SEVERITY: nit
WHERE: Acceptance Criteria AC-01, Test Plan AC-01
EVIDENCE: AC-01 requires the base template to be created "repeatably". Design lines 266 to 268 say source downloads track Ubuntu's moving `current` directory, so a later fresh build will not be byte-identical, and that exact reuse comes from the retained bundle. The AC-01 proof runs one bootstrap and one bundle import. It never defines what a repeat run must show, so a reviewer cannot tell which reading of "repeatably" passes.
PROPOSAL: Define "repeatably" in AC-01 or its proof. One option: rerunning the committed script on a new unused ID produces an equivalent base, and importing the retained bundle reproduces the same verified disk.

FINDING: F-04
KIND: judgement
SEVERITY: nit
WHERE: Test Plan AC-03
EVIDENCE: AC-03 requires "no per-build `qm importdisk`/upload anywhere in the flow". The AC-03 proof checks the template flag, the cloud-init volume, leftover credentials, the CPU model and CPU validation. It sets no pass condition for the absence of an import or upload step. In source, the only `qm importdisk` is in the once-per-base import-base-template.sh:46, and the build block at ubuntu.pkr.hcl:82-119 has no import or upload step.
PROPOSAL: Add a pass condition to the AC-03 proof. For example, inspecting ubuntu.pkr.hcl and the native build log shows no import or upload step after Stage 0.

FINDING: F-05
KIND: factual
SEVERITY: nit
WHERE: Open Questions
EVIDENCE: Lines 470 to 476 come after the Q1 option table and its "Why this is yours" line, still under the `### Q1:` heading. They record settled decisions (off-node bootstrap, the Bash/jq adapter) and history about R-1 F-02, so they read as part of the pending Q1. Line 474 also states "The actual noble/amd64 manifest includes jq" with no citation. The standard requires Context and Design claims to be cited.
PROPOSAL: Move these decision notes to Design or Context. Cite the jq claim with the retained portable build log showing wait-cloud-init.sh parsing real cloud-init JSON, or with the upstream manifest. Leave only Q1 under Open Questions.

### R-9


CRITERION: AC-01 A committed `create-base-template.sh` turns the official Ubuntu cloud image into a base cloud-init template on the PVE host (qemu-guest-agent embedded), repeatably; no hand-clicking.
VERDICT: not verified
EVIDENCE: I ran `git rev-parse HEAD`, `git status --short`, `git ls-files` and `python3 -B -m unittest discover -s packer/ubuntu/tests -v` at edcdb0a169316f22d98854d9f44f8fab18459edf. HEAD matches the target and the tree is clean. create-base-template.sh, prepare-base-image.sh and import-base-template.sh are tracked. All 26 tests passed, 16 of them in test_base_template. These cover the required remote host and explicit ID, refusal of a used ID with no download or delete, corrupt and partial bundles, upload corruption, the ID recheck on the node, disk shrink refusal, reuse of a verified bundle and the qm sequence that imports a cloud-init template. `git diff --stat 0b33ecf edcdb0a` shows only the 0001 spec changed. I read the source. prepare-base-image.sh:34-42 installs qemu-guest-agent and clears machine-id and host keys. import-base-template.sh:44-52 creates the VM, imports the disk, attaches ide2 cloudinit, enables the agent and runs qm template. I also read retained results that I did not observe being produced. /tmp/builders-offnode/import-final-results.json reports template 1, ide2 cloudinit, agent enabled=1, a non-root client without Packer or libguestfs, an occupied ID refused and protected guests unchanged. Limitations: I ran no live preparation or import against Proxmox. The local tests use stubs for ssh, qm and pvesh. A full Fedora restoration and an off-host backup are not established. The prior dirty-target reason no longer applies.

CRITERION: AC-02 `packer init .` installs both `hashicorp/proxmox` (`1.2.4`) and `hashicorp/qemu` plugins.
VERDICT: met
EVIDENCE: I ran `packer init .` in packer/ubuntu at edcdb0a with Packer v1.16.2 (/tmp/builders-pr4-tools/packer). I set PACKER_PLUGIN_PATH, PACKER_CONFIG_DIR and PACKER_CACHE_DIR to an empty scratch directory, /tmp/r8-review.EVAPGo. Output: "Installed plugin github.com/hashicorp/proxmox v1.2.4" and "Installed plugin github.com/hashicorp/qemu v1.1.8", exit 0. A following `packer validate .` with a placeholder token against those plugins printed "The configuration is valid." ubuntu.pkr.hcl:1-12 pins proxmox = 1.2.4 and qemu = 1.1.8. Limitations: I ran the command directly, not through `make init` (Makefile:5 runs the same command). The run was on linux_amd64 only. The binary's zip hash matches the linux_amd64 entry of a SHA256SUMS file in the implementer's tool directory, and I did not verify that file's signature.

CRITERION: AC-03 `packer build -only='proxmox-clone.ubuntu' …` clones the base and produces a **template** on the PVE node (verified via `qm config <vmid>` showing `template: 1`) with an **empty cloud-init drive** attached; no per-build `qm importdisk`/upload anywhere in the flow. The native CPU model defaults to `host` and is configurable; the template and two fresh clones use the selected default, and blank or whitespace-padded model names fail local validation.
VERDICT: not verified
EVIDENCE: I ran these at edcdb0a: `packer fmt -check -recursive .`, `packer validate .`, `packer validate -var 'proxmox_cpu_type=x86-64-v2-AES' .`, `packer validate -var 'proxmox_cpu_type=' .`, `packer validate -var 'proxmox_cpu_type= host ' .`, a validate with a whitespace-only value, and `packer inspect .`. fmt passed (exit 0). The default and the override printed "The configuration is valid." The empty, padded and whitespace-only values exited 1 with the variables.pkr.hcl:193 message. inspect shows var.proxmox_cpu_type "host" and both sources. In source, ubuntu.pkr.hcl:49-80 sets full_clone, cpu_type = var.proxmox_cpu_type, cloud_init = true and cloud_init_storage_pool, with ssh_username "ubuntu" and ssh_timeout "20m". The Packer flow has no importdisk or disk upload. I also read retained results that I did not observe being produced. /tmp/builders-hostcpu-20261104/native-results.json reports template 1, ide0 cloudinit and cpu host, and two clones with cpu host, the Xeon E5-2620 model, AES and AVX. I recomputed hashes for the 20 runtime files in runtime-manifest.json against edcdb0a blobs. Nineteen match. variables.pkr.hcl differs, and reversing the two lines in validation-guard-followup.patch gives da40255d2fcada1b48f87aae26e4f4c62130fff7af2ff5dd4de1ee3e91b3218b, which matches the manifest. Limitations: I observed no native build, no qm config and no clones. Only the local validation part of this composite criterion ran in this review.

CRITERION: AC-04 `packer build -only='qemu.ubuntu' …` still produces the local qcow2/raw artifact.
VERDICT: not verified
EVIDENCE: I ran the unittest discovery (test_raw_export) and `packer validate .` at edcdb0a. The raw export test passed: export is optional, a real qemu-img conversion runs and an existing raw file is never overwritten. The qemu source and its export-raw.sh post-processor validate. I also read retained results that I did not observe being produced. /tmp/builders-offnode/portable-final-build.log ends with qemu.ubuntu artifacts in output-noble-amd64, and inspection-results.json reports qcow2_and_raw_identical true at 10 GiB virtual size. Limitations: I ran no QEMU Packer build. The retained build predates the native CPU, timeout and guard changes. The manifest comparison above shows ubuntu.pkr.hcl, the shared scripts and export-raw.sh are identical to the tested files.

CRITERION: AC-05 The resulting image contains **no** baked hostname, static IP/netplan identity, or SSH host keys, and boots with a **fresh `machine-id`** (two clones get distinct ids).
VERDICT: not verified
EVIDENCE: I inspected seal-image.sh:13-22 at edcdb0a. It removes ssh_host_*, runs `cloud-init clean --logs --seed --configs ssh_config network`, truncates /etc/machine-id, relinks the D-Bus id, writes localhost to /etc/hostname and drops the 127.0.1.1 hosts entry. tests/test_sealing.sh:44-55 asserts these outcomes. I read the script but did not run it. I also read retained results that I did not observe being produced. /tmp/builders-hostcpu-20261104/inspection-results.json reports native generic_hostname, machine_id_empty, ssh_keys_absent and netplan_absent all true. native-results.json shows two native clones with distinct machine IDs and host keys. /tmp/builders-offnode/inspection-results.json and portable-clone-results.json show the same for the portable artifact and two portable boots. Limitations: I inspected no artifact and booted no instance. test_sealing.sh needs Docker, which this review may not run. Whether AC-05 must cover both outputs is still owner question Q1, so I applied no particular reading.

CRITERION: AC-06 The sealed image retains no build password, authorized keys or generated SSH policy override. The default Ubuntu account may remain only locked and keyless, with its standard sudo policy. Any usable deployed login and site-specific identity or SSH policy are supplied at clone time.
VERDICT: not verified
EVIDENCE: I inspected seal-image.sh:11-16, cloud-init/user-data, ubuntu.pkr.hcl:30-33 and 77-79, tests/test_sealing.sh and the Makefile at edcdb0a. The sealer sets the ubuntu hash to `*`, removes the ubuntu and root authorized_keys and cleans the cloud-init ssh_config, which removes 50-cloud-init.conf. test_sealing.sh:16-19 reproduces `passwordauthentication yes` from the real seed, and :44-50 asserts `no`, hash `*` and that the override is absent. Makefile:10 only runs ShellCheck on it, which matches the manual boundary stated in the AC-06 Test Plan row. The native SSH settings match the Design text: only the key is generated, and the username and timeout are set explicitly. I also read retained results that I did not observe being produced. The native and portable inspection-results.json files report build_keys_absent, build_ssh_override_absent and build_password_discarded true. Both native clones show ubuntu_password "L", ssh_password_auth "no" and ssh_login_verified true. Both portable boots show password_auth "no" and consumer_key_login true. final-audit.json shows clone 990102 with consumer ciuser probe1, and the template config has no ciuser or sshkeys. Limitations: I did not run test_sealing.sh, since Docker is prohibited here. I observed no sealed disk and no fresh boot.

CRITERION: AC-07 `packer/ubuntu/readme.md` documents the `-only` invocation for both formats and the required Proxmox variables/secrets.
VERDICT: met
EVIDENCE: I read packer/ubuntu/readme.md at edcdb0a and checked every variable in variables.pkr.hcl against the readme and proxmox.auto.pkrvars.hcl.example. readme.md:130 gives `packer build -only='proxmox-clone.ubuntu' .`, and readme.md:177-183 give the qemu forms, including output_raw=true. readme.md:123-132 tells the reader to copy the example file, which sets proxmox_url, proxmox_api_token_id, proxmox_node, proxmox_insecure, proxmox_storage_pool, proxmox_cpu_type, proxmox_task_timeout, base_template_name, template_name and template_vmid. The secret comes from a hidden-prompt PKR_VAR_proxmox_api_token with a never-commit warning (readme.md:128-135). The prose also explains proxmox_insecure, template_vmid, proxmox_storage_pool, proxmox_task_timeout and proxmox_cpu_type (readme.md:136-160). The `packer init .` and validate commands I ran follow the guide's preparation step. Limitations: I did not follow the guide through either build. proxmox_url, proxmox_node, base_template_name and template_name appear in the readme only through the referenced example file and the line 123 summary.

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Test Plan, Tasks delivery note, Review Log
EVIDENCE: `vh-adlc fresh docs/specs/0001-packer-proxmox-native-output.md --repo . --plugin-pin 0e52f51f01b84eda75a976763c42d8ec0a07b544` at edcdb0a reports both R-6 (spec) and R-7 (implementation) as stale with reason `baseline-changed`. `git diff 0b33ecf edcdb0a` shows normative edits to the Test Plan rows for AC-01, AC-03 and AC-06, plus the new Q1. So the current normative baseline has no current spec review and no owner acceptance. The Tasks delivery note says "R-7 observed AC-02 and AC-07 as met" and does not say that R-7 is now stale against this baseline.
PROPOSAL: Run a spec review at edcdb0a, or a later commit, before any acceptance row. Say in the delivery note that R-6 and R-7 reviewed the previous baseline.

FINDING: F-02
KIND: factual
SEVERITY: nit
WHERE: packer/ubuntu/ubuntu.pkr.hcl:47, Design (Selecting output format at invocation)
EVIDENCE: The comment at ubuntu.pkr.hcl:47 gives `packer build -only='proxmox-clone.ubuntu' -var-file=proxmox.auto.pkrvars.hcl .`. readme.md:130 and :186 say `*.auto.pkrvars.hcl` loads automatically and use no -var-file, while the Design example uses `-var-file=variables.pkrvars.hcl` for both builders. Passing the auto file explicitly loads it twice. This does no harm, but it is a third invocation form.
PROPOSAL: Align the source comment with readme.md:130, so the native command takes no -var-file and relies on the automatically loaded file.

### R-10


FINDING: F-01
KIND: factual
SEVERITY: nit
WHERE: Tasks, delivery note
EVIDENCE: Spec lines 449 to 450 say "R-9 refreshed the implementation review: AC-02 and AC-07 were observed as met; live-build criteria remain not independently verified." At 1dcd2c59a5a01cc2301f63e41ab1516cbe6d88f1, running `vh-adlc fresh docs/specs/0001-packer-proxmox-native-output.md --repo . --plugin-pin 0e52f51f01b84eda75a976763c42d8ec0a07b544` reports R-8 as stale with reason `baseline-changed`. It reports R-9 as stale with reasons `baseline-changed` and `covered-changed`, because covered path packer/ubuntu/ubuntu.pkr.hcl changed. `git diff edcdb0a HEAD -- packer` shows that change is the ubuntu.pkr.hcl:47 build comment only, which no longer passes `-var-file=proxmox.auto.pkrvars.hcl`. Lines 445 to 447 say the runtime and test files match the owner-reviewed manifest and that no runtime feature changed. That was true for deae257, but the note never mentions that 1dcd2c5 later edited this comment in a covered runtime file. R-9 F-01 raised the same problem about R-7, and the note now repeats it one review later.
PROPOSAL: State that R-8 and R-9 reviewed edcdb0a and are now stale against the current baseline. Also record that the only covered-path change since then is the comment at ubuntu.pkr.hcl:47, and that it changes no executable setting.

### R-11


CRITERION: AC-01 A committed `create-base-template.sh` turns the official Ubuntu cloud image into a base cloud-init template on the PVE host (qemu-guest-agent embedded), repeatably; no hand-clicking.
VERDICT: not verified
EVIDENCE: Executed `python3 -B -m unittest discover -s packer/ubuntu/tests -v` at 1dcd2c59a5a01cc2301f63e41ab1516cbe6d88f1 with a clean tree: 26 tests ran OK, including 16 base-template fixtures. The fixtures cover a missing host or ID, refusal of an occupied ID without download or delete, rejection of a corrupt or partial bundle before upload, rejection of upload corruption, a shrink refusal and an ID recheck before `qm create`, cleanup limited to the staging directory, and the stubbed import sequence. Read the committed prepare-base-image.sh, create-base-template.sh and import-base-template.sh: they verify the upstream checksum, install qemu-guest-agent through virt-customize, clear machine-id and host keys, check the bundle checksum locally and on the node, then run `qm create`, `importdisk`, set a cloud-init ide2 drive and finish with `qm template`. The live off-node preparation, the SSH-only bundle import on Proxmox 9.1.7, the occupied-ID refusal and the guest-preservation audit were read only as retained implementer evidence (docs/validation/0001-2026-11-04.md, /tmp/builders-offnode/). I did not execute them. The Test Plan's repeat import of the same bundle on a second unused ID was not found as an executed result in the committed summary. The live criterion is composite, and local fixtures with stubbed qm and pvesh do not establish it.

CRITERION: AC-02 `packer init .` installs both `hashicorp/proxmox` (`1.2.4`) and `hashicorp/qemu` plugins.
VERDICT: met
EVIDENCE: Executed `packer init .` in packer/ubuntu using Packer v1.16.2 (the retained /tmp/builders-pr4-tools/packer ELF binary), with PACKER_PLUGIN_PATH, PACKER_CONFIG_DIR and PACKER_CACHE_DIR in an empty scratch directory outside the repository. Exit 0. Output: "Installed plugin github.com/hashicorp/qemu v1.1.8" and "Installed plugin github.com/hashicorp/proxmox v1.2.4". `packer plugins installed` listed both binaries. With those plugins, `packer validate .`, `packer validate -only=qemu.ubuntu .` and `packer fmt -check -recursive packer/ubuntu` all succeeded. The repository tree and index were unchanged afterwards. Limitation: Packer is not installed on this host, so the implementer's retained binary was used. ShellCheck is absent here, so the shellcheck step of `make check` was not observed.

CRITERION: AC-03 `packer build -only='proxmox-clone.ubuntu' …` clones the base and produces a **template** on the PVE node (verified via `qm config <vmid>` showing `template: 1`) with an **empty cloud-init drive** attached; no per-build `qm importdisk`/upload anywhere in the flow. The native CPU model defaults to `host` and is configurable; the template and two fresh clones use the selected default, and blank or whitespace-padded model names fail local validation.
VERDICT: not verified
EVIDENCE: Executed locally with the scratch plugins: `packer validate .` passed with the `host` default. `-var 'proxmox_cpu_type=x86-64-v2-AES'` validated. `-var 'proxmox_cpu_type='` and `-var 'proxmox_cpu_type= host '` each exited 1 with the variable's "non-empty model name" error. `packer inspect` reports var.proxmox_cpu_type "host". Static read of ubuntu.pkr.hcl: the proxmox-clone source sets full_clone, cpu_type = var.proxmox_cpu_type, cloud_init = true and cloud_init_storage_pool. The only post-processor (line 111) is shell-local, limited to qemu.ubuntu. The file contains no importdisk or qm call. The only `file` provisioner uploads build-config.yaml into the guest, not a disk. `git diff 0b33ecf 1dcd2c5 -- packer/` shows only the comment edit at line 47. The live native build, the `template: 1` and cloud-init volume inspection, and the two fresh clones reporting `cpu: host` with AES/AVX are retained implementer evidence (/tmp/builders-hostcpu-20261104/, the validation summary) that I did not execute. The composite criterion is not upgraded by the passing local subset.

CRITERION: AC-04 `packer build -only='qemu.ubuntu' …` still produces the local qcow2/raw artifact.
VERDICT: not verified
EVIDENCE: Executed `packer validate -only=qemu.ubuntu .`: valid. The unittest run includes test_export_is_optional_and_does_not_overwrite, which passed with a real qemu-img conversion of a disposable file. Read the qemu source: output_directory, the qcow2 vm_name and the shell-local export-raw.sh post-processor gated by output_raw. The portable KVM build, which produced matching 10 GiB qcow2 and raw disks, is retained implementer evidence (/tmp/builders-offnode/portable-final-build.log, the validation summary) that I did not execute. The summary states the portable image was not rebuilt after the native-only CPU and guard changes. My diff since 0b33ecf confirms the QEMU source and guest scripts are unchanged.

CRITERION: AC-05 The resulting image contains **no** baked hostname, static IP/netplan identity, or SSH host keys, and boots with a **fresh `machine-id`** (two clones get distinct ids).
VERDICT: not verified
EVIDENCE: Read seal-image.sh at the target. It removes /etc/ssh/ssh_host_*, runs `cloud-init clean --logs --seed --configs ssh_config network`, truncates /etc/machine-id and relinks the D-Bus id, writes `localhost` to /etc/hostname and deletes the 127.0.1.1 hosts entry. install.sh and build-config.yaml set no hostname or static network. Executed test_sealing_requires_an_explicit_image_build_flag, which passed. The offline disk inspections and the fresh-boot pairs with distinct machine IDs and host keys for both outputs are retained implementer evidence that I did not execute. No guest or disk was inspected in this review.

CRITERION: AC-06 The sealed image retains no build password, authorized keys or generated SSH policy override. The default Ubuntu account may remain only locked and keyless, with its standard sudo policy. Any usable deployed login and site-specific identity or SSH policy are supplied at clone time.
VERDICT: not verified
EVIDENCE: Read seal-image.sh. It runs `usermod --password '*' ubuntu`, removes the authorized_keys files for ubuntu and root, and removes the cloud-init ssh_config override and seed. It leaves the cloud-init sudoers rule, which the current criterion allows. cloud-init/user-data enables temporary password SSH for the QEMU build only, and the readme and Design describe that temporary access and its removal. The real cloud-init check tests/test_sealing.sh needs Docker and was not executed by me. `make check` only lints it, and ShellCheck is absent on this host. Sealed-artifact inspection and fresh boots with consumer-supplied users and keys are retained implementer evidence only.

CRITERION: AC-07 `packer/ubuntu/readme.md` documents the `-only` invocation for both formats and the required Proxmox variables/secrets.
VERDICT: met
EVIDENCE: Inspected packer/ubuntu/readme.md at the target. It gives `packer build -only='proxmox-clone.ubuntu' .` and `packer build -only='qemu.ubuntu' .`, plus the raw and tcg variants. It documents the token ID and secret through PKR_VAR_proxmox_api_token, with a prompt that keeps the secret out of shell history, and the copy of proxmox.auto.pkrvars.hcl.example. It explains proxmox_insecure, template_vmid, proxmox_storage_pool, proxmox_task_timeout and proxmox_cpu_type, and how -var-file and auto-loading behave. I executed a scan comparing each declared Proxmox variable in variables.pkr.hcl with the readme and the example. All 11 are named in the example file. proxmox_url, proxmox_api_token_id, proxmox_node and base_template_name appear in the readme as described values ("endpoint, node, storage and base template name", token ID form) rather than by name. Packer validation confirms that the variable names in the example match the template. Limitation: the guide was not followed through a live build.

NO FINDINGS

### R-12

FINDING: F-01
KIND: judgement
SEVERITY: should-fix
WHERE: Acceptance Criteria AC-09 and AC-10; Design, Bootstrap preservation map (Krew row)
EVIDENCE: The map row "Krew, stern, view-secret and neat" says "Selected plugins must work for a fresh user ... Any proposed omission needs an owner decision". AC-09 lists only "Zi/Powerlevel10k, MOTD, GitHub CLI and kubectl" and does not mention Krew. AC-10 requires only "the selected kubectl alias/completion and selected Krew plugins", and no section says which plugins are selected. The source behaviour is purely per user. pds-source/bash/debian/software/install_kubectl.sh:60 checks `$HOME/.krew/bin/kubectl-krew`, line 97 installs `("neat" "view-secret" "stern")`, and lines 76 and 102 only print warnings when a download fails. An empty selection would therefore tick AC-09 and AC-10, and the user's earlier stern/view-secret/neat tooling would still be lost.
PROPOSAL: Name neat, view-secret and stern (and Krew itself) in AC-09 and AC-10 as required for a fresh user from both outputs, or record an owner decision that omits them. The AC-10 proof should run each plugin as the new user.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: Design, Bootstrap preservation map (Zi and Powerlevel10k row) and following paragraph; AC-10; AC-11
EVIDENCE: The map promises "preserving the existing preset and Zi workflow" and also "first shell startup does not require an installer download". The paragraph after it adds that Zi/plugin downloads are "selected at exact revisions". The existing workflow is the packaged pds-source/bash/config/zshrc:11-33. It runs unpinned `zi light romkatv/powerlevel10k`, `zsh-users/*`, `agkozak/zsh-z`, `michielvha/zsh-readline` and `zi snippet OMZP::docker|history|git`, which Zi clones into each user's home on first startup. Powerlevel10k's gitstatus also fetches a gitstatusd binary into the user's cache on first prompt. AC-11 requires "existing Zi/preset behavior continue to work", and tests/image_provisioning_test.py:70-71 asserts those exact unpinned `zi light` lines. zsh.sh:16 also clones Zi at the default branch. As written, the design cannot satisfy both "preserve the existing workflow" and "no download, exact revisions". It also names no mechanism, such as a shared Zi home or skel-seeded plugins with version ices, and does not list gitstatusd among the bounded inputs.
PROPOSAL: Say which zshrc and Zi changes PDS will make: pinned revisions for Zi and every plugin and snippet, a prebuilt shared or skel location, and gitstatusd handling. Reword AC-11's "existing Zi/preset behavior" to mean the same preset and plugin set, not unpinned per-user first-start cloning.

FINDING: F-03
KIND: judgement
SEVERITY: should-fix
WHERE: Design, PDS provisioning and package identity; Bounded image checks and delivery order; Scope (Out of scope); AC-08
EVIDENCE: Design says "The normal signed-repository route must also pass before final delivery", and AC-08 requires a "verified signed-repository release build". Scope puts "Merging, releasing PDS" out of scope. pds-source/.github/workflows/build-apt-package.yml:134 and :169 create a release and APT publication only on pushes to main. Lines 68-80 also overwrite the version with GitVersion output. The candidate's `version: 1.0.0` (packaging/nfpm.yaml:2) is a placeholder, so the published version will differ from the candidate (latest release 0.19.0). The delivery order paragraph names "its separate PDS dependency" but no handoff. It does not say the owner merges PDS first, that the assigned release version then replaces the candidate pin in builders, or that builders cannot be accepted until then.
PROPOSAL: Add an explicit handoff: the PDS PR is merged and released by the owner, its CI-assigned version is recorded as the builders pin, and the signed-route builds for both outputs then run before builders acceptance. State that the candidate's 1.0.0 is a local placeholder identified only by its SHA-256.

FINDING: F-04
KIND: judgement
SEVERITY: should-fix
WHERE: Design, Bootstrap preservation map (Hostname, users ... login shell, sudo row); AC-10; Test Plan AC-10; Design, Variables & secrets
EVIDENCE: The map says "A documented example selects Zsh and sudo for the deployed user". The Test Plan for AC-10 only says "launch Zsh", so a user whose login shell is still Bash passes. For the native output, the earlier recorded clone checks used Proxmox-supplied users and keys (Context, "Native host CPU follow-up"). Proxmox's generated cloud-init user data does not set a login shell or sudo rule, so choosing Zsh for a native clone needs custom user data (for example a cicustom snippet on snippet-capable storage). The token scope in Variables & secrets covers only VM IDs, the target pool and the bridge. No section names this dependency for the two native clone checks.
PROPOSAL: Make the AC-10 proof require that the new user's login shell is Zsh and that the documented sudo choice applies on both outputs. Name the native clone-time mechanism and any storage or permission it needs.

FINDING: F-05
KIND: factual
SEVERITY: nit
WHERE: Context, Combined PR preparation (2026-11-04)
EVIDENCE: Context says the earlier `origin/main:packer/ubuntu/scripts/install.sh` "selected Zi, shell configuration, an update cron entry and kubectl". The preserved history in docs/specs/0003-pds-provisioning-migration.md:45-53 also lists `set_sudo_nopasswd`, `restricted_ssh_security_profile`, GitHub CLI and an inline MOTD/neofetch block. The Bootstrap preservation map relies on the GitHub CLI, MOTD, sudo and SSH-policy rows as earlier capabilities. I could not read the origin blob itself with Read/Grep/Glob.
PROPOSAL: Complete the list of earlier capabilities, citing the origin file and lines, so it matches the preservation map.

FINDING: F-06
KIND: judgement
SEVERITY: nit
WHERE: AC-10, AC-11; Test Plan AC-10
EVIDENCE: Installing the package changes deployed-user shells in two ways that no section mentions. pds-source/packaging/scripts/postinstall.sh:29-38 appends an auto-load block to /etc/bash.bashrc that runs `. /usr/share/pds/init.sh 2>/dev/null || true`. packaging/profile.d/pds.sh:26-29 hides loader stderr and prints "PDS Functions loaded!" on interactive login. So AC-11's "reports library failures" holds for the explicit build-time source but not for every deployed user's shell. Also, the provisioners run under `sudo -n bash` (ubuntu.pkr.hcl:97,102), so `configure_zsh` (zsh.sh:59-60,67) and `install_kubectl` (install_kubectl.sh:25-28,84-85) write to the invoking HOME. That HOME is likely /root rather than the ubuntu account, and the AC-10 inspection of "build-user paths" does not name /root.
PROPOSAL: State whether the image keeps package auto-loading and the login message for deployed users, and narrow AC-11's failure-reporting promise to the paths it covers. Include /root in the AC-10 residue inspection.

### R-13

FINDING: F-01
KIND: judgement
SEVERITY: should-fix
WHERE: Design, Baked update and SSH policy; AC-14; Test Plan AC-14
EVIDENCE: The design keeps "the existing nightly `00:00` update policy". The only existing implementation is pds-source/bash/common/admin/sysadmin.sh:8-9, which appends `0 0 * * * root apt update -y && apt upgrade -y` to /etc/crontab. It sets no DEBIAN_FRONTEND and no dpkg conffile options. Under cron, stdin is not a terminal, so a conffile prompt during `apt upgrade` aborts the configure step. The image modifies at least two dpkg conffiles: /etc/crontab (cron package), through this same helper, and /etc/bash.bashrc (bash package), through pds-source/packaging/scripts/postinstall.sh:30-34. The first upstream conffile change in either package can therefore leave dpkg half-configured and stop every later nightly upgrade. The AC-14 proof checks only "exactly one midnight job, scheduler enablement", so a job that fails every night still passes. The owner's request for scheduler proof is not met by a job and timer that exist but never succeed.
PROPOSAL: Require the managed job to run non-interactively, with DEBIAN_FRONTEND=noninteractive and explicit conffile handling such as `--force-confdef --force-confold`. In AC-14's proof, run the installed job's exact command in a fresh instance of each output under cron's environment (cron PATH, stdin /dev/null) and require exit 0. Include a modified-conffile case in the disposable-Ubuntu test.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: Design, Baked update and SSH policy; AC-06; AC-14; Test Plan AC-06 and AC-14
EVIDENCE: On Ubuntu, sshd_config includes `sshd_config.d/*.conf` before its own settings, and OpenSSH keeps the first value it reads. The cloud image ships 60-cloudimg-settings.conf (tests/test_sealing.sh:14 models it). When a cloud-config sets `ssh_pwauth`, cloud-init writes 50-cloud-init.conf, which sorts ahead of both. The build seed itself does this (packer/ubuntu/cloud-init/user-data:4). The current PDS function only edits the main /etc/ssh/sshd_config with sed (sysadmin.sh:140-144), so any drop-in overrides it. The design asks for "a retained managed OpenSSH configuration" that stays effective "after clone-time cloud-init runs" and for keyboard-interactive to be disabled to enforce key-only login. It never says where that file goes or how it is ordered against 50-cloud-init.conf. The Test Plan boots fresh instances only with consumer configs that produce no such drop-in, so it cannot tell whether the baked policy wins or loses when clone-time input sets `ssh_pwauth: true`. A drop-in that sorts before 50 would also apply to the QEMU build's password session after any sshd reload. That is the build-access ordering the design wants to protect.
PROPOSAL: Name the managed drop-in path and its sort order relative to 50-cloud-init.conf and 60-cloudimg-settings.conf, and state the result the owner selected: key-only is enforced even when deployment input requests password auth. Add a fresh instance per output whose cloud-config sets `ssh_pwauth: true` and check `sshd -T`, and confirm in the build log that no sshd reload or restart happens before sealing.

FINDING: F-03
KIND: judgement
SEVERITY: should-fix
WHERE: Test Plan AC-06, AC-14
EVIDENCE: The AC-14 proof asks to "Observe ... failed password/root login". By default, cloud-init creates deployed users with locked passwords, and sealing removes /root/.ssh/authorized_keys (seal-image.sh:12). So both logins fail whatever PasswordAuthentication, KbdInteractiveAuthentication and PermitRootLogin say. These negative probes cannot fail, and they do not show that the policy is in force.
PROPOSAL: Make the negative probes able to fail. Give the test user a known password and inject a root key in one owned instance per output. Then require password, keyboard-interactive and root-key attempts to be refused, with the server offering only `publickey`, alongside the `sshd -T` values.

FINDING: F-04
KIND: judgement
SEVERITY: should-fix
WHERE: Design, Bootstrap preservation map (Krew row) and following Zi paragraphs; AC-10
EVIDENCE: The Krew row requires Krew, neat, view-secret and stern for "a fresh deployment user through supported PDS image/user setup" and says "Failed downloads cannot be logged as successful provisioning". That implies the downloads happen at build time. The candidate installs everything under `$HOME/.krew` of the invoking user (install_kubectl.sh:60,71-73,84-104), and the build runs as root via `sudo -n bash` (ubuntu.pkr.hcl:102). A user created at clone time therefore needs either a shared Krew root that is baked into the image or a per-user download on first login. The design names neither. Lines 534-536 add "This scope adds no image-specific plugin cache, shared prefetched asset tree or plugin lockfile" without limiting that to Zi. Read literally, it rules out the shared Krew tree that the build-time wording implies. If Krew is downloaded at first login instead, that contradicts the provisioning-failure wording, and AC-10's proof gives no network condition for Krew as it does for Zi.
PROPOSAL: State where Krew and its three plugins live for users created after sealing, for example a system KREW_ROOT installed at build time and on every user's PATH, and when they are downloaded. Limit the "no shared prefetched asset tree" sentence to Zi plugins, or explicitly extend first-login behavior to Krew with a matching AC-10 proof condition.

FINDING: F-05
KIND: judgement
SEVERITY: should-fix
WHERE: Design, PDS provisioning and package identity; Baked update and SSH policy; AC-08
EVIDENCE: Normal builds install an exact PDS version "from the signed PDS APT repository", and AC-08 verifies "dpkg package metadata ... in each built output". The baked nightly job runs a plain `apt upgrade -y` on every package. If the signed PDS source stays configured in the sealed image, deployed instances move to whatever PDS release is newest at the next midnight. The same applies to kubectl within the pkgs.k8s.io channel that install_kubectl.sh:16 adds. The design does not say whether the PDS repository and its trust key remain in the image. So the exact-version guarantee and the shell assets of deployed users after first night are undefined, and no Test Plan row checks the retained source.
PROPOSAL: State whether the sealed image keeps the signed PDS source. If it does, say that the exact pin describes the image at seal time and that deployed instances follow PDS releases nightly. If it does not, remove the source during provisioning or sealing. Add an offline inspection of /etc/apt/sources.list.d and keyrings to AC-08's proof.

FINDING: F-06
KIND: factual
SEVERITY: nit
WHERE: Design, File-based MOTD presets; Test Plan AC-13
EVIDENCE: The Test Plan asks to "compare EdgeForge with the preserved legacy banner". The original block (motd-preset-drafts/edgeforge-original-block.txt:21-28 and 39-49) prints a plain banner, then a coloured copy, then runs neofetch, and it replaces other MOTD scripts. The draft edgeforge.txt holds only the plain lines, and its line 8 drops the trailing spaces of the original's last echo. Without a defined comparison target, a byte comparison fails and any looser comparison is undefined.
PROPOSAL: Define the comparison target as the rendered output of the original plain echo lines 21-28, with trailing whitespace ignored. State that the coloured copy and the unconditional neofetch are not kept, since neofetch stays available through the optional information argument.

### R-14

FINDING: F-01
KIND: judgement
SEVERITY: should-fix
WHERE: Test Plan AC-14; Design, Baked update and SSH policy
EVIDENCE: The repaired AC-14 proof says that with `ssh_pwauth: true`, a temporary known non-root password and a temporary root key, "permissive SSH settings would admit the negative probes". That holds for password login, which the 50-cloud-init.conf drop-in written for `ssh_pwauth: true` would enable without 00-pds-security.conf (test_sealing.sh:14-19 reproduces this). It does not hold for the other two probes. Ubuntu's cloud-init default `disable_root: true` installs root's injected key with a forced command that prints "Please login as the user ..." and exits. A root-key attempt then fails even under the distribution's `PermitRootLogin prohibit-password`, unless the probe tells authentication refusal apart from the forced-command exit. Ubuntu's main sshd_config also already sets `KbdInteractiveAuthentication no`, and no deployment input in the plan enables it. So the keyboard-interactive probe is refused with or without the baked file, and "only publickey offered" cannot show it either. These are inferences from Ubuntu and cloud-init defaults, not observed in this review. The current tree sets no `disable_root` anywhere (Grep for disable_root found no match under packer/).
PROPOSAL: In the owned negative-probe instance, set `disable_root: false` and require root-key refusal at authentication ("Permission denied", no forced-command banner). To prove precedence directly, add a temporary lower-precedence test drop-in, for example `10-test-permissive.conf` setting PasswordAuthentication, KbdInteractiveAuthentication and PermitRootLogin to yes, and require refusal and `sshd -T` values to stay unchanged.

FINDING: F-02
KIND: judgement
SEVERITY: nit
WHERE: Design, Baked update and SSH policy; Scope (PDS remains independently usable for ordinary host setup)
EVIDENCE: Design line 600 requires "Apply the final policy without any sshd reload/restart before sealing", and line 594-595 requires the PDS repair to "make the intended effective settings reliable". OpenSSH only applies new configuration when it starts or is reloaded. The current function edits the file and prints "Restricted SSH security profile will be applied on next login." (pds-source/bash/common/admin/sysadmin.sh:140-145), which is wrong for a running daemon. The design does not say whether the repaired `restricted_ssh_security_profile` reloads sshd. If it reloads, it breaks the build-access constraint. If it never reloads, the policy is not in effect on an ordinary host until a reload or restart, and no criterion covers that ordinary-host path.
PROPOSAL: State that the function writes and validates the drop-in (`sshd -t`) without reloading, and that ordinary-host use gets an explicit, documented reload step or opt-in flag that the image build never uses.

FINDING: F-03
KIND: judgement
SEVERITY: nit
WHERE: Test Plan AC-14
EVIDENCE: The proof says "Build logs must show no sshd reload/restart before sealing." The Packer log records provisioner output. It does not reliably record service restarts triggered by package maintainer scripts or restart helpers during the PDS step's APT installs (for example GitHub CLI and kubectl through install_gh.sh:24-25). If no restart line appears in the log, that does not show no restart happened.
PROPOSAL: Use guest-side evidence. Record ssh.service's MainPID and ActiveEnterTimestamp (or its journal entries) right after the policy is written and again just before sealing, and require them to match.

FINDING: F-04
KIND: judgement
SEVERITY: nit
WHERE: Design, Baked update and SSH policy; AC-14
EVIDENCE: The managed job runs `apt-get` at 00:00 with noninteractive conffile handling. The design does not say how it coexists with Ubuntu's own APT timers in the cloud image. `apt-daily.timer` has a 12-hour randomized delay, so it can hold the APT lists or dpkg lock at midnight. By default `apt-get` fails at once on a held lock. The single cron-environment run in the Test Plan would not reveal this intermittent failure. This is inferred from Ubuntu defaults and was not observed here.
PROPOSAL: Make the managed command wait for or retry APT/dpkg locks (for example a bounded `DPkg::Lock::Timeout`). State that Ubuntu's apt-daily/unattended-upgrades timers remain alongside the PDS job, or say how they are handled.

FINDING: F-05
KIND: factual
SEVERITY: nit
WHERE: Design, `source "qemu" "ubuntu"` (portable local artifact)
EVIDENCE: Line 411 says "Local QEMU checks exercise shared image provisioning; they do not establish native-builder correctness. Spec 0002 must test both paths." The revised Scope (lines 258-259, 266-267) and Bounded image checks (lines 639-648) require real builds, offline inspection and two fresh boots of both outputs in this feature. They also say feature 0002's absence "cannot excuse missing checks for this Ubuntu amd64 delivery".
PROPOSAL: Reword line 411 so this feature tests both Ubuntu amd64 paths, and feature 0002 covers only the wider matrix.

### R-15

FINDING: F-01
KIND: judgement
SEVERITY: nit
WHERE: Design, Baked update and SSH policy (build-access paragraph); Test Plan AC-14
EVIDENCE: Design line 605 says "Finish package operations capable of restarting services before installing the final policy". Lines 606 to 607 limit the restart evidence to the time between "immediately before policy installation" and "again before sealing". The sealing step, which the design keeps as a separate final script (line 481), still runs package operations after that point. packer/ubuntu/scripts/seal-image.sh:24 runs `apt-get -y autoremove`, and its maintainer scripts and APT hooks can restart services. So the spec's own ordering rule is broken by an existing step, and its PID window ends before that step runs. seal-image.sh:28 also truncates every regular file under /var/log, which includes persistent journal files under /var/log/journal. Journal evidence for line 607 must therefore be captured before sealing truncates it, and the spec does not say so. I did not observe a restart. This is inferred from the current sealer source.
PROPOSAL: Either move autoremove ahead of policy installation, or extend the PID/activation comparison to the end of sealing, just before shutdown. Also state that the guest journal evidence is exported before seal-image.sh truncates /var/log.

FINDING: F-02
KIND: judgement
SEVERITY: nit
WHERE: Test Plan AC-14 (cron-environment run)
EVIDENCE: The proof runs "the installed job's exact command under cron PATH with stdin /dev/null and require exit 0". The existing job lives in /etc/crontab (pds-source/bash/common/admin/sysadmin.sh:8-9), and cron runs those entries with /bin/sh (dash on Ubuntu) and a minimal environment. The new managed command adds a bounded lock wait/retry (Design lines 584 to 585), so it is no longer the simple `&&` chain that dash runs safely. If the command is run from a root Bash session with the provisioning or login environment still set, Bash-only syntax or inherited variables such as DEBIAN_FRONTEND can make it pass, even though the real 00:00 run would fail. I inferred this from cron's defaults and the current helper. I executed nothing.
PROPOSAL: Require the fresh-instance run to use /bin/sh -c with a cleared environment that matches cron's (for example env -i with cron's PATH, HOME, SHELL and LOGNAME). Alternatively, require evidence that cron itself ran the managed entry and logged exit 0.

### R-16

```text
FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Design (Provisioning changes; Bootstrap preservation map)
EVIDENCE: docs/specs/0001-packer-proxmox-native-output.md:558 says the nightly update job and restricted SSH baseline "are baked into each image", and :427-428 says "Generic SSH restrictions are supplied by PDS at build time and retained in the finished image" without qualification. Both are normative Design text and contradict :488-489 ("They are not a mandatory policy for every custom image"), :605-607 and AC-15, which let a custom recipe omit those calls. The summary at :20 also states the policies unconditionally.
PROPOSAL: Qualify :558 and :427-428 as default-recipe behavior, for example "the default recipe bakes both into each output; a custom recipe may omit them", and add the same qualifier to the summary line.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: Acceptance Criteria AC-15, Test Plan AC-15
EVIDENCE: AC-15 (:711) requires custom recipe selection "for either output", but the proof (:731) says only "Build clean default and custom artifacts". It does not say that a custom artifact is built for each output, which custom recipe is used, or which observations show that the PDS policy is absent. The Design at :496 promises a committed example that omits the update and SSH calls, but the proof does not tie the tested custom selection to that example. It is also unclear whether custom artifacts need the fresh boots in AC-05/AC-06 or only offline inspection.
PROPOSAL: Make the proof build the committed example custom recipe on both outputs. Inspect each sealed disk offline and require: no 00-pds-security.conf, no PDS-managed update job, the example's own selections present, and the AC-06 credential and identity checks passing. State whether this needs a fresh boot or offline inspection is enough.

FINDING: F-03
KIND: judgement
SEVERITY: nit
WHERE: Design (File-based MOTD presets; Bootstrap preservation map), AC-13
EVIDENCE: :661 and AC-13 (:707) keep "an explicit configurable MOTD-preset input", and :555 keeps an explicit kubectl version/channel input. Under :491-495, the recipe file is now the selection mechanism. The spec does not say how these Packer inputs reach the recipe, or whether a custom recipe may ignore them. That leaves room for an input that silently has no effect under a custom recipe.
PROPOSAL: State that builders exports these inputs to the selected recipe, that the default recipe consumes them, and that a custom recipe may use or ignore them. Alternatively, state that preset selection lives only in the recipe and reword AC-13 to match.

FINDING: F-04
KIND: judgement
SEVERITY: nit
WHERE: Design (Baked update and SSH policy)
EVIDENCE: :633-637 requires package operations that can restart services to finish before the SSH policy is installed, and requires no sshd restart before sealing. Under the recipe model, call order is set in the recipe file. The spec makes default.sh responsible for this, but does not say whether a custom recipe that selects restricted_ssh_security_profile before later installers carries the same ordering duty or gets a builder check. On the QEMU password path, an sshd restart after the policy is applied would cut Packer's build access.
PROPOSAL: Add one sentence saying that any recipe selecting the SSH policy must call it last, after service-restarting installers, and that the PID and activation check applies whenever that call is selected, not only to the default recipe.
```

### R-17

```text
FINDING: F-01
KIND: judgement
SEVERITY: nit
WHERE: Design, Baked update and SSH policy (custom-recipe ordering sentence); Test Plan AC-14, AC-15
EVIDENCE: docs/specs/0001-packer-proxmox-native-output.md:645-647 says "Any recipe selecting `restricted_ssh_security_profile` must call it last" and "The guest PID/activation check applies whenever that policy is selected, including in a custom recipe." Builders runs the selected recipe as one trusted script (:494-496), and :640 places the PID capture "immediately before policy installation", which is inside the recipe. The spec does not say how builders finds that point in a custom recipe, or whether the call-last rule is enforced or only documented. AC-14 and its proof cover only the default recipe (:716, :737). The AC-15 proof (:738) exercises only custom.example.sh, which omits the SSH policy (:497-498). So no criterion or proof row observes the custom-recipe obligation, and a custom recipe that calls the policy before a later installer passes every box.
PROPOSAL: Name the mechanism. For example, builders captures ssh.service MainPID/ActiveEnterTimestamp through a small builder-provided step or wrapper around the selected policy call and compares the values at the end of sealing, and the AC-15 proof shows this check fails for a fixture recipe that restarts sshd after selecting the policy. Otherwise, reword :645-647 as a documented recipe-author rule that builders does not verify.

FINDING: F-02
KIND: factual
SEVERITY: nit
WHERE: Summary (line 20); frontmatter goal (line 5)
EVIDENCE: :20 says "a PDS default recipe selecting nightly updates and restricted SSH". :492 puts the default recipe in builders at `packer/ubuntu/recipes/default.sh`, and :493-494 says operators select another recipe "without changing the default recipe or PDS". So the recipe belongs to builders, and PDS only supplies the functions it calls. The frontmatter goal at :5 still says, without qualification, that the images have "automatic updates and restricted SSH". The R-16 F-01 repair qualified :428 and :563 the same way.
PROPOSAL: Change :20 to say "a builders default recipe that calls PDS functions for nightly updates and restricted SSH". In the goal, add "by default" or a similar qualifier.
```

## Sources

- [Proxmox cloud-init source](https://github.com/proxmox/qemu-server/blob/master/src/PVE/QemuServer/Cloudinit.pm), `cloudinit_userdata` and `get_custom_cloudinit_files`/`read_cloudinit_snippets_file`, read on 2026-11-04: generated user data omits an explicit shell, while custom user data is read from snippet storage. This upstream inspection does not validate the installed node.

- PDS candidate `/home/m/code/PDS-image-provisioning` at `04c8dee+dirty`: `packaging/init.sh`, `packaging/nfpm.yaml:50-66`, `bash/common/shell/zsh.sh:4-68`, `bash/config/zshrc`, `bash/debian/software/install_kubectl.sh:7-107` and `tests/image_provisioning_test.py` establish the observed package contract and remaining installer gaps.
- `gh api repos/michielvha/PDS/releases/latest`, `commits/main` and `pulls`, read on 2026-11-04: published release, source baseline and unrelated open PR boundary. The private preparation snapshot and package-test log preserve this run's inputs.

- [Packer `proxmox-clone` builder](https://developer.hashicorp.com/packer/integrations/hashicorp/proxmox/latest/components/builder/clone)
- [Create Proxmox cloud-init templates for Packer (base bootstrap)](https://dev.to/mike1237/create-proxmox-cloud-init-templates-for-use-with-packer-193a)
- [kencx homelab: Packer proxmox-iso vs proxmox-clone](https://kencx.github.io/homelab/images/packer.html)
- [Building Ubuntu 24.04 Proxmox templates with Packer](https://thecomalley.github.io/packer-proxmox-ubuntu)
- [Packer `-only` / `-except`](https://developer.hashicorp.com/packer/docs/commands/build#only-foo-bar-baz)
- [`bpg/proxmox` Terraform provider](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
- Legacy flow before `deae257`: `packer/ubuntu/ubuntu.pkr.hcl`, `scripts/install.sh` and the removed `scripts/cleanup.sh`.
- [Feature-document standard](https://github.com/vhco-pro/docs/blob/0e52f51f01b84eda75a976763c42d8ec0a07b544/conventions/feature-documents.md): lifecycle, criteria, proof and review-record formats.

- [Committed validation summary](../validation/0001-2026-11-04.md): implementer-observed build, recovery, clone and cleanup checks, with their limits.
