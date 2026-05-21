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

_powerlens_start_daemon() {
    if [[ -f "$_POWERLENS_PIDFILE" ]] \
        && kill -0 "$(< "$_POWERLENS_PIDFILE")" 2>/dev/null; then
        return  # already running
    fi
    mkdir -p "$_POWERLENS_CACHE"
    "$_powerlens_bin" --daemon \
        --iface "$POWERLENS_NET_IFACE" \
        --refresh "$POWERLENS_REFRESH" &!
    echo $! > "$_POWERLENS_PIDFILE"
    echo $(( ${$(< "$_POWERLENS_COUNTER" 2>/dev/null):-0} + 1 )) \
        > "$_POWERLENS_COUNTER"
}

_powerlens_stop_daemon() {
    local count=$(( ${$(< "$_POWERLENS_COUNTER" 2>/dev/null):-1} - 1 ))
    if (( count <= 0 )); then
        kill "$(< "$_POWERLENS_PIDFILE" 2>/dev/null)" 2>/dev/null
        rm -f "$_POWERLENS_PIDFILE" "$_POWERLENS_COUNTER"
    else
        echo "$count" > "$_POWERLENS_COUNTER"
    fi
}

_powerlens_last_mtime=0
_powerlens_cached_rprompt=""

# Extract a scalar value from a flat JSON string by key name.
_powerlens_jget() {
    local json=$1 key=$2 val
    if [[ $json =~ "\"${key}\":\"([^\"]+)\"" ]]; then
        val="${match[1]}"
    elif [[ $json =~ "\"${key}\":([^,}]+)" ]]; then
        val="${match[1]}"
        val="${val// /}"
    fi
    print -n "$val"
}

_powerlens_update_rprompt() {
    local cache="$_POWERLENS_CACHE/metrics.json"
    local mtime
    mtime=$(stat -f %m "$cache" 2>/dev/null) || {
        RPROMPT="$(_powerlens_degraded)"; return
    }

    if [[ "$mtime" != "$_powerlens_last_mtime" ]]; then
        local json ts now
        json=$(< "$cache")
        ts=$(_powerlens_jget "$json" "ts")
        now=$(date +%s)

        if (( now - ts > 10 )); then
            _powerlens_start_daemon
            RPROMPT="$(_powerlens_degraded)"; return
        fi

        _powerlens_last_mtime="$mtime"
        _powerlens_cached_rprompt=$(_powerlens_format "$json")
    fi

    RPROMPT="$_powerlens_cached_rprompt"
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
