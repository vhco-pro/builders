#!/usr/bin/env bash
# Read-only artifact checks; never boot, modify or import the supplied disk.
set -euo pipefail
if [[ $# != 3 || ( "$2" != default && "$2" != custom ) ]]; then
    printf '%s\n' 'Usage: check-image.sh <disk> <default|custom> <expected-PDS-version>' >&2
    exit 2
fi
image=$1 mode=$2 version=$3
[[ -r "$image" ]]
qemu-img info --output=json "$image" | jq -e '(.format == "qcow2" or .format == "raw") and (has("backing-filename") | not)' >/dev/null
read_file() { virt-cat -a "$image" "$1"; }
exists() {
    local result
    result=$(guestfish --ro -a "$image" -i exists "$1")
    [[ "$result" == true || "$result" == false ]] || return 2
    [[ "$result" == true ]]
}
require_absent() {
    local result
    result=$(guestfish --ro -a "$image" -i exists "$1")
    [[ "$result" == false ]] || { printf 'Unexpected or unreadable artifact path: %s\n' "$1" >&2; return 1; }
}
[[ -z "$(read_file /etc/machine-id)" ]]
[[ "$(read_file /etc/hostname)" == localhost ]]
[[ "$(read_file /etc/shadow | awk -F: '$1 == "ubuntu" { print $2 }')" == '*' ]]
[[ -z "$(guestfish --ro -a "$image" -i glob-expand '/etc/ssh/ssh_host_*')" ]]
exists /etc/update-motd.d/90-pds
for path in /etc/skel/.zshrc /etc/skel/.p10k.zsh; do
    shared_config=$(read_file "$path")
    if grep -Eq '/root/|/home/ubuntu/' <<< "$shared_config"; then
        printf 'Build-user path retained in shared configuration: %s\n' "$path" >&2
        exit 1
    fi
done
read_file /var/lib/builders/pds.json |
    jq -e --arg version "$version" '.package == "pds" and .version == $version and (.source == "candidate" or .source == "signed-repository")' >/dev/null
for path in /root/.ssh/authorized_keys /home/ubuntu/.ssh/authorized_keys \
    /root/.bash_history /home/ubuntu/.bash_history /var/lib/cloud/seed \
    /etc/ssh/sshd_config.d/50-cloud-init.conf; do
    require_absent "$path"
done
policy=/etc/ssh/sshd_config.d/00-pds-security.conf
job=/etc/cron.d/pds-update
if [[ "$mode" == default ]]; then
    exists "$policy"
    exists "$job"
    effective=$(read_file "$policy")
    for setting in 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' \
        'PubkeyAuthentication yes' 'PermitRootLogin no'; do
        grep -Fxq "$setting" <<< "$effective"
    done
    read_file "$job" | grep -Fxq '0 0 * * * root /usr/local/sbin/pds-update >> /var/log/pds-update.log 2>&1'
else
    require_absent "$policy"
    require_absent "$job"
fi
printf 'PASS: read-only %s artifact checks; PDS %s. Boot and authentication tests remain separate.\n' "$mode" "$version"
