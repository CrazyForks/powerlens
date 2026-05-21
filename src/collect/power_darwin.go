package collect

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <CoreFoundation/CoreFoundation.h>

// getBatteryCurrentCapacity returns battery percentage (0-100), or -1 if no battery.
double getBatteryCurrentCapacity() {
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) return -1;
    CFArrayRef list = IOPSCopyPowerSourcesList(blob);
    if (!list || CFArrayGetCount(list) == 0) {
        CFRelease(blob);
        return -1;
    }

    CFDictionaryRef ps = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, 0));
    if (!ps) {
        CFRelease(list);
        CFRelease(blob);
        return -1;
    }
    CFNumberRef cur = CFDictionaryGetValue(ps, CFSTR(kIOPSCurrentCapacityKey));
    int capacity = 0;
    if (cur) CFNumberGetValue(cur, kCFNumberIntType, &capacity);

    CFRelease(list);
    CFRelease(blob);
    return (double)capacity;
}

// isCharging returns 1 if the system is running on AC power, 0 otherwise.
int isCharging() {
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) return 0;
    CFArrayRef list = IOPSCopyPowerSourcesList(blob);
    if (!list || CFArrayGetCount(list) == 0) {
        CFRelease(blob);
        return 0;
    }

    CFDictionaryRef ps = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, 0));
    int charging = 0;
    if (ps) {
        CFStringRef state = CFDictionaryGetValue(ps, CFSTR(kIOPSPowerSourceStateKey));
        charging = (state && CFStringCompare(state, CFSTR(kIOPSACPowerValue), 0) == kCFCompareEqualTo);
    }

    CFRelease(list);
    CFRelease(blob);
    return charging;
}
*/
import "C"
import (
	"os/exec"
	"strconv"
	"strings"
)

// GetPower returns system power draw (W), battery percent, and charging state.
// On systems with no battery, battery is returned as -1 and err is nil.
// Power is measured via powermetrics (requires sudo on Intel) with ioreg fallback.
func GetPower() (watts float64, battery int, charging bool, err error) {
	// Battery % and charging state via IOKit
	b := C.getBatteryCurrentCapacity()
	battery = int(b)
	charging = C.isCharging() != 0

	// CPU package power via powermetrics (1 sample, 100ms window)
	// Note: requires sudo on Intel Mac; works without sudo on Apple Silicon.
	out, e := exec.Command(
		"powermetrics",
		"--samplers", "cpu_power",
		"-n", "1",
		"-i", "100",
		"--format", "plist",
	).Output()
	if e != nil {
		// Fallback: estimate from PowerTelemetryData via ioreg
		watts = batteryFallbackWatts()
		return
	}
	w := parsePowermetricsWatts(string(out))
	if w >= 0 {
		watts = w
	} else {
		watts = batteryFallbackWatts()
	}
	return
}

// parsePowermetricsWatts extracts package_watts from powermetrics plist output.
// The plist format places key and value on the same line:
//
//	<key>package_watts</key><real>26.86</real>
func parsePowermetricsWatts(plist string) float64 {
	for _, line := range strings.Split(plist, "\n") {
		if strings.Contains(line, "package_watts") {
			// Extract the float value from the <real>...</real> tag
			start := strings.Index(line, "<real>")
			end := strings.Index(line, "</real>")
			if start >= 0 && end > start {
				valStr := line[start+len("<real>") : end]
				if v, parseErr := strconv.ParseFloat(strings.TrimSpace(valStr), 64); parseErr == nil {
					return v
				}
			}
		}
	}
	return -1
}

// batteryFallbackWatts uses ioreg PowerTelemetryData.SystemLoad (milliwatts)
// as a fallback when powermetrics is unavailable (e.g., Intel without sudo).
func batteryFallbackWatts() float64 {
	out, err := exec.Command("ioreg", "-rn", "AppleSmartBattery").Output()
	if err != nil {
		return -1
	}
	for _, line := range strings.Split(string(out), "\n") {
		// PowerTelemetryData contains SystemLoad in mW:
		// "PowerTelemetryData" = {"SystemLoad"=26622,...}
		if strings.Contains(line, "SystemLoad") {
			// Find "SystemLoad"=<number>
			idx := strings.Index(line, "SystemLoad")
			if idx < 0 {
				continue
			}
			rest := line[idx+len("SystemLoad\"="):]
			// rest starts with the numeric value
			end := strings.IndexAny(rest, ",}")
			if end < 0 {
				end = len(rest)
			}
			valStr := strings.TrimSpace(rest[:end])
			if v, parseErr := strconv.ParseFloat(valStr, 64); parseErr == nil && v > 0 {
				return v / 1000.0 // mW → W
			}
		}
	}
	return -1
}
