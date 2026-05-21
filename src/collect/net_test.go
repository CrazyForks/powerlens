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
