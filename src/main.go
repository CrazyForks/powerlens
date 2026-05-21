package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/user/powerlens/collect"
)

func main() {
	daemon := flag.Bool("daemon", false, "run as background daemon")
	iface := flag.String("iface", "auto", "network interface: auto | all | en0")
	refresh := flag.Int("refresh", 2, "poll interval in seconds")
	flag.Parse()

	if !*daemon {
		// One-shot mode: print JSON to stdout (for debugging)
		var prev collect.NetSample
		m, _ := collect.All(*iface, &prev)
		json.NewEncoder(os.Stdout).Encode(m)
		return
	}

	cacheDir := collect.XDGCacheDir()
	if err := os.MkdirAll(cacheDir, 0755); err != nil {
		fmt.Fprintln(os.Stderr, "powerlens: cannot create cache dir:", err)
		os.Exit(1)
	}
	outPath := filepath.Join(cacheDir, "metrics.json")

	var prev collect.NetSample
	interval := time.Duration(*refresh) * time.Second
	for {
		m, _ := collect.All(*iface, &prev)
		collect.WriteJSON(outPath, m) //nolint:errcheck
		time.Sleep(interval)
	}
}
