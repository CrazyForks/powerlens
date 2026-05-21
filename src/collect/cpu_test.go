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
