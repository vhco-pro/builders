---
status: draft
status_description: "Migrated for owner review; no current vh-adlc acceptance or completion is claimed."
issue: https://github.com/vhco-pro/builders/issues/3
goal: "Configure builder images through selected functions from an exact version of the standalone PDS package."
covers:
  - packer/ubuntu/
  - readme.md
---

# Plan: Move provisioning into PDS ("select and apply")

Configure builder images through selected functions from an exact version of the standalone PDS package.

## Context

Migration: this file now uses the pinned vh-adlc format in its existing location. Earlier checklist ticks are historical and are not imported as current acceptance. No review or owner-acceptance record has been invented.

The design below is imported from the earlier draft and has not gained review or acceptance through migration. Current implementation status must be checked before starting it.

The old readme said it out loud: *"Move all the functionality to PDS and just import here, script should
be select and apply."* Today `packer/ubuntu/scripts/install.sh` is the opposite of that; a long inline
script that **duplicates logic PDS already has**, while also *calling* PDS-style functions it never
reliably installs (there's a standing `TODO: Rework fetching the functions to using the pds apt
package`). The copied `scripts/.p10k.zsh` and `scripts/zshrc` are likewise duplicates of files that live
in PDS (`bash/config/.p10k.zsh`).

PDS is now a real, installable artifact; the **`pds` Debian package** served from a GitHub Pages APT
repo (`https://michielvha.github.io/PDS/apt/`), which lands functions under `/usr/share/pds/` and adds a
`pds` CLI. So the migration is now concrete: **install the package, source it, call functions.**

Mapping the current `install.sh` calls to where they already exist in PDS:

| `install.sh` calls | Lives in PDS at | Nature |
| --- | --- | --- |
| `install_zi`, `configure_zsh` | `bash/module/` (zsh) | zsh **config only** → **migrate** (see note) |
| `set_sudo_nopasswd`, `update_system_cron_entry` | `bash/module/sysadmin.sh` | generic → **migrate** |
| `restricted_ssh_security_profile` | `bash/common/admin/sysadmin.sh` | hardening → **migrate (with care)** |
| `install_kubectl` | `bash/debian/software/install_kubectl.sh` | third-party repo tooling → **migrate** |
| `gh` (GitHub CLI) | *(not in PDS yet)* | third-party apt repo → **contribute to PDS** |
| custom MOTD / neofetch block | *(inline only — not in PDS yet)* | generic → **contribute to PDS** |
| `configure_admin`, hostname, SSH keys, netplan | *(inline)* | **identity → cloud-init (0001), not PDS** |

So most of `install.sh` is either already in PDS or belongs in cloud-init. What's left for builders is a
thin **select-and-apply** list.

**apt vs PDS boundary (decided in 0001).** Anything in Ubuntu's default apt repos is installed directly
via the cloud-init `packages:` list (native apt integration), *not* through PDS. PDS is only for what apt
can't do cleanly: third-party repos (`gh`, `kubectl`), multi-arch/non-default binaries, and config/setup
logic. Concretely:

- **zsh:** the `zsh` *package* is installed by cloud-init (apt). PDS's `install_zi` / `configure_zsh` do
  only the **configuration** (zi, Powerlevel10k, plugins, `/etc/zshrc`), not the apt install. Ensure the
  PDS functions don't re-`apt install zsh` (or make it a no-op when present).
- **gh / kubectl:** these need third-party apt repos, so they are PDS's job, not the cloud-init list.
- **MOTD:** contribute as `setup_motd`; PDS may pick a maintained tool (e.g. fastfetch) since `neofetch`
  is deprecated upstream.

Current source: `packer/ubuntu/ubuntu.pkr.hcl` defines the two outputs; `Makefile` defines the available local checks. The feature links were confirmed by reading GitHub issues #1, #2 and #3 during this migration.

## Scope

- Builder provisioning = **install the `pds` package → source it → call a declarative list of PDS
  functions**. No inline install/config logic in the repo.
- Remove the duplicated shell-config files (`scripts/.p10k.zsh`, `scripts/zshrc`) in favour of PDS's.
- Establish a **"select and apply" manifest** per image so adding an OS/role is "list the functions,"
  not "write a script"; dovetails with the multi-OS goal in 0002.
- Everything that makes the image *machine-specific* stays **out** (that's 0001's cloud-init boundary).

Out of scope:

- Identity provisioning (hostname, admin user, SSH keys, static net); owned by clone-time cloud-init.
- Changing PDS itself beyond **filling gaps** the builder needs (e.g. a MOTD function) and ensuring the
  needed functions are actually bundled in the `pds` package.
- Reworking the `seal-image.sh` teardown beyond what 0001 already specifies (machine-id, cloud-init reset).

## Design

### 1. Install PDS from the APT repo (pinned)

First provisioner step, non-interactive:

```bash
curl -fsSL https://michielvha.github.io/PDS/pds-repo.gpg \
  | sudo tee /usr/share/keyrings/pds-repo.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/pds-repo.gpg] https://michielvha.github.io/PDS/apt/ stable main" \
  | sudo tee /etc/apt/sources.list.d/pds-repo.list
sudo apt-get update
sudo apt-get install -y pds=${var.pds_version}    # pin for reproducible builds
```

### 2. Source PDS explicitly (build-time is non-interactive)

PDS auto-loads via `/etc/profile.d` **only for interactive login shells**. Packer provisioners are
non-interactive, so we source the init script directly rather than relying on profile.d:

```bash
# shellcheck disable=SC1091
source /usr/share/pds/init.sh      # exposes install_kubectl, configure_zsh, ... (verify exact path)
```

### 3. "Select and apply"; the thin per-image provisioner

`install.sh` collapses to a declarative sequence of PDS calls (the *only* logic builders keeps), e.g.:

```bash
source /usr/share/pds/init.sh

# --- generic golden-image provisioning, all from PDS ---
install_zi
configure_zsh
install_kubectl
update_system_cron_entry
setup_motd                       # (to be contributed to PDS)
set_sudo_nopasswd                # applied to the clone-time user model, not a baked build user
restricted_ssh_security_profile  # see ordering caveat below
```

The exact list is the image's "manifest." Keeping it a plain, readable sequence (vs a config file) is
enough for now; a per-role manifest file can come later if we grow many roles. Shell-config files come
from the PDS package, so `scripts/.p10k.zsh` / `scripts/zshrc` and their `file` provisioners are deleted.

### 4. Gaps to close in PDS (cross-repo; tracked/worked in the PDS repo)

Verified against PDS `packaging/nfpm.yaml` (bundles `bash/debian/` + `bash/common/` → `/usr/share/pds/`;
`init.sh` auto-sources two levels deep, `platform/category/*.sh`) and the function locations:

- **No hard blocker.** Every function this migration calls has a copy in the *packaged* set
  (`common/` or `debian/`): `install_zi`/`configure_zsh` (`common/shell/zsh.sh`), `set_sudo_nopasswd`
  (`common/shell` + `common/admin`), `update_system_cron_entry` + `restricted_ssh_security_profile`
  (`common/admin/sysadmin.sh`), `install_kubectl` (`debian/software`). `bash/module/` is **not** packaged,
  which is fine since it only holds duplicates.
- **One real gap; MOTD:** the custom MOTD/neofetch block has no PDS equivalent. Contribute it (e.g.
  `setup_motd`) so builders can drop its last inline block.
- **Cleanup; duplicate definitions:** several functions exist in *both* `bash/module/` and `bash/common/`
  (`set_sudo_nopasswd`, `update_system_cron_entry`, `configure_zsh`, ...). The unpackaged `module/`
  copies risk drift; pick `common/` as canonical and retire/repackage `module/` consistently.
- **Non-interactive contract:** `profile.d/pds.sh` (interactive-only, prints a welcome banner) is *not*
  our entry point; builders sources `init.sh` directly. Confirm `source /usr/share/pds/init.sh` is
  **side-effect-free and safe under `set -eux`** (it sources *all* category `*.sh`, so any file with
  top-level side effects or required env would break a non-interactive build). Worth a guarantee in PDS.
- **Path/name consistency:** PDS `packaging/README.md` says `/usr/share/pds-funcs/` while the real install
  path is `/usr/share/pds/`; align the docs.

> These are PDS-repo tasks. This spec only *depends* on them landing; builders work starts once the `pds`
> package exposes `setup_motd` and the non-interactive `source` contract is confirmed.

## Acceptance Criteria

- [ ] AC-01: `packer/ubuntu/scripts/install.sh` contains **no** inline install/config implementations; only PDS install + `source` + a select-and-apply list of PDS function calls.
- [ ] AC-02: The `pds` package is installed from the APT repo at a **pinned version** during the build.
- [ ] AC-03: Duplicated `scripts/.p10k.zsh` and `scripts/zshrc` are removed; their config comes from PDS.
- [ ] AC-04: Every PDS function the manifest calls is **resolved from the installed package** (confirmed via `pds show <fn>`), not from a local copy; and any gap is filed/added upstream in PDS first.
- [ ] AC-05: The Ubuntu image still builds green through 0002's harness (Layer 0–3), proving the PDS-provisioned image has the expected tooling (kubectl, zsh/p10k, cron updater, MOTD) and no identity baked in.
- [ ] AC-06: `packer/ubuntu/readme.md` documents the select-and-apply model and the per-image function list.

## Test Plan

| Criterion | Proof |
| --- | --- |
| AC-01 | Inspect the provisioning entrypoint and run a package-backed image build; confirm shared installation/configuration is selected through PDS calls rather than copied implementations. |
| AC-02 | Build with a chosen exact published PDS package version and verify the installed package version inside the image. |
| AC-03 | Inspect the resulting filesystem and source references; shell configuration must come from the installed PDS package, not local duplicate files. |
| AC-04 | Use `pds show` and package-file inspection to establish the origin of every selected function; inspect its upstream tracking when a gap remains. |
| AC-05 | Run the implemented image harness through Layers 0-3 for the PDS-backed image, checking selected tooling and fresh identity. |
| AC-06 | Follow the Ubuntu guide and compare the documented function selection with the executable provisioner. |

## Tasks

None scheduled under vh-adlc yet. Do not reconstruct completed task commits retrospectively. Plan the unchecked work after review and owner acceptance.

## Open Questions

### Q1: When should optional SSH hardening be applied?

**Recommendation:** A. Defer SSH policy to consumer configuration until build and first-boot access are independently verified.

| Option | You get | It costs |
| --- | --- | --- |
| A. Consumer configuration | Explicit access policy per deployed machine | Consumers must apply the policy |
| B. Final image provisioner | One common policy in the image | The build connection and clone-time access must remain usable |

**Why this is yours:** The original draft left this access-policy choice open. PDS remains reusable in either case.

### Q2: Should the PDS image selection stay in Bash or move to a separate manifest?

**Recommendation:** A. Keep a short Bash selection while only one image recipe needs it.

| Option | You get | It costs |
| --- | --- | --- |
| A. Bash function selection | Direct calls to the standalone library | Multiple roles may eventually repeat selection lists |
| B. Separate role manifest | A data-driven selection interface | Requires a new schema and interpreter |

**Why this is yours:** The original draft proposed starting with Bash but did not record an owner decision in the current workflow.

## Review Log

| Date | Review | Kind | Commit | Model | Isolation | Outcome |
| --- | --- | --- | --- | --- | --- | --- |

## Sources

- [PDS repo](https://github.com/michielvha/PDS) and its `packaging/README.md` (apt package + `pds` CLI).
- PDS APT repo: `https://michielvha.github.io/PDS/apt/` (GPG key + `deb` source, `apt install pds`).
- Depends on / shares the `build` block with [`0001-packer-proxmox-native-output.md`](0001-packer-proxmox-native-output.md);
  verified by [`0002-image-build-testing.md`](0002-image-build-testing.md).
- Legacy being replaced: `packer/ubuntu/scripts/install.sh`, `scripts/.p10k.zsh`, `scripts/zshrc`.
- [Feature-document standard](https://github.com/vhco-pro/docs/blob/0e52f51f01b84eda75a976763c42d8ec0a07b544/conventions/feature-documents.md): lifecycle, criteria, proof and review-record formats.
