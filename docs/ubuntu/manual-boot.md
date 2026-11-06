# Boot an exported Ubuntu disk manually

Use QEMU to inspect a sealed amd64 image without Proxmox. The image needs a deployment user and key;
the temporary Packer login has already been removed. This procedure uses an ephemeral disk overlay,
so guest writes disappear when QEMU exits.

## Create a NoCloud seed

Run from the repository root. Set `public_key_file` to an existing public key, never a private key:

```bash
public_key_file="$HOME/.ssh/id_ed25519.pub"
ssh-keygen -lf "$public_key_file"
public_key=$(awk 'NR == 1 {print $1, $2}' "$public_key_file")
seed_dir=$(mktemp -d)
cat > "$seed_dir/meta-data" <<'EOF'
instance-id: manual-image-check
local-hostname: manual-image-check
EOF
cat > "$seed_dir/user-data" <<EOF
#cloud-config
users:
  - name: imageadmin
    shell: /usr/bin/zsh
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $public_key
ssh_pwauth: false
disable_root: true
EOF
genisoimage -output "$seed_dir/seed.iso" -volid cidata -joliet -rock \
  "$seed_dir/user-data" "$seed_dir/meta-data"
```

The generated seed contains the public key and the chosen login policy. Give separate deployments
their own instance ID and hostname. Keep `seed_dir` available until QEMU has stopped.

## Boot the amd64 image

The default output path is shown below. Replace it if the build used another codename or directory:

```bash
image=packer/ubuntu/output-noble-amd64/ubuntu-noble-amd64.qcow2
qemu-system-x86_64 \
  -accel kvm -m 4G -smp 4 \
  -drive "file=$image,format=qcow2,if=virtio" \
  -cdrom "$seed_dir/seed.iso" \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -snapshot -nographic
```

Use `-accel tcg` instead of `-accel kvm` when hardware virtualization is unavailable. With `-nographic`,
QEMU uses the terminal for its serial console; `Ctrl-a x` exits QEMU. Another terminal can connect
after cloud-init finishes:

```bash
ssh -i ~/.ssh/id_ed25519 -p 2222 imageadmin@127.0.0.1
```

Use the private key corresponding to `public_key_file` if it has another name. Verify the SSH host key
when reusing the forwarded port for a different guest. Remove the seed directory after QEMU exits:

```bash
rm -r -- "$seed_dir"
```

The current image matrix booted the portable output on owned Proxmox guests. This manual host-QEMU
recipe is documented from the supported QEMU/NoCloud interfaces; it is not a new live validation result.

## Related procedures

- [Build-time SSH and VNC](ssh-and-debugging.md) connects before sealing.
- [Inspect a disk without booting it](image-inspection.md) covers guestfish and raw-image chroot.
- [Legacy ARM boot recipes](../legacy/armbian-qemu.md) retain the separate Armbian examples.
- [QEMU invocation](https://www.qemu.org/docs/master/system/invocation.html) documents snapshot mode,
  acceleration, serial consoles and host port forwarding.
- [NoCloud](https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html) documents
  `user-data`, `meta-data` and the `cidata` label.
