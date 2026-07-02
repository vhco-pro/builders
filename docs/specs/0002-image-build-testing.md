# 0002 — Automated testing harness for image builds

- **Status:** draft
- **Scope:** A layered, automated test harness so agents can iterate on templates with confidence,
  and so adding a new OS is "plug into the harness" rather than "reinvent testing." Covers static
  validation, build smoke tests, offline artifact assertions, and boot/functional tests, plus where
  each layer runs (local Apple Silicon vs GitHub-hosted CI vs self-hosted homelab runner).
  **Out of scope:** Terraform `bpg/proxmox` clone-time integration testing (that's the consumer;
  noted as Layer 4 for context only).

## Context

Spec 0001 gives us one template with two builders (`proxmox-clone` for a native Proxmox template,
`qemu` for a local qcow2/raw) that share the **same cloud-image base** and the **same provisioners**.
Before we expand to more operating systems we need an automated way to prove a build is correct —
otherwise every agent change is a manual "build it and eyeball it" cycle, which doesn't scale and isn't
reproducible.

The central constraint is **where a test can physically run**:

- The `proxmox-clone` builder talks to a **live Proxmox API** (and clones a base template that lives on
  it). PVE is x86 + KVM; it can't be hosted on an Apple Silicon Mac. So anything exercising the Proxmox
  path needs line-of-sight to the real homelab PVE (a self-hosted runner) or a manual run.
- The `qemu` builder runs locally, but QEMU only hardware-accelerates a guest whose arch matches the
  host. On an arm64 Mac, arm64 guests use **HVF** (fast); **amd64** guests fall back to **TCG**
  software emulation (works, but slow). Our current target is amd64, so amd64 builds are slow on the
  Mac and fast on an amd64 KVM CI runner.
- **Static checks and offline artifact inspection** need neither KVM nor PVE and run everywhere.

Both builders start from the **same** upstream Ubuntu cloud image and run the **same** provisioners
(see 0001), so the cheap `qemu` path is a faithful check of what the Proxmox template will contain. The
local/CI qemu loop catches the overwhelming majority of regressions instantly; only the
Proxmox-specific behaviour (clone succeeds, template flag set, empty cloud-init drive attached) needs
the homelab.

## Primer — where CI actually runs (new to this)

A GitHub Actions **runner** is just the machine that executes a CI job. Two kinds:

- **GitHub-hosted:** lives in GitHub's cloud. Great for anything self-contained, but it **cannot reach
  your homelab Proxmox** — that's on your LAN, behind your router. It has no line-of-sight and no
  business holding your Proxmox credentials.
- **Self-hosted:** a small agent *you* install on a machine **inside** your homelab (e.g. a VM on the
  Proxmox). It dials out to GitHub, picks up jobs, and runs them locally — so it *can* reach Proxmox.

**Do we need a self-hosted runner? Not to start.** The thing you actually want — "the agent checks its
own work without waiting on CI" — is served entirely by the cheap **local** checks (Layer 0, plus an
optional fast arm64 build for Layer 2). A self-hosted runner is only needed later to *automate* the
Proxmox-path verification; until then that step is a manual run when you're on the homelab. It's an
explicit **phase 2**, not a prerequisite.

## Goals

- A test harness with clear **layers**, each independently runnable, cheapest-first.
- Every layer's **execution environment is explicit** (local Mac / GitHub-hosted / self-hosted).
- Agents get a **fast, fully-local-or-CI feedback loop** for the bulk of changes (no homelab needed).
- The generic-image invariants from spec 0001 are **machine-verified** (empty `machine-id`, no baked
  identity/keys/static netplan), not eyeballed.
- Adding a **new OS** means dropping in a per-template test manifest, not writing a new harness.
- One entrypoint (`make test` / a task runner) that selects layers by flag, mirrored 1:1 by CI.

## Non-goals

- Terraform clone-time / end-to-end infra tests (Layer 4 — the consumer repo owns this).
- Standing up a dedicated always-on test PVE cluster. We reuse the homelab PVE via a self-hosted
  runner (with a dedicated test storage pool / vmid range to avoid clobbering real templates).

## Design

### Test layers

| Layer | What it checks | Needs KVM? | Needs PVE? | Speed |
| --- | --- | --- | --- | --- |
| **0 — Lint/validate** | `packer fmt -check`, `packer validate` (dummy vars), `shellcheck` on `scripts/*.sh`, `cloud-init schema` + `yamllint` on user-data | no | no | instant |
| **1 — Build smoke** | The build actually completes and yields an artifact (exercises all shared provisioners) | qemu: yes (or slow TCG); proxmox: n/a | proxmox path only | mins |
| **2 — Offline assertions** | Inspect the produced qcow2/raw *without booting*: `/etc/machine-id` empty, no `authorized_keys`, no static netplan identity, no persisted SSH host keys, expected files present | no | no | seconds |
| **3 — Boot/functional** | Boot the artifact headless in QEMU with a throwaway cloud-init NoCloud seed; assert cloud-init applied identity, machine-id is freshly generated (and differs across two boots), expected packages/services present | yes (or slow TCG) | no | mins |
| **4 — Clone integration** *(out of scope)* | `bpg/proxmox` clones the template + smoke-tests the VM | — | yes | mins |

Layers 0 and 2 are the cheap, deterministic, secret-free core — they should be the mandatory PR gate.

### Where each layer runs

| Environment | Layer 0 | Layer 1 (qemu) | Layer 1 (proxmox) | Layer 2 | Layer 3 |
| --- | --- | --- | --- | --- | --- |
| **Apple Silicon Mac** | ✅ | ✅ arm64 (HVF) / 🐌 amd64 (TCG) | ❌ no PVE | ✅ | ✅ arm64 / 🐌 amd64 |
| **GitHub-hosted (amd64)** | ✅ | ✅ amd64 (KVM, if `/dev/kvm` present) | ❌ no PVE reach/secrets | ✅ | ✅ amd64 (KVM) |
| **Self-hosted homelab runner** | ✅ | ✅ | ✅ (PVE line-of-sight + secrets) | ✅ | ✅ |

Notes:
- **`packer validate` does not contact Proxmox** — it's a static config check, so it runs anywhere
  with placeholder Proxmox vars. That's why Layer 0 covers the proxmox source too.
- **GitHub-hosted Linux runners** now expose KVM/nested virt on public repos, but this must not be
  assumed — a preflight (`ls -l /dev/kvm` / `kvm-ok`) gates whether Layer 1/3 accelerate or skip.
- **Offline inspection (Layer 2)** is arch-agnostic (it reads the amd64 filesystem, doesn't execute
  it), so it runs fast on the Mac. Use `libguestfs` (`guestfish`/`virt-cat`); on macOS run it via a
  container image to avoid the finicky native install, or loopback-mount the raw image.

### Recommended topology (three tiers)

- **Local agent self-check (your Mac, no wait, no CI):** Layer 0 always (instant), plus an optional
  fast **arm64** `qemu` build + Layer 2 offline assertions when deeper confidence is wanted. This is the
  loop an agent runs to check its own work before pushing. **amd64 builds are not run locally** — arm64
  is close enough for provisioner-logic feedback, and full amd64 goes to the pipeline (decided).
- **PR gate (GitHub-hosted, every PR):** Layer 0 + Layer 1 (**amd64** `qemu` build, KVM) + Layer 2
  offline assertions + Layer 3 boot test if KVM present. No homelab, no secrets, deterministic. This is
  where amd64 gets exercised for real.
- **Proxmox verification (phase 2 — self-hosted runner = a VM on the homelab Proxmox host, on merge to
  `main` or manual dispatch; until then run manually on the homelab):** Layer 1 `proxmox-clone` build
  against the real PVE → assert the output is flagged `template: 1` (`qm config <vmid>`) with an empty
  cloud-init drive attached, and that the clone+provision succeeded. Uses a **dedicated vmid range +
  `test-*` names** (optionally a `packer-test` pool) on the existing Proxmox host; API token supplied
  via runner/shell env, never committed. Kept **off the per-PR path** — it needs the physical host and
  must not block fast iteration.

### Multi-OS extensibility

Structure the harness so a template is described by a small **per-template test manifest** (e.g.
`packer/<os>/test/manifest.{yaml,goss.yaml}`) declaring: expected packages/services, files that must
exist, and the generic-image invariants to assert. The harness runs the *same* Layer 0–3 logic
against any template + manifest. Adding an OS = new `packer/<os>/` + its manifest; the test matrix is
`{os} × {output-format}`.

### Tooling (decided)

- **Layer 0:** `packer fmt`/`validate` (built in), `shellcheck`, `cloud-init schema`, `yamllint`.
- **Layer 2:** `libguestfs` (`guestfish`, `virt-cat`, `virt-inspector`); on macOS run it via a container.
- **Layer 3 assertions: Goss / dgoss** — lightweight YAML, no runtime deps on the target, and it fits
  the "per-template manifest" model cleanly. (InSpec/Testinfra considered and dropped as heavier.)
- **Runner/entrypoint: `Makefile`** — preinstalled everywhere (Mac + Linux + CI), zero-dependency so an
  agent can always run it. Targets like `make check` (Layer 0), `make test-local` (0 + arm64 1 + 2),
  `make test-proxmox`. CI invokes the same targets verbatim, so local and CI run identical commands.

## Acceptance criteria

- [ ] `make check` runs Layer 0 (fmt/validate/shellcheck/cloud-init schema) with **no KVM and no PVE**
      and passes on both Apple Silicon and a GitHub-hosted runner — the agent's instant self-check.
- [ ] `make test-local` runs an **arm64** `qemu` build + Layer 2 offline assertions on Apple Silicon,
      no PVE, giving the agent deeper confidence without waiting on CI.
- [ ] Layer 1 (**amd64** `qemu` build) + Layer 3 boot test run in GitHub-hosted CI (KVM-gated) on every PR.
- [ ] Layer 2 machine-asserts every spec-0001 generic-image invariant (empty machine-id, no
      authorized_keys, no static netplan identity, no persisted SSH host keys) and fails the build if
      any is violated.
- [ ] Layer 3 proves cloud-init applies clone-time identity and that machine-id is freshly generated
      and differs between two independent boots of the same artifact.
- [ ] The `proxmox-clone` path is verified against the homelab PVE (clone+provision succeeds, output
      flagged `template: 1`, empty cloud-init drive attached), using a reserved vmid range + `test-*`
      names and env-supplied secrets — run manually at first, automated on a self-hosted runner (a VM on
      the Proxmox host) in phase 2.
- [ ] Documented "how to run tests locally on macOS" including the arm64-fast / amd64-slow caveat and
      the container-based `libguestfs` path.
- [ ] Adding a hypothetical second OS requires only a new template dir + test manifest — no harness
      changes (validated by dry-running the harness against a stub manifest).

## Decisions (resolved)

- **Test target:** the **existing** homelab Proxmox host (no separate node). Isolate test builds with a
  reserved **vmid range** (e.g. 9000–9099) + `test-*` template names, optionally grouped in a
  `packer-test` **pool** for easy bulk cleanup. (A "pool" is just a label for grouping — it doesn't
  reserve compute; a separate "node" would be a whole extra host, which we don't need.)
- **Self-hosted runner:** **not required to start.** The agent's no-wait loop is local (Layer 0 + arm64
  Layer 1/2). A self-hosted runner is **phase 2**, only to automate the Proxmox verification; until
  then that step is a manual run on the homelab. When we do it, it's a **VM on the homelab Proxmox
  host** (decided).
- **Layer 3 framework:** **Goss / dgoss.**
- **amd64-on-Mac:** don't build amd64 locally — arm64 is close enough for provisioner-logic feedback;
  amd64 build/boot runs in the pipeline.
- **Runner entrypoint:** **Makefile.**
- **NoCloud seed for Layer 3 (explained):** to boot-test the image we must feed it a cloud-init the same
  way production will — via a small **NoCloud** seed disk (a mini virtual drive holding `user-data` +
  `meta-data`). **Decided: the test seed mirrors the shape `bpg/proxmox` injects at clone time** (same
  fields: hostname, SSH keys, network, edgectl user-data). That way a green boot test means the *real*
  clone-time path works, not just some artificial one.

## Open questions

- **API token scoping on the phase-2 runner VM:** how the Proxmox token is stored/limited on that VM
  (the placement itself is decided: a VM on the Proxmox host).
- **libguestfs-on-macOS packaging:** which container image / invocation is the least-friction path for
  Layer 2 locally.

## References

- [`packer validate`](https://developer.hashicorp.com/packer/docs/commands/validate) — static, no API contact.
- [QEMU on Apple Silicon / HVF accelerator](https://www.qemu.org/docs/master/system/target-i386.html) — HVF only accelerates same-arch guests.
- [GitHub-hosted runners & KVM/nested virtualization](https://docs.github.com/actions/using-github-hosted-runners/about-github-hosted-runners).
- [Goss / dgoss](https://github.com/goss-org/goss) — server/image validation via YAML manifests.
- [libguestfs](https://libguestfs.org/) — offline image inspection.
- Depends on: [`0001-packer-proxmox-native-output.md`](0001-packer-proxmox-native-output.md).
