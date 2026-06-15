package collect

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

type Metrics struct {
	Power        float64 `json:"power"`
	Battery      int     `json:"battery"`
	Charging     bool    `json:"charging"`
	CpuTemp      float64 `json:"cpu_temp"`  // °C; -1 = unavailable
	FanSpeed     float64 `json:"fan_speed"` // RPM avg; -1 = fanless/unavailable
	CPU          float64 `json:"cpu"`
	Mem          float64 `json:"mem"`
	NetUp        float64 `json:"net_up"`
	NetDown      float64 `json:"net_down"`
	NetIface     string  `json:"net_iface"`
	NetIfaceType string  `json:"net_iface_type"` // wifi | ethernet | other
	Ts           int64   `json:"ts"`
}

func WriteJSON(path string, m Metrics) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if err := json.NewEncoder(f).Encode(m); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// All collects all metrics in one call. prev is updated for network delta.
func All(iface string, prev *NetSample) (Metrics, error) {
	var m Metrics
	m.Ts = time.Now().Unix()

	m.Power, m.Battery, m.Charging, m.CpuTemp, _ = GetPowerAndTemp()
	m.FanSpeed = GetFanSpeed()

	cpu, err := GetCPU()
	if err == nil {
		m.CPU = cpu
	}

	mem, err := GetMem()
	if err == nil {
		m.Mem = mem
	}

	up, down, ifaceName, ifaceType, err := GetNet(iface, prev)
	if err == nil {
		m.NetUp, m.NetDown, m.NetIface, m.NetIfaceType = up, down, ifaceName, ifaceType
	}
	return m, nil
}

func XDGCacheDir() string {
	if d := os.Getenv("XDG_CACHE_HOME"); d != "" {
		return filepath.Join(d, "powerlens")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cache", "powerlens")
}
