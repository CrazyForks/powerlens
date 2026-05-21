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

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read file error: %v", err)
	}
	var got collect.Metrics
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}
	if got.Power != 42.7 || got.NetIface != "en0" || got.Ts != 1706000000 {
		t.Errorf("round-trip mismatch: %+v", got)
	}
}
