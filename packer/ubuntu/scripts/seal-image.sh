#!/usr/bin/env bash
# Seal the image after all provisioning has finished. Fail if sealing fails.
set -euo pipefail

if [[ $# -ne 1 || "${1:-}" != --image-build ]]; then
    printf '%s\n' 'Usage: seal-image.sh --image-build (disposable build guest only).' >&2
    exit 2
fi

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

apt-get -y autoremove
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /var/lib/systemd/random-seed
find /var/log -type f -exec truncate --size=0 {} \;
rm -f /root/.bash_history /home/ubuntu/.bash_history /root/.wget-hsts
rm -rf /tmp/* /var/tmp/*
