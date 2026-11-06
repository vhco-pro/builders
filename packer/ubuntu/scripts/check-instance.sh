#!/usr/bin/env bash
# Run as the deployed user inside an owned, fresh disposable validation instance.
set -euo pipefail
if [[ $# != 1 || ( "$1" != default && "$1" != custom ) ]]; then
    printf '%s\n' 'Usage: check-instance.sh <default|custom> (inside a disposable clone)' >&2
    exit 2
fi
mode=$1
[[ "$(id -u)" != 0 ]] || { printf '%s\n' 'Run as the new deployment user, not root.' >&2; exit 1; }
login_shell=$(getent passwd "$(id -un)" | cut -d: -f7)
[[ "$login_shell" == */zsh ]]
sudo -n true
[[ -s "$HOME/.p10k.zsh" && -r /usr/local/share/zi/zi.zsh ]]
shell_check="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/check-user-shell.zsh"
[[ -r "$shell_check" ]] || { printf '%s\n' 'Keep check-user-shell.zsh beside this check script.' >&2; exit 1; }
# First run may download the existing Zi plugins; the second must reuse the setup.
for startup in 1 2; do
    printf 'Verify Zsh startup %s (the first may download Zi plugins).\n' "$startup"
    zsh -lic 'source "$1" "$2"' builders-shell-check "$shell_check" "$mode"
done
if [[ "$mode" == default ]]; then
    [[ ! -w /usr/local/share/pds/krew ]]
    systemctl is-enabled cron
    effective=$(sudo -n /usr/sbin/sshd -T)
    for setting in 'passwordauthentication no' 'kbdinteractiveauthentication no' \
        'pubkeyauthentication yes' 'permitrootlogin no'; do
        grep -Fxq "$setting" <<< "$effective"
    done
else
    sudo -n test ! -e /etc/ssh/sshd_config.d/00-pds-security.conf
    sudo -n test ! -e /etc/cron.d/pds-update
fi
printf 'PASS: %s fresh-user tooling, shell and selected policy checks.\n' "$mode"
