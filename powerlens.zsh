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

# Returns hex color string for a metric value.
# Usage: _powerlens_color <metric> <value>
# metric: power | cpu | mem | net | battery
_powerlens_color() {
    local metric=$1 value=$2

    # Network and battery never get threshold color
    [[ "$metric" == "net" || "$metric" == "battery" ]] && {
        print -n "#aaaaaa"; return
    }

    if [[ "$POWERLENS_COLOR_MODE" == "alert" ]]; then
        local threshold
        case $metric in
            power) threshold=$POWERLENS_ALERT_POWER ;;
            cpu)   threshold=$POWERLENS_ALERT_CPU   ;;
            mem)   threshold=$POWERLENS_ALERT_MEM   ;;
        esac
        if (( value > threshold )); then
            print -n "#FF9500"
        else
            print -n "#aaaaaa"
        fi
        return
    fi

    # multi mode — 4-level threshold lookup
    local idle light moderate
    case $metric in
        power) idle=$POWERLENS_THRESH_POWER_IDLE; light=$POWERLENS_THRESH_POWER_LIGHT; moderate=$POWERLENS_THRESH_POWER_MODERATE ;;
        cpu)   idle=$POWERLENS_THRESH_CPU_IDLE;   light=$POWERLENS_THRESH_CPU_LIGHT;   moderate=$POWERLENS_THRESH_CPU_MODERATE ;;
        mem)   idle=$POWERLENS_THRESH_MEM_IDLE;   light=$POWERLENS_THRESH_MEM_LIGHT;   moderate=$POWERLENS_THRESH_MEM_MODERATE ;;
    esac

    if   (( value < idle     )); then print -n "#00FF9F"
    elif (( value < light    )); then print -n "#00D4FF"
    elif (( value < moderate )); then print -n "#FF006E"
    else                              print -n "#FF9500"
    fi
}

# Wraps a hex color around text for zsh prompt rendering.
_powerlens_wrap() {
    local hex=$1 text=$2
    local r=$(( 16#${hex[2,3]} ))
    local g=$(( 16#${hex[4,5]} ))
    local b=$(( 16#${hex[6,7]} ))
    print -n "%{\e[38;2;${r};${g};${b}m%}${text}%{\e[0m%}"
}

# Format a number: compact removes decimals, full keeps 1 decimal place.
_powerlens_fmt_num() {
    local val=$1
    if [[ "$POWERLENS_MODE" == "compact" ]]; then
        printf "%.0f" "$val"
    else
        printf "%.1f" "$val"
    fi
}

# Format MB/s value: compact → "1.2M", full → "1.2MB/s"
_powerlens_fmt_net() {
    local val=$1
    if [[ "$POWERLENS_MODE" == "compact" ]]; then
        printf "%.1fM" "$val"
    else
        printf "%.1fMB/s" "$val"
    fi
}

# Format all metrics from JSON into a colored RPROMPT string.
_powerlens_format() {
    local json=$1
    local power battery charging cpu mem net_up net_down
    power=$(_powerlens_jget "$json" "power")
    battery=$(_powerlens_jget "$json" "battery")
    charging=$(_powerlens_jget "$json" "charging")
    cpu=$(_powerlens_jget "$json" "cpu")
    mem=$(_powerlens_jget "$json" "mem")
    net_up=$(_powerlens_jget "$json" "net_up")
    net_down=$(_powerlens_jget "$json" "net_down")

    local sep=" "
    local result=""

    # ⚡ Power
    local pc=$(_powerlens_color power ${power%%.*})
    result+="$(_powerlens_wrap $pc "⚡$(_powerlens_fmt_num $power)W")"

    # 🔋 Battery (follows power color)
    if [[ "$POWERLENS_SHOW_BATTERY" == "true" ]]; then
        local icon="🔋"
        [[ "$charging" == "true" ]] && icon="🔌"
        result+="${sep}$(_powerlens_wrap $pc "${icon}${battery}%")"
    fi

    # ⚙ CPU
    if [[ "$POWERLENS_SHOW_CPU" == "true" ]]; then
        local cc=$(_powerlens_color cpu ${cpu%%.*})
        result+="${sep}$(_powerlens_wrap $cc "⚙$(_powerlens_fmt_num $cpu)%")"
    fi

    # 🧠 Memory
    if [[ "$POWERLENS_SHOW_MEM" == "true" ]]; then
        local mc=$(_powerlens_color mem ${mem%%.*})
        result+="${sep}$(_powerlens_wrap $mc "🧠$(_powerlens_fmt_num $mem)%")"
    fi

    # ↑↓ Network
    if [[ "$POWERLENS_SHOW_NET" == "true" ]]; then
        local nc=$(_powerlens_color net 0)
        local net_str
        if [[ "$POWERLENS_MODE" == "compact" ]]; then
            net_str="↑$(_powerlens_fmt_net $net_up)↓$(_powerlens_fmt_net $net_down)"
        else
            net_str="↑ $(_powerlens_fmt_net $net_up)  ↓ $(_powerlens_fmt_net $net_down)"
        fi
        result+="${sep}$(_powerlens_wrap $nc "$net_str")"
    fi

    print -n "$result"
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
