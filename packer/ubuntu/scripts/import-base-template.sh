#!/usr/bin/env bash
# Runs on Proxmox through create-base-template.sh; needs only native node tools.
set -euo pipefail

mode="${1:-}"
vmid="${2:-}"
if [[ ! "$vmid" =~ ^[1-9][0-9]{2,8}$ ]] || (( vmid < 100 )); then
    printf '%s\n' 'Pass an unused Proxmox VM ID.' >&2
    exit 1
fi
if [[ "$mode" == --check && $# == 2 ]]; then
    :
elif [[ "$mode" == --import && $# == 7 ]]; then
    image_dir="$3"
    name="$4"
    storage="$5"
    bridge="$6"
    disk_size="$7"
    for value in "$name" "$storage" "$bridge"; do
        [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || exit 1
    done
    [[ "$disk_size" =~ ^[1-9][0-9]*[GM]$ ]] || exit 1
else
    printf '%s\n' 'Usage: import-base-template.sh --check <vmid> | --import <vmid> <bundle> <name> <storage> <bridge> <size>' >&2
    exit 1
fi
for tool in pvesh qm qemu-img; do
    command -v "$tool" >/dev/null || { printf 'Missing Proxmox command: %s\n' "$tool" >&2; exit 1; }
done
if ! pvesh get /cluster/nextid --vmid "$vmid" >/dev/null; then
    printf 'VM ID %s is unavailable or could not be checked; nothing was changed.\n' "$vmid" >&2
    exit 1
fi
[[ "$mode" == --import ]] || exit 0
checksum="$(cat -- "$image_dir/base-image.sha256")"
[[ "$checksum" =~ ^[a-fA-F0-9]{64}[[:blank:]]+base[.]qcow2$ ]] || exit 1
(cd -- "$image_dir" && sha256sum -c base-image.sha256)
# Grow only the temporary upload. qemu-img refuses shrinking without --shrink,
# so an undersized request fails before a VM is created. The local bundle stays intact.
qemu-img resize -f qcow2 "$image_dir/base.qcow2" "$disk_size"

# qm create also refuses an allocation racing the availability check.
# Keep a partial new VM for inspection if a later import/configuration fails.
qm create "$vmid" --name "$name" --memory 2048 --cores 2 \
    --net0 "virtio,bridge=$bridge" --scsihw virtio-scsi-pci --ostype l26
qm importdisk "$vmid" "$image_dir/base.qcow2" "$storage"
imported_disk="$(qm config "$vmid" | sed -n 's/^unused0: //p')"
[[ -n "$imported_disk" ]] || { printf '%s\n' 'Imported disk was not found in the new VM configuration.' >&2; exit 1; }
qm set "$vmid" --scsi0 "$imported_disk" --ide2 "$storage:cloudinit"
qm set "$vmid" --boot order=scsi0 --serial0 socket --vga serial0
qm set "$vmid" --ipconfig0 ip=dhcp --agent enabled=1
qm template "$vmid"
