#!/usr/bin/env bash
# The operator-selected Bash recipe owns PDS selections; cleanup remains separate.
set -euo pipefail

[[ $# == 3 || $# == 4 ]] || { printf '%s\n' 'Usage: run-recipe.sh <settings.json> <PDS-init.sh> <recipe.sh> [runtime-directory]' >&2; exit 2; }
settings=$1 library=$2 recipe=$3 runtime=${4:-/run/builders}
[[ -r "$recipe" && -r "$library" ]] || { printf '%s\n' 'The recipe or installed PDS library is unreadable.' >&2; exit 1; }
bash -n "$recipe"
export BUILD_MOTD_PRESET BUILD_KUBECTL_CHANNEL
BUILD_MOTD_PRESET=$(jq -er '.motd_preset | strings | select(test("^[a-z0-9][a-z0-9_-]*$"))' "$settings")
BUILD_KUBECTL_CHANNEL=$(jq -er '.kubectl_channel | strings | select(test("^1\\.[0-9]+$"))' "$settings")
mkdir -p "$runtime"
chmod 0700 "$runtime"
rm -f -- "$runtime/ssh-policy.json"
# shellcheck source=ssh-policy-observer.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/ssh-policy-observer.sh"
pds_before_ssh_policy() { builders_capture_ssh_policy "$runtime"; }
# shellcheck disable=SC1090
source "$library"
printf 'Applying recipe SHA256: %s\n' "$(sha256sum "$recipe" | cut -d ' ' -f1)"
# shellcheck disable=SC1090
source "$recipe"
builders_check_ssh_policy "$runtime"
