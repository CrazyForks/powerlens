#!/usr/bin/env zsh
setopt errexit nounset pipefail

typeset -gr POWERLENS_MARKER_START="# >>> PowerLens installer >>>"
typeset -gr POWERLENS_MARKER_END="# <<< PowerLens installer <<<"
typeset -g _powerlens_zshrc_temporary_file=""

# Print an error to stderr and signal failure.
_powerlens_die() {
    print -u2 "PowerLens: $1"
    return 1
}

# Remove any leftover temp file; used as the EXIT/signal trap.
_powerlens_cleanup_temporary_files() {
    local exit_status=$?
    if [[ -n "$_powerlens_zshrc_temporary_file" && -e "$_powerlens_zshrc_temporary_file" ]]; then
        rm -f -- "$_powerlens_zshrc_temporary_file"
    fi
    _powerlens_zshrc_temporary_file=""
    return "$exit_status"
}

# Restore traps, clean up, then exit with the signal's status.
_powerlens_handle_signal() {
    local exit_status=$1
    trap - EXIT HUP INT TERM
    _powerlens_cleanup_temporary_files
    exit "$exit_status"
}

# Require macOS and a regular (non-symlink) startup file.
_powerlens_check_preconditions() {
    local zshrc=$1
    [[ "$(uname -s)" == "Darwin" ]] || {
        _powerlens_die "PowerLens requires macOS"
        return 1
    }
    if [[ -L "$zshrc" ]]; then
        _powerlens_die "startup file is a symbolic link: $zshrc; edit its target manually"
        return 1
    fi
}

_powerlens_uninstall_main() {
    local zshrc
    zshrc=${POWERLENS_ZSHRC:-${ZDOTDIR:-$HOME}/.zshrc}
    _powerlens_check_preconditions "$zshrc" || return 1
}

trap _powerlens_cleanup_temporary_files EXIT
trap '_powerlens_handle_signal 129' HUP
trap '_powerlens_handle_signal 130' INT
trap '_powerlens_handle_signal 143' TERM
_powerlens_uninstall_main "$@"
