# CPU Temperature Feature — Design Spec

**Date:** 2026-05-21  
**Status:** Approved

---

## Overview

Add CPU temperature as a new independently-toggleable metric in the PowerLens RPROMPT. Temperature is collected in the Go daemon and rendered in the Zsh display layer alongside the existing CPU % metric.

---

## Display

**Position:** Between CPU % and Memory (⚙ → 🌡 → 🧠)

**compact mode:**
```
⚡38W 🔋87% ⚙34% 🌡55° 🧠62% ↑1.2M↓3.8M
```

**full mode:**
```
⚡ 38.4W 🔋 87% ⚙ 34.2% 🌡 55.0°C 🧠 62.1% ↑ 1.2MB/s ↓ 3.8MB/s
```

**Unavailable (`cpu_temp == -1`):** `🌡--°` (compact) / `🌡 --°C` (full)

---

## Architecture

### Go layer — `src/collect/temp_darwin.go` (new file)

Implements `GetCPUTemp() (float64, error)` returning °C, or -1 on failure.

**Apple Silicon path:**  
Extend the existing `powermetrics` call in `power_darwin.go`. The `cpu_power` sampler's plist output already contains `cpu_die_temperature_celsius` on M-series chips. Add `parsePowermetricsTemp(plist string) float64` alongside the existing `parsePowermetricsWatts`. To avoid a second `powermetrics` subprocess, `GetPower()` is refactored to return the raw plist string so both power and temperature can be parsed from one call.

**Intel path:**  
CGo + IOKit SMC access. Reads key `TC0D` (CPU die temperature), following the same pattern as battery/charging in `power_darwin.go`. Falls back to `-1` if the key is absent or the SMC cannot be opened.

### `src/collect/metrics.go` — Metrics struct

New field added:
```go
CpuTemp float64 `json:"cpu_temp"` // °C; -1 = unavailable
```

`All()` calls `GetCPUTemp()` and sets `m.CpuTemp`; failure is silently ignored (field stays -1).

### Test — `src/collect/temp_darwin_test.go`

Verifies `GetCPUTemp()` returns a value in [0, 120] or exactly -1. Follows the style of `cpu_test.go` and `mem_test.go`.

---

## Zsh layer

### `powerlens.plugin.zsh` — new defaults

```zsh
: ${POWERLENS_SHOW_TEMP:=true}

# multi mode thresholds (°C)
: ${POWERLENS_THRESH_TEMP_IDLE:=50}
: ${POWERLENS_THRESH_TEMP_LIGHT:=70}
: ${POWERLENS_THRESH_TEMP_MODERATE:=85}

# alert mode threshold
: ${POWERLENS_ALERT_TEMP:=80}
```

### `powerlens.zsh` — changes

- `_powerlens_color()`: add `temp` case using the same 4-level gradient logic as `cpu` and `mem`
- `_powerlens_format()`: parse `cpu_temp` from JSON; insert `🌡` block after CPU %, before memory; skip if `POWERLENS_SHOW_TEMP != true`
- `_powerlens_degraded()`: include `🌡 --°` in the degraded string

---

## Color thresholds (multi mode)

| Range     | Color   | Hex       | Label    |
|-----------|---------|-----------|----------|
| < 50°C    | Green   | `#00FF9F` | Idle     |
| 50–70°C   | Blue    | `#00D4FF` | Light    |
| 70–85°C   | Pink    | `#FF006E` | Moderate |
| ≥ 85°C    | Orange  | `#FF9500` | Hot      |

Alert mode default threshold: **80°C** → orange; below → gray (`#aaaaaa`).

---

## Error handling

- Any failure in `GetCPUTemp()` returns `-1`; callers never crash
- Zsh renders `🌡--°` when `cpu_temp == -1`; all other metrics unaffected
- `POWERLENS_SHOW_TEMP=false` skips the metric entirely with zero overhead

---

## Binary rebuild

CGo changes require recompiling both architectures:
```bash
make all   # produces bin/powerlens-fetch-arm64 and bin/powerlens-fetch-amd64
```
Updated binaries are committed to the repo (existing workflow).
