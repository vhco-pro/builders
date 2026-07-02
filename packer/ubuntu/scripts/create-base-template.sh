#!/usr/bin/env bash
# Stage 0: create the base Ubuntu cloud-init template on Proxmox that the
# `proxmox-clone` Packer builder clones (spec 0001 / issue #1).
#
# Run this ONCE per Ubuntu release, ON the Proxmox host (or piped over SSH to it).
# It downloads the official Ubuntu cloud image, embeds qemu-guest-agent so
# Proxmox can read the VM's IP, and converts it into a template.
#
# Requires on the PVE host: qm (Proxmox), wget, and libguestfs-tools (virt-customize).
# Idempotent: it destroys and recreates BASE_VMID.
set -euo pipefail

# ---- config (override via env) ----
UBUNTU_VERSION="${UBUNTU_VERSION:-noble}" # noble = 24.04
ARCH="${ARCH:-amd64}"
BASE_VMID="${BASE_VMID:-9000}"
BASE_NAME="${BASE_NAME:-ubuntu-2404-cloudimg}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
DISK_SIZE="${DISK_SIZE:-32G}"

IMG="${UBUNTU_VERSION}-server-cloudimg-${ARCH}.img"
URL="https://cloud-images.ubuntu.com/${UBUNTU_VERSION}/current/${IMG}"

echo "==> Downloading ${URL}"
wget -q -O "/tmp/${IMG}" "${URL}"

echo "==> Embedding qemu-guest-agent into the image"
virt-customize -a "/tmp/${IMG}" --install qemu-guest-agent

echo "==> (Re)creating base template ${BASE_VMID} (${BASE_NAME})"
qm destroy "${BASE_VMID}" --purge 2>/dev/null || true
qm create "${BASE_VMID}" --name "${BASE_NAME}" --memory 2048 --cores 2 \
  --net0 "virtio,bridge=${BRIDGE}" --scsihw virtio-scsi-pci --ostype l26
qm importdisk "${BASE_VMID}" "/tmp/${IMG}" "${STORAGE}"
qm set "${BASE_VMID}" --scsi0 "${STORAGE}:vm-${BASE_VMID}-disk-0"
qm set "${BASE_VMID}" --ide2 "${STORAGE}:cloudinit"
qm set "${BASE_VMID}" --boot c --bootdisk scsi0
qm set "${BASE_VMID}" --serial0 socket --vga serial0
qm set "${BASE_VMID}" --ipconfig0 ip=dhcp
qm set "${BASE_VMID}" --agent enabled=1
qm resize "${BASE_VMID}" scsi0 "${DISK_SIZE}"
qm template "${BASE_VMID}"

echo "==> Base template ready: ${BASE_NAME} (vmid ${BASE_VMID})"
echo "    Set base_template_name = \"${BASE_NAME}\" for the proxmox-clone build."
