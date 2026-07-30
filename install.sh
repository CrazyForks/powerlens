#!/usr/bin/env zsh
setopt errexit nounset pipefail

typeset -gr POWERLENS_DEFAULT_REPO_URL="https://github.com/luyangkk/powerlens.git"
typeset -gr POWERLENS_MARKER_START="# >>> PowerLens installer >>>"
typeset -gr POWERLENS_MARKER_END="# <<< PowerLens installer <<<"

_powerlens_die() {
    print -u2 "PowerLens: $1"
    return 1
}

_powerlens_validate_install() {
    local install_dir=$1 binary

    case "$(uname -m)" in
        arm64) binary="bin/powerlens-fetch-arm64" ;;
        x86_64) binary="bin/powerlens-fetch-amd64" ;;
        *) _powerlens_die "unsupported Mac architecture: $(uname -m)" ;;
    esac

    [[ -f "$install_dir/powerlens.plugin.zsh" ]] || _powerlens_die "missing powerlens.plugin.zsh in $install_dir"
    [[ -f "$install_dir/powerlens.zsh" ]] || _powerlens_die "missing powerlens.zsh in $install_dir"
    [[ -x "$install_dir/$binary" ]] || _powerlens_die "missing executable $binary in $install_dir"
}

_powerlens_install_or_update() {
    local install_dir=$1 repo_url=$2
    local parent_dir=${install_dir:h} temporary_dir

    if [[ -e "$install_dir" || -L "$install_dir" ]]; then
        _powerlens_validate_install "$install_dir"
        return
    fi

    mkdir -p -- "$parent_dir"
    temporary_dir=$(mktemp -d "$parent_dir/.powerlens-install-XXXXXX") || return 1

    if ! git clone --branch main --single-branch -- "$repo_url" "$temporary_dir"; then
        rm -rf -- "$temporary_dir"
        return 1
    fi

    if ! _powerlens_validate_install "$temporary_dir"; then
        rm -rf -- "$temporary_dir"
        return 1
    fi

    if ! mv -- "$temporary_dir" "$install_dir"; then
        rm -rf -- "$temporary_dir"
        return 1
    fi
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
        _powerlens_die "could not detect zsh or Oh My Zsh"
        return 1
    fi
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

_powerlens_configure_plain_zsh() {
    local zshrc=$1 install_dir=$2
    local plugin_path="$install_dir/powerlens.plugin.zsh"
    local temporary_zshrc backup_path

    mkdir -p -- "${zshrc:h}"
    [[ -e "$zshrc" ]] || : > "$zshrc"

    if grep -E '^[[:space:]]*(source|\\.)[[:space:]]+' "$zshrc" | grep -F -q -- "$plugin_path"; then
        return
    fi

    backup_path="${zshrc}.powerlens-backup-$(date +%Y%m%d-%H%M%S)"
    cp -- "$zshrc" "$backup_path"

    temporary_zshrc=$(mktemp "${zshrc}.powerlens-tmp-XXXXXX") || return 1
    if ! {
        cat -- "$zshrc"
        print
        print -- "$POWERLENS_MARKER_START"
        print -r -- "source ${(qqq)plugin_path}"
        print -- "$POWERLENS_MARKER_END"
    } > "$temporary_zshrc"; then
        rm -f -- "$temporary_zshrc"
        return 1
    fi

    if ! mv -- "$temporary_zshrc" "$zshrc"; then
        rm -f -- "$temporary_zshrc"
        return 1
    fi
}

_powerlens_configure_omz() {
    local zshrc=$1 install_dir=$2
    local loader_count temporary_zshrc backup_path

    loader_count=$(_powerlens_omz_loader_count "$zshrc")
    if [[ "$loader_count" != 1 ]]; then
        _powerlens_die "expected exactly one active Oh My Zsh loader in $zshrc"
        return 1
    fi

    _powerlens_plugins_contain_powerlens "$zshrc" && return

    backup_path="${zshrc}.powerlens-backup-$(date +%Y%m%d-%H%M%S)"
    cp -- "$zshrc" "$backup_path"

    temporary_zshrc=$(mktemp "${zshrc}.powerlens-tmp-XXXXXX") || return 1
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
        rm -f -- "$temporary_zshrc"
        return 1
    fi

    if ! mv -- "$temporary_zshrc" "$zshrc"; then
        rm -f -- "$temporary_zshrc"
        return 1
    fi
}

_powerlens_main() {
    local shell_mode zshrc repo_url install_dir

    zshrc=${POWERLENS_ZSHRC:-"$HOME/.zshrc"}
    repo_url=${POWERLENS_REPO_URL:-$POWERLENS_DEFAULT_REPO_URL}
    shell_mode=$(_powerlens_detect_shell_mode "$zshrc") || return 1
    install_dir=${POWERLENS_INSTALL_DIR:-$(_powerlens_default_install_dir "$shell_mode")}

    [[ "$install_dir" == /* ]] || install_dir="$PWD/$install_dir"
    _powerlens_install_or_update "$install_dir" "$repo_url"

    case "$shell_mode" in
        omz) _powerlens_configure_omz "$zshrc" "$install_dir" ;;
        zsh) _powerlens_configure_plain_zsh "$zshrc" "$install_dir" ;;
    esac
}

_powerlens_main "$@"
