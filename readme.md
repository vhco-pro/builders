# builders

Packer templates for generic VM images. Build an Ubuntu template directly on Proxmox, or produce a
portable qcow2 with an optional raw export. Cloud-init supplies each deployed machine's hostname,
network configuration and access credentials.

The Ubuntu paths share package provisioning and image cleanup. The planned
[PDS](https://github.com/michielvha/PDS) integration will add selected tools and shell configuration;
it is tracked separately in [spec 0003](docs/specs/0003-pds-provisioning-migration.md).

## Templates

| Path | Purpose |
| --- | --- |
| [`packer/ubuntu/`](packer/ubuntu/readme.md) | Ubuntu cloud image to a native Proxmox template or portable disk. |
| [`armbian-build-framework/`](armbian-build-framework/) | Existing ARM SBC image customisations for Rock 5A and Raspberry Pi 4B. |

## Start here

Follow the [Ubuntu guide](packer/ubuntu/readme.md) for prerequisites, the one-time Proxmox base
bootstrap, token authentication, build commands and clone-time configuration.

```bash
make init
make check
cd packer/ubuntu
# After preparing the Proxmox base and local API variables:
packer build -only='proxmox-clone.ubuntu' .
# Or, with local QEMU installed:
packer build -only='qemu.ubuntu' -var 'output_raw=true' .
```

Builds create generic images. Consumers such as Terraform's
[`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest/docs) provider clone the
template and supply per-machine cloud-init configuration. Building an image does not deploy a
production workload.

Designs and acceptance criteria live in [`docs/specs/`](docs/specs/README.md). The full automated
image-test harness is planned in spec 0002; `make check` provides the current local checks.

## Development workflow

Read [AGENTS.md](AGENTS.md) before changing the repository. The existing
[feature documents](docs/specs/README.md) use the pinned vh-adlc lifecycle, with independent
review and explicit owner acceptance. The feature documents distinguish draft specifications,
observed verification and accepted implementations; earlier manual checks do not establish acceptance.

## License

GPLv3, see [LICENSE](LICENSE).
