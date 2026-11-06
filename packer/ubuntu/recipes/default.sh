#!/usr/bin/env bash
# Shared implementations live in PDS. Order service-changing installs before SSH policy.
install_zi
configure_zsh
setup_motd_preset "$BUILD_MOTD_PRESET"
install_gh
install_kubectl "$BUILD_KUBECTL_CHANNEL" --system
update_system_cron_entry
restricted_ssh_security_profile
