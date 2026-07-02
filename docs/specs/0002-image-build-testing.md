# 0002 — Automated testing harness for image builds

- **Status:** draft
- **Scope:** A layered, automated test harness so agents can iterate on templates with confidence,
  and so adding a new OS is "plug into the harness" rather than "reinvent testing." Covers static
  validation, build smoke tests, offline artifact assertions, and boot/functional tests, plus where
  each layer runs (local Apple Silicon vs GitHub-hosted CI vs self-hosted homelab runner).
  **Out of scope:** Terraform `bpg/proxmox` clone-time integration testing (that's the consumer;
  noted as Layer 4 for context only).

## Context

Spec 0001 gives us one template with two builders (`proxmox-iso` for a native Proxmox template,
`qemu` for a local qcow2/raw) sharing the same provisioners. Before we expand to more operating
systems we need an automated way to prove a build is correct — otherwise every agent change is a
manual "build it and eyeball it" cycle, which doesn't scale and isn't reproducible.

The central constraint is **where a test can physically run**:

- The `proxmox-iso` builder talks to a **live Proxmox API**. PVE is x86 + KVM; it can't be hosted on
  an Apple Silicon Mac. So anything exercising the Proxmox path needs line-of-sight to the real
  homelab PVE (a self-hosted runner) or a manual run.
- The `qemu` builder runs locally, but QEMU only hardware-accelerates a guest whose arch matches the
  host. On an arm64 Mac, arm64 guests use **HVF** (fast); **amd64** guests fall back to **TCG**
  software emulation (works, but slow). Our current target is amd64, so amd64 builds are slow on the
  Mac and fast on an amd64 KVM CI runner.
- **Static checks and offline artifact inspection** need neither KVM nor PVE and run everywhere.

Because both builders share provisioners, validating *image contents* via the cheap `qemu` path
covers most correctness; only Proxmox-specific behaviour (template flag, cloud-init drive attach)
genuinely needs the homelab.

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

### Recommended CI topology

- **PR gate (GitHub-hosted, every PR):** Layer 0 + Layer 1 (amd64 `qemu` build, KVM) + Layer 2
  offline assertions + Layer 3 boot test if KVM present. No homelab, no secrets, deterministic.
  This fully validates the *shared provisioner content* both builders use.
- **Proxmox verification (self-hosted homelab runner, on merge to `main` or manual dispatch):**
  Layer 1 `proxmox-iso` build against the real PVE → assert the output is flagged
  `template: 1` (`qm config <vmid>`) with a cloud-init drive attached. Uses a **dedicated test
  storage pool and vmid range**; API token supplied via runner env, never committed.
- Keep the homelab-dependent job **off the per-PR path** — it needs the physical host and shouldn't
  block fast iteration.

### Multi-OS extensibility

Structure the harness so a template is described by a small **per-template test manifest** (e.g.
`packer/<os>/test/manifest.{yaml,goss.yaml}`) declaring: expected packages/services, files that must
exist, and the generic-image invariants to assert. The harness runs the *same* Layer 0–3 logic
against any template + manifest. Adding an OS = new `packer/<os>/` + its manifest; the test matrix is
`{os} × {output-format}`.

### Tooling (candidates, decide in review)

- **Layer 0:** `packer fmt`/`validate` (built in), `shellcheck`, `cloud-init schema`, `yamllint`.
- **Layer 2:** `libguestfs` (`guestfish`, `virt-cat`, `virt-inspector`).
- **Layer 3 assertions:** **Goss/dgoss** (lightweight YAML, leaning this way) vs InSpec vs
  Testinfra (pytest). Goss fits the "per-template manifest" model cleanly.
- **Runner/entrypoint:** a `Makefile` or `Taskfile` target (`make test LAYER=0-2`, `make test-proxmox`)
  that CI invokes verbatim, so local and CI run identical commands.

## Acceptance criteria

- [ ] `make test` (or task equivalent) runs Layers 0 + 2 with **no KVM and no PVE**, and passes on a
      clean checkout on both Apple Silicon and a GitHub-hosted runner.
- [ ] Layer 1 `qemu` build + Layer 3 boot test run in GitHub-hosted CI (KVM-gated) on every PR.
- [ ] Layer 2 machine-asserts every spec-0001 generic-image invariant (empty machine-id, no
      authorized_keys, no static netplan identity, no persisted SSH host keys) and fails the build if
      any is violated.
- [ ] Layer 3 proves cloud-init applies clone-time identity and that machine-id is freshly generated
      and differs between two independent boots of the same artifact.
- [ ] The `proxmox-iso` path is verified on a self-hosted homelab runner (template flag + cloud-init
      drive) on merge/dispatch, using a dedicated test pool/vmid range and env-supplied secrets.
- [ ] Documented "how to run tests locally on macOS" including the arm64-fast / amd64-slow caveat and
      the container-based `libguestfs` path.
- [ ] Adding a hypothetical second OS requires only a new template dir + test manifest — no harness
      changes (validated by dry-running the harness against a stub manifest).

## Open questions

- **Do we have (or want) a dedicated test PVE node/pool**, or do we run Proxmox verification against
  the prod homelab PVE with an isolated vmid range + `test-*` template names?
- **Self-hosted runner placement:** on the PVE host itself, on a separate homelab box, or an
  ephemeral VM? Security posture for the API token on that runner.
- **Layer 3 framework:** Goss (leaning) vs InSpec vs Testinfra.
- **amd64-on-Mac policy:** do we bother supporting slow TCG amd64 builds locally, or tell agents to
  push amd64 builds to CI and only build arm64 locally?
- **Runner entrypoint:** Makefile vs Taskfile (`Taskfile.yml`).
- Does Layer 3's boot test reuse the same NoCloud seed shape that `bpg/proxmox` will inject, so the
  test mirrors real clone-time cloud-init?

## References

- [`packer validate`](https://developer.hashicorp.com/packer/docs/commands/validate) — static, no API contact.
- [QEMU on Apple Silicon / HVF accelerator](https://www.qemu.org/docs/master/system/target-i386.html) — HVF only accelerates same-arch guests.
- [GitHub-hosted runners & KVM/nested virtualization](https://docs.github.com/actions/using-github-hosted-runners/about-github-hosted-runners).
- [Goss / dgoss](https://github.com/goss-org/goss) — server/image validation via YAML manifests.
- [libguestfs](https://libguestfs.org/) — offline image inspection.
- Depends on: [`0001-packer-proxmox-native-output.md`](0001-packer-proxmox-native-output.md).
