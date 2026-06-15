package collect_test

import (
	"testing"

	"github.com/user/powerlens/collect"
)

func TestGetFanSpeed(t *testing.T) {
	rpm := collect.GetFanSpeed()
	if rpm == -1 {
		return // fanless Mac or SMC unavailable — acceptable
	}
	if rpm < 0 || rpm > 20000 {
		t.Errorf("expected RPM in [0, 20000] or -1, got %.0f", rpm)
	}
}
