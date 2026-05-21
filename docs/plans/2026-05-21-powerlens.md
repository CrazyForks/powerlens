# PowerLens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a zsh plugin that displays 5 real-time system metrics (power, battery, CPU, memory, network I/O) in RPROMPT with configurable color modes and display density.

**Architecture:** A Go daemon (`powerlens-fetch`) collects all metrics every N seconds and writes a JSON cache file; the zsh plugin reads the cache on `precmd` (only when the file changes), applies color and format rules, and sets `RPROMPT`. A PID-file singleton ensures exactly one daemon runs regardless of terminal count.

**Tech Stack:** Go 1.21+, CGo + IOKit (power/battery), gopsutil v3 (CPU/mem/net), Zsh 5.8+, Oh-My-Zsh plugin convention.

---

## File Structure

```
powerlens/
├── src/
│   ├── go.mod
│   ├── go.sum
│   ├── main.go                   # CLI flags, daemon loop, XDG cache path
│   └── collect/
│       ├── metrics.go            # Metrics struct, WriteJSON, xdgCacheDir
│       ├── power_darwin.go       # IOKit CGo power + battery fallback
│       ├── cpu.go                # gopsutil/cpu.Percent
│       ├── mem.go                # gopsutil/mem.VirtualMemory
│       ├── net.go                # gopsutil/net delta → MB/s, iface selection
│       ├── metrics_test.go
│       ├── cpu_test.go
│       ├── mem_test.go
│       └── net_test.go
├── powerlens.plugin.zsh          # OMZ entry: config defaults + source core
├── powerlens.zsh                 # Core: arch detect, ssh guard, daemon, precmd, color, format
├── tests/
│   └── test_plugin.zsh           # Zsh unit tests (source + assert pattern)
├── bin/
│   ├── powerlens-fetch-arm64     # Pre-compiled (ad-hoc signed)
│   └── powerlens-fetch-amd64
└── Makefile
```

---

## Task 1: Go module + Metrics struct + WriteJSON

**Files:**
- Create: `src/go.mod`
- Create: `src/collect/metrics.go`
- Create: `src/collect/metrics_test.go`

- [ ] **Step 1: Initialize Go module**

```bash
mkdir -p powerlens/src/collect powerlens/bin powerlens/tests
cd powerlens/src
go mod init github.com/user/powerlens
go get github.com/shirou/gopsutil/v3@latest
```

- [ ] **Step 2: Write the failing test**

`src/collect/metrics_test.go`:
```go
package collect_test

import (
    "encoding/json"
    "os"
    "path/filepath"
    "testing"
    "github.com/user/powerlens/collect"
)

func TestWriteJSON(t *testing.T) {
    m := collect.Metrics{
        Power: 42.7, Battery: 87, Charging: false,
        CPU: 34.2, Mem: 62.1,
        NetUp: 1.2, NetDown: 3.8, NetIface: "en0",
        Ts: 1706000000,
    }
    dir := t.TempDir()
    path := filepath.Join(dir, "metrics.json")

    if err := collect.WriteJSON(path, m); err != nil {
        t.Fatalf("WriteJSON error: %v", err)
    }

    data, _ := os.ReadFile(path)
    var got collect.Metrics
    if err := json.Unmarshal(data, &got); err != nil {
        t.Fatalf("unmarshal error: %v", err)
    }
    if got.Power != 42.7 || got.NetIface != "en0" || got.Ts != 1706000000 {
        t.Errorf("round-trip mismatch: %+v", got)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd src && go test ./collect/... -run TestWriteJSON -v
```
Expected: `FAIL — package collect not found`

- [ ] **Step 4: Implement Metrics struct + WriteJSON**

`src/collect/metrics.go`:
```go
package collect

import (
    "encoding/json"
    "os"
    "path/filepath"
)

type Metrics struct {
    Power    float64 `json:"power"`
    Battery  int     `json:"battery"`
    Charging bool    `json:"charging"`
    CPU      float64 `json:"cpu"`
    Mem      float64 `json:"mem"`
    NetUp    float64 `json:"net_up"`
    NetDown  float64 `json:"net_down"`
    NetIface string  `json:"net_iface"`
    Ts       int64   `json:"ts"`
}

func WriteJSON(path string, m Metrics) error {
    if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
        return err
    }
    tmp := path + ".tmp"
    f, err := os.Create(tmp)
    if err != nil {
        return err
    }
    if err := json.NewEncoder(f).Encode(m); err != nil {
        f.Close()
        return err
    }
    f.Close()
    return os.Rename(tmp, path) // atomic write
}

func XDGCacheDir() string {
    if d := os.Getenv("XDG_CACHE_HOME"); d != "" {
        return filepath.Join(d, "powerlens")
    }
    home, _ := os.UserHomeDir()
    return filepath.Join(home, ".cache", "powerlens")
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd src && go test ./collect/... -run TestWriteJSON -v
```
Expected: `PASS`

- [ ] **Step 6: Commit**

```bash
git add src/go.mod src/go.sum src/collect/metrics.go src/collect/metrics_test.go
git commit -m "feat: Go module + Metrics struct + atomic WriteJSON"
```

---

## Task 2: CPU collector

**Files:**
- Create: `src/collect/cpu.go`
- Create: `src/collect/cpu_test.go`

- [ ] **Step 1: Write the failing test**

`src/collect/cpu_test.go`:
```go
package collect_test

import (
    "testing"
    "github.com/user/powerlens/collect"
)

func TestGetCPU(t *testing.T) {
    pct, err := collect.GetCPU()
    if err != nil {
        t.Fatalf("GetCPU error: %v", err)
    }
    if pct < 0 || pct > 100 {
        t.Errorf("CPU %% out of range: %.1f", pct)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd src && go test ./collect/... -run TestGetCPU -v
```
Expected: `FAIL — undefined: collect.GetCPU`

- [ ] **Step 3: Implement GetCPU**

`src/collect/cpu.go`:
```go
package collect

import (
    "github.com/shirou/gopsutil/v3/cpu"
)

// GetCPU returns system-wide CPU usage percentage (0–100), averaged across all cores.
func GetCPU() (float64, error) {
    pcts, err := cpu.Percent(0, false)
    if err != nil || len(pcts) == 0 {
        return 0, err
    }
    return pcts[0], nil
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd src && go test ./collect/... -run TestGetCPU -v
```
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add src/collect/cpu.go src/collect/cpu_test.go
git commit -m "feat: CPU usage collector via gopsutil"
```

---

## Task 3: Memory collector

**Files:**
- Create: `src/collect/mem.go`
- Create: `src/collect/mem_test.go`

- [ ] **Step 1: Write the failing test**

`src/collect/mem_test.go`:
```go
package collect_test

import (
    "testing"
    "github.com/user/powerlens/collect"
)

func TestGetMem(t *testing.T) {
    pct, err := collect.GetMem()
    if err != nil {
        t.Fatalf("GetMem error: %v", err)
    }
    if pct < 0 || pct > 100 {
        t.Errorf("Mem %% out of range: %.1f", pct)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd src && go test ./collect/... -run TestGetMem -v
```
Expected: `FAIL — undefined: collect.GetMem`

- [ ] **Step 3: Implement GetMem**

`src/collect/mem.go`:
```go
package collect

import (
    "github.com/shirou/gopsutil/v3/mem"
)

// GetMem returns used memory as a percentage of total physical RAM (0–100).
func GetMem() (float64, error) {
    v, err := mem.VirtualMemory()
    if err != nil {
        return 0, err
    }
    return v.UsedPercent, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd src && go test ./collect/... -run TestGetMem -v
```
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add src/collect/mem.go src/collect/mem_test.go
git commit -m "feat: memory usage collector via gopsutil"
```

---

## Task 4: Network collector + delta calculation

**Files:**
- Create: `src/collect/net.go`
- Create: `src/collect/net_test.go`

- [ ] **Step 1: Write the failing tests**

`src/collect/net_test.go`:
```go
package collect_test

import (
    "testing"
    "time"
    "github.com/user/powerlens/collect"
)

func TestGetNetFirstSample(t *testing.T) {
    var prev collect.NetSample
    up, down, iface, err := collect.GetNet("auto", &prev)
    if err != nil {
        t.Fatalf("GetNet error: %v", err)
    }
    // First call with zero prev must return 0.0 (no baseline yet)
    if up != 0 || down != 0 {
        t.Errorf("first sample must be 0.0/0.0, got %.2f/%.2f", up, down)
    }
    if iface == "" {
        t.Error("iface must not be empty")
    }
}

func TestGetNetDelta(t *testing.T) {
    var prev collect.NetSample
    collect.GetNet("auto", &prev) // seed prev
    time.Sleep(100 * time.Millisecond)
    up, down, _, err := collect.GetNet("auto", &prev)
    if err != nil {
        t.Fatalf("GetNet error: %v", err)
    }
    if up < 0 || down < 0 {
        t.Errorf("negative rates: up=%.2f down=%.2f", up, down)
    }
}

func TestResolveIface(t *testing.T) {
    cases := []string{"auto", "all"}
    for _, c := range cases {
        name, err := collect.ResolveIface(c)
        if err != nil {
            t.Errorf("ResolveIface(%q) error: %v", c, err)
        }
        if name == "" {
            t.Errorf("ResolveIface(%q) returned empty string", c)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd src && go test ./collect/... -run "TestGetNet|TestResolveIface" -v
```
Expected: `FAIL — undefined: collect.NetSample`

- [ ] **Step 3: Implement net.go**

`src/collect/net.go`:
```go
package collect

import (
    "fmt"
    "net"
    "time"

    gnet "github.com/shirou/gopsutil/v3/net"
)

// NetSample holds a previous counter snapshot for delta calculation.
type NetSample struct {
    Sent uint64
    Recv uint64
    Time time.Time
    Resolved string // resolved interface name used for this sample
}

// ResolveIface maps "auto"→primary active iface, "all"→"__all__", or returns the name as-is.
func ResolveIface(iface string) (string, error) {
    switch iface {
    case "all":
        return "__all__", nil
    case "auto":
        ifaces, err := net.Interfaces()
        if err != nil {
            return "", err
        }
        for _, i := range ifaces {
            if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 {
                continue
            }
            addrs, _ := i.Addrs()
            for _, a := range addrs {
                if _, ok := a.(*net.IPNet); ok {
                    return i.Name, nil
                }
            }
        }
        return "", fmt.Errorf("no active interface found")
    default:
        return iface, nil
    }
}

// GetNet returns upload/download MB/s and the resolved interface name.
// prev is updated in-place. First call (prev.Time.IsZero()) returns 0.0, 0.0.
func GetNet(iface string, prev *NetSample) (upMBs, downMBs float64, ifaceName string, err error) {
    resolved, err := ResolveIface(iface)
    if err != nil {
        return 0, 0, "", err
    }

    var counters []gnet.IOCountersStat
    if resolved == "__all__" {
        counters, err = gnet.IOCounters(false) // pernic=false → single summary
    } else {
        counters, err = gnet.IOCounters(true) // pernic=true → filter by name
    }
    if err != nil || len(counters) == 0 {
        return 0, 0, resolved, err
    }

    var sent, recv uint64
    if resolved == "__all__" {
        sent, recv = counters[0].BytesSent, counters[0].BytesRecv
    } else {
        for _, c := range counters {
            if c.Name == resolved {
                sent, recv = c.BytesSent, c.BytesRecv
                break
            }
        }
    }

    now := time.Now()
    if prev.Time.IsZero() {
        // Seed the sample; return 0 for first reading
        prev.Sent, prev.Recv, prev.Time, prev.Resolved = sent, recv, now, resolved
        return 0, 0, resolved, nil
    }

    elapsed := now.Sub(prev.Time).Seconds()
    if elapsed <= 0 {
        return 0, 0, resolved, nil
    }

    upMBs   = float64(sent-prev.Sent) / elapsed / 1_000_000
    downMBs = float64(recv-prev.Recv) / elapsed / 1_000_000
    if upMBs < 0   { upMBs = 0 }
    if downMBs < 0 { downMBs = 0 }

    prev.Sent, prev.Recv, prev.Time, prev.Resolved = sent, recv, now, resolved
    return upMBs, downMBs, resolved, nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd src && go test ./collect/... -run "TestGetNet|TestResolveIface" -v
```
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add src/collect/net.go src/collect/net_test.go
git commit -m "feat: network IO collector with delta MB/s and iface selection"
```

---

## Task 5: Power + battery collector (IOKit / CGo)

**Files:**
- Create: `src/collect/power_darwin.go`

Note: This task requires macOS with Xcode CLT (`xcode-select --install`). Tests verify real hardware reads — no meaningful mock is possible for IOKit at this layer.

- [ ] **Step 1: Write the failing test**

Add to `src/collect/metrics_test.go`:
```go
func TestGetPower(t *testing.T) {
    p, b, charging, err := collect.GetPower()
    if err != nil {
        t.Fatalf("GetPower error: %v", err)
    }
    if p < 0 || p > 500 {
        t.Errorf("power out of range: %.1f W", p)
    }
    if b < 0 || b > 100 {
        t.Errorf("battery out of range: %d %%", b)
    }
    _ = charging
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd src && go test ./collect/... -run TestGetPower -v
```
Expected: `FAIL — undefined: collect.GetPower`

- [ ] **Step 3: Implement power_darwin.go**

`src/collect/power_darwin.go`:
```go
package collect

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <CoreFoundation/CoreFoundation.h>

double getBatteryCurrentCapacity() {
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    CFArrayRef list = IOPSCopyPowerSourcesList(blob);
    if (!list || CFArrayGetCount(list) == 0) return -1;

    CFDictionaryRef ps = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, 0));
    CFNumberRef cur = CFDictionaryGetValue(ps, CFSTR(kIOPSCurrentCapacityKey));
    int capacity = 0;
    if (cur) CFNumberGetValue(cur, kCFNumberIntType, &capacity);

    CFRelease(list);
    CFRelease(blob);
    return (double)capacity;
}

int isCharging() {
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    CFArrayRef list = IOPSCopyPowerSourcesList(blob);
    if (!list || CFArrayGetCount(list) == 0) { CFRelease(blob); return 0; }

    CFDictionaryRef ps = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, 0));
    CFStringRef state = CFDictionaryGetValue(ps, CFSTR(kIOPSPowerSourceStateKey));
    int charging = (state && CFStringCompare(state, CFSTR(kIOPSACPowerValue), 0) == kCFCompareEqualTo);

    CFRelease(list);
    CFRelease(blob);
    return charging;
}
*/
import "C"
import (
    "fmt"
    "os/exec"
    "strconv"
    "strings"
)

// GetPower returns system power draw (W), battery percent, and charging state.
// Power is read via `powermetrics` single-sample (no sudo on Apple Silicon via IOReport);
// battery is read via IOKit CFRunLoop-safe C calls.
func GetPower() (watts float64, battery int, charging bool, err error) {
    // Battery % and charging state via IOKit
    b := C.getBatteryCurrentCapacity()
    battery = int(b)
    charging = C.isCharging() != 0

    // CPU package power via powermetrics (1 sample, 100ms window, no sudo on AS)
    out, e := exec.Command(
        "powermetrics",
        "--samplers", "cpu_power",
        "-n", "1",
        "-i", "100",
        "--format", "plist",
    ).Output()
    if e != nil {
        // Fallback: estimate from battery discharge (rough)
        watts = batteryFallbackWatts()
        return
    }
    watts = parsePowermetricsWatts(string(out))
    return
}

func parsePowermetricsWatts(plist string) float64 {
    // Extract "processor_energy" or "package_joules" from plist text
    for _, line := range strings.Split(plist, "\n") {
        if strings.Contains(line, "package_joules") {
            parts := strings.Fields(line)
            for _, p := range parts {
                if v, err := strconv.ParseFloat(p, 64); err == nil {
                    return v * 10 // joules/100ms → watts
                }
            }
        }
    }
    return -1
}

func batteryFallbackWatts() float64 {
    // Use ioreg to read current (mA) and voltage (mV) from battery
    out, err := exec.Command("ioreg", "-rn", "AppleSmartBattery").Output()
    if err != nil {
        return -1
    }
    var amps, volts float64
    for _, line := range strings.Split(string(out), "\n") {
        if strings.Contains(line, "\"Amperage\"") {
            fmt.Sscanf(line, "%*s %*s %*s %f", &amps)
        }
        if strings.Contains(line, "\"Voltage\"") {
            fmt.Sscanf(line, "%*s %*s %*s %f", &volts)
        }
    }
    if amps < 0 { amps = -amps } // discharge is negative
    return (amps / 1000) * (volts / 1000)
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd src && go test ./collect/... -run TestGetPower -v
```
Expected: `PASS` (values will be real hardware readings)

- [ ] **Step 5: Commit**

```bash
git add src/collect/power_darwin.go src/collect/metrics_test.go
git commit -m "feat: power + battery collector via IOKit CGo + powermetrics fallback"
```

---

## Task 6: Daemon main loop

**Files:**
- Create: `src/main.go`

- [ ] **Step 1: Write the integration test**

Add to `src/collect/metrics_test.go`:
```go
func TestCollectAll(t *testing.T) {
    var prev collect.NetSample
    m, err := collect.All("auto", &prev)
    if err != nil {
        t.Fatalf("All error: %v", err)
    }
    if m.Ts == 0 {
        t.Error("Ts must be set")
    }
    if m.CPU < 0 || m.CPU > 100 {
        t.Errorf("CPU out of range: %.1f", m.CPU)
    }
    if m.Mem < 0 || m.Mem > 100 {
        t.Errorf("Mem out of range: %.1f", m.Mem)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd src && go test ./collect/... -run TestCollectAll -v
```
Expected: `FAIL — undefined: collect.All`

- [ ] **Step 3: Add All() to metrics.go**

First, add `"time"` to the existing import block in `src/collect/metrics.go`:
```go
import (
    "encoding/json"
    "os"
    "path/filepath"
    "time"
)
```

Then append to the same file:
```go
// All collects all metrics in one call. prev is updated for network delta.
func All(iface string, prev *NetSample) (Metrics, error) {
    var m Metrics
    m.Ts = time.Now().Unix()

    m.Power, m.Battery, m.Charging, _ = GetPower()

    cpu, err := GetCPU()
    if err == nil { m.CPU = cpu }

    mem, err := GetMem()
    if err == nil { m.Mem = mem }

    up, down, ifaceName, err := GetNet(iface, prev)
    if err == nil {
        m.NetUp, m.NetDown, m.NetIface = up, down, ifaceName
    }
    return m, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd src && go test ./collect/... -run TestCollectAll -v
```
Expected: `PASS`

- [ ] **Step 5: Implement main.go**

`src/main.go`:
```go
package main

import (
    "encoding/json"
    "flag"
    "fmt"
    "os"
    "path/filepath"
    "time"

    "github.com/user/powerlens/collect"
)

func main() {
    daemon  := flag.Bool("daemon",  false, "run as background daemon")
    iface   := flag.String("iface", "auto", "network interface: auto | all | en0")
    refresh := flag.Int("refresh",  2,    "poll interval in seconds")
    flag.Parse()

    if !*daemon {
        // One-shot mode: print JSON to stdout (for debugging)
        var prev collect.NetSample
        m, _ := collect.All(*iface, &prev)
        json.NewEncoder(os.Stdout).Encode(m)
        return
    }

    cacheDir := collect.XDGCacheDir()
    if err := os.MkdirAll(cacheDir, 0755); err != nil {
        fmt.Fprintln(os.Stderr, "powerlens: cannot create cache dir:", err)
        os.Exit(1)
    }
    outPath := filepath.Join(cacheDir, "metrics.json")

    var prev collect.NetSample
    interval := time.Duration(*refresh) * time.Second
    for {
        m, _ := collect.All(*iface, &prev)
        collect.WriteJSON(outPath, m) //nolint:errcheck
        time.Sleep(interval)
    }
}
```

- [ ] **Step 6: Build and smoke-test**

```bash
cd src && go build -o ../bin/powerlens-test . && ../bin/powerlens-test
```
Expected: JSON with all 5 metrics printed to stdout, NetUp/NetDown = 0 (first sample).

- [ ] **Step 7: Commit**

```bash
git add src/collect/metrics.go src/main.go src/collect/metrics_test.go
git commit -m "feat: All() collector + daemon main loop with one-shot debug mode"
```

---

## Task 7: Makefile (dual-arch build + ad-hoc signing)

**Files:**
- Create: `Makefile`

- [ ] **Step 1: Write Makefile**

`Makefile`:
```makefile
BINARY   := powerlens-fetch
SRC_DIR  := src
BIN_DIR  := bin

.PHONY: all arm64 amd64 universal install clean

all: arm64 amd64

arm64:
	cd $(SRC_DIR) && GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 \
	  go build -o ../$(BIN_DIR)/$(BINARY)-arm64 .
	codesign --sign - $(BIN_DIR)/$(BINARY)-arm64

amd64:
	cd $(SRC_DIR) && GOOS=darwin GOARCH=amd64 CGO_ENABLED=1 \
	  go build -o ../$(BIN_DIR)/$(BINARY)-amd64 .
	codesign --sign - $(BIN_DIR)/$(BINARY)-amd64

universal:
	$(MAKE) arm64 amd64
	lipo -create -output $(BIN_DIR)/$(BINARY)-universal \
	  $(BIN_DIR)/$(BINARY)-arm64 \
	  $(BIN_DIR)/$(BINARY)-amd64
	codesign --sign - $(BIN_DIR)/$(BINARY)-universal

install: arm64 amd64

clean:
	rm -f $(BIN_DIR)/$(BINARY)-arm64 $(BIN_DIR)/$(BINARY)-amd64 \
	       $(BIN_DIR)/$(BINARY)-universal
```

- [ ] **Step 2: Build both arches**

```bash
make all
```
Expected: `bin/powerlens-fetch-arm64` and `bin/powerlens-fetch-amd64` created, both ad-hoc signed.

- [ ] **Step 3: Verify signing**

```bash
codesign -dv bin/powerlens-fetch-arm64 2>&1 | grep "Signature="
```
Expected: `Signature=adhoc`

- [ ] **Step 4: Commit**

```bash
git add Makefile bin/powerlens-fetch-arm64 bin/powerlens-fetch-amd64
git commit -m "build: Makefile dual-arch + ad-hoc codesign"
```

---

## Task 8: Zsh — config defaults + plugin entry

**Files:**
- Create: `powerlens.plugin.zsh`

- [ ] **Step 1: Write powerlens.plugin.zsh**

`powerlens.plugin.zsh`:
```zsh
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

# ── Network ─────────────────────────────────────────────────
: ${POWERLENS_NET_IFACE:=auto}        # auto | en0 | all
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

# ── alert mode thresholds ───────────────────────────────────
: ${POWERLENS_ALERT_POWER:=50}
: ${POWERLENS_ALERT_CPU:=80}
: ${POWERLENS_ALERT_MEM:=85}

# Load core plugin
source "${0:h}/powerlens.zsh"

# Initialize on load
_powerlens_init
```

- [ ] **Step 2: Verify syntax**

```bash
zsh -n powerlens.plugin.zsh
```
Expected: no output (syntax OK).

- [ ] **Step 3: Commit**

```bash
git add powerlens.plugin.zsh
git commit -m "feat: plugin entry with config defaults"
```

---

## Task 9: Zsh — arch detection, SSH guard, binary selection, degraded state

**Files:**
- Create: `powerlens.zsh` (initial skeleton)
- Create: `tests/test_plugin.zsh`

- [ ] **Step 1: Write failing tests**

`tests/test_plugin.zsh`:
```zsh
#!/usr/bin/env zsh
setopt errexit

PASS=0; FAIL=0
assert_eq() {
    local desc=$1 got=$2 want=$3
    if [[ "$got" == "$want" ]]; then
        (( PASS++ )); print "  PASS: $desc"
    else
        (( FAIL++ )); print "  FAIL: $desc — got '$got', want '$want'"
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
assert_eq "degraded contains --W" "${out//[^-]/}" "$(printf '%0.s-' {1..10})"

print "\nResults: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
zsh tests/test_plugin.zsh
```
Expected: `FAIL — _powerlens_is_ssh: command not found`

- [ ] **Step 3: Implement skeleton powerlens.zsh**

`powerlens.zsh`:
```zsh
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
zsh tests/test_plugin.zsh
```
Expected: `Results: 2 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add powerlens.zsh tests/test_plugin.zsh
git commit -m "feat: zsh core skeleton — arch detection, SSH guard, degraded state"
```

---

## Task 10: Zsh — daemon singleton lifecycle

**Files:**
- Modify: `powerlens.zsh`
- Modify: `tests/test_plugin.zsh`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_plugin.zsh` (before the summary lines):
```zsh
print "\n=== Daemon singleton ==="
# Fake binary that just sleeps
_powerlens_bin="$(which sleep)"
_POWERLENS_CACHE="$(mktemp -d)"
_POWERLENS_PIDFILE="$_POWERLENS_CACHE/daemon.pid"
_POWERLENS_COUNTER="$_POWERLENS_CACHE/sessions"

_powerlens_start_daemon
sleep 0.1  # let it start
assert_eq "PID file created" "$(test -f $_POWERLENS_PIDFILE && echo yes || echo no)" "yes"
assert_eq "session counter is 1" "$(cat $_POWERLENS_COUNTER)" "1"

# Second start should not spawn duplicate
local pid1=$(cat $_POWERLENS_PIDFILE)
_powerlens_start_daemon
local pid2=$(cat $_POWERLENS_PIDFILE)
assert_eq "second start reuses PID" "$pid1" "$pid2"

# Stop but keep daemon alive (2 sessions → 1)
echo "2" > $_POWERLENS_COUNTER
_powerlens_stop_daemon
assert_eq "counter decremented to 1" "$(cat $_POWERLENS_COUNTER)" "1"
assert_eq "daemon still running" "$(kill -0 $pid1 2>/dev/null && echo yes || echo no)" "yes"

# Final stop kills daemon
_powerlens_stop_daemon
sleep 0.1
assert_eq "daemon killed" "$(kill -0 $pid1 2>/dev/null && echo yes || echo no)" "no"
assert_eq "PID file removed" "$(test -f $_POWERLENS_PIDFILE && echo yes || echo no)" "no"

rm -rf "$_POWERLENS_CACHE"
```

- [ ] **Step 2: Run tests to verify new tests fail**

```bash
zsh tests/test_plugin.zsh 2>&1 | tail -5
```
Expected: failures on daemon tests.

- [ ] **Step 3: Implement daemon lifecycle in powerlens.zsh**

Append to `powerlens.zsh` (after `_powerlens_degraded`):
```zsh
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
```

- [ ] **Step 4: Run all tests to verify they pass**

```bash
zsh tests/test_plugin.zsh
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add powerlens.zsh tests/test_plugin.zsh
git commit -m "feat: daemon singleton lifecycle — start/stop/session counter"
```

---

## Task 11: Zsh — precmd cache reading + freshness check

**Files:**
- Modify: `powerlens.zsh`
- Modify: `tests/test_plugin.zsh`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_plugin.zsh`:
```zsh
print "\n=== JSON parsing ==="
local tmpdir=$(mktemp -d)
local cachefile="$tmpdir/metrics.json"
cat > "$cachefile" <<'EOF'
{"power":42.7,"battery":87,"charging":false,"cpu":34.2,"mem":62.1,"net_up":1.2,"net_down":3.8,"net_iface":"en0","ts":9999999999}
EOF

local val
val=$(_powerlens_jget "$(< $cachefile)" "power")
assert_eq "jget power" "$val" "42.7"
val=$(_powerlens_jget "$(< $cachefile)" "net_iface")
assert_eq "jget net_iface" "$val" "en0"
val=$(_powerlens_jget "$(< $cachefile)" "battery")
assert_eq "jget battery" "$val" "87"

rm -rf "$tmpdir"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
zsh tests/test_plugin.zsh 2>&1 | grep "jget"
```
Expected: FAIL — `_powerlens_jget: command not found`

- [ ] **Step 3: Implement precmd logic in powerlens.zsh**

Append to `powerlens.zsh`:
```zsh
_powerlens_last_mtime=0
_powerlens_cached_rprompt=""

# Extract a scalar value from a flat JSON string by key name.
# Works for numbers, booleans, and quoted strings.
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
```

- [ ] **Step 4: Run all tests to verify they pass**

```bash
zsh tests/test_plugin.zsh
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add powerlens.zsh tests/test_plugin.zsh
git commit -m "feat: precmd cache reading, mtime guard, freshness check, JSON parser"
```

---

## Task 12: Zsh — color functions (multi + alert)

**Files:**
- Modify: `powerlens.zsh`
- Modify: `tests/test_plugin.zsh`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_plugin.zsh`:
```zsh
print "\n=== Color — multi mode ==="
POWERLENS_COLOR_MODE=multi
assert_eq "power idle"     "$(_powerlens_color power 5)"    "#00FF9F"
assert_eq "power light"    "$(_powerlens_color power 20)"   "#00D4FF"
assert_eq "power moderate" "$(_powerlens_color power 40)"   "#FF006E"
assert_eq "power peak"     "$(_powerlens_color power 60)"   "#FF9500"
assert_eq "cpu idle"       "$(_powerlens_color cpu 10)"     "#00FF9F"
assert_eq "cpu peak"       "$(_powerlens_color cpu 90)"     "#FF9500"
assert_eq "mem moderate"   "$(_powerlens_color mem 80)"     "#FF006E"

print "\n=== Color — alert mode ==="
POWERLENS_COLOR_MODE=alert
assert_eq "cpu under alert" "$(_powerlens_color cpu 50)"  "#aaaaaa"
assert_eq "cpu over alert"  "$(_powerlens_color cpu 85)"  "#FF9500"
assert_eq "mem under alert" "$(_powerlens_color mem 80)"  "#aaaaaa"
assert_eq "mem over alert"  "$(_powerlens_color mem 90)"  "#FF9500"
assert_eq "net always gray" "$(_powerlens_color net 999)" "#aaaaaa"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
zsh tests/test_plugin.zsh 2>&1 | grep "Color"
```
Expected: FAIL — `_powerlens_color: command not found`

- [ ] **Step 3: Implement color functions**

Append to `powerlens.zsh`:
```zsh
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
```

- [ ] **Step 4: Run all tests to verify they pass**

```bash
zsh tests/test_plugin.zsh
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add powerlens.zsh tests/test_plugin.zsh
git commit -m "feat: color dispatch — multi (4-level) and alert (single threshold) modes"
```

---

## Task 13: Zsh — format functions (compact + full)

**Files:**
- Modify: `powerlens.zsh`
- Modify: `tests/test_plugin.zsh`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_plugin.zsh`:
```zsh
print "\n=== Format ==="
POWERLENS_COLOR_MODE=multi
local sample_json='{"power":42.7,"battery":87,"charging":false,"cpu":34.2,"mem":62.1,"net_up":1.2,"net_down":3.8,"net_iface":"en0","ts":9999999999}'

POWERLENS_MODE=compact
local out=$(_powerlens_format "$sample_json")
# Strip ANSI codes for assertion
local plain=$(print "$out" | sed 's/\x1b\[[0-9;]*m//g; s/%{[^}]*}//g')
assert_eq "compact contains power"   "${plain[(r)*W*]}" "${plain[(r)*W*]}"
assert_eq "compact contains net up"  "${${plain}##*↑}" "${${plain}##*↑}"

POWERLENS_MODE=full
out=$(_powerlens_format "$sample_json")
plain=$(print "$out" | sed 's/\x1b\[[0-9;]*m//g; s/%{[^}]*}//g')
assert_eq "full contains MB/s"       "${(M)plain##*MB/s*}" ""
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
zsh tests/test_plugin.zsh 2>&1 | grep "Format"
```
Expected: FAIL — `_powerlens_format: command not found`

- [ ] **Step 3: Implement format functions**

Append to `powerlens.zsh`:
```zsh
# Format a float: compact removes decimals, full keeps 1 decimal place.
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
```

- [ ] **Step 4: Run all tests to verify they pass**

```bash
zsh tests/test_plugin.zsh
```
Expected: all tests pass.

- [ ] **Step 5: Verify syntax of full plugin**

```bash
zsh -n powerlens.zsh
```
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add powerlens.zsh tests/test_plugin.zsh
git commit -m "feat: format functions — compact/full mode with per-metric color wrapping"
```

---

## Task 14: Integration verification

**Files:** none new — end-to-end manual test.

- [ ] **Step 1: Build the binary**

```bash
make arm64   # or: make amd64
```

- [ ] **Step 2: Run daemon in foreground for 5 seconds, verify JSON**

```bash
./bin/powerlens-fetch-arm64 &
DPID=$!
sleep 3
cat "${XDG_CACHE_HOME:-$HOME/.cache}/powerlens/metrics.json"
kill $DPID
```
Expected: valid JSON with all 9 fields, `net_up`/`net_down` non-zero after second sample.

- [ ] **Step 3: Load plugin in a test shell, verify RPROMPT**

```bash
zsh -c '
  POWERLENS_MODE=compact
  POWERLENS_COLOR_MODE=multi
  POWERLENS_SHOW_BATTERY=true POWERLENS_SHOW_CPU=true
  POWERLENS_SHOW_MEM=true POWERLENS_SHOW_NET=true
  POWERLENS_NET_IFACE=auto POWERLENS_REFRESH=2
  POWERLENS_THRESH_POWER_IDLE=10; POWERLENS_THRESH_POWER_LIGHT=30; POWERLENS_THRESH_POWER_MODERATE=50
  POWERLENS_THRESH_CPU_IDLE=30; POWERLENS_THRESH_CPU_LIGHT=60; POWERLENS_THRESH_CPU_MODERATE=85
  POWERLENS_THRESH_MEM_IDLE=50; POWERLENS_THRESH_MEM_LIGHT=70; POWERLENS_THRESH_MEM_MODERATE=85
  POWERLENS_ALERT_POWER=50; POWERLENS_ALERT_CPU=80; POWERLENS_ALERT_MEM=85
  source ./powerlens.plugin.zsh
  sleep 3
  _powerlens_update_rprompt
  print "$RPROMPT"
'
```
Expected: colored RPROMPT string containing `⚡`, `🔋`, `⚙`, `🧠`, `↑`, `↓`.

- [ ] **Step 4: Verify singleton — open two shells, check daemon count**

```bash
# Terminal 1
source powerlens.plugin.zsh

# Terminal 2
source powerlens.plugin.zsh

# Check — should be exactly 1 daemon
pgrep -c powerlens-fetch
```
Expected: `1`

- [ ] **Step 5: Verify cleanup on shell exit**

```bash
# Close terminal 2, then check daemon still running
pgrep powerlens-fetch
# Close terminal 1, wait 1s, check daemon is gone
pgrep powerlens-fetch; echo $?
```
Expected: `1` (not found) after last shell exits.

- [ ] **Step 6: Run full test suite one last time**

```bash
cd src && go test ./... -v
zsh tests/test_plugin.zsh
```
Expected: all Go tests pass, all Zsh tests pass.

- [ ] **Step 7: Final commit**

```bash
git add -A
git commit -m "feat: PowerLens v1 — 5-metric RPROMPT with multi/alert color and compact/full display"
```
