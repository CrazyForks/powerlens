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

_powerlens_main() {
    local shell_mode=${POWERLENS_SHELL_MODE:-zsh}
    local zshrc=${POWERLENS_ZSHRC:-"$HOME/.zshrc"}
    local repo_url=${POWERLENS_REPO_URL:-$POWERLENS_DEFAULT_REPO_URL}
    local install_dir=${POWERLENS_INSTALL_DIR:-"${XDG_DATA_HOME:-$HOME/.local/share}/powerlens"}

    [[ "$shell_mode" == zsh ]] || _powerlens_die "only plain zsh is supported"

    [[ "$install_dir" == /* ]] || install_dir="$PWD/$install_dir"
    _powerlens_install_or_update "$install_dir" "$repo_url"
    _powerlens_configure_plain_zsh "$zshrc" "$install_dir"
}

_powerlens_main "$@"
