#!/bin/bash -eux
# Seal the image: strip build-time identity and reset first-boot state so every
# clone comes up fresh and unique (spec 0001 / issue #1). Runs last.

# Redirect stderr to stdout so Packer doesn't paint the whole run red.
exec 2>&1

LOG="/var/log/cleanup.log"
USER_NAME="ubuntu"

echo "==> Remove SSH keys used for the build"
rm -f /home/ubuntu/.ssh/authorized_keys
rm -f /root/.ssh/authorized_keys

echo "==> Remove persisted SSH host keys (regenerated on first boot)"
rm -f /etc/ssh/ssh_host_*

echo "==> Reset cloud-init so clones re-run first-boot config"
cloud-init clean --logs || true
rm -f /etc/netplan/50-cloud-init.yaml

echo "==> Reset machine-id so clones don't collide"
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

echo "==> Clean tmp, logs, apt caches and history"
rm -rf /tmp/* /var/tmp/*
find /var/log -type f -exec truncate --size=0 {} \;
rm -f /root/.bash_history /home/ubuntu/.bash_history /root/.wget-hsts
rm -rf /usr/share/doc/*
find /var/cache -type f -exec rm -f {} \;
apt-get -y autoremove
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /var/lib/systemd/random-seed

# Reset the default user's password (the build used a known one for SSH access).
echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd
echo "Cleanup complete." >> "$LOG"

export HISTSIZE=0
