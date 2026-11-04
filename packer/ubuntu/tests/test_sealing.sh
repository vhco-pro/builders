#!/usr/bin/env bash
# Destructive integration test: run only in a disposable Ubuntu container.
set -euo pipefail

if [[ ! -f /.dockerenv ]]; then
    printf '%s\n' 'Run this test in a disposable Docker container, never on a host.' >&2
    exit 2
fi
scripts_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd)"
seed_file="$scripts_dir/../cloud-init/user-data"
fixture_dir=/var/lib/builders-sealing-test
mkdir -p /run/sshd /etc/ssh/sshd_config.d /var/lib/dbus "$fixture_dir"
id ubuntu >/dev/null 2>&1 || useradd --create-home ubuntu
printf '%s\n' 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/60-cloudimg-settings.conf

cloud-init single --name set_passwords --frequency always --file "$seed_file"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/hostkey"
policy=$(sshd -T -h "$fixture_dir/hostkey")
grep -qx 'passwordauthentication yes' <<<"$policy"
printf '%s\n' 'Reproduced temporary build policy: passwordauthentication yes'

for path in /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys \
    /etc/netplan/50-cloud-init.yaml /var/lib/cloud/seed/nocloud/user-data; do
    mkdir -p "$(dirname -- "$path")"
    printf '%s\n' 'temporary build fixture' > "$path"
done
printf '%s\n' 0123456789abcdef0123456789abcdef > /etc/machine-id

# Docker bind-mounts /etc/hosts, preventing sed -i from renaming it. Keep the
# sealer's expression and adapt only the write to this Docker-managed file.
cat > /usr/local/bin/sed <<'ADAPTER'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# == 3 && "$1" == -i && "$3" == /etc/hosts ]]; then
    result=$(/usr/bin/sed "$2" "$3")
    printf '%s\n' "$result" > "$3"
else
    exec /usr/bin/sed "$@"
fi
ADAPTER
chmod +x /usr/local/bin/sed
bash "$scripts_dir/seal-image.sh" --image-build

policy=$(sshd -T -h "$fixture_dir/hostkey")
grep -qx 'passwordauthentication no' <<<"$policy"
test "$(getent shadow ubuntu | cut -d: -f2)" = '*'
test -f /etc/machine-id && test ! -s /etc/machine-id
test "$(readlink /var/lib/dbus/machine-id)" = /etc/machine-id
test "$(cat /etc/hostname)" = localhost
test ! -e /etc/ssh/sshd_config.d/50-cloud-init.conf
for path in /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys \
    /etc/netplan/50-cloud-init.yaml /var/lib/cloud/seed; do
    test ! -e "$path"
done
compgen -G '/etc/ssh/ssh_host_*' >/dev/null && exit 1
printf '%s\n' 'PASS: build password, SSH override, keys and identity removed.'
