package collect

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include <IOKit/IOKitLib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>

#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_READ_KEYINFO 9
#define KERNEL_INDEX_SMC     2

typedef struct {
	uint8_t  major;
	uint8_t  minor;
	uint8_t  build;
	uint8_t  reserved;
	uint16_t release;
} FanSMCKeyData_vers_t;

typedef struct {
	uint16_t version;
	uint16_t length;
	uint32_t cpuPLimit;
	uint32_t gpuPLimit;
	uint32_t memPLimit;
} FanSMCKeyData_pLimitData_t;

typedef struct {
	uint32_t dataSize;
	uint32_t dataType;
	uint8_t  dataAttributes;
} FanSMCKeyData_keyInfo_t;

typedef struct {
	uint32_t                   key;
	FanSMCKeyData_vers_t       vers;
	FanSMCKeyData_pLimitData_t pLimitData;
	FanSMCKeyData_keyInfo_t    keyInfo;
	uint8_t                    result;
	uint8_t                    status;
	uint8_t                    data8;
	uint32_t                   data32;
	uint8_t                    bytes[32];
} FanSMCKeyData_t;

static uint32_t fanSmcKey(const char *s) {
	return ((uint32_t)(uint8_t)s[0] << 24)
	     | ((uint32_t)(uint8_t)s[1] << 16)
	     | ((uint32_t)(uint8_t)s[2] <<  8)
	     | ((uint32_t)(uint8_t)s[3]);
}

static kern_return_t fanSmcCall(io_connect_t conn, int idx,
                                FanSMCKeyData_t *in, FanSMCKeyData_t *out) {
	size_t inSz = sizeof(FanSMCKeyData_t), outSz = sizeof(FanSMCKeyData_t);
	return IOConnectCallStructMethod(conn, idx, in, inSz, out, &outSz);
}

// getFanSpeedAvg opens the SMC, reads FNum (number of fans), then reads
// F0Ac/F1Ac/... (fpe2 type: 16-bit big-endian unsigned, 2 fractional bits → ÷4 = RPM).
// Returns the average RPM across all fans, or -1.0 if no fans or SMC unavailable.
double getFanSpeedAvg() {
	io_iterator_t iter = 0;
	io_object_t   svc  = 0;
	io_connect_t  conn = 0;

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

	// Read FNum: number of fans (ui8, 1 byte)
	FanSMCKeyData_t in = {0}, out = {0};
	in.key   = fanSmcKey("FNum");
	in.data8 = SMC_CMD_READ_KEYINFO;
	if (fanSmcCall(conn, KERNEL_INDEX_SMC, &in, &out) != kIOReturnSuccess) {
		IOServiceClose(conn);
		return -1.0;
	}
	FanSMCKeyData_t in2 = {0}, out2 = {0};
	in2.key              = fanSmcKey("FNum");
	in2.keyInfo.dataSize = out.keyInfo.dataSize;
	in2.data8            = SMC_CMD_READ_BYTES;
	if (fanSmcCall(conn, KERNEL_INDEX_SMC, &in2, &out2) != kIOReturnSuccess) {
		IOServiceClose(conn);
		return -1.0;
	}
	int numFans = (int)(uint8_t)out2.bytes[0];
	if (numFans <= 0) {
		IOServiceClose(conn);
		return -1.0;
	}

	// Read each fan's actual speed (F0Ac, F1Ac, ...)
	// fpe2: 16-bit big-endian unsigned, 2 fractional bits → divide by 4 for RPM
	double total = 0.0;
	int    count = 0;
	for (int i = 0; i < numFans && i < 10; i++) {
		char keyStr[5];
		snprintf(keyStr, sizeof(keyStr), "F%dAc", i);

		FanSMCKeyData_t ki = {0}, ko = {0};
		ki.key   = fanSmcKey(keyStr);
		ki.data8 = SMC_CMD_READ_KEYINFO;
		if (fanSmcCall(conn, KERNEL_INDEX_SMC, &ki, &ko) != kIOReturnSuccess) continue;

		FanSMCKeyData_t ri = {0}, ro = {0};
		ri.key              = fanSmcKey(keyStr);
		ri.keyInfo.dataSize = ko.keyInfo.dataSize;
		ri.data8            = SMC_CMD_READ_BYTES;
		if (fanSmcCall(conn, KERNEL_INDEX_SMC, &ri, &ro) != kIOReturnSuccess) continue;

		// fpe2: 2 bytes big-endian, divide by 4
		uint16_t raw = ((uint16_t)(uint8_t)ro.bytes[0] << 8) | (uint8_t)ro.bytes[1];
		double rpm = (double)raw / 4.0;
		if (rpm >= 0) {
			total += rpm;
			count++;
		}
	}

	IOServiceClose(conn);
	if (count == 0) return -1.0;
	return total / (double)count;
}
*/
import "C"

// GetFanSpeed returns the average RPM across all fans via SMC.
// Returns -1 if the Mac is fanless or the SMC is unavailable.
func GetFanSpeed() float64 {
	return float64(C.getFanSpeedAvg())
}
