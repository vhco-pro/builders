#!/usr/bin/env bash
# Observe the service only when the selected recipe calls the shared SSH policy.
builders_capture_ssh_policy() {
    local runtime="$1" snapshot cursor headers directories
    [[ ! -f "$runtime/ssh-policy.json" ]] || return 0
    systemctl is-active --quiet ssh.service || return 1
    snapshot=$(systemctl show ssh.service --property=MainPID --property=ActiveEnterTimestampMonotonic --property=ExecMainStartTimestampMonotonic) || return 1
    grep -Eq '^MainPID=[1-9][0-9]*$' <<< "$snapshot" || return 1
    cursor=$(journalctl -u ssh.service -n 1 --show-cursor --no-pager | sed -n 's/^-- cursor: //p') || return 1
    [[ -n "$cursor" ]] || { printf '%s\n' 'Cannot capture the SSH journal cursor.' >&2; return 1; }
    # journalctl normally locates files using /etc/machine-id. Sealing clears
    # that identity, so retain the actual directories before it changes.
    headers=$(LC_ALL=C journalctl --header --no-pager) || return 1
    directories=$(sed -nE 's#^[[:space:]]*File path:[[:space:]]*(/(var|run)/log/journal/[a-f0-9]{32})/[^/]*$#\1#p' <<< "$headers" |
        jq -Rsc 'split("\n") | map(select(length > 0)) | unique') || return 1
    jq -e 'length > 0' <<< "$directories" >/dev/null || { printf '%s\n' 'Cannot locate the SSH journal files.' >&2; return 1; }
    jq -n --arg snapshot "$snapshot" --arg cursor "$cursor" --argjson directories "$directories" \
        '{snapshot: $snapshot, cursor: $cursor, directories: $directories}' > "$runtime/ssh-policy.json"
}

builders_check_ssh_policy() {
    local runtime="$1" expected actual cursor journal directories directory cursor_entry
    local files=()
    [[ -f "$runtime/ssh-policy.json" ]] || return 0
    expected=$(jq -er '.snapshot' "$runtime/ssh-policy.json") || return 1
    actual=$(systemctl show ssh.service --property=MainPID --property=ActiveEnterTimestampMonotonic --property=ExecMainStartTimestampMonotonic) || return 1
    if [[ "$expected" != "$actual" ]]; then
        printf '%s\n' 'SSH service restarted after the selected policy was configured.' >&2
        return 1
    fi
    cursor=$(jq -er '.cursor' "$runtime/ssh-policy.json") || return 1
    directories=$(jq -er '.directories[]' "$runtime/ssh-policy.json") || return 1
    while IFS= read -r directory; do files+=("--file=$directory/*.journal*"); done <<< "$directories"
    cursor_entry=$(LC_ALL=C journalctl "${files[@]}" -u ssh.service --cursor="$cursor" --reverse --lines=1 --show-cursor --no-pager) || return 1
    if ! grep -Fxq -- "-- cursor: $cursor" <<< "$cursor_entry"; then
        printf '%s\n' 'The captured SSH journal entry is unavailable; cannot verify this interval.' >&2
        return 1
    fi
    journal=$(LC_ALL=C journalctl "${files[@]}" -u ssh.service --after-cursor="$cursor" --no-pager) || return 1
    printf 'SSH service evidence since policy selection:\n%s\n%s\n' "$actual" "$journal"
    if grep -Eiq 'reload|restart|Starting |Stopping |Stopped |Started ' <<< "$journal"; then
        printf '%s\n' 'SSH service activation changed after policy selection; move service operations before that call.' >&2
        return 1
    fi
}
