# Packer images

Choose a template, then select its output with `-only`. Proxmox is an optional backend; a local
QEMU build needs no Proxmox server or credentials.

- [Ubuntu template](ubuntu/readme.md): available outputs and the shared build flow.
- [Local QEMU build](../docs/ubuntu/local-build.md): prerequisites, commands and output files.
- [Optional Proxmox build](../docs/ubuntu/proxmox.md): base bootstrap and native golden templates.
- [SSH and debugging](../docs/ubuntu/ssh-and-debugging.md): build access, VNC tunnels and disk inspection.
- [Development checks](../docs/development.md): local verification and the manual sealing test.
