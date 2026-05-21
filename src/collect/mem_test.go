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
