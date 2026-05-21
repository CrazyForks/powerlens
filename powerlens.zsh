# PowerLens core — loaded by powerlens.plugin.zsh
zmodload zsh/datetime

_POWERLENS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/powerlens"
_POWERLENS_PIDFILE="$_POWERLENS_CACHE/daemon.pid"
_POWERLENS_COUNTER="$_POWERLENS_CACHE/sessions"

if [[ "$(uname -m)" == "arm64" ]]; then
    _powerlens_bin="${0:h}/bin/powerlens-fetch-arm64"
else
    _powerlens_bin="${0:h}/bin/powerlens-fetch-amd64"
fi

# Degraded RPROMPT — all values shown as --
_powerlens_degraded() {
    _powerlens_wrap "#444444" "⚡ --W 🔋 --% ⚙ --% 🌡 --° 🧠 --% ↑ -- ↓ --"
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
    local _prev=0
    [[ -f "$_POWERLENS_COUNTER" ]] && _prev=$(< "$_POWERLENS_COUNTER")
    echo $(( _prev + 1 )) > "$_POWERLENS_COUNTER"
}

_powerlens_stop_daemon() {
    local _prev=1
    [[ -f "$_POWERLENS_COUNTER" ]] && _prev=$(< "$_POWERLENS_COUNTER")
    local count=$(( _prev - 1 ))
    if (( count <= 0 )); then
        [[ -f "$_POWERLENS_PIDFILE" ]] && kill "$(< "$_POWERLENS_PIDFILE")" 2>/dev/null
        rm -f "$_POWERLENS_PIDFILE" "$_POWERLENS_COUNTER"
    else
        echo "$count" > "$_POWERLENS_COUNTER"
    fi
}

_powerlens_last_mtime=0
_powerlens_cached_rprompt=""
_powerlens_last_degraded=0
_POWERLENS_DEGRADED=""

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
        RPROMPT="$_POWERLENS_DEGRADED"
        (( _powerlens_last_degraded )) && return 1
        _powerlens_last_degraded=1; return 0
    }

    if [[ "$mtime" != "$_powerlens_last_mtime" ]]; then
        local json ts
        json=$(< "$cache")
        ts=$(_powerlens_jget "$json" "ts")
        _powerlens_last_mtime="$mtime"

        if (( EPOCHSECONDS - ts > 10 )); then
            _powerlens_start_daemon
            _powerlens_cached_rprompt="$_POWERLENS_DEGRADED"
            RPROMPT="$_POWERLENS_DEGRADED"
            (( _powerlens_last_degraded )) && return 1
            _powerlens_last_degraded=1; return 0
        fi

        _powerlens_last_degraded=0
        _powerlens_cached_rprompt=$(_powerlens_format "$json")
        RPROMPT="$_powerlens_cached_rprompt"
        return 0
    fi

    RPROMPT="$_powerlens_cached_rprompt"
    return 1
}

_powerlens_color() {
    local metric=$1 value=${2%%.*}

    [[ "$metric" == "net" || "$metric" == "battery" ]] && {
        print -n "#aaaaaa"; return
    }

    if [[ "$POWERLENS_COLOR_MODE" == "alert" ]]; then
        local threshold
        case $metric in
            power) threshold=$POWERLENS_ALERT_POWER ;;
            cpu)   threshold=$POWERLENS_ALERT_CPU   ;;
            mem)   threshold=$POWERLENS_ALERT_MEM   ;;
            temp)  threshold=$POWERLENS_ALERT_TEMP  ;;
        esac
        if (( value > threshold )); then
            print -n "#FF9500"
        else
            print -n "#aaaaaa"
        fi
        return
    fi

    local idle light moderate
    case $metric in
        power) idle=$POWERLENS_THRESH_POWER_IDLE; light=$POWERLENS_THRESH_POWER_LIGHT; moderate=$POWERLENS_THRESH_POWER_MODERATE ;;
        cpu)   idle=$POWERLENS_THRESH_CPU_IDLE;   light=$POWERLENS_THRESH_CPU_LIGHT;   moderate=$POWERLENS_THRESH_CPU_MODERATE ;;
        mem)   idle=$POWERLENS_THRESH_MEM_IDLE;   light=$POWERLENS_THRESH_MEM_LIGHT;   moderate=$POWERLENS_THRESH_MEM_MODERATE ;;
        temp)  idle=$POWERLENS_THRESH_TEMP_IDLE;  light=$POWERLENS_THRESH_TEMP_LIGHT;  moderate=$POWERLENS_THRESH_TEMP_MODERATE ;;
    esac

    if   (( value < idle     )); then print -n "#00FF9F"
    elif (( value < light    )); then print -n "#00D4FF"
    elif (( value < moderate )); then print -n "#FF006E"
    else                              print -n "#FF9500"
    fi
}

_powerlens_wrap() {
    local hex=$1 text=$2
    local r=$(( 16#${hex[2,3]} ))
    local g=$(( 16#${hex[4,5]} ))
    local b=$(( 16#${hex[6,7]} ))
    print -n "%{\e[38;2;${r};${g};${b}m%}${text}%{\e[0m%}"
}

_powerlens_fmt_num() {
    local val=$1
    if [[ "$POWERLENS_MODE" == "compact" ]]; then
        printf "%.0f" "$val"
    else
        printf "%.1f" "$val"
    fi
}

_powerlens_fmt_net() {
    local val=$1
    if [[ "$POWERLENS_MODE" == "compact" ]]; then
        printf "%.1fM" "$val"
    else
        printf "%.1fMB/s" "$val"
    fi
}

_powerlens_format() {
    local json=$1
    local power battery charging cpu mem net_up net_down cpu_temp
    power=$(_powerlens_jget "$json" "power")
    battery=$(_powerlens_jget "$json" "battery")
    charging=$(_powerlens_jget "$json" "charging")
    cpu=$(_powerlens_jget "$json" "cpu")
    mem=$(_powerlens_jget "$json" "mem")
    cpu_temp=$(_powerlens_jget "$json" "cpu_temp")
    net_up=$(_powerlens_jget "$json" "net_up")
    net_down=$(_powerlens_jget "$json" "net_down")

    local sep=" "
    local result=""

    local pc=$(_powerlens_color power $power)
    result+="$(_powerlens_wrap $pc "⚡$(_powerlens_fmt_num $power)W")"

    # 🔋 Battery (follows power color)
    if [[ "$POWERLENS_SHOW_BATTERY" == "true" ]]; then
        local icon="🔋"
        [[ "$charging" == "true" ]] && icon="🔌"
        result+="${sep}$(_powerlens_wrap $pc "${icon}${battery}%%")"
    fi

    if [[ "$POWERLENS_SHOW_CPU" == "true" ]]; then
        local cc=$(_powerlens_color cpu $cpu)
        result+="${sep}$(_powerlens_wrap $cc "⚙$(_powerlens_fmt_num $cpu)%%")"
    fi

    if [[ "$POWERLENS_SHOW_TEMP" == "true" ]]; then
        local tc temp_str
        if [[ "$cpu_temp" == "-1" || -z "$cpu_temp" ]]; then
            tc="#aaaaaa"
            if [[ "$POWERLENS_MODE" == "full" ]]; then
                temp_str="🌡 --°C"
            else
                temp_str="🌡--°"
            fi
        else
            tc=$(_powerlens_color temp ${cpu_temp%%.*})
            if [[ "$POWERLENS_MODE" == "full" ]]; then
                temp_str="🌡 $(_powerlens_fmt_num $cpu_temp)°C"
            else
                temp_str="🌡$(_powerlens_fmt_num $cpu_temp)°"
            fi
        fi
        result+="${sep}$(_powerlens_wrap $tc "$temp_str")"
    fi

    if [[ "$POWERLENS_SHOW_MEM" == "true" ]]; then
        local mc=$(_powerlens_color mem $mem)
        result+="${sep}$(_powerlens_wrap $mc "🧠$(_powerlens_fmt_num $mem)%%")"
    fi

    if [[ "$POWERLENS_SHOW_NET" == "true" ]]; then
        local nc="#aaaaaa"
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

# Clear RPROMPT on submit so it doesn't accumulate in scrollback.
_powerlens_zle_line_finish() {
    RPROMPT=""
    zle reset-prompt
}

# Only redraws when ZLE is active (guards against non-interactive contexts).
TRAPALRM() {
    [[ -n "$ZLE_STATE" ]] && _powerlens_update_rprompt && zle reset-prompt
}

_powerlens_init() {
    _POWERLENS_DEGRADED=$(_powerlens_degraded)
    _powerlens_start_daemon
    precmd() { _powerlens_update_rprompt }
    zshexit() { _powerlens_stop_daemon }
    zle -N zle-line-finish _powerlens_zle_line_finish
    if (( ${TMOUT:-0} == 0 || ${TMOUT:-0} > POWERLENS_REFRESH )); then
        TMOUT=$POWERLENS_REFRESH
    fi
}
