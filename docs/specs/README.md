# Specs

Every non-trivial change to this repo starts here. We design the behaviour, review it, then implement.
This is the deliberate replacement for the old copy-paste workflow.

## Workflow

1. **Draft** — copy [`_template.md`](_template.md) to `NNNN-short-slug.md` (next free number) and fill it in.
2. **Review** — discuss and refine until the design is agreed. Status stays `draft`.
3. **Implement** — build it. Flip status to `in-progress`, then `done` when the acceptance criteria pass.
4. **Document** — a done spec is a self-contained record of *what* changed and *why*, readable on its own.
   (The writing agent turns these into blog posts, so keep the narrative honest and complete.)

## Index

| # | Spec | Status |
| --- | --- | --- |
| 0001 | [Packer: Proxmox-native builder with selectable output formats](0001-packer-proxmox-native-output.md) | draft |
