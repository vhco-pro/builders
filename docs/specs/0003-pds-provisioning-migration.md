# 0003 — Move provisioning into PDS ("select and apply")

- **Status:** draft
- **Scope:** the `build` block's provisioners for `packer/ubuntu` — replace inline install/config logic
  with calls into the **PDS** apt package. Applies to *both* builders from 0001 (they share the `build`
  block). **Out of scope:** identity provisioning (hostname/user/SSH keys → cloud-init at clone time,
  per 0001), the builder/output mechanics (0001), the test harness (0002), and PDS's own internals.

## Context

The old readme said it out loud: *"Move all the functionality to PDS and just import here, script should
be select and apply."* Today `packer/ubuntu/scripts/install.sh` is the opposite of that — a long inline
script that **duplicates logic PDS already has**, while also *calling* PDS-style functions it never
reliably installs (there's a standing `TODO: Rework fetching the functions to using the pds apt
package`). The copied `scripts/.p10k.zsh` and `scripts/zshrc` are likewise duplicates of files that live
in PDS (`bash/config/.p10k.zsh`).

PDS is now a real, installable artifact — the **`pds` Debian package** served from a GitHub Pages APT
repo (`https://michielvha.github.io/PDS/apt/`), which lands functions under `/usr/share/pds/` and adds a
`pds` CLI. So the migration is now concrete: **install the package, source it, call functions.**

Mapping the current `install.sh` calls to where they already exist in PDS:

| `install.sh` calls | Lives in PDS at | Nature |
| --- | --- | --- |
| `install_zi`, `configure_zsh` | `bash/module/` (zsh) | generic tooling → **migrate** |
| `set_sudo_nopasswd`, `update_system_cron_entry` | `bash/module/sysadmin.sh` | generic → **migrate** |
| `restricted_ssh_security_profile` | `bash/common/admin/sysadmin.sh` | hardening → **migrate (with care)** |
| `install_kubectl` | `bash/debian/software/install_kubectl.sh` | tooling → **migrate** |
| custom MOTD / neofetch block | *(inline only — not in PDS yet)* | generic → **contribute to PDS** |
| `configure_admin`, hostname, SSH keys, netplan | *(inline)* | **identity → cloud-init (0001), not PDS** |

So most of `install.sh` is either already in PDS or belongs in cloud-init. What's left for builders is a
thin **select-and-apply** list.

## Goals

- Builder provisioning = **install the `pds` package → source it → call a declarative list of PDS
  functions**. No inline install/config logic in the repo.
- Remove the duplicated shell-config files (`scripts/.p10k.zsh`, `scripts/zshrc`) in favour of PDS's.
- Establish a **"select and apply" manifest** per image so adding an OS/role is "list the functions,"
  not "write a script" — dovetails with the multi-OS goal in 0002.
- Everything that makes the image *machine-specific* stays **out** (that's 0001's cloud-init boundary).

## Non-goals

- Identity provisioning (hostname, admin user, SSH keys, static net) — owned by clone-time cloud-init.
- Changing PDS itself beyond **filling gaps** the builder needs (e.g. a MOTD function) and ensuring the
  needed functions are actually bundled in the `pds` package.
- Reworking the `cleanup.sh` teardown beyond what 0001 already specifies (machine-id, cloud-init reset).

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

### 3. "Select and apply" — the thin per-image provisioner

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

### 4. Gaps to close in PDS (cross-repo dependency)

- **Packaging coverage:** the `pds` package is built from PDS's `bash/debian/` tree (nfpm), but several
  functions we need live in `bash/common/` and `bash/module/`. **Verify the `.deb` actually bundles
  every function in the table above** (`pds list` / `pds show <fn>` after install); if not, they must be
  added to the packaged set upstream before this migration can complete.
- **Missing function:** the custom MOTD/neofetch block isn't in PDS — contribute it as e.g. `setup_motd`.
- **Init path:** README references `/usr/share/pds-funcs/` while `profile.d/pds.sh` sources
  `/usr/share/pds/init.sh` — confirm the real path and use it.

## Acceptance criteria

- [ ] `packer/ubuntu/scripts/install.sh` contains **no** inline install/config implementations — only
      PDS install + `source` + a select-and-apply list of PDS function calls.
- [ ] The `pds` package is installed from the APT repo at a **pinned version** during the build.
- [ ] Duplicated `scripts/.p10k.zsh` and `scripts/zshrc` are removed; their config comes from PDS.
- [ ] Every PDS function the manifest calls is **resolved from the installed package** (confirmed via
      `pds show <fn>`), not from a local copy — and any gap is filed/added upstream in PDS first.
- [ ] The Ubuntu image still builds green through 0002's harness (Layer 0–3), proving the PDS-provisioned
      image has the expected tooling (kubectl, zsh/p10k, cron updater, MOTD) and no identity baked in.
- [ ] `packer/ubuntu/readme.md` documents the select-and-apply model and the per-image function list.

## Open questions

- **Build-time SSH ordering:** `restricted_ssh_security_profile` disables password auth / root login.
  Packer connects over SSH during the build — applying hardening too early can sever that connection.
  Run it last / ensure it's compatible with the temporary build key and with clone-time key injection.
  (Decide: apply in `install.sh` late, or defer purely-SSH hardening to cloud-init?)
- **`pds` version pinning vs latest:** pin an exact version per builders release (reproducible) vs track
  `stable` (fresh). Leaning pinned, bumped deliberately.
- **Manifest form:** plain bash sequence (now) vs a declarative per-role manifest file (later, when there
  are multiple roles/OSes). Start simple.
- **Offline/air-gapped builds:** the old script had a `TODO: check for internet or provide some local
  way to pull the module`. Out of scope now, but note the APT-repo dependency means builds need network.

## References

- [PDS repo](https://github.com/michielvha/PDS) and its `packaging/README.md` (apt package + `pds` CLI).
- PDS APT repo: `https://michielvha.github.io/PDS/apt/` (GPG key + `deb` source, `apt install pds`).
- Depends on / shares the `build` block with [`0001-packer-proxmox-native-output.md`](0001-packer-proxmox-native-output.md);
  verified by [`0002-image-build-testing.md`](0002-image-build-testing.md).
- Legacy being replaced: `packer/ubuntu/scripts/install.sh`, `scripts/.p10k.zsh`, `scripts/zshrc`.
