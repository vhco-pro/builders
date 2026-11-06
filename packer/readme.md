# Packer images

Choose a template, then select its output with `-only`. Proxmox is an optional backend; a local
QEMU build needs no Proxmox server or credentials.

- [Ubuntu template](ubuntu/readme.md): available outputs and the shared build flow.
- [Build host setup](../docs/ubuntu/build-host-setup.md): Packer, QEMU and optional desktop tools.
- [Local QEMU build](../docs/ubuntu/local-build.md): prerequisites, commands and output files.
- [Optional Proxmox build](../docs/ubuntu/proxmox.md): base bootstrap and native golden templates.
- [SSH and debugging](../docs/ubuntu/ssh-and-debugging.md): build access, VNC tunnels and disk inspection.
- [Manual boot](../docs/ubuntu/manual-boot.md) and [image inspection](../docs/ubuntu/image-inspection.md): QEMU, deployment seeds, raw mounts and chroot.
- [Legacy ARM recipes](../docs/legacy/armbian-qemu.md): preserved Armbian and U-Boot commands.
- [Development checks](../docs/development.md): local verification and the manual sealing test.
