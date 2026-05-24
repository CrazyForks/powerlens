# PowerLens — system metrics in RPROMPT
# Source this file via Oh-My-Zsh plugins=(... powerlens ...)

# ── Display ─────────────────────────────────────────────────
: ${POWERLENS_MODE:=compact}          # compact | full
: ${POWERLENS_COLOR_MODE:=multi}      # multi | alert

# ── Per-metric toggles ───────────────────────────────────────
: ${POWERLENS_SHOW_BATTERY:=true}
: ${POWERLENS_SHOW_CPU:=true}
: ${POWERLENS_SHOW_MEM:=true}
: ${POWERLENS_SHOW_NET:=true}
: ${POWERLENS_SHOW_TEMP:=true}

# ── Network ─────────────────────────────────────────────────
: ${POWERLENS_NET_IFACE:=default}     # default | wifi | ethernet
: ${POWERLENS_REFRESH:=2}

# ── multi mode thresholds ───────────────────────────────────
: ${POWERLENS_THRESH_POWER_IDLE:=10}
: ${POWERLENS_THRESH_POWER_LIGHT:=30}
: ${POWERLENS_THRESH_POWER_MODERATE:=50}
: ${POWERLENS_THRESH_CPU_IDLE:=30}
: ${POWERLENS_THRESH_CPU_LIGHT:=60}
: ${POWERLENS_THRESH_CPU_MODERATE:=85}
: ${POWERLENS_THRESH_MEM_IDLE:=50}
: ${POWERLENS_THRESH_MEM_LIGHT:=70}
: ${POWERLENS_THRESH_MEM_MODERATE:=85}
: ${POWERLENS_THRESH_TEMP_IDLE:=50}
: ${POWERLENS_THRESH_TEMP_LIGHT:=70}
: ${POWERLENS_THRESH_TEMP_MODERATE:=85}

# ── alert mode thresholds ───────────────────────────────────
: ${POWERLENS_ALERT_POWER:=50}
: ${POWERLENS_ALERT_CPU:=80}
: ${POWERLENS_ALERT_MEM:=85}
: ${POWERLENS_ALERT_TEMP:=80}

# Load core plugin
source "${0:h}/powerlens.zsh"

# Initialize on load
_powerlens_init
