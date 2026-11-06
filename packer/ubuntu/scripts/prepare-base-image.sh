#!/usr/bin/env bash
# Produce a reusable, checksummed base-image bundle on the build machine.
set -euo pipefail

output_dir="${1:?Usage: prepare-base-image.sh <new-output-directory>}"
[[ $# == 1 ]] || { printf '%s\n' 'Pass exactly one new output directory.' >&2; exit 1; }
UBUNTU_VERSION="${UBUNTU_VERSION:-noble}"
ARCH="${ARCH:-amd64}"
UBUNTU_IMAGE_RELEASE="${UBUNTU_IMAGE_RELEASE:-current}"
export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"
for value in "$UBUNTU_VERSION" "$ARCH" "$UBUNTU_IMAGE_RELEASE"; do
    [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { printf '%s\n' 'Invalid Ubuntu release or architecture.' >&2; exit 1; }
done
for tool in curl sha256sum virt-customize; do
    command -v "$tool" >/dev/null || { printf 'Missing required command: %s\n' "$tool" >&2; exit 1; }
done
# mkdir refuses an existing directory. A failed preparation is left for inspection.
mkdir -- "$output_dir"
image_name="${UBUNTU_VERSION}-server-cloudimg-${ARCH}.img"
image_url="https://cloud-images.ubuntu.com/${UBUNTU_VERSION}/${UBUNTU_IMAGE_RELEASE}"
curl -fL --connect-timeout 15 --max-time 300 --retry 2 -o "$output_dir/$image_name" "$image_url/$image_name"
curl -fsSL --connect-timeout 15 --max-time 60 --retry 2 -o "$output_dir/upstream-SHA256SUMS" "$image_url/SHA256SUMS"
awk -v image="$image_name" '$2 == image || $2 == "*" image { print }' "$output_dir/upstream-SHA256SUMS" > "$output_dir/upstream-image.sha256"
[[ -s "$output_dir/upstream-image.sha256" ]] || { printf '%s\n' 'Image checksum was not found.' >&2; exit 1; }
(cd -- "$output_dir" && sha256sum -c upstream-image.sha256)
{
    printf 'source_url=%s/%s\n' "$image_url" "$image_name"
    printf 'architecture=%s\n' "$ARCH"
    printf 'libguestfs_backend=%s\n' "$LIBGUESTFS_BACKEND"
    virt-customize --version
} > "$output_dir/build-info.txt"

# Customization can generate a machine-id. Clear it before any base is cloned.
virt-customize --network -a "$output_dir/$image_name" --install qemu-guest-agent \
    --run-command '
        set -e
        truncate -s 0 /etc/machine-id
        rm -f /var/lib/dbus/machine-id
        ln -s /etc/machine-id /var/lib/dbus/machine-id
        rm -f /etc/ssh/ssh_host_*
        test -f /etc/machine-id && test ! -s /etc/machine-id
    ' 2>&1 | tee "$output_dir/prepare.log"
mv -- "$output_dir/$image_name" "$output_dir/base.qcow2"
(cd -- "$output_dir" && sha256sum base.qcow2 > base-image.sha256)
printf 'Prepared base-image bundle: %s\n' "$output_dir"
