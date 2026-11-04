# Feature documents

The canonical lifecycle is vh-adlc at the revision pinned in [AGENTS.md](../../AGENTS.md).
Each feature has one document containing its scope, criteria, test plan, tasks, questions and reviews.
Use the shared vh-adlc reviewer; do not replace independent review with the implementing agent's assessment.

The existing files retain their paths and issue links. They are imported as drafts with unchecked
criteria because no current framework acceptance or committed implementation review exists. Earlier
implementation and test history remains in the documents and Git history. No completion is inferred
from the migration. The current drafts must not be committed or published before owner review.

| Issue | Feature | Status |
| --- | --- | --- |
| #1 | [Ubuntu images and PDS bootstrap](0001-packer-proxmox-native-output.md) | draft |
| #2 | [Image test harness](0002-image-build-testing.md) | draft |
| #3 | [PDS delivery folded into #1](0003-pds-provisioning-migration.md) | superseded |

Issue #3 remains open until the integrated bootstrap is verified and merged. Feature #2 keeps its
wider multi-OS/macOS scope; the bounded Ubuntu checks belong to #1.

Start with `vh-adlc find --issue <n>` or `vh-adlc find --slug <slug>`, then follow the procedure named by `vh-adlc next`. Run `knowledge` and read
the resolved pages before editing. `lint` checks document shape; `fresh` checks review currency; a
status change needs the corresponding `gate` result. Commit and publication restrictions in
[AGENTS.md](../../AGENTS.md) still apply. A review of uncommitted work uses `+dirty` and cannot complete
a feature.

Use the [pinned central template](https://github.com/vhco-pro/docs/blob/0e52f51f01b84eda75a976763c42d8ec0a07b544/guides/feature-document-template.md).
Fill it with measured facts rather than copying another feature's decisions or evidence.
