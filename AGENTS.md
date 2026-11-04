# Repository instructions

Read the personal conventions at
https://github.com/vhco-pro/docs/blob/0e52f51f01b84eda75a976763c42d8ec0a07b544/AGENTS.md
and follow the task routes there before implementation.

For all code, read conventions/coding.md at that revision. For feature work, read
conventions/feature-documents.md and conventions/delivery.md. For documentation,
read conventions/documentation.md and guides/humanize-prose.md. Load only the
relevant pages. If a required source is unavailable, report it and stop.
When onboarding or bootstrapping, read the matching guides/ page.
Preserve local instructions; report a conflict instead of silently overriding either source.

Feature documents: docs/specs/

## Local commands and constraints

- `make init` installs the Packer plugins declared by the Ubuntu template.
- `make check` runs formatting, Packer validation, ShellCheck and local regression tests.
  It needs Packer, ShellCheck, Python 3, jq and qemu-img. Packer validation fetches public
  checksum metadata but does not require Proxmox credentials.
- Feature documents use the pinned vh-adlc format. Use the shared lifecycle and
  independent reviewer from the vh-adlc plugin; do not maintain a second local agent workflow.
- Keep PDS standalone. Builders selects shared PDS functions when that package integration
  is implemented. Keep image provisioning separate from Proxmox bootstrap and image sealing.
- Run `seal-image.sh --image-build` only inside a fresh disposable build guest. It removes
  access keys and resets machine identity. It is not an existing-machine setup command.
- Real Proxmox integration tests need task authorization, unused test IDs and recorded
  ownership. Never delete, stop or reconfigure pre-existing guests as test cleanup.
  The normal local checks must not perform remote VM mutations.
- Prepare base images off-node. The node import uses native Proxmox commands over SSH;
  do not install Packer or libguestfs on the hypervisor. Keep replacement-machine recovery
  in `packer/ubuntu/recovery.md` aligned with the tested scripts.
- Preserve unrelated work, staged changes and existing worktrees. No reset, stash or cleanup
  to make a review target clean. A dirty-tree diagnostic review is not release acceptance.
- Commits, pushes, PR writes, merges and releases need explicit owner approval. Permission to
  commit or update a PR does not authorize merging, releasing or publishing the homelab guides.
