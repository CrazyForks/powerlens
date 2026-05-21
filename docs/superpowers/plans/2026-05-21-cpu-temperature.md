# CPU Temperature Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add CPU temperature as a new independently-toggleable `🌡` metric between CPU % and Memory in PowerLens RPROMPT.

**Architecture:** `GetPower()` is refactored into `GetPowerAndTemp()` so the single `powermetrics` subprocess call can yield both watts and temperature (Apple Silicon). On Intel (where powermetrics requires sudo), temperature falls back to a direct CGo SMC read of key `TC0D`. A new `temp_darwin.go` holds all temperature logic. The Zsh layer adds a `temp` color case, a new display block, and a `POWERLENS_SHOW_TEMP` toggle.

**Tech Stack:** Go 1.22, CGo + IOKit/SMC, macOS plist parsing (existing string scan approach), Zsh 5.8+.

---

## File Structure

```
src/collect/
  metrics.go          — add CpuTemp field; update All() to call GetPowerAndTemp()
  power_darwin.go     — rename GetPower → GetPowerAndTemp (returns tempC float64 too)
  temp_darwin.go      — NEW: CGo SMC reader + parsePowermetricsTemp + GetCPUTemp()
  temp_darwin_test.go — NEW: range test for GetCPUTemp

powerlens.plugin.zsh  — add POWERLENS_SHOW_TEMP and temp threshold defaults
powerlens.zsh         — add temp color case, format block, degraded update
```

---

### Task 1: Add `CpuTemp` to the Metrics struct

**Files:**
- Modify: `src/collect/metrics.go`

- [ ] **Step 1: Add the field**

In `src/collect/metrics.go`, add `CpuTemp` after `Charging`:

```go
type Metrics struct {
	Power    float64 `json:"power"`
	Battery  int     `json:"battery"`
	Charging bool    `json:"charging"`
	CpuTemp  float64 `json:"cpu_temp"` // °C; -1 = unavailable
	CPU      float64 `json:"cpu"`
	Mem      float64 `json:"mem"`
	NetUp    float64 `json:"net_up"`
	NetDown  float64 `json:"net_down"`
	NetIface string  `json:"net_iface"`
	Ts       int64   `json:"ts"`
}
```

- [ ] **Step 2: Verify the project still builds**

```bash
cd src && go build ./...
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/collect/metrics.go
git commit -m "feat: add CpuTemp field to Metrics struct"
```

---

### Task 2: Create `temp_darwin.go` with temperature collection

**Files:**
- Create: `src/collect/temp_darwin.go`
- Create: `src/collect/temp_darwin_test.go`

- [ ] **Step 1: Write the failing test first**

Create `src/collect/temp_darwin_test.go`:

```go
package collect_test

import (
	"testing"

	"github.com/user/powerlens/collect"
)

func TestGetCPUTemp(t *testing.T) {
	temp := collect.GetCPUTemp("")
	if temp == -1 {
		return // hardware unavailable — acceptable
	}
	if temp < 0 || temp > 120 {
		t.Errorf("expected temp in [0, 120]°C or -1, got %.1f", temp)
	}
}
```

- [ ] **Step 2: Run test to confirm it fails (function not yet defined)**

```bash
cd src && go test ./collect/ -run TestGetCPUTemp -v
```

Expected: compile error — `collect.GetCPUTemp` undefined.

- [ ] **Step 3: Create `temp_darwin.go`**

Create `src/collect/temp_darwin.go`:

```go
package collect

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <string.h>
#include <stdint.h>

#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_READ_KEYINFO 9
#define KERNEL_INDEX_SMC     2

typedef struct {
	uint8_t  major;
	uint8_t  minor;
	uint8_t  build;
	uint8_t  reserved;
	uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
	uint16_t version;
	uint16_t length;
	uint32_t cpuPLimit;
	uint32_t gpuPLimit;
	uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
	uint32_t dataSize;
	uint32_t dataType;
	uint8_t  dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
	uint32_t                 key;
	SMCKeyData_vers_t        vers;
	SMCKeyData_pLimitData_t  pLimitData;
	SMCKeyData_keyInfo_t     keyInfo;
	uint8_t                  result;
	uint8_t                  status;
	uint8_t                  data8;
	uint32_t                 data32;
	uint8_t                  bytes[32];
} SMCKeyData_t;

static uint32_t smcKey(const char *s) {
	return ((uint32_t)(uint8_t)s[0] << 24)
	     | ((uint32_t)(uint8_t)s[1] << 16)
	     | ((uint32_t)(uint8_t)s[2] <<  8)
	     | ((uint32_t)(uint8_t)s[3]);
}

static kern_return_t smcCall(io_connect_t conn, int idx,
                              SMCKeyData_t *in, SMCKeyData_t *out) {
	size_t inSz = sizeof(SMCKeyData_t), outSz = sizeof(SMCKeyData_t);
	return IOConnectCallStructMethod(conn, idx, in, inSz, out, &outSz);
}

// getCPUDieTemp opens the SMC, tries keys TC0D / TC0P / TC0F,
// and returns temperature in °C (sp78 format), or -1.0 on failure.
double getCPUDieTemp() {
	io_iterator_t iter = 0;
	io_object_t   svc  = 0;
	io_connect_t  conn = 0;
	double        temp = -1.0;

	CFMutableDictionaryRef matching = IOServiceMatching("AppleSMC");
	if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != kIOReturnSuccess)
		return -1.0;

	svc = IOIteratorNext(iter);
	IOObjectRelease(iter);
	if (!svc) return -1.0;

	if (IOServiceOpen(svc, mach_task_self(), 0, &conn) != kIOReturnSuccess) {
		IOObjectRelease(svc);
		return -1.0;
	}
	IOObjectRelease(svc);

	// sp78: signed fixed-point 8.8, 2 bytes big-endian → divide by 256 for °C
	uint32_t sp78 = ((uint32_t)'s' << 24) | ((uint32_t)'p' << 16)
	              | ((uint32_t)'7' <<  8) | (uint32_t)'8';

	const char *keys[] = {"TC0D", "TC0P", "TC0F", NULL};
	for (int k = 0; keys[k] && temp < 0; k++) {
		SMCKeyData_t in = {0}, out = {0};
		in.key   = smcKey(keys[k]);
		in.data8 = SMC_CMD_READ_KEYINFO;
		if (smcCall(conn, KERNEL_INDEX_SMC, &in, &out) != kIOReturnSuccess) continue;
		if (out.keyInfo.dataType != sp78 || out.keyInfo.dataSize < 2)       continue;

		SMCKeyData_t in2 = {0}, out2 = {0};
		in2.key              = smcKey(keys[k]);
		in2.keyInfo.dataSize = out.keyInfo.dataSize;
		in2.data8            = SMC_CMD_READ_BYTES;
		if (smcCall(conn, KERNEL_INDEX_SMC, &in2, &out2) != kIOReturnSuccess) continue;

		int16_t raw = (int16_t)(((uint8_t)out2.bytes[0] << 8) | (uint8_t)out2.bytes[1]);
		temp = (double)raw / 256.0;
	}

	IOServiceClose(conn);
	return temp;
}
*/
import "C"
import (
	"strconv"
	"strings"
)

// getSMCTemp reads CPU die temperature from the SMC (Intel path).
func getSMCTemp() float64 {
	return float64(C.getCPUDieTemp())
}

// parsePowermetricsTemp extracts cpu_die_temperature_celsius from a
// powermetrics plist string (Apple Silicon path). Returns -1 if absent.
func parsePowermetricsTemp(plist string) float64 {
	for _, line := range strings.Split(plist, "\n") {
		if strings.Contains(line, "cpu_die_temperature_celsius") {
			start := strings.Index(line, "<real>")
			end := strings.Index(line, "</real>")
			if start >= 0 && end > start {
				valStr := line[start+len("<real>") : end]
				if v, err := strconv.ParseFloat(strings.TrimSpace(valStr), 64); err == nil {
					return v
				}
			}
		}
	}
	return -1
}

// GetCPUTemp returns the CPU die temperature in °C.
// plist is the powermetrics output string (non-empty on Apple Silicon);
// if empty or the key is missing, falls back to a direct SMC read (Intel).
// Returns -1 if temperature cannot be determined.
func GetCPUTemp(plist string) float64 {
	if plist != "" {
		if t := parsePowermetricsTemp(plist); t >= 0 {
			return t
		}
	}
	return getSMCTemp()
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd src && go test ./collect/ -run TestGetCPUTemp -v
```

Expected: PASS (returns a valid °C value or -1 if hardware path unsupported).

- [ ] **Step 5: Commit**

```bash
git add src/collect/temp_darwin.go src/collect/temp_darwin_test.go
git commit -m "feat: CPU temperature collection via SMC (Intel) and powermetrics plist (Apple Silicon)"
```

---

### Task 3: Refactor `GetPower` → `GetPowerAndTemp` in `power_darwin.go`

**Files:**
- Modify: `src/collect/power_darwin.go`

- [ ] **Step 1: Replace `GetPower` with `GetPowerAndTemp`**

Replace the existing `GetPower` function signature and body. Keep all helper functions (`parsePowermetricsWatts`, `batteryFallbackWatts`, and the CGo battery/charging code) unchanged. Only the exported function changes:

```go
// GetPowerAndTemp returns system power draw (W), battery %, charging state,
// and CPU die temperature (°C, or -1 if unavailable). A single powermetrics
// call feeds both watts and temperature parsing on Apple Silicon; Intel uses
// the SMC fallback inside GetCPUTemp.
func GetPowerAndTemp() (watts float64, battery int, charging bool, tempC float64, err error) {
	b := C.getBatteryCurrentCapacity()
	battery = int(b)
	charging = C.isCharging() != 0
	tempC = -1

	out, e := exec.Command(
		"powermetrics",
		"--samplers", "cpu_power",
		"-n", "1",
		"-i", "100",
		"--format", "plist",
	).Output()
	if e != nil {
		watts = batteryFallbackWatts()
		tempC = GetCPUTemp("") // Intel SMC path
		return
	}
	plist := string(out)
	w := parsePowermetricsWatts(plist)
	if w >= 0 {
		watts = w
	} else {
		watts = batteryFallbackWatts()
	}
	tempC = GetCPUTemp(plist)
	return
}
```

- [ ] **Step 2: Verify build**

```bash
cd src && go build ./...
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/collect/power_darwin.go
git commit -m "refactor: GetPower → GetPowerAndTemp, share powermetrics plist with temperature"
```

---

### Task 4: Wire `GetPowerAndTemp` into `All()` in `metrics.go`

**Files:**
- Modify: `src/collect/metrics.go`

- [ ] **Step 1: Update `All()` to call `GetPowerAndTemp`**

Replace the `GetPower` call in `All()`:

```go
func All(iface string, prev *NetSample) (Metrics, error) {
	var m Metrics
	m.Ts = time.Now().Unix()

	m.Power, m.Battery, m.Charging, m.CpuTemp, _ = GetPowerAndTemp()

	cpu, err := GetCPU()
	if err == nil {
		m.CPU = cpu
	}

	mem, err := GetMem()
	if err == nil {
		m.Mem = mem
	}

	up, down, ifaceName, err := GetNet(iface, prev)
	if err == nil {
		m.NetUp, m.NetDown, m.NetIface = up, down, ifaceName
	}
	return m, nil
}
```

- [ ] **Step 2: Run full test suite**

```bash
cd src && go test ./... -v
```

Expected: all tests pass.

- [ ] **Step 3: Smoke-test one-shot mode (prints JSON with cpu_temp)**

```bash
cd src && go run . 2>/dev/null
```

Expected: JSON output containing `"cpu_temp":` with a numeric value (or -1 on Intel without sudo for powermetrics).

- [ ] **Step 4: Commit**

```bash
git add src/collect/metrics.go
git commit -m "feat: populate CpuTemp in All() via GetPowerAndTemp"
```

---

### Task 5: Update `powerlens.plugin.zsh` with temperature defaults

**Files:**
- Modify: `powerlens.plugin.zsh`

- [ ] **Step 1: Add temp toggle and threshold defaults**

After the `POWERLENS_SHOW_NET` line, add:

```zsh
: ${POWERLENS_SHOW_TEMP:=true}
```

After the `POWERLENS_THRESH_MEM_MODERATE` line, add:

```zsh
: ${POWERLENS_THRESH_TEMP_IDLE:=50}
: ${POWERLENS_THRESH_TEMP_LIGHT:=70}
: ${POWERLENS_THRESH_TEMP_MODERATE:=85}
```

After the `POWERLENS_ALERT_MEM` line, add:

```zsh
: ${POWERLENS_ALERT_TEMP:=80}
```

- [ ] **Step 2: Commit**

```bash
git add powerlens.plugin.zsh
git commit -m "feat: add POWERLENS_SHOW_TEMP and temperature threshold defaults"
```

---

### Task 6: Update `powerlens.zsh` — color, format, and degraded string

**Files:**
- Modify: `powerlens.zsh`

- [ ] **Step 1: Add `temp` case to `_powerlens_color()`**

In `_powerlens_color()`, the opening guard already skips `net` and `battery`. Inside the `alert` mode `case`, add after the `mem)` line:

```zsh
temp) threshold=$POWERLENS_ALERT_TEMP ;;
```

In the `multi` mode `case`, add after the `mem)` line:

```zsh
temp) idle=$POWERLENS_THRESH_TEMP_IDLE; light=$POWERLENS_THRESH_TEMP_LIGHT; moderate=$POWERLENS_THRESH_TEMP_MODERATE ;;
```

- [ ] **Step 2: Add temperature block to `_powerlens_format()`**

In `_powerlens_format()`, declare `cpu_temp` alongside the other variables:

```zsh
local power battery charging cpu mem net_up net_down cpu_temp
```

Add the extraction after `mem=...`:

```zsh
cpu_temp=$(_powerlens_jget "$json" "cpu_temp")
```

After the CPU block and before the Memory block, insert:

```zsh
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
```

- [ ] **Step 3: Update `_powerlens_degraded()`**

Change:

```zsh
_powerlens_wrap "#444444" "⚡ --W 🔋 --% ⚙ --% 🧠 --% ↑ -- ↓ --"
```

To:

```zsh
_powerlens_wrap "#444444" "⚡ --W 🔋 --% ⚙ --% 🌡 --° 🧠 --% ↑ -- ↓ --"
```

- [ ] **Step 4: Commit**

```bash
git add powerlens.zsh
git commit -m "feat: display CPU temperature in RPROMPT with color thresholds and toggle"
```

---

### Task 7: Rebuild pre-compiled binaries

**Files:**
- Modify: `bin/powerlens-fetch-arm64`
- Modify: `bin/powerlens-fetch-amd64`

- [ ] **Step 1: Build both architectures**

```bash
make all
```

Expected output (from Makefile targets):
```
GOARCH=arm64 go build -o bin/powerlens-fetch-arm64 ./...
GOARCH=amd64 go build -o bin/powerlens-fetch-amd64 ./...
```

Both files updated in `bin/`.

- [ ] **Step 2: Smoke-test the arm64 binary one-shot**

```bash
bin/powerlens-fetch-arm64 2>/dev/null || bin/powerlens-fetch-amd64 2>/dev/null
```

Expected: JSON containing `"cpu_temp":` field.

- [ ] **Step 3: Commit binaries**

```bash
git add bin/powerlens-fetch-arm64 bin/powerlens-fetch-amd64
git commit -m "build: rebuild binaries with CPU temperature support"
```

---

### Task 8: Manual smoke test

**Files:** none (verification only)

- [ ] **Step 1: Reload the shell plugin**

```bash
source ~/.zshrc
```

- [ ] **Step 2: Verify temperature appears in RPROMPT**

At the prompt, wait 2–3 seconds for the daemon to write `metrics.json`. RPROMPT should show:

```
⚡38W 🔋87% ⚙34% 🌡55° 🧠62% ↑1.2M↓3.8M
```

`🌡` value should be a plausible CPU temperature (30–90°C range).

- [ ] **Step 3: Verify `POWERLENS_SHOW_TEMP=false` hides it**

```bash
POWERLENS_SHOW_TEMP=false source ~/.zshrc
```

RPROMPT should revert to the old format with no `🌡` metric.

- [ ] **Step 4: Check degraded display**

```bash
cat ~/.cache/powerlens/metrics.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cpu_temp'))"
```

Expected: a float like `55.3` (or `-1.0` on Intel if powermetrics unavailable — acceptable).

- [ ] **Step 5: Update README**

In `README.md`, add `cpu_temp` to the feature table and add `POWERLENS_SHOW_TEMP` / threshold vars to the configuration section following the pattern of existing metrics. Commit:

```bash
git add README.md
git commit -m "docs: document CPU temperature metric and configuration"
```
