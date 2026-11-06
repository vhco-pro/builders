#!/usr/bin/env bash
# Read-only artifact checks; never boot, modify or import the supplied disk.
set -euo pipefail
if [[ $# != 4 || ( "$2" != default && "$2" != custom ) || ( "$4" != candidate && "$4" != signed-repository ) ]]; then
    printf '%s\n' 'Usage: check-image.sh <disk> <default|custom> <expected-PDS-version> <candidate|signed-repository>' >&2
    exit 2
fi
image=$1 mode=$2 version=$3 expected_source=$4
[[ -r "$image" ]]
qemu-img info --output=json "$image" | jq -e '(.format == "qcow2" or .format == "raw") and (has("backing-filename") | not)' >/dev/null
# Keep one read-only appliance alive for every assertion, including cleanup on failure.
session=$(guestfish --ro -a "$image" -i --listen)
if [[ "$session" =~ ^GUESTFISH_PID=([0-9]+)\; ]]; then
    guestfish_pid=${BASH_REMATCH[1]}
else
    printf '%s\n' 'libguestfs did not return a session PID.' >&2
    exit 1
fi
trap 'guestfish --remote="$guestfish_pid" exit >/dev/null' EXIT
disk() { guestfish --remote="$guestfish_pid" "$@"; }
read_file() { disk cat "$1"; }
exists() {
    local result
    result=$(disk exists "$1")
    [[ "$result" == true || "$result" == false ]] || return 2
    [[ "$result" == true ]]
}
require_absent() {
    local result
    result=$(disk exists "$1")
    [[ "$result" == false ]] || { printf 'Unexpected or unreadable artifact path: %s\n' "$1" >&2; return 1; }
}
machine_id=$(read_file /etc/machine-id)
[[ -z "$machine_id" ]]
[[ "$(read_file /etc/hostname)" == localhost ]]
[[ "$(read_file /etc/shadow | awk -F: '$1 == "ubuntu" { print $2 }')" == '*' ]]
host_keys=$(disk glob-expand '/etc/ssh/ssh_host_*')
[[ -z "$host_keys" ]]
exists /etc/update-motd.d/90-pds
for path in /etc/skel/.zshrc /etc/skel/.p10k.zsh; do
    shared_config=$(read_file "$path")
    if grep -Eq '/root/|/home/ubuntu/' <<< "$shared_config"; then
        printf 'Build-user path retained in shared configuration: %s\n' "$path" >&2
        exit 1
    fi
done
read_file /var/lib/builders/pds.json |
    jq -e --arg version "$version" --arg source "$expected_source" '.package == "pds" and .version == $version and .source == $source' >/dev/null
for build_home in /root /home/ubuntu; do
    entries=$(disk ls "$build_home")
    while IFS= read -r entry; do
        case "$entry" in
            ''|.bashrc|.profile|.bash_logout) ;;
            .sudo_as_admin_successful)
                marker=$(read_file "$build_home/.sudo_as_admin_successful")
                [[ -z "$marker" ]]
                ;;
            .cache)
                cache_entries=$(disk ls "$build_home/.cache")
                [[ -z "$cache_entries" || "$cache_entries" == motd.legal-displayed ]]
                if [[ -n "$cache_entries" ]]; then
                    marker=$(read_file "$build_home/.cache/motd.legal-displayed")
                    [[ -z "$marker" ]]
                fi
                ;;
            .zshrc)
                loader=$(read_file "$build_home/.zshrc")
                [[ "$loader" == 'source /etc/zshrc' ]]
                ;;
            .p10k.zsh)
                preset=$(read_file "$build_home/.p10k.zsh")
                shared_preset=$(read_file /etc/skel/.p10k.zsh)
                [[ "$preset" == "$shared_preset" ]]
                ;;
            .ssh)
                ssh_entries=$(disk ls "$build_home/.ssh")
                [[ -z "$ssh_entries" ]]
                ;;
            *) printf 'Unexpected build-home residue: %s/%s\n' "$build_home" "$entry" >&2; exit 1 ;;
        esac
    done <<< "$entries"
done
for path in /root/.ssh/authorized_keys /home/ubuntu/.ssh/authorized_keys \
    /root/.bash_history /home/ubuntu/.bash_history /var/lib/cloud/seed \
    /etc/ssh/sshd_config.d/50-cloud-init.conf /etc/netplan/50-cloud-init.yaml \
    /var/lib/cloud/instance /var/lib/cloud/instances; do
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
printf 'PASS: read-only %s artifact checks; PDS %s (%s). Boot and authentication tests remain separate.\n' "$mode" "$version" "$expected_source"
