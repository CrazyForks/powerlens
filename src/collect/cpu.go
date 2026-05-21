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
