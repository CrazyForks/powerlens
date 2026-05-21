package collect

import (
	"fmt"
	"net"
	"time"

	gnet "github.com/shirou/gopsutil/v3/net"
)

// NetSample holds a previous counter snapshot for delta calculation.
type NetSample struct {
	Sent     uint64
	Recv     uint64
	Time     time.Time
	Resolved string // resolved interface name used for this sample
}

// ResolveIface maps "auto"→primary active iface, "all"→"__all__", or returns the name as-is.
func ResolveIface(iface string) (string, error) {
	switch iface {
	case "all":
		return "__all__", nil
	case "auto":
		ifaces, err := net.Interfaces()
		if err != nil {
			return "", err
		}
		for _, i := range ifaces {
			if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 {
				continue
			}
			addrs, _ := i.Addrs()
			for _, a := range addrs {
				if _, ok := a.(*net.IPNet); ok {
					return i.Name, nil
				}
			}
		}
		return "", fmt.Errorf("no active interface found")
	default:
		return iface, nil
	}
}

// GetNet returns upload/download MB/s and the resolved interface name.
// prev is updated in-place. First call (prev.Time.IsZero()) returns 0.0, 0.0.
func GetNet(iface string, prev *NetSample) (upMBs, downMBs float64, ifaceName string, err error) {
	resolved, err := ResolveIface(iface)
	if err != nil {
		return 0, 0, "", err
	}

	var counters []gnet.IOCountersStat
	if resolved == "__all__" {
		counters, err = gnet.IOCounters(false) // pernic=false → single summary
	} else {
		counters, err = gnet.IOCounters(true) // pernic=true → filter by name
	}
	if err != nil || len(counters) == 0 {
		return 0, 0, resolved, err
	}

	var sent, recv uint64
	if resolved == "__all__" {
		sent, recv = counters[0].BytesSent, counters[0].BytesRecv
	} else {
		for _, c := range counters {
			if c.Name == resolved {
				sent, recv = c.BytesSent, c.BytesRecv
				break
			}
		}
	}

	now := time.Now()
	if prev.Time.IsZero() {
		// Seed the sample; return 0 for first reading
		prev.Sent, prev.Recv, prev.Time, prev.Resolved = sent, recv, now, resolved
		return 0, 0, resolved, nil
	}

	elapsed := now.Sub(prev.Time).Seconds()
	if elapsed <= 0 {
		return 0, 0, resolved, nil
	}

	upMBs = float64(sent-prev.Sent) / elapsed / 1_000_000
	downMBs = float64(recv-prev.Recv) / elapsed / 1_000_000
	if upMBs < 0 {
		upMBs = 0
	}
	if downMBs < 0 {
		downMBs = 0
	}

	prev.Sent, prev.Recv, prev.Time, prev.Resolved = sent, recv, now, resolved
	return upMBs, downMBs, resolved, nil
}
