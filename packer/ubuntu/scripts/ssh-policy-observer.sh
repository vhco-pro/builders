#!/usr/bin/env bash
# Observe the service only when the selected recipe calls the shared SSH policy.
builders_capture_ssh_policy() {
    local runtime="$1" snapshot cursor
    [[ ! -f "$runtime/ssh-policy.json" ]] || return 0
    systemctl is-active --quiet ssh.service || return 1
    snapshot=$(systemctl show ssh.service --property=MainPID --property=ActiveEnterTimestampMonotonic --property=ExecMainStartTimestampMonotonic) || return 1
    grep -Eq '^MainPID=[1-9][0-9]*$' <<< "$snapshot" || return 1
    cursor=$(journalctl -u ssh.service -n 1 --show-cursor --no-pager | sed -n 's/^-- cursor: //p') || return 1
    [[ -n "$cursor" ]] || { printf '%s\n' 'Cannot capture the SSH journal cursor.' >&2; return 1; }
    jq -n --arg snapshot "$snapshot" --arg cursor "$cursor" \
        '{snapshot: $snapshot, cursor: $cursor}' > "$runtime/ssh-policy.json"
}

builders_check_ssh_policy() {
    local runtime="$1" expected actual cursor journal
    [[ -f "$runtime/ssh-policy.json" ]] || return 0
    expected=$(jq -er '.snapshot' "$runtime/ssh-policy.json") || return 1
    actual=$(systemctl show ssh.service --property=MainPID --property=ActiveEnterTimestampMonotonic --property=ExecMainStartTimestampMonotonic) || return 1
    if [[ "$expected" != "$actual" ]]; then
        printf '%s\n' 'SSH service restarted after the selected policy was configured.' >&2
        return 1
    fi
    cursor=$(jq -er '.cursor' "$runtime/ssh-policy.json") || return 1
    journal=$(journalctl -u ssh.service --after-cursor="$cursor" --no-pager) || return 1
    printf 'SSH service evidence since policy selection:\n%s\n%s\n' "$actual" "$journal"
    if grep -Eiq 'reload|restart|Starting |Stopping |Stopped |Started ' <<< "$journal"; then
        printf '%s\n' 'SSH service activation changed after policy selection; move service operations before that call.' >&2
        return 1
    fi
}
