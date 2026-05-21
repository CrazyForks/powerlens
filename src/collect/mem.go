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
