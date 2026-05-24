package collect

import (
	"bufio"
	"bytes"
	"fmt"
	"net"
	"os/exec"
	"strings"
	"time"

	gnet "github.com/shirou/gopsutil/v3/net"
)

// NetSample holds a previous counter snapshot for delta calculation.
type NetSample struct {
	Sent      uint64
	Recv      uint64
	Time      time.Time
	Resolved  string // locked interface name
	IfaceType string // locked interface type: wifi | ethernet | other
}

// ResolveIface resolves mode to (interfaceName, ifaceType, error).
// Supported modes: "default", "wifi", "ethernet".
func ResolveIface(mode string) (string, string, error) {
	switch mode {
	case "default":
		return resolveDefault()
	case "wifi":
		return resolveByNetworkSetup("wifi")
	case "ethernet":
		return resolveByNetworkSetup("ethernet")
	default:
		return "", "", fmt.Errorf("unsupported mode %q: use default, wifi, or ethernet", mode)
	}
}

// resolveDefault finds the interface used for the default route and determines its type.
func resolveDefault() (string, string, error) {
	out, err := exec.Command("route", "get", "default").Output()
	if err != nil {
		return "", "", fmt.Errorf("route get default: %w", err)
	}
	name := parseRouteInterface(out)
	if name == "" {
		return "", "", fmt.Errorf("could not parse interface from route get default")
	}
	typeMap, _ := buildIfaceTypeMap()
	ifaceType := typeMap[name]
	if ifaceType == "" {
		ifaceType = "other"
	}
	return name, ifaceType, nil
}

// parseRouteInterface extracts the interface name from "route get default" output.
func parseRouteInterface(out []byte) string {
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "interface:") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				return parts[1]
			}
		}
	}
	return ""
}

// resolveByNetworkSetup finds the first interface of the requested type (wifi or ethernet).
func resolveByNetworkSetup(wantType string) (string, string, error) {
	typeMap, ifaceList, err := buildIfaceTypeMapOrdered()
	if err != nil {
		return "", "", err
	}
	for _, name := range ifaceList {
		if typeMap[name] == wantType {
			// Verify the interface is actually up and has an address.
			iface, err := net.InterfaceByName(name)
			if err != nil {
				continue
			}
			if iface.Flags&net.FlagUp == 0 {
				continue
			}
			addrs, _ := iface.Addrs()
			hasIP := false
			for _, a := range addrs {
				if _, ok := a.(*net.IPNet); ok {
					hasIP = true
					break
				}
			}
			if hasIP {
				return name, wantType, nil
			}
		}
	}
	return "", "", fmt.Errorf("no active %s interface found", wantType)
}

// buildIfaceTypeMap returns a map of interface name → type (wifi|ethernet|other).
func buildIfaceTypeMap() (map[string]string, error) {
	m, _, err := buildIfaceTypeMapOrdered()
	return m, err
}

// buildIfaceTypeMapOrdered returns the type map and the ordered list of interface names.
func buildIfaceTypeMapOrdered() (map[string]string, []string, error) {
	out, err := exec.Command("networksetup", "-listallhardwareports").Output()
	if err != nil {
		return map[string]string{}, nil, fmt.Errorf("networksetup: %w", err)
	}
	return parseNetworkSetupOutput(out)
}

// parseNetworkSetupOutput parses "networksetup -listallhardwareports" output.
// Returns a type map and an ordered slice of interface names.
func parseNetworkSetupOutput(out []byte) (map[string]string, []string, error) {
	typeMap := make(map[string]string)
	var order []string
	var portName string

	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "Hardware Port:") {
			portName = strings.TrimPrefix(line, "Hardware Port:")
			portName = strings.TrimSpace(portName)
		} else if strings.HasPrefix(line, "Device:") {
			device := strings.TrimSpace(strings.TrimPrefix(line, "Device:"))
			if device != "" && portName != "" {
				typeMap[device] = classifyPort(portName)
				order = append(order, device)
			}
			portName = ""
		}
	}
	return typeMap, order, nil
}

// classifyPort maps a hardware port name to wifi | ethernet | other.
func classifyPort(portName string) string {
	upper := strings.ToUpper(portName)
	if strings.Contains(upper, "WI-FI") || strings.Contains(upper, "WIFI") || strings.Contains(upper, "AIRPORT") {
		return "wifi"
	}
	if strings.Contains(upper, "ETHERNET") || strings.Contains(upper, "LAN") {
		return "ethernet"
	}
	return "other"
}

// GetNet returns upload/download MB/s, the resolved interface name, and its type.
// prev is updated in-place. First call (prev.Time.IsZero()) returns 0.0, 0.0.
// The resolved interface is cached in prev and only re-resolved if it goes down.
func GetNet(mode string, prev *NetSample) (upMBs, downMBs float64, ifaceName, ifaceType string, err error) {
	name, itype, err := resolveStable(mode, prev)
	if err != nil {
		return 0, 0, "", "", err
	}

	counters, err := gnet.IOCounters(true)
	if err != nil || len(counters) == 0 {
		return 0, 0, name, itype, err
	}

	var sent, recv uint64
	for _, c := range counters {
		if c.Name == name {
			sent, recv = c.BytesSent, c.BytesRecv
			break
		}
	}

	now := time.Now()
	if prev.Time.IsZero() {
		prev.Sent, prev.Recv, prev.Time = sent, recv, now
		return 0, 0, name, itype, nil
	}

	elapsed := now.Sub(prev.Time).Seconds()
	if elapsed <= 0 {
		return 0, 0, name, itype, nil
	}

	upMBs = float64(sent-prev.Sent) / elapsed / 1_000_000
	downMBs = float64(recv-prev.Recv) / elapsed / 1_000_000
	if upMBs < 0 {
		upMBs = 0
	}
	if downMBs < 0 {
		downMBs = 0
	}

	prev.Sent, prev.Recv, prev.Time = sent, recv, now
	return upMBs, downMBs, name, itype, nil
}

// resolveStable returns the cached interface, re-resolving only if it went down.
func resolveStable(mode string, prev *NetSample) (string, string, error) {
	if prev.Resolved != "" && isIfaceUp(prev.Resolved) {
		return prev.Resolved, prev.IfaceType, nil
	}
	name, itype, err := ResolveIface(mode)
	if err != nil {
		return "", "", err
	}
	prev.Resolved, prev.IfaceType = name, itype
	return name, itype, nil
}

// isIfaceUp returns true if the named interface exists and is UP with an address.
func isIfaceUp(name string) bool {
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return false
	}
	if iface.Flags&net.FlagUp == 0 {
		return false
	}
	addrs, _ := iface.Addrs()
	for _, a := range addrs {
		if _, ok := a.(*net.IPNet); ok {
			return true
		}
	}
	return false
}
