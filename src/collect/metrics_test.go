package collect_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/user/powerlens/collect"
)

func TestGetPower(t *testing.T) {
	p, b, charging, tempC, err := collect.GetPowerAndTemp()
	if err != nil {
		t.Fatalf("GetPowerAndTemp error: %v", err)
	}
	if p < 0 || p > 500 {
		t.Errorf("power out of range: %.1f W", p)
	}
	if b < 0 || b > 100 {
		t.Errorf("battery out of range: %d %%", b)
	}
	_ = charging
	_ = tempC
}

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
	if m.FanSpeed != -1 && (m.FanSpeed < 0 || m.FanSpeed > 20000) {
		t.Errorf("FanSpeed out of range: %.0f", m.FanSpeed)
	}
}

func TestWriteJSON(t *testing.T) {
	m := collect.Metrics{
		Power: 42.7, Battery: 87, Charging: false,
		CPU: 34.2, Mem: 62.1,
		FanSpeed: 1500.0,
		NetUp: 1.2, NetDown: 3.8, NetIface: "en0",
		Ts: 1706000000,
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "metrics.json")

	if err := collect.WriteJSON(path, m); err != nil {
		t.Fatalf("WriteJSON error: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read file error: %v", err)
	}
	var got collect.Metrics
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}
	if got.Power != 42.7 || got.NetIface != "en0" || got.Ts != 1706000000 || got.FanSpeed != 1500.0 {
		t.Errorf("round-trip mismatch: %+v", got)
	}
}
