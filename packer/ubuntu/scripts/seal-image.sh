#!/usr/bin/env bash
# Seal the image after all provisioning has finished. Fail if sealing fails.
set -euo pipefail

if [[ $# -ne 1 || "${1:-}" != --image-build ]]; then
    printf '%s\n' 'Usage: seal-image.sh --image-build (disposable build guest only).' >&2
    exit 2
fi

# shellcheck source=ssh-policy-observer.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/ssh-policy-observer.sh"
builders_check_ssh_policy /run/builders

# The build login must not survive in the exported disk.
usermod --password '*' ubuntu
rm -f /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys
rm -f /etc/ssh/ssh_host_*
# Discard the build's SSH password override and generated network configuration.
# Clone-time cloud-init supplies the deployed machine's access and addressing.
cloud-init clean --logs --seed --configs ssh_config network

truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
printf '%s\n' localhost > /etc/hostname
sed -i '/^127[.]0[.]1[.]1[[:space:]]/d' /etc/hosts

apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /var/lib/systemd/random-seed
# Export the journal before truncating logs. No package operations run after policy.
builders_check_ssh_policy /run/builders
find /var/log -type f -exec truncate --size=0 {} \;
# Build homes are workspaces. Shared tools/assets belong in system and skel paths.
for build_home in /root /home/ubuntu; do
    find "$build_home" -mindepth 1 -maxdepth 1 \
        ! -name .bashrc ! -name .profile ! -name .bash_logout \
        ! -name .zshrc ! -name .p10k.zsh -exec rm -rf -- {} +
done
rm -rf /tmp/* /var/tmp/*
rm -f /run/builders/ssh-policy.json
