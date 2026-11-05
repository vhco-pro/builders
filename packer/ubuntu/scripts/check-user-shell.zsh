#!/usr/bin/env zsh
# Sourced by a dedicated login Zsh so every fresh-user probe can fail the check.
setopt ERR_EXIT NO_UNSET PIPE_FAIL
(( $# == 1 )) || exit 2
case "$1" in default|custom) ;; *) exit 2 ;; esac

(( $+functions[zi] ))
(( $+functions[p10k] ))
[[ -s ~/.p10k.zsh ]]
if [[ "$1" == default ]]; then
    [[ "$KREW_ROOT" == /usr/local/share/pds/krew ]]
    alias k
    whence __start_kubectl
    kubectl version --client
    kubectl krew list
    kubectl neat --help >/dev/null
    kubectl view-secret --help >/dev/null
    kubectl stern --version
fi
