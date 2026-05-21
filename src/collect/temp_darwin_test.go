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
