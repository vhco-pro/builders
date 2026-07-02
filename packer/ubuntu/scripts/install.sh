#!/bin/bash -eux
# Generic post-cloud-init step for the golden image (spec 0001 / issue #1).
#
# SCOPE: the image is GENERIC. Identity (hostname, users, SSH keys, static
# network) is injected at CLONE time via cloud-init, never here. Networking
# stays on DHCP (the cloud image default). Tooling (kubectl, zsh, hardening,
# MOTD) moves to the PDS package in issue #3, so this stays intentionally
# minimal and the image builds green and unidentified.

# Redirect stderr to stdout so Packer doesn't paint the whole run red.
exec 2>&1

echo "==> Waiting for cloud-init to finish..."
cloud-init status --wait

echo "==> Generic provisioning complete (nothing baked in)."
