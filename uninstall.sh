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

# Stop the PowerLens daemon: pidfile PID first, then any orphaned matches.
_powerlens_stop_daemon() {
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/powerlens"
    local pidfile="$cache_dir/daemon.pid"
    local pid

    if [[ -f "$pidfile" ]]; then
        pid=$(< "$pidfile")
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    fi
    # Machine-wide teardown: reap any cross-session or orphaned daemon.
    pkill -f 'powerlens-fetch' 2>/dev/null || true
    return 0
}

# True if the startup file contains both installer markers.
_powerlens_has_marker_block() {
    local zshrc=$1
    [[ -f "$zshrc" ]] || return 1
    grep -F -q -- "$POWERLENS_MARKER_START" "$zshrc" \
      && grep -F -q -- "$POWERLENS_MARKER_END" "$zshrc"
}

# True if a "powerlens" token appears outside markers, on a non-comment line.
_powerlens_unmarked_powerlens_present() {
    local zshrc=$1 line inside=0
    [[ -f "$zshrc" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$POWERLENS_MARKER_START" ]] && { inside=1; continue; }
        [[ "$line" == "$POWERLENS_MARKER_END" ]] && { inside=0; continue; }
        (( inside )) && continue
        [[ "$line" == \#* ]] && continue
        [[ "$line" == *powerlens* ]] && return 0
    done < "$zshrc"
    return 1
}

# Remove the marked block (and one preceding blank line); back up first.
_powerlens_clean_zshrc() {
    local zshrc=$1 backup_path temporary_zshrc line

    if _powerlens_unmarked_powerlens_present "$zshrc"; then
        print -u2 "PowerLens: found a manual 'powerlens' entry outside the installer markers in $zshrc; remove it yourself"
    fi

    _powerlens_has_marker_block "$zshrc" || return 0

    backup_path="${zshrc}.powerlens-backup-$(date +%Y%m%d-%H%M%S)"
    cp -- "$zshrc" "$backup_path"

    temporary_zshrc=$(mktemp "${zshrc}.powerlens-tmp-XXXXXX") || return 1
    _powerlens_zshrc_temporary_file=$temporary_zshrc

    # Buffer non-block lines, dropping a single blank line right before the block.
    local skipping=0 pending_blank=0
    : > "$temporary_zshrc"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$POWERLENS_MARKER_START" ]]; then
            skipping=1
            pending_blank=0   # drop the buffered blank line before the block
            continue
        fi
        if (( skipping )); then
            [[ "$line" == "$POWERLENS_MARKER_END" ]] && skipping=0
            continue
        fi
        if (( pending_blank )); then
            print -r -- "" >> "$temporary_zshrc"
            pending_blank=0
        fi
        if [[ -z "$line" ]]; then
            pending_blank=1
            continue
        fi
        print -r -- "$line" >> "$temporary_zshrc"
    done < "$zshrc"
    (( pending_blank )) && print -r -- "" >> "$temporary_zshrc"

    if ! mv -- "$temporary_zshrc" "$zshrc"; then
        _powerlens_cleanup_temporary_files
        return 1
    fi
    _powerlens_zshrc_temporary_file=""
}

# Delete the first candidate install dir that looks like a PowerLens checkout.
_powerlens_remove_install_dir() {
    local candidate
    local -a candidates
    candidates=(
        "${POWERLENS_INSTALL_DIR:-}"
        "${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}/plugins/powerlens"
        "${XDG_DATA_HOME:-$HOME/.local/share}/powerlens"
    )
    for candidate in "${candidates[@]}"; do
        [[ -n "$candidate" && -d "$candidate" ]] || continue
        if [[ -f "$candidate/powerlens.plugin.zsh" ]]; then
            rm -rf -- "$candidate"
            return 0
        fi
        print -u2 "PowerLens: $candidate is not a PowerLens install (no powerlens.plugin.zsh); leaving it in place"
    done
    return 0
}

# Delete the runtime cache directory.
_powerlens_remove_cache_dir() {
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/powerlens"
    [[ -d "$cache_dir" ]] && rm -rf -- "$cache_dir"
    return 0
}

_powerlens_uninstall_main() {
    local zshrc
    zshrc=${POWERLENS_ZSHRC:-${ZDOTDIR:-$HOME}/.zshrc}
    _powerlens_check_preconditions "$zshrc" || return 1
    _powerlens_stop_daemon
    _powerlens_clean_zshrc "$zshrc"
    _powerlens_remove_install_dir
    _powerlens_remove_cache_dir
    print -r -- "PowerLens: Uninstall complete."
    print -r -- "PowerLens: Any hand-written POWERLENS_* lines were left in your startup file."
    print -r -- "PowerLens: Restart your shell with:"
    print -r -- "exec zsh"
}

trap _powerlens_cleanup_temporary_files EXIT
trap '_powerlens_handle_signal 129' HUP
trap '_powerlens_handle_signal 130' INT
trap '_powerlens_handle_signal 143' TERM
_powerlens_uninstall_main "$@"
