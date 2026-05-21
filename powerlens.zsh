# PowerLens core — loaded by powerlens.plugin.zsh

_POWERLENS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/powerlens"
_POWERLENS_PIDFILE="$_POWERLENS_CACHE/daemon.pid"
_POWERLENS_COUNTER="$_POWERLENS_CACHE/sessions"

# Detect arch and set binary path
if [[ "$(uname -m)" == "arm64" ]]; then
    _powerlens_bin="${0:h}/bin/powerlens-fetch-arm64"
else
    _powerlens_bin="${0:h}/bin/powerlens-fetch-amd64"
fi

# Returns 0 (true) if running inside an SSH session
_powerlens_is_ssh() {
    [[ -n "$SSH_TTY" || -n "$SSH_CONNECTION" || -n "$SSH_CLIENT" ]]
}

# Degraded RPROMPT — all values shown as --
_powerlens_degraded() {
    local g="%{\e[38;2;68;68;68m%}"  # #444444
    local r="%{\e[0m%}"
    print -n "${g}⚡ --W 🔋 --% ⚙ --% 🧠 --% ↑ -- ↓ --${r}"
}

# Entry point called by plugin.zsh after sourcing
_powerlens_init() {
    if _powerlens_is_ssh; then
        # In SSH: just set a static degraded prompt, no daemon
        RPROMPT="$(_powerlens_degraded)"
        return
    fi
    _powerlens_start_daemon
    precmd() { _powerlens_update_rprompt }
    zshexit() { _powerlens_stop_daemon }
}
