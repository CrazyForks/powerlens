#!/usr/bin/env zsh
setopt errexit

PASS=0; FAIL=0
assert_eq() {
    local desc=$1 got=$2 want=$3
    if [[ "$got" == "$want" ]]; then
        (( ++PASS )); print "  PASS: $desc"
    else
        (( ++FAIL )); print "  FAIL: $desc — got '$got', want '$want'"
    fi
}

# Source plugin defaults
POWERLENS_MODE=compact
POWERLENS_COLOR_MODE=multi
POWERLENS_SHOW_BATTERY=true; POWERLENS_SHOW_CPU=true
POWERLENS_SHOW_MEM=true; POWERLENS_SHOW_NET=true
POWERLENS_NET_IFACE=auto; POWERLENS_REFRESH=2
POWERLENS_THRESH_POWER_IDLE=10; POWERLENS_THRESH_POWER_LIGHT=30; POWERLENS_THRESH_POWER_MODERATE=50
POWERLENS_THRESH_CPU_IDLE=30; POWERLENS_THRESH_CPU_LIGHT=60; POWERLENS_THRESH_CPU_MODERATE=85
POWERLENS_THRESH_MEM_IDLE=50; POWERLENS_THRESH_MEM_LIGHT=70; POWERLENS_THRESH_MEM_MODERATE=85
POWERLENS_ALERT_POWER=50; POWERLENS_ALERT_CPU=80; POWERLENS_ALERT_MEM=85

source "${0:h}/../powerlens.zsh"

print "\n=== SSH guard ==="
SSH_TTY="/dev/ttys001"
assert_eq "_powerlens_is_ssh returns true in SSH" "$(_powerlens_is_ssh && echo yes || echo no)" "yes"
unset SSH_TTY

print "\n=== Degraded output ==="
out=$(_powerlens_degraded)
assert_eq "degraded contains --W" "${out//[^-]/}" "$(printf '%0.s-' {1..12})"

print "\nResults: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
