#!/usr/bin/env bash
# Wait for first boot; accept completed boots with deprecation notices only.
set -euo pipefail

command -v jq >/dev/null || { printf '%s\n' 'Missing required command: jq' >&2; exit 1; }

status_code=0
state=$(cloud-init status --wait --format=json) || status_code=$?
printf '%s\n' "$state"
case "$status_code" in
    0|2) ;;
    *) exit "$status_code" ;;
esac

if ! jq -e -s --argjson code "$status_code" '
    length == 1 and (.[0] |
    .status == "done"
    and (.errors | type == "array" and length == 0)
    and (.recoverable_errors | type == "object")
    and ((.recoverable_errors | keys) == ["DEPRECATED"]
         or ($code == 0 and (.recoverable_errors | length) == 0)))
' >/dev/null <<<"$state"; then
    printf '%s\n' 'cloud-init did not report a clean or deprecation-only completed boot.' >&2
    exit 1
fi

if (( status_code == 2 )); then
    printf '%s\n' 'cloud-init completed with datasource deprecation notices; continuing.'
fi
