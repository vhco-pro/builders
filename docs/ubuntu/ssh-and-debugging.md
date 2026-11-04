# SSH and image debugging

Choose the connection for the stage you are troubleshooting. Temporary build access is removed
when Packer seals the image; an exported image needs its own deployment user and SSH key.

## Keep a QEMU build open for inspection

From the repository root:

```bash
cd packer/ubuntu
PACKER_LOG=1 packer build -debug -only='qemu.ubuntu' .
```

Packer pauses between build steps in debug mode. Connect at the pause after its SSH connection
step (`StepConnect`), then run `cloud-init status --wait` in the guest if needed. Configuration and
sealing run together in the next provisioning step; debug mode does not pause between them.
The QEMU seed uses the temporary `ubuntu` / `ubuntu` login. After sealing, its password hash, SSH
policy override and build keys are removed.

Read the selected SSH forwarding port from Packer's debug output; it is not a fixed template setting.
For a build on the same machine, this example assumes Packer selected port 2222:

```bash
build_ssh_port=2222 # Replace with the port reported by this build.
ssh -p "$build_ssh_port" ubuntu@127.0.0.1
```

For a build on a remote host, forward its selected port to your workstation first. The example
retains the existing `sysadmin@x86` build-host connection; replace it with your SSH destination.
Run the tunnel in one terminal and the guest login in another:

```bash
build_ssh_port=2222 # Replace with the build host's selected SSH port.
ssh -N -L "127.0.0.1:2222:127.0.0.1:${build_ssh_port}" sysadmin@x86
```

```bash
ssh -p 2222 ubuntu@127.0.0.1
```

Verify the guest's SSH host key when connecting. A newly built guest can have a different key from
an earlier guest that used the same local port.

## Forward VNC over SSH

For a headless build, use the VNC address and port printed by Packer. QEMU's Packer builder selects
an available VNC port and binds it to loopback by default. For build host `sysadmin@x86` and port 5905:

```bash
ssh -N -L 127.0.0.1:5905:127.0.0.1:5905 sysadmin@x86
```

That example assumes Packer reports VNC port 5905. Replace the final port with the actual remote
port when it differs, then connect a viewer on your workstation:

```bash
vncviewer 127.0.0.1::5905
```

The double colon specifies a TCP port in TigerVNC. A Linux viewer can be installed as
`tigervnc-viewer` on Ubuntu/Debian or `tigervnc` on Fedora. On Windows, use a compatible VNC viewer
such as MobaXterm through the same SSH tunnel.

## Connect to a deployed VM

The sealed image has no shared password or baked-in personal key. Configure a user and its public
key through the deployment platform's cloud-init inputs, then connect with that identity:

```bash
ssh -i ~/.ssh/id_ed25519 your_user@vm.example.local
```

For a locally booted disk, supply a [NoCloud seed](https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html)
with the deployment user and key.
For a Proxmox clone, supply the user/key in its cloud-init configuration and connect to the guest's
address. The temporary build password is not a recovery login for either output.

During a native Proxmox build, Packer injects its own temporary SSH key. Use the Proxmox console
to watch boot and cloud-init output; the build account has no console password.

## Inspect an exported disk without booting it

Use libguestfs to read a qcow2 filesystem without mounting the image file as a raw partition.
Fedora 43 provides `guestfish` in
[`libguestfs`](https://packages.fedoraproject.org/pkgs/libguestfs/libguestfs/fedora-43.html);
Ubuntu/Debian include it in `libguestfs-tools`. Start from the repository root:

```bash
image=packer/ubuntu/output-noble-amd64/ubuntu-noble-amd64.qcow2
guestfish --ro -a "$image" -i cat /etc/hostname
```

Use the [recovery guide's libguestfs prerequisites](recovery.md#rebuild-when-the-bundle-is-also-lost)
when a host kernel is unreadable or the appliance cannot start. Keep debug logs local until any
credentials and private connection details have been removed before sharing.

## References

- [Packer QEMU configuration](https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu): selected SSH/VNC ports and loopback VNC binding.
- [TigerVNC viewer](https://tigervnc.org/doc/vncviewer.html): viewer connection syntax.
- [guestfish](https://libguestfs.org/guestfish.1.html): read-only filesystem inspection.
