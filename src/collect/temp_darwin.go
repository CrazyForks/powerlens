package collect

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <string.h>
#include <stdint.h>

#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_READ_KEYINFO 9
#define KERNEL_INDEX_SMC     2

typedef struct {
	uint8_t  major;
	uint8_t  minor;
	uint8_t  build;
	uint8_t  reserved;
	uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
	uint16_t version;
	uint16_t length;
	uint32_t cpuPLimit;
	uint32_t gpuPLimit;
	uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
	uint32_t dataSize;
	uint32_t dataType;
	uint8_t  dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
	uint32_t                 key;
	SMCKeyData_vers_t        vers;
	SMCKeyData_pLimitData_t  pLimitData;
	SMCKeyData_keyInfo_t     keyInfo;
	uint8_t                  result;
	uint8_t                  status;
	uint8_t                  data8;
	uint32_t                 data32;
	uint8_t                  bytes[32];
} SMCKeyData_t;

static uint32_t smcKey(const char *s) {
	return ((uint32_t)(uint8_t)s[0] << 24)
	     | ((uint32_t)(uint8_t)s[1] << 16)
	     | ((uint32_t)(uint8_t)s[2] <<  8)
	     | ((uint32_t)(uint8_t)s[3]);
}

static kern_return_t smcCall(io_connect_t conn, int idx,
                              SMCKeyData_t *in, SMCKeyData_t *out) {
	size_t inSz = sizeof(SMCKeyData_t), outSz = sizeof(SMCKeyData_t);
	return IOConnectCallStructMethod(conn, idx, in, inSz, out, &outSz);
}

// getCPUDieTemp opens the SMC, tries keys TC0D / TC0P / TC0F,
// and returns temperature in degrees Celsius (sp78 format), or -1.0 on failure.
double getCPUDieTemp() {
	io_iterator_t iter = 0;
	io_object_t   svc  = 0;
	io_connect_t  conn = 0;
	double        temp = -1.0;

	CFMutableDictionaryRef matching = IOServiceMatching("AppleSMC");
	if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != kIOReturnSuccess)
		return -1.0;

	svc = IOIteratorNext(iter);
	IOObjectRelease(iter);
	if (!svc) return -1.0;

	if (IOServiceOpen(svc, mach_task_self(), 0, &conn) != kIOReturnSuccess) {
		IOObjectRelease(svc);
		return -1.0;
	}
	IOObjectRelease(svc);

	// sp78: signed fixed-point 8.8, 2 bytes big-endian → divide by 256 for °C
	uint32_t sp78 = ((uint32_t)'s' << 24) | ((uint32_t)'p' << 16)
	              | ((uint32_t)'7' <<  8) | (uint32_t)'8';

	const char *keys[] = {"TC0D", "TC0P", "TC0F", NULL};
	for (int k = 0; keys[k] && temp < 0; k++) {
		SMCKeyData_t in = {0}, out = {0};
		in.key   = smcKey(keys[k]);
		in.data8 = SMC_CMD_READ_KEYINFO;
		if (smcCall(conn, KERNEL_INDEX_SMC, &in, &out) != kIOReturnSuccess) continue;
		if (out.keyInfo.dataType != sp78 || out.keyInfo.dataSize < 2)       continue;

		SMCKeyData_t in2 = {0}, out2 = {0};
		in2.key              = smcKey(keys[k]);
		in2.keyInfo.dataSize = out.keyInfo.dataSize;
		in2.data8            = SMC_CMD_READ_BYTES;
		if (smcCall(conn, KERNEL_INDEX_SMC, &in2, &out2) != kIOReturnSuccess) continue;

		int16_t raw = (int16_t)(((uint8_t)out2.bytes[0] << 8) | (uint8_t)out2.bytes[1]);
		temp = (double)raw / 256.0;
	}

	IOServiceClose(conn);
	return temp;
}
*/
import "C"
import (
	"strconv"
	"strings"
)

// getSMCTemp reads CPU die temperature from the SMC (Intel path).
func getSMCTemp() float64 {
	return float64(C.getCPUDieTemp())
}

// parsePowermetricsTemp extracts cpu_die_temperature_celsius from a
// powermetrics plist string (Apple Silicon path). Returns -1 if absent.
func parsePowermetricsTemp(plist string) float64 {
	for _, line := range strings.Split(plist, "\n") {
		if strings.Contains(line, "cpu_die_temperature_celsius") {
			start := strings.Index(line, "<real>")
			end := strings.Index(line, "</real>")
			if start >= 0 && end > start {
				valStr := line[start+len("<real>") : end]
				if v, err := strconv.ParseFloat(strings.TrimSpace(valStr), 64); err == nil {
					return v
				}
			}
		}
	}
	return -1
}

// GetCPUTemp returns the CPU die temperature in °C.
// plist is the powermetrics output string (non-empty on Apple Silicon);
// if empty or the key is missing, falls back to a direct SMC read (Intel).
// Returns -1 if temperature cannot be determined.
func GetCPUTemp(plist string) float64 {
	if plist != "" {
		if t := parsePowermetricsTemp(plist); t >= 0 {
			return t
		}
	}
	return getSMCTemp()
}
