#!/usr/bin/env bash
# Prepare or reuse a local base-image bundle, then import it over SSH.
set -euo pipefail

: "${BASE_VMID:?Set BASE_VMID to an unused Proxmox VM ID}"
: "${PVE_HOST:?Set PVE_HOST to your Proxmox SSH destination, such as root@pve}"
if [[ ! "$BASE_VMID" =~ ^[1-9][0-9]{2,8}$ ]] || (( BASE_VMID < 100 )); then
    printf '%s\n' 'BASE_VMID must be an integer between 100 and 999999999.' >&2
    exit 1
fi
[[ "$PVE_HOST" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]*$ ]] || { printf '%s\n' 'Invalid PVE_HOST.' >&2; exit 1; }

UBUNTU_VERSION="${UBUNTU_VERSION:-noble}"
BASE_NAME="${BASE_NAME:-ubuntu-${UBUNTU_VERSION}-cloudimg}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
DISK_SIZE="${DISK_SIZE:-32G}"
for value in "$BASE_NAME" "$STORAGE" "$BRIDGE"; do
    [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { printf '%s\n' 'Invalid template name, storage or bridge.' >&2; exit 1; }
done
[[ "$DISK_SIZE" =~ ^[1-9][0-9]*[GM]$ ]] || { printf '%s\n' 'DISK_SIZE must be a positive size in G or M.' >&2; exit 1; }

scripts_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ssh_options=(-o StrictHostKeyChecking=yes -o ConnectTimeout=15)
# Refuse occupied IDs before downloading, preparing or uploading an image.
ssh "${ssh_options[@]}" -- "$PVE_HOST" bash -s -- --check "$BASE_VMID" < "$scripts_dir/import-base-template.sh"

work_dir="$(mktemp -d)"
remote_dir=''
cleanup() {
    local status=$?
    if [[ -n "$remote_dir" ]]; then
        ssh "${ssh_options[@]}" -- "$PVE_HOST" "rm -rf -- '$remote_dir'" || {
            printf 'Remove the temporary upload directory manually: %s:%s\n' "$PVE_HOST" "$remote_dir" >&2
            status=1
        }
    fi
    rm -rf -- "$work_dir"
    exit "$status"
}
trap cleanup EXIT

image_dir="${BASE_IMAGE_DIR:-$work_dir/base}"
if [[ -z "${BASE_IMAGE_DIR:-}" ]]; then
    bash "$scripts_dir/prepare-base-image.sh" "$image_dir"
fi
checksum="$(cat -- "$image_dir/base-image.sha256")"
[[ "$checksum" =~ ^[a-fA-F0-9]{64}[[:blank:]]+base[.]qcow2$ ]] || { printf '%s\n' 'Invalid base-image checksum record.' >&2; exit 1; }
(cd -- "$image_dir" && sha256sum -c base-image.sha256)

if ! allocated_dir="$(ssh "${ssh_options[@]}" -- "$PVE_HOST" mktemp -d /var/tmp/builders-base.XXXXXXXX)"; then
    printf 'Remote staging failed; inspect the node before cleanup. Reply: %q\n' "$allocated_dir" >&2
    exit 1
fi
if [[ ! "$allocated_dir" =~ ^/var/tmp/builders-base[.][a-zA-Z0-9]{8}$ ]]; then
    printf 'Unexpected upload directory; no remote cleanup attempted. Reply: %q\n' "$allocated_dir" >&2
    exit 1
fi
remote_dir="$allocated_dir"
for file in base.qcow2 base-image.sha256; do
    ssh "${ssh_options[@]}" -- "$PVE_HOST" "cat > '$remote_dir/$file'" < "$image_dir/$file"
done
ssh "${ssh_options[@]}" -- "$PVE_HOST" bash -s -- --import "$BASE_VMID" "$remote_dir" \
    "$BASE_NAME" "$STORAGE" "$BRIDGE" "$DISK_SIZE" < "$scripts_dir/import-base-template.sh"
printf 'Base template created: %s (VM ID %s)\n' "$BASE_NAME" "$BASE_VMID"
