#!/usr/bin/env bash
# Install an exact PDS package and retain its signed source for later host updates.
set -euo pipefail

[[ $# == 2 ]] || { printf '%s\n' 'Usage: install-pds.sh <settings.json> <inputs-directory>' >&2; exit 2; }
settings=$1 inputs=$2
for tool in jq dpkg dpkg-deb dpkg-query gpg sha256sum apt-get; do
    command -v "$tool" >/dev/null || { printf 'Missing native PDS bootstrap prerequisite: %s\n' "$tool" >&2; exit 1; }
done
version=$(jq -er '.version | strings | select(test("^[0-9][A-Za-z0-9.+:~_-]*$"))' "$settings")
repository=$(jq -er '.repository | strings | select(test("^https://[^[:space:]]+/$"))' "$settings")
fingerprint=$(jq -er '.key_fingerprint | strings | select(test("^[A-F0-9]{40}$"))' "$settings")
candidate_sha256=$(jq -er '.candidate_sha256 | strings | select(. == "" or test("^[a-f0-9]{64}$"))' "$settings")
key="$inputs/repository-key.asc"
candidate="$inputs/candidate.deb"
architecture=$(dpkg --print-architecture)

# Refuse malformed candidates before configuring repositories or installing packages.
source_kind=signed-repository
if [[ -n "$candidate_sha256" ]]; then
    [[ -r "$candidate" ]] || { printf '%s\n' 'The explicit PDS candidate is missing.' >&2; exit 1; }
    printf '%s  %s\n' "$candidate_sha256" "$candidate" | sha256sum --check --status
    [[ "$(dpkg-deb --field "$candidate" Package)" == pds ]]
    [[ "$(dpkg-deb --field "$candidate" Version)" == "$version" ]]
    candidate_arch=$(dpkg-deb --field "$candidate" Architecture)
    [[ "$candidate_arch" == all || "$candidate_arch" == "$architecture" ]]
    source_kind=candidate
elif [[ -e "$candidate" ]]; then
    printf '%s\n' 'A candidate exists without an explicit SHA-256; refusing a repository fallback.' >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -m 0700 "$work/gnupg"
primary_fingerprints=$(gpg --no-options --homedir "$work/gnupg" --batch --with-colons --show-keys "$key" |
    awk -F: '$1 == "pub" { primary=1; next } $1 == "sub" { primary=0 } $1 == "fpr" && primary { print $10; primary=0 }')
[[ "$primary_fingerprints" == "$fingerprint" ]] || { printf '%s\n' 'PDS signing key fingerprint mismatch.' >&2; exit 1; }
gpg --no-options --homedir "$work/gnupg" --batch --yes --dearmor --output "$work/key.gpg" "$key"
printf 'deb [signed-by=/usr/share/keyrings/pds-repo.gpg] %s stable main\n' "$repository" > "$work/pds.list"
install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d /var/lib/builders
install -m 0644 "$work/key.gpg" /usr/share/keyrings/pds-repo.gpg
install -m 0644 "$work/pds.list" /etc/apt/sources.list.d/pds.list
apt-get update
if [[ "$source_kind" == candidate ]]; then
    apt-get install -y --no-install-recommends "$candidate"
else
    apt-get install -y --no-install-recommends "pds=$version"
fi
installed=$(dpkg-query -W -f='${Status}\t${Version}\t${Architecture}\n' pds)
IFS=$'\t' read -r status installed_version installed_arch <<< "$installed"
[[ "$status" == 'install ok installed' && "$installed_version" == "$version" ]]
[[ "$installed_arch" == all || "$installed_arch" == "$architecture" ]]
jq -n --arg version "$installed_version" --arg architecture "$installed_arch" \
    --arg source "$source_kind" --arg sha256 "$candidate_sha256" \
    --arg repository "$repository" --arg key_fingerprint "$fingerprint" \
    '{package: "pds", version: $version, architecture: $architecture, source: $source,
      candidate_sha256: $sha256, repository: $repository, key_fingerprint: $key_fingerprint}' > "$work/provenance.json"
install -m 0644 "$work/provenance.json" /var/lib/builders/pds.json
printf 'Installed PDS %s (%s); provenance: /var/lib/builders/pds.json\n' "$installed_version" "$source_kind"
