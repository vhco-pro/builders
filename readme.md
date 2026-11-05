# builders

Build generic OS images with Packer. Ubuntu supports local qcow2/raw disks and an optional native
Proxmox template path. Cloud-init supplies each deployed machine's identity and SSH access.

## Build an Ubuntu image

This branch's [PDS recipe integration](docs/ubuntu/provisioning.md) requires the pending PDS feature
release or an explicit candidate package. The last published PDS version lacks the new helpers.

Install the [local build prerequisites](docs/ubuntu/local-build.md#prerequisites), then run:

```bash
cd packer/ubuntu
packer init .
packer build -only='qemu.ubuntu' .
```

This path needs no Proxmox server or credentials. For a native template, follow the optional
[Proxmox guide](docs/ubuntu/proxmox.md).

## Templates and guides

| Start here | What you get |
| --- | --- |
| [Ubuntu](packer/ubuntu/readme.md) | Choose an output and find build, SSH, debugging and recovery guides. |
| [Armbian](armbian-build-framework/) | Existing Rock 5A and Raspberry Pi 4B image customisations. |

See [image recipes](docs/ubuntu/provisioning.md) for defaults, customization and deployment users.
For contributions, see [development checks](docs/development.md) and [feature documents](docs/specs/README.md).

GPLv3. See [LICENSE](LICENSE).
