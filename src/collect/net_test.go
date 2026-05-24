package collect_test

import (
	"testing"
	"time"

	"github.com/user/powerlens/collect"
)

// TestResolveIfaceDefault verifies "default" mode returns a non-empty interface name and type.
func TestResolveIfaceDefault(t *testing.T) {
	name, ifaceType, err := collect.ResolveIface("default")
	if err != nil {
		t.Fatalf("ResolveIface(default) error: %v", err)
	}
	if name == "" {
		t.Error("ResolveIface(default) returned empty interface name")
	}
	if ifaceType == "" {
		t.Error("ResolveIface(default) returned empty interface type")
	}
}

// TestResolveIfaceWifi verifies "wifi" mode finds a WiFi interface.
func TestResolveIfaceWifi(t *testing.T) {
	name, ifaceType, err := collect.ResolveIface("wifi")
	if err != nil {
		t.Skipf("no WiFi interface found (may not exist in this environment): %v", err)
	}
	if name == "" {
		t.Error("ResolveIface(wifi) returned empty interface name")
	}
	if ifaceType != "wifi" {
		t.Errorf("ResolveIface(wifi) type = %q, want %q", ifaceType, "wifi")
	}
}

// TestResolveIfaceEthernet verifies "ethernet" mode finds a wired interface.
func TestResolveIfaceEthernet(t *testing.T) {
	name, ifaceType, err := collect.ResolveIface("ethernet")
	if err != nil {
		t.Skipf("no Ethernet interface found (may not be connected): %v", err)
	}
	if name == "" {
		t.Error("ResolveIface(ethernet) returned empty interface name")
	}
	if ifaceType != "ethernet" {
		t.Errorf("ResolveIface(ethernet) type = %q, want %q", ifaceType, "ethernet")
	}
}

// TestResolveIfaceUnknownMode verifies unknown modes return an error.
func TestResolveIfaceUnknownMode(t *testing.T) {
	_, _, err := collect.ResolveIface("auto")
	if err == nil {
		t.Error("ResolveIface(auto) should return error for removed mode")
	}
	_, _, err = collect.ResolveIface("all")
	if err == nil {
		t.Error("ResolveIface(all) should return error for removed mode")
	}
}

// TestGetNetFirstSampleDefault verifies first call returns 0/0 and a type.
func TestGetNetFirstSampleDefault(t *testing.T) {
	var prev collect.NetSample
	up, down, ifaceName, ifaceType, err := collect.GetNet("default", &prev)
	if err != nil {
		t.Fatalf("GetNet error: %v", err)
	}
	if up != 0 || down != 0 {
		t.Errorf("first sample must be 0.0/0.0, got %.2f/%.2f", up, down)
	}
	if ifaceName == "" {
		t.Error("ifaceName must not be empty")
	}
	if ifaceType == "" {
		t.Error("ifaceType must not be empty")
	}
}

// TestGetNetDeltaNonNegative verifies rate delta is always >= 0.
func TestGetNetDeltaNonNegative(t *testing.T) {
	var prev collect.NetSample
	collect.GetNet("default", &prev) //nolint:errcheck // seed prev
	time.Sleep(100 * time.Millisecond)
	up, down, _, _, err := collect.GetNet("default", &prev)
	if err != nil {
		t.Fatalf("GetNet error: %v", err)
	}
	if up < 0 || down < 0 {
		t.Errorf("negative rates: up=%.2f down=%.2f", up, down)
	}
}

// TestGetNetInterfaceStability verifies the resolved interface name is stable across consecutive calls.
func TestGetNetInterfaceStability(t *testing.T) {
	var prev collect.NetSample
	_, _, name1, _, _ := collect.GetNet("default", &prev) //nolint:errcheck
	time.Sleep(50 * time.Millisecond)
	_, _, name2, _, _ := collect.GetNet("default", &prev) //nolint:errcheck
	if name1 != name2 {
		t.Errorf("interface changed between polls: %q → %q", name1, name2)
	}
}
