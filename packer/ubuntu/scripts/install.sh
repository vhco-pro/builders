#!/usr/bin/env bash
set -euo pipefail

# Apply this image's native Ubuntu settings after first boot has completed.
config_file="${1:?Usage: install.sh <cloud-config-file>}"
if [[ ! -r "$config_file" ]]; then
    printf 'Cannot read cloud config: %s\n' "$config_file" >&2
    exit 1
fi

for module in package_update_upgrade_install locale timezone keyboard; do
    cloud-init single --name "$module" --frequency always --file "$config_file"
done
# Finish package removals before the selected recipe may configure SSH policy.
apt-get -y autoremove
