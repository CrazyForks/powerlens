# PowerLens - Zsh Plugin Design Specification

**Date**: 2026-05-21
**Status**: Draft (v3 — 5-metric expansion)

---

## 1. Concept & Vision

PowerLens is a lightweight zsh plugin that displays real-time system metrics in the right prompt area (RPROMPT): power consumption, battery, CPU usage, memory usage, and network I/O. It provides instant visual feedback without disrupting the command input workflow, embodying a **Cyberpunk aesthetic** with neon colors on dark terminals.

The design philosophy: **information density without cognitive overhead** — all readings are glanceable, not requiring focused attention to interpret.

---

## 2. Design Language

### 2.1 Aesthetic Direction
**Cyberpunk/Neon Terminal** — Inspired by retro-futuristic interfaces, terminal hacker aesthetics, and modern TUI tools like btop.

### 2.2 Color Palette

Two color modes are supported (see §4.2):

**`multi` mode — 4-level independent color per metric:**

| Level | Color | Hex |
|-------|-------|-----|
| Idle | Neon Green | `#00FF9F` |
| Light | Electric Cyan | `#00D4FF` |
| Moderate | Hot Pink/Magenta | `#FF006E` |
| Peak | Warning Orange | `#FF9500` |

**`alert` mode — neutral + single alert threshold:**

| State | Color | Hex |
|-------|-------|-----|
| Normal | Neutral Gray | `#aaaaaa` |
| Alert | Warning Orange | `#FF9500` |

**Background Terminal**: Assumes dark terminal. Optimized for `T="builtin" print` compatible colors.

### 2.3 Metric Thresholds

**`multi` mode thresholds (all configurable):**

| Metric | Idle | Light | Moderate | Peak |
|--------|------|-------|----------|------|
| ⚡ Power | 0–10W | 10–30W | 30–50W | 50W+ |
| ⚙ CPU | 0–30% | 30–60% | 60–85% | 85%+ |
| 🧠 Memory | 0–50% | 50–70% | 70–85% | 85%+ |
| 🔋 Battery | follows power level color | — | — | — |
| ↑↓ Network | fixed neutral gray (no threshold — bandwidth baseline varies per user) | — | — | — |

**`alert` mode single thresholds (all configurable):**

| Metric | Default Alert |
|--------|--------------|
| ⚡ Power | 50W |
| ⚙ CPU | 80% |
| 🧠 Memory | 85% |

### 2.4 Display Format

**Display priority order:** ⚡ Power → 🔋 Battery → ⚙ CPU → 🧠 Memory → ↑↓ Network

**Compact mode (default):**
```
⚡38W 🔋87% ⚙34% 🧠62% ↑1.2M↓3.8M
```
- Values abbreviated: no decimals on power/CPU/mem, unit simplified to `M` for MB/s
- No space between value and unit

**Full mode (`POWERLENS_MODE=full`):**
```
⚡ 38.4W 🔋 87% ⚙ 47.3% 🧠 76.8% ↑ 2.4MB/s ↓ 8.1MB/s
```
- Values unabbreviated with one decimal place
- Explicit units, spaces around values

**Degraded (daemon down / stale data):**
```
⚡ --W  🔋 --%  ⚙ --%  🧠 --%  ↑ --  ↓ --
```
All values replaced with `--` in neutral gray `#444444`.

---

## 3. Architecture

### 3.1 Project Structure

```
powerlens/
├── powerlens.plugin.zsh          # OMZ plugin entry point
├── powerlens.zsh                 # Core plugin logic
├── scripts/
│   └── powerlens-daemon.zsh      # Daemon fallback (superseded by Go binary)
├── bin/
│   ├── powerlens-fetch-arm64     # Apple Silicon (contains gopsutil, ~7MB)
│   └── powerlens-fetch-amd64     # Intel
├── Makefile                      # Build-from-source target
└── README.md
```

### 3.2 Component Interaction

```
┌─────────────────────────────────────────────────────────────┐
│                        Zsh Prompt                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ $PWD ❯         ⚡38W 🔋87% ⚙34% 🧠62% ↑1.2M↓3.8M  │   │
│  └─────────────────────────────────────────────────────┘   │
│                          ↑ precmd hook                     │
│  ┌───────────────────────▼─────────────────────────────┐   │
│  │              PowerLens Plugin Logic                  │   │
│  │  • Reads metrics.json only when mtime changes        │   │
│  │  • Checks data freshness (>10s → restart daemon)    │   │
│  │  • Applies color mode (multi | alert)                │   │
│  │  • Formats compact or full string → RPROMPT          │   │
│  └───────────────────────┬─────────────────────────────┘   │
│                          ↓                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │     Go Daemon — powerlens-fetch (singleton)         │   │
│  │  • IOKit → power                                    │   │
│  │  • gopsutil/cpu → CPU %                             │   │
│  │  • gopsutil/mem → memory %                          │   │
│  │  • gopsutil/net → ↑↓ bytes/s (iface: auto/en0/all) │   │
│  │  • Writes metrics.json every N seconds              │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 Data Flow

1. **Init**: Plugin detects arch, selects binary; skips daemon in SSH (`$SSH_TTY` / `$SSH_CONNECTION`)
2. **Singleton**: PID file check; start daemon if not running; increment session counter
3. **Fetch**: Daemon collects all 5 metrics every `POWERLENS_REFRESH` seconds, writes `metrics.json`
4. **Display**: `precmd` compares `metrics.json` mtime to last-seen; re-parses JSON only on change
5. **Freshness**: If `ts` in JSON is >10s old, daemon assumed dead → show `--` → restart daemon
6. **Cleanup**: `zshexit` decrements session counter; last shell kills daemon, removes PID file

---

## 4. Features & Interactions

### 4.1 Core Features

| Feature | Description |
|---------|-------------|
| 5-metric display | Power, battery, CPU, memory, network in priority order |
| Two color modes | `multi` (4-level per metric) or `alert` (neutral + orange on threshold) |
| Two display modes | `compact` (abbreviated) or `full` (unabbreviated with units) |
| Per-metric toggle | Each metric can be independently disabled |
| Daemon singleton | One shared daemon across all terminal windows |
| Crash recovery | Stale data (>10s) triggers auto-restart |
| SSH-aware | Daemon skipped in remote shells; shows `--` gracefully |
| Network interface | Configurable: auto-detect primary, specific iface, or all combined |

### 4.2 Configuration Options

```zsh
# ~/.zshrc

# ── Display mode ──────────────────────────────────
POWERLENS_MODE=compact          # compact | full
POWERLENS_COLOR_MODE=multi      # multi | alert

# ── Per-metric toggles ────────────────────────────
POWERLENS_SHOW_BATTERY=true
POWERLENS_SHOW_CPU=true
POWERLENS_SHOW_MEM=true
POWERLENS_SHOW_NET=true

# ── Network ───────────────────────────────────────
POWERLENS_NET_IFACE=auto        # auto | en0 | all
POWERLENS_REFRESH=2             # Daemon poll interval (seconds)

# ── multi mode thresholds ─────────────────────────
POWERLENS_THRESH_POWER_IDLE=10
POWERLENS_THRESH_POWER_LIGHT=30
POWERLENS_THRESH_POWER_MODERATE=50
POWERLENS_THRESH_CPU_IDLE=30
POWERLENS_THRESH_CPU_LIGHT=60
POWERLENS_THRESH_CPU_MODERATE=85
POWERLENS_THRESH_MEM_IDLE=50
POWERLENS_THRESH_MEM_LIGHT=70
POWERLENS_THRESH_MEM_MODERATE=85

# ── alert mode single thresholds ─────────────────
POWERLENS_ALERT_POWER=50
POWERLENS_ALERT_CPU=80
POWERLENS_ALERT_MEM=85

# ── opt-in features ───────────────────────────────
POWERLENS_USE_POWERMETRICS=false  # sudo powermetrics (more accurate, needs elevation)
```

### 4.3 Behavior

| Scenario | Behavior |
|----------|----------|
| Normal | All enabled metrics shown in priority order |
| Daemon stale (>10s) | All values → `--`, daemon restarted |
| SSH remote shell | Daemon skipped; all values → `--` gracefully |
| No battery (desktop Mac) | Battery element hidden; `POWERLENS_SHOW_BATTERY` auto-false |
| Charging | `🔋` → `🔌` |
| Very low power (<5W) | Sleep indicator |
| `alert` mode, under threshold | Neutral gray `#aaaaaa` |
| `alert` mode, over threshold | Warning orange `#FF9500` per-metric |

### 4.4 Terminal Compatibility

- **Tested**: iTerm2, Terminal.app, Kitty, Alacritty, Warp
- **Feature detection**: true color check; fallback to 256-color approximate
- **SSH**: `$SSH_TTY` / `$SSH_CONNECTION` detection disables daemon

---

## 5. Data Source & Go Binary

### 5.1 JSON Schema

Daemon writes to `${XDG_CACHE_HOME:-$HOME/.cache}/powerlens/metrics.json`:

```json
{
  "power":    42.7,
  "battery":  87,
  "charging": false,
  "cpu":      34.2,
  "mem":      62.1,
  "net_up":   1.2,
  "net_down": 3.8,
  "net_iface":"en0",
  "ts":       1706000000
}
```

### 5.2 Data Sources (Go binary)

```go
func CollectMetrics(cfg Config) Metrics {
    // power    — IOKit (no sudo); fallback: battery current×voltage
    // battery  — IOKit
    // cpu      — gopsutil/cpu.Percent(interval, perCPU=false)
    // mem      — gopsutil/mem.VirtualMemory().UsedPercent
    // net      — gopsutil/net.IOCounters(); byte delta ÷ elapsed → MB/s stored in JSON
    //            iface selection: auto (route table primary) | explicit | sum-all
    // ts       — time.Now().Unix()
}
```

Network: daemon keeps previous `IOCounters` sample in memory. Each cycle: `(bytes_now - bytes_prev) / elapsed / 1_000_000` → MB/s stored in JSON. First sample after start emits `0.0` (no prior baseline).

### 5.3 Architecture Selection

```zsh
# powerlens.zsh
_powerlens_arch=$(uname -m)
[[ "$_powerlens_arch" == "arm64" ]] \
  && _powerlens_bin="${0:h}/bin/powerlens-fetch-arm64" \
  || _powerlens_bin="${0:h}/bin/powerlens-fetch-amd64"
```

### 5.4 macOS Gatekeeper

Binaries are ad-hoc signed (`codesign --sign -`). On block:
1. Plugin prints one-time `xattr -d com.apple.quarantine <binary>` guidance
2. `make install` (Go 1.21+) builds from source — no signing needed

### 5.5 Daemon Singleton & Lifecycle

```zsh
_POWERLENS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/powerlens"
_POWERLENS_PIDFILE="$_POWERLENS_CACHE/daemon.pid"
_POWERLENS_COUNTER="$_POWERLENS_CACHE/sessions"

_powerlens_start_daemon() {
  if [[ -f "$_POWERLENS_PIDFILE" ]] \
      && kill -0 "$(< "$_POWERLENS_PIDFILE")" 2>/dev/null; then
    return  # already running
  fi
  mkdir -p "$_POWERLENS_CACHE"
  "$_powerlens_bin" --daemon \
    --iface "$POWERLENS_NET_IFACE" \
    --refresh "$POWERLENS_REFRESH" &
  echo $! > "$_POWERLENS_PIDFILE"
  echo $(( $(< "$_POWERLENS_COUNTER" 2>/dev/null || echo 0) + 1 )) \
    > "$_POWERLENS_COUNTER"
}

_powerlens_stop_daemon() {
  local count=$(( $(< "$_POWERLENS_COUNTER" 2>/dev/null || echo 1) - 1 ))
  if (( count <= 0 )); then
    kill "$(< "$_POWERLENS_PIDFILE" 2>/dev/null)" 2>/dev/null
    rm -f "$_POWERLENS_PIDFILE" "$_POWERLENS_COUNTER"
  else
    echo "$count" > "$_POWERLENS_COUNTER"
  fi
}

zshexit() { _powerlens_stop_daemon }
```

### 5.6 precmd — Cache Reading & Color

```zsh
_powerlens_last_mtime=0
_powerlens_cached_rprompt=""

_powerlens_update_rprompt() {
  local cache="$_POWERLENS_CACHE/metrics.json"
  local mtime
  mtime=$(stat -f %m "$cache" 2>/dev/null) || {
    RPROMPT=$(_powerlens_degraded); return
  }

  if [[ "$mtime" != "$_powerlens_last_mtime" ]]; then
    local json ts now
    json=$(< "$cache")
    ts=$(  echo "$json" | grep -o '"ts":[0-9]*'    | grep -o '[0-9]*')
    now=$(date +%s)
    if (( now - ts > 10 )); then
      _powerlens_start_daemon
      RPROMPT=$(_powerlens_degraded); return
    fi
    _powerlens_last_mtime="$mtime"
    _powerlens_cached_rprompt=$(_powerlens_format "$json")
  fi

  RPROMPT="$_powerlens_cached_rprompt"
}

precmd() { _powerlens_update_rprompt }
```

Color dispatch in `_powerlens_format`:
- `multi`: each metric independently looks up its 4-level threshold table
- `alert`: each metric uses `#aaaaaa`; if value > `POWERLENS_ALERT_*`, use `#FF9500`

### 5.7 Performance Target

| Metric | Target |
|--------|--------|
| Daemon memory | < 10MB (gopsutil adds ~3MB vs power-only) |
| Daemon CPU | < 0.1% average |
| prompt render | < 5ms |
| Data fetch cycle | every 2s (configurable) |
| Terminal count → daemon count | N terminals → 1 daemon |

---

## 6. Installation

### 6.1 OMZ

```bash
git clone https://github.com/user/powerlens.git \
  ~/.oh-my-zsh/custom/plugins/powerlens
# Add to plugins=(...) in ~/.zshrc
```

### 6.2 Build from source

```bash
cd ~/.oh-my-zsh/custom/plugins/powerlens
make install   # requires Go 1.21+
```

### 6.3 First-run

1. Plugin detects arch → selects binary
2. Detects SSH → skips daemon if remote
3. Daemon singleton starts (or attaches to existing)
4. All 5 metrics appear immediately with defaults
5. No configuration required for basic use

---

## 7. File Manifest

| File | Purpose | Lines Est. |
|------|---------|------------|
| `powerlens.plugin.zsh` | OMZ registration | ~10 |
| `powerlens.zsh` | Hooks, singleton, color modes, formatting | ~280 |
| `bin/powerlens-fetch-arm64` | All-in-one binary (IOKit + gopsutil) | N/A |
| `bin/powerlens-fetch-amd64` | Intel build | N/A |
| `Makefile` | Build targets (arm64, amd64, universal) | ~40 |
| `README.md` | Install, config, Gatekeeper notes | ~300 |

---

## 8. Open Questions

- [ ] Support for multiple battery Macs (MagSafe + TB)?
- [ ] Integration with powerlevel10k geometry?
- [ ] Historical data mini-graph in expanded mode?
  - Unicode Braille block (`⣀⣄⣆⣇⣗⣷⣿`) — 8 samples in ~4 chars via ring buffer
- [ ] CI notarization via GitHub Actions + Apple Developer account?
- [ ] `POWERLENS_COLOR_MODE` toggle keybinding (e.g., switch multi↔alert without editing `.zshrc`)?

---

## 9. Success Metrics

- **Startup time**: < 100ms
- **Render time**: < 5ms per prompt
- **Accuracy**: power within 5% of system profiler; CPU/mem within 2% of Activity Monitor
- **Compatibility**: macOS 12+ (Monterey+), arm64 and amd64
- **Multi-window**: N terminals → 1 daemon
- **Resilience**: daemon crash detected in ≤10s, auto-recovered without user action
