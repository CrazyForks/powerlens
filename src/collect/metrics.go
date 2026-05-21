package collect

import (
	"encoding/json"
	"os"
	"path/filepath"
)

type Metrics struct {
	Power    float64 `json:"power"`
	Battery  int     `json:"battery"`
	Charging bool    `json:"charging"`
	CPU      float64 `json:"cpu"`
	Mem      float64 `json:"mem"`
	NetUp    float64 `json:"net_up"`
	NetDown  float64 `json:"net_down"`
	NetIface string  `json:"net_iface"`
	Ts       int64   `json:"ts"`
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

func XDGCacheDir() string {
	if d := os.Getenv("XDG_CACHE_HOME"); d != "" {
		return filepath.Join(d, "powerlens")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cache", "powerlens")
}
