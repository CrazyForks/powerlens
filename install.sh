#!/usr/bin/env zsh
setopt errexit nounset pipefail

typeset -gr POWERLENS_DEFAULT_REPO_URL="https://github.com/luyangkk/powerlens.git"
typeset -gr POWERLENS_MARKER_START="# >>> PowerLens installer >>>"
typeset -gr POWERLENS_MARKER_END="# <<< PowerLens installer <<<"
typeset -g _powerlens_install_temporary_dir=""
typeset -g _powerlens_zshrc_temporary_file=""

_powerlens_die() {
    print -u2 "PowerLens: $1"
    return 1
}

_powerlens_cleanup_temporary_files() {
    local exit_status=$?

    if [[ -n "$_powerlens_install_temporary_dir" && -e "$_powerlens_install_temporary_dir" ]]; then
        rm -rf -- "$_powerlens_install_temporary_dir"
    fi
    _powerlens_install_temporary_dir=""
    if [[ -n "$_powerlens_zshrc_temporary_file" && -e "$_powerlens_zshrc_temporary_file" ]]; then
        rm -f -- "$_powerlens_zshrc_temporary_file"
    fi
    _powerlens_zshrc_temporary_file=""

    return "$exit_status"
}

_powerlens_check_preconditions() {
    local zshrc=$1 parent_dir required_command

    [[ "$(uname -s)" == "Darwin" ]] || {
        _powerlens_die "PowerLens requires macOS"
        return 1
    }

    for required_command in git zsh curl; do
        command -v "$required_command" >/dev/null || {
            _powerlens_die "required command not found: $required_command"
            return 1
        }
    done

    if [[ -e "$zshrc" ]]; then
        [[ -f "$zshrc" && -w "$zshrc" ]] || {
            _powerlens_die "startup file must be a writable regular file: $zshrc"
            return 1
        }
    else
        parent_dir=${zshrc:h}
        [[ -d "$parent_dir" && -w "$parent_dir" ]] || {
            _powerlens_die "startup file parent must exist and be writable: $parent_dir"
            return 1
        }
    fi
}

_powerlens_validate_install() {
    local install_dir=$1 binary

    case "$(uname -m)" in
        arm64) binary="bin/powerlens-fetch-arm64" ;;
        x86_64) binary="bin/powerlens-fetch-amd64" ;;
        *) _powerlens_die "unsupported Mac architecture: $(uname -m)"; return 1 ;;
    esac

    [[ -f "$install_dir/powerlens.plugin.zsh" ]] || {
        _powerlens_die "missing powerlens.plugin.zsh in $install_dir"
        return 1
    }
    [[ -f "$install_dir/powerlens.zsh" ]] || {
        _powerlens_die "missing powerlens.zsh in $install_dir"
        return 1
    }
    [[ -x "$install_dir/$binary" ]] || {
        _powerlens_die "missing executable $binary in $install_dir"
        return 1
    }
}

_powerlens_normalize_repo_url() {
    local repo_url=$1

    repo_url=${repo_url%/}
    repo_url=${repo_url%.git}
    print -r -- "$repo_url"
}

_powerlens_validate_existing_repo() {
    local install_dir=$1 repo_url=$2
    local status_output actual_origin expected_origin normalized_actual_origin

    [[ -d "$install_dir/.git" ]] || {
        _powerlens_die "not a PowerLens Git repository: $install_dir; move it aside or set POWERLENS_INSTALL_DIR to another path"
        return 1
    }

    status_output=$(git -C "$install_dir" status --porcelain) || {
        _powerlens_die "not a PowerLens Git repository: $install_dir; move it aside or set POWERLENS_INSTALL_DIR to another path"
        return 1
    }
    [[ -z "$status_output" ]] || {
        _powerlens_die "local changes in $install_dir; commit, revert, or move them before updating"
        return 1
    }

    actual_origin=$(git -C "$install_dir" remote get-url origin) || {
        _powerlens_die "unexpected origin in $install_dir; move it aside or set POWERLENS_INSTALL_DIR to another path"
        return 1
    }
    expected_origin=$(_powerlens_normalize_repo_url "$repo_url")
    normalized_actual_origin=$(_powerlens_normalize_repo_url "$actual_origin")
    [[ "$normalized_actual_origin" == "$expected_origin" ]] || {
        _powerlens_die "unexpected origin in $install_dir; move it aside or set POWERLENS_INSTALL_DIR to another path"
        return 1
    }

    git -C "$install_dir" fetch -- origin main:refs/remotes/origin/main || return 1
    git -C "$install_dir" merge-base --is-ancestor HEAD origin/main || {
        _powerlens_die "cannot fast-forward $install_dir; move it aside or set POWERLENS_INSTALL_DIR to another path"
        return 1
    }
    git -C "$install_dir" merge --ff-only origin/main || return 1
    _powerlens_validate_install "$install_dir"
}

_powerlens_install_or_update() {
    local install_dir=$1 repo_url=$2
    local parent_dir=${install_dir:h} temporary_dir

    if [[ -e "$install_dir" || -L "$install_dir" ]]; then
        _powerlens_validate_existing_repo "$install_dir" "$repo_url"
        return
    fi

    mkdir -p -- "$parent_dir"
    temporary_dir=$(mktemp -d "$parent_dir/.powerlens-install-XXXXXX") || return 1
    _powerlens_install_temporary_dir=$temporary_dir

    if ! git clone --branch main --single-branch -- "$repo_url" "$temporary_dir"; then
        _powerlens_cleanup_temporary_files
        return 1
    fi

    if ! _powerlens_validate_install "$temporary_dir"; then
        _powerlens_cleanup_temporary_files
        return 1
    fi

    if ! mv -- "$temporary_dir" "$install_dir"; then
        _powerlens_cleanup_temporary_files
        return 1
    fi
    _powerlens_install_temporary_dir=""
}

_powerlens_omz_loader_count() {
    local zshrc=$1

    [[ -f "$zshrc" ]] || {
        print 0
        return
    }

    awk '
        /^[[:space:]]*(source|\.)[[:space:]]/ {
            line = $0
            sub(/#.*/, "", line)
            if (index(line, "oh-my-zsh.sh")) {
                count++
            }
        }
        END { print count + 0 }
    ' "$zshrc"
}

_powerlens_detect_shell_mode() {
    local zshrc=$1

    case "${POWERLENS_SHELL_MODE:-}" in
        omz|zsh) print -r -- "$POWERLENS_SHELL_MODE"; return 0 ;;
        "") ;;
        *) _powerlens_die "POWERLENS_SHELL_MODE must be omz or zsh"; return 1 ;;
    esac

    if [[ -f "${ZSH:-}/oh-my-zsh.sh" || -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]] || \
        [[ "$(_powerlens_omz_loader_count "$zshrc")" == 1 ]]; then
        print -r -- omz
    elif [[ "${SHELL:-}" == */zsh || "${SHELL:-}" == zsh ]]; then
        print -r -- zsh
    else
        _powerlens_choose_mode_from_tty
    fi
}

_powerlens_choose_mode_from_tty() {
    local choice

    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        _powerlens_die "could not detect zsh or Oh My Zsh; set POWERLENS_SHELL_MODE=omz or POWERLENS_SHELL_MODE=zsh"
        return 1
    fi

    if ! {
        print -r -- "PowerLens: unable to detect your shell setup. Choose an installation mode:"
        print -r -- "  1) Oh My Zsh"
        print -r -- "  2) plain zsh"
        print -n -r -- "Enter 1 or 2: "
    } > /dev/tty || ! IFS= read -r choice < /dev/tty; then
        _powerlens_die "could not detect zsh or Oh My Zsh; set POWERLENS_SHELL_MODE=omz or POWERLENS_SHELL_MODE=zsh"
        return 1
    fi

    case "$choice" in
        1|omz) print -r -- omz ;;
        2|zsh) print -r -- zsh ;;
        *)
            _powerlens_die "choose 1 (omz) or 2 (zsh), or set POWERLENS_SHELL_MODE=omz or POWERLENS_SHELL_MODE=zsh"
            return 1
            ;;
    esac
}

_powerlens_default_install_dir() {
    local mode=$1

    case "$mode" in
        omz) print -r -- "${ZSH_CUSTOM:-${ZSH:-$HOME/.oh-my-zsh}/custom}/plugins/powerlens" ;;
        zsh) print -r -- "${XDG_DATA_HOME:-$HOME/.local/share}/powerlens" ;;
        *) _powerlens_die "unknown shell mode: $mode"; return 1 ;;
    esac
}

_powerlens_plugins_contain_powerlens() {
    local zshrc=$1

    [[ -f "$zshrc" ]] || return 1

    awk '
        function contains_powerlens(line, words, count, word_index) {
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/[()]/, " ", line)
            count = split(line, words, /[[:space:]]+/)
            for (word_index = 1; word_index <= count; word_index++) {
                if (words[word_index] == "powerlens" || words[word_index] == "\047powerlens\047" || words[word_index] == "\"powerlens\"") {
                    return 1
                }
            }
            return 0
        }

        /^[[:space:]]*#/ { next }
        !in_plugins && /^[[:space:]]*plugins[+]?=[[:space:]]*\(/ { in_plugins = 1 }
        in_plugins {
            if (contains_powerlens($0)) {
                found = 1
                exit
            }
            if ($0 ~ /\)/) {
                in_plugins = 0
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$zshrc"
}

_powerlens_plain_source_present() {
    local zshrc=$1 plugin_path=$2 line source_path
    local -a words

    while IFS= read -r line || [[ -n "$line" ]]; do
        words=(${(z)line})
        (( ${#words} >= 2 )) || continue
        [[ "$words[1]" == source || "$words[1]" == "." ]] || continue
        source_path=${(Q)words[2]}
        [[ "$source_path" == "$plugin_path" ]] && return 0
    done < "$zshrc"

    return 1
}

_powerlens_configure_plain_zsh() {
    local zshrc=$1 install_dir=$2
    local plugin_path="$install_dir/powerlens.plugin.zsh"
    local temporary_zshrc backup_path

    [[ -e "$zshrc" ]] || : > "$zshrc"

    if _powerlens_plain_source_present "$zshrc" "$plugin_path"; then
        return
    fi

    backup_path="${zshrc}.powerlens-backup-$(date +%Y%m%d-%H%M%S)"
    cp -- "$zshrc" "$backup_path"

    temporary_zshrc=$(mktemp "${zshrc}.powerlens-tmp-XXXXXX") || return 1
    _powerlens_zshrc_temporary_file=$temporary_zshrc
    if ! {
        cat -- "$zshrc"
        print
        print -- "$POWERLENS_MARKER_START"
        print -r -- "source ${(qqq)plugin_path}"
        print -- "$POWERLENS_MARKER_END"
    } > "$temporary_zshrc"; then
        _powerlens_cleanup_temporary_files
        return 1
    fi

    if ! mv -- "$temporary_zshrc" "$zshrc"; then
        _powerlens_cleanup_temporary_files
        return 1
    fi
    _powerlens_zshrc_temporary_file=""
}

_powerlens_configure_omz() {
    local zshrc=$1 install_dir=$2
    local loader_count temporary_zshrc backup_path

    loader_count=$(_powerlens_omz_loader_count "$zshrc")
    if [[ "$loader_count" != 1 ]]; then
        _powerlens_die "expected exactly one active Oh My Zsh loader in $zshrc; add plugins+=(powerlens) manually before the loader"
        return 1
    fi

    _powerlens_plugins_contain_powerlens "$zshrc" && return

    backup_path="${zshrc}.powerlens-backup-$(date +%Y%m%d-%H%M%S)"
    cp -- "$zshrc" "$backup_path"

    temporary_zshrc=$(mktemp "${zshrc}.powerlens-tmp-XXXXXX") || return 1
    _powerlens_zshrc_temporary_file=$temporary_zshrc
    if ! awk -v marker_start="$POWERLENS_MARKER_START" -v marker_end="$POWERLENS_MARKER_END" '
        /^[[:space:]]*(source|\.)[[:space:]]/ {
            line = $0
            sub(/#.*/, "", line)
            if (index(line, "oh-my-zsh.sh")) {
                print marker_start
                print "plugins+=(powerlens)"
                print marker_end
            }
        }
        { print }
    ' "$zshrc" > "$temporary_zshrc"; then
        _powerlens_cleanup_temporary_files
        return 1
    fi

    if ! mv -- "$temporary_zshrc" "$zshrc"; then
        _powerlens_cleanup_temporary_files
        return 1
    fi
    _powerlens_zshrc_temporary_file=""
}

_powerlens_main() {
    local shell_mode shell_label zshrc repo_url install_dir action

    zshrc=${POWERLENS_ZSHRC:-${ZDOTDIR:-$HOME}/.zshrc}
    repo_url=${POWERLENS_REPO_URL:-$POWERLENS_DEFAULT_REPO_URL}
    _powerlens_check_preconditions "$zshrc" || return 1
    shell_mode=$(_powerlens_detect_shell_mode "$zshrc") || return 1
    install_dir=${POWERLENS_INSTALL_DIR:-$(_powerlens_default_install_dir "$shell_mode")}

    [[ "$install_dir" == /* ]] || install_dir="$PWD/$install_dir"
    if [[ -e "$install_dir" || -L "$install_dir" ]]; then
        action=Updating
    else
        action=Installing
    fi
    case "$shell_mode" in
        omz) shell_label="Oh My Zsh" ;;
        zsh) shell_label="plain zsh" ;;
    esac

    print -r -- "PowerLens: $action PowerLens"
    print -r -- "PowerLens: Shell mode: $shell_label"
    print -r -- "PowerLens: Install directory: $install_dir"
    print -r -- "PowerLens: Startup file: $zshrc"
    _powerlens_install_or_update "$install_dir" "$repo_url"

    case "$shell_mode" in
        omz) _powerlens_configure_omz "$zshrc" "$install_dir" ;;
        zsh) _powerlens_configure_plain_zsh "$zshrc" "$install_dir" ;;
    esac

    print -r -- "PowerLens: Ready. Restart your shell with:"
    print -r -- "exec zsh"
}

trap _powerlens_cleanup_temporary_files EXIT HUP INT TERM
_powerlens_main "$@"
