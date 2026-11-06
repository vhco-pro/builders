# Inspect an exported image

Choose guestfish for filesystem inspection without booting. Raw-image mounting and chroot remain
available for the manual workflows from the original README.

## Read a qcow2 or raw disk with guestfish

Fedora 43 provides `guestfish` in
[`libguestfs`](https://packages.fedoraproject.org/pkgs/libguestfs/libguestfs/fedora-43.html);
Ubuntu/Debian include it in `libguestfs-tools`. From the repository root:

```bash
image=packer/ubuntu/output-noble-amd64/ubuntu-noble-amd64.qcow2
guestfish --ro -a "$image" -i cat /etc/hostname
```

Use the [recovery guide's prerequisites](recovery.md#rebuild-when-the-bundle-is-also-lost) if the host
kernel is unreadable or the appliance cannot start. `--ro` keeps the disk unchanged.

## Mount a raw image and enter chroot

Loop mounting applies to raw files. A qcow2 file needs guestfish or a conversion to raw first.
Use a working copy for repairs, on a host with the same CPU architecture as the image:

```bash
cp --reflink=auto /path/to/exported-image.raw /path/to/working-copy.raw
image=/path/to/working-copy.raw
sudo mkdir -p /mnt/image
sudo fdisk -l "$image"
```

A raw file containing one filesystem can be mounted directly:

```bash
sudo mount -o loop "$image" /mnt/image
```

For a partitioned raw disk, use the root partition's start sector and sector size shown by `fdisk`.
Set both values from that output; the values below are examples:

```bash
start_sector=2048 # Replace with the root partition's start sector.
sector_bytes=512  # Replace with the reported sector size.
offset_bytes=$((start_sector * sector_bytes))
sudo mount -o "loop,offset=$offset_bytes" "$image" /mnt/image
```

Choose one of the two mount commands, then enter its userspace and unmount when finished:

```bash
sudo chroot /mnt/image /bin/bash
# Run the inspection or repair commands inside the image.
exit
sudo umount /mnt/image
```

The mount is writable, so changes affect the working copy. Add `ro` to the chosen mount options for
inspection only. A repair that needs `/proc`, devices or DNS requires those chroot prerequisites as
well; the shell command alone does not set up a complete package-repair environment. A modified copy
needs artifact and fresh-boot checks before being used as a template.

See [guestfish's manual](https://libguestfs.org/guestfish.1.html) for inspection options and
[manual boot](manual-boot.md) for a disposable QEMU run with a deployment seed.
