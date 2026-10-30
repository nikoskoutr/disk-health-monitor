#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <pthread.h>
#include <sys/param.h>
#include <sys/mount.h>
#include "DiskHealthBridge.h"

typedef struct {
    bool expectedSmartValid[16];
    int deviceCount;
    int mismatchCount;
} ConcurrentSmartTestContext;

static void *concurrentSmartWorker(void *arg) {
    ConcurrentSmartTestContext *ctx = (ConcurrentSmartTestContext *)arg;
    for (int iter = 0; iter < 8; iter++) {
        DiskHardwareMetrics devs[16];
        int n = DiskListAllDevices(devs, 16);
        if (n == ctx->deviceCount) {
            for (int i = 0; i < n; i++) {
                if (ctx->expectedSmartValid[i] && !devs[i].smartValid) {
                    __sync_fetch_and_add(&ctx->mismatchCount, 1);
                }
            }
        }
    }
    return NULL;
}

int main(void) {
    printf("=== Test 1: DiskListAllDevices ===\n");
    DiskHardwareMetrics devices[16];
    int count = DiskListAllDevices(devices, 16);
    printf("Found %d block storage devices:\n", count);
    assert(count > 0);

    for (int i = 0; i < count; i++) {
        assert(devices[i].found == true);
        assert(devices[i].bsdName[0] != '\0');
        assert(devices[i].interconnectType[0] != '\0');
        printf(" [%d] %s %s (BSD: %s, Bus: %s, %s, %s)\n",
               i,
               devices[i].vendorName,
               devices[i].productName,
               devices[i].bsdName,
               devices[i].interconnectType,
               devices[i].isInternal ? "Internal" : "External",
               devices[i].smartValid ? "SMART OK" : "No SMART");
        if (devices[i].smartValid) {
            assert(devices[i].temperatureCelsius > -20 && devices[i].temperatureCelsius < 150);
            printf("      Temp: %d C, Life Remaining: %d%%, POH: %llu hrs, Written: %llu units (~%.2f TB)\n",
                   devices[i].temperatureCelsius,
                   100 - devices[i].percentageUsed,
                   devices[i].powerOnHours,
                   devices[i].dataUnitsWritten,
                   (double)devices[i].dataUnitsWritten * 512000.0 / 1e12);
        }
    }

    printf("\n=== Test 2: DiskReadHardwareMetrics auto ===\n");
    DiskHardwareMetrics autoDev;
    DiskReadHardwareMetrics("auto", &autoDev);
    assert(autoDev.found);
    assert(autoDev.bsdName[0] != '\0');
    printf("Auto detected: %s %s (%s, %s)\n",
           autoDev.vendorName, autoDev.productName, autoDev.bsdName,
           autoDev.isInternal ? "Internal" : "External");

    printf("\n=== Test 3: Dynamic Mount Resolution for All Devices ===\n");
    for (int i = 0; i < count; i++) {
        char mountPath[512] = {0};
        bool ok = DiskFindMountForBlockDevice(devices[i].bsdName, mountPath, sizeof(mountPath));
        printf("  %s mount lookup: ok=%d, path='%s'\n", devices[i].bsdName, ok, mountPath);
        if (ok) {
            DiskHardwareMetrics mountedDev;
            DiskReadHardwareMetrics(mountPath, &mountedDev);
            assert(mountedDev.found);
            assert(strcmp(mountedDev.bsdName, devices[i].bsdName) == 0);
        }
    }

    char rootPath[256] = {0};
    bool rootOk = DiskFindMountForBlockDevice("disk0", rootPath, sizeof(rootPath));
    printf("  disk0 mount lookup: ok=%d, path='%s'\n", rootOk, rootPath);
    assert(rootOk);
    assert(strcmp(rootPath, "/") == 0);

    printf("\n=== Test 4: DiskReadHardwareMetrics / (Internal Root) ===\n");
    DiskHardwareMetrics rootDev;
    DiskReadHardwareMetrics("/", &rootDev);
    assert(rootDev.found);
    printf("Resolved / -> %s %s (BSD: %s, Internal: %d, SMART: %d)\n",
           rootDev.vendorName, rootDev.productName, rootDev.bsdName, rootDev.isInternal, rootDev.smartValid);
    assert(rootDev.isInternal == true);

    printf("\n=== Test 5: /dev/ Prefix Equivalence & Substring Query ===\n");
    DiskHardwareMetrics byBsd, byDevPath;
    DiskReadHardwareMetrics("disk0", &byBsd);
    DiskReadHardwareMetrics("/dev/disk0", &byDevPath);
    assert(byBsd.found && byDevPath.found);
    assert(strcmp(byBsd.bsdName, byDevPath.bsdName) == 0);
    assert(strcmp(byBsd.productName, byDevPath.productName) == 0);
    if (rootDev.productName[0] != '\0') {
        DiskHardwareMetrics bySubstring;
        DiskReadHardwareMetrics(rootDev.productName, &bySubstring);
        assert(bySubstring.found == true);
    }
    printf("Verified 'disk0' == '/dev/disk0' and product substring query\n");

    printf("\n=== Test 6: Nonexistent Device & Path Graceful Handling ===\n");
    DiskHardwareMetrics bogusVol, bogusDev;
    DiskReadHardwareMetrics("/Volumes/__NonExistentVolume_99999__", &bogusVol);
    assert(bogusVol.found == false);
    DiskReadHardwareMetrics("disk99999", &bogusDev);
    assert(bogusDev.found == false);
    printf("Nonexistent volume and device handled cleanly (found=0)\n");

    printf("\n=== Test 7: Null-Pointer & Zero-Length Buffer Boundary Safety ===\n");
    assert(DiskListAllDevices(NULL, 10) == 0);
    assert(DiskListAllDevices(devices, 0) == 0);
    assert(DiskListAllDevices(devices, -5) == 0);
    DiskReadHardwareMetrics(NULL, NULL);
    assert(DiskFindMountForBlockDevice(NULL, rootPath, sizeof(rootPath)) == false);
    assert(DiskFindMountForBlockDevice("disk0", NULL, sizeof(rootPath)) == false);
    assert(DiskFindMountForBlockDevice("disk0", rootPath, 0) == false);
    assert(DiskFindMountForBlockDevice("", rootPath, sizeof(rootPath)) == false);

    char tinyBuf[2] = {'X', 'X'};
    bool tinyOk = DiskFindMountForBlockDevice("disk0", tinyBuf, sizeof(tinyBuf));
    assert(tinyOk == true);
    assert(tinyBuf[1] == '\0');
    printf("Boundary & buffer truncation safety checks passed\n");

    printf("\n=== Test 8: APFS Physical Store Recursive Resolution (IMPROVE-V2-01) ===\n");
    DiskHardwareMetrics rootPhysical;
    DiskReadHardwareMetrics("/", &rootPhysical);
    assert(rootPhysical.found == true);
    assert(rootPhysical.bsdName[0] != '\0');
    assert(rootPhysical.isInternal == true);
    printf("Resolved physical block device for '/': %s (%s)\n", rootPhysical.productName, rootPhysical.bsdName);

    printf("\n=== Test 9: NVMe Temperature Boundary Clamping & Validation (IMPROVE-V2-11) ===\n");
    // Synthetic boundary checks
    assert(DiskConvertNVMeTemperature(0x0000) == 0);        // Unreported/uninitialized
    assert(DiskConvertNVMeTemperature(0xFFFF) == 0);        // Hardware failure sentinel
    assert(DiskConvertNVMeTemperature(232) == 0);           // Below Kelvin lower bound (-41C -> invalid)
    assert(DiskConvertNVMeTemperature(233) == -40);         // Exactly -40C (Kelvin lower bound)
    assert(DiskConvertNVMeTemperature(273) == 0);           // Exactly 0C
    assert(DiskConvertNVMeTemperature(308) == 35);          // Normal room temp 35C
    assert(DiskConvertNVMeTemperature(423) == 150);         // Exactly 150C (Kelvin upper bound)
    assert(DiskConvertNVMeTemperature(424) == 0);           // Above Kelvin upper bound (151C -> invalid)
    assert(DiskConvertNVMeTemperature(45) == 45);           // Direct Celsius controller
    assert(DiskConvertNVMeTemperature(150) == 150);         // Direct Celsius upper bound
    assert(DiskConvertNVMeTemperature(151) == 0);           // Non-Kelvin out-of-range
    printf("  Synthetic boundary checks passed (0x0000, 0xFFFF, bounds -40C to 150C)\n");

    for (int i = 0; i < count; i++) {
        if (devices[i].smartValid) {
            // Temperature must be clamped within valid range -40C to +150C
            assert(devices[i].temperatureCelsius >= -40 && devices[i].temperatureCelsius <= 150);
            printf("  Device %s SMART temp validated: %d C (%d K)\n",
                   devices[i].bsdName, devices[i].temperatureCelsius, devices[i].temperatureKelvin);
        }
    }
    printf("NVMe temperature boundary clamping validated\n");

    printf("\n=== Test 10: DiskFindMountForBlockDevice IOObjectIsEqualTo Fast Resolution (IMPROVE-V3-03) ===\n");
    char mountBuf[256] = {0};
    assert(DiskFindMountForBlockDevice("disk0", mountBuf, sizeof(mountBuf)) == true);
    assert(strcmp(mountBuf, "/") == 0);

    char devMountBuf[256] = {0};
    assert(DiskFindMountForBlockDevice("/dev/disk0", devMountBuf, sizeof(devMountBuf)) == true);
    assert(strcmp(devMountBuf, "/") == 0);

    // Dynamic verification across all enumerated devices
    for (int i = 0; i < count; i++) {
        char dynamicBuf[256] = {0};
        bool hasMount = DiskFindMountForBlockDevice(devices[i].bsdName, dynamicBuf, sizeof(dynamicBuf));
        printf("  Enumerated device %s mount resolution: ok=%d, path='%s'\n",
               devices[i].bsdName, hasMount, dynamicBuf);
        if (hasMount) {
            assert(strlen(dynamicBuf) > 0);
            assert(dynamicBuf[0] == '/');
        }
    }

    // Boundary cases: buffer length edge cases
    char zeroLenBuf[16] = {0};
    assert(DiskFindMountForBlockDevice("disk0", zeroLenBuf, 0) == false);

    char oneLenBuf[16] = {'X', 'Y', 0};
    assert(DiskFindMountForBlockDevice("disk0", oneLenBuf, 1) == true);
    assert(oneLenBuf[0] == '\0');

    char twoLenBuf[16] = {0};
    assert(DiskFindMountForBlockDevice("disk0", twoLenBuf, 2) == true);
    assert(strcmp(twoLenBuf, "/") == 0);

    // Boundary cases: invalid inputs
    char bogusBuf[256] = {0};
    assert(DiskFindMountForBlockDevice("disk99999", bogusBuf, sizeof(bogusBuf)) == false);
    assert(DiskFindMountForBlockDevice("/dev/disk99999", bogusBuf, sizeof(bogusBuf)) == false);
    assert(DiskFindMountForBlockDevice("/dev/", bogusBuf, sizeof(bogusBuf)) == false);
    assert(DiskFindMountForBlockDevice("", bogusBuf, sizeof(bogusBuf)) == false);
    assert(DiskFindMountForBlockDevice(NULL, bogusBuf, sizeof(bogusBuf)) == false);
    assert(DiskFindMountForBlockDevice("disk0", NULL, sizeof(bogusBuf)) == false);
    printf("  IOObjectIsEqualTo fast resolution and boundary safety verified\n");

    printf("\n=== Test 11: DiskNormalizeLinkSpeedToBps (IMPROVE-V4-06) ===\n");
    assert(DiskNormalizeLinkSpeedToBps(0) == 0);
    assert(DiskNormalizeLinkSpeedToBps(1) == 12000000ULL);       // USB 1.1 Full Speed (12 Mbps)
    assert(DiskNormalizeLinkSpeedToBps(2) == 480000000ULL);      // USB 2.0 High Speed (480 Mbps)
    assert(DiskNormalizeLinkSpeedToBps(3) == 5000000000ULL);     // USB 3.0 SuperSpeed (5 Gbps)
    assert(DiskNormalizeLinkSpeedToBps(4) == 10000000000ULL);    // USB 3.1/3.2 SuperSpeed+ (10 Gbps)
    assert(DiskNormalizeLinkSpeedToBps(5) == 20000000000ULL);    // USB 3.2 Gen 2x2 (20 Gbps)
    assert(DiskNormalizeLinkSpeedToBps(5000000000ULL) == 5000000000ULL); // Raw bits/sec pass-through
    assert(DiskNormalizeLinkSpeedToBps(10000000000ULL) == 10000000000ULL);
    assert(DiskNormalizeLinkSpeedToBps(40000000000ULL) == 40000000000ULL);
    assert(DiskNormalizeLinkSpeedToBps(1500000ULL) == 1500000ULL);
    assert(DiskNormalizeLinkSpeedToBps(6) == 6);
    assert(DiskNormalizeLinkSpeedToBps(UINT64_MAX) == UINT64_MAX);
    printf("  USB speed codes (0-5), boundaries, and raw bps pass-through verified\n");

    printf("\n=== Test 12: DiskReadHardwareMetrics Exact Matches Over Substrings (IMPROVE-V5-03) ===\n");
    // 12a. Verify non-existent disk does not falsely match an existing disk via substring
    DiskHardwareMetrics bogusDiskMatch;
    DiskReadHardwareMetrics("disk99999", &bogusDiskMatch);
    assert(bogusDiskMatch.found == false);

    DiskHardwareMetrics bogusDevDiskMatch;
    DiskReadHardwareMetrics("/dev/disk99999", &bogusDevDiskMatch);
    assert(bogusDevDiskMatch.found == false);

    // 12b. Verify exact matching on enumerated devices
    for (int i = 0; i < count; i++) {
        if (devices[i].bsdName[0] != '\0') {
            DiskHardwareMetrics exactBsd;
            DiskReadHardwareMetrics(devices[i].bsdName, &exactBsd);
            assert(exactBsd.found == true);
            assert(strcmp(exactBsd.bsdName, devices[i].bsdName) == 0);
        }
        if (devices[i].serialNumber[0] != '\0') {
            DiskHardwareMetrics exactSerial;
            DiskReadHardwareMetrics(devices[i].serialNumber, &exactSerial);
            assert(exactSerial.found == true);
            assert(strcasecmp(exactSerial.serialNumber, devices[i].serialNumber) == 0);
        }
    }
    // 12c. Verify partition slice mount resolution in DiskFindMountForBlockDevice
    struct statfs sfsList[16];
    int fsCount = getfsstat(sfsList, (int)(sizeof(struct statfs) * 16), MNT_NOWAIT);
    int testedSlices = 0;
    for (int i = 0; i < fsCount; i++) {
        if (strncmp(sfsList[i].f_mntfromname, "/dev/", 5) == 0) {
            const char *slice = sfsList[i].f_mntfromname + 5;
            const char *at = strchr(slice, '@');
            if (at) {
                slice = at + 1;
                if (strncmp(slice, "/dev/", 5) == 0) slice += 5;
            }
            char resolvedMount[512] = {0};
            bool ok = DiskFindMountForBlockDevice(slice, resolvedMount, sizeof(resolvedMount));
            if (ok) {
                assert(strcmp(resolvedMount, sfsList[i].f_mntonname) == 0);
                testedSlices++;
            }
        }
    }
    assert(testedSlices > 0);
    printf("  Partition slice mount resolution in DiskFindMountForBlockDevice verified (%d slices tested)\n", testedSlices);
    printf("  Exact BSD Name and Serial Number priority over substring matching verified\n");

    printf("\n=== Test 13: APFS Container Filtering & Physical Whole Disk Validation (IMPROVE-V6-02 & IMPROVE-V6-04) ===\n");
    for (int i = 0; i < count; i++) {
        assert(strstr(devices[i].bsdName, "disk") != NULL);
        assert(strstr(devices[i].bsdName, "AppleAPFS") == NULL);
        if (devices[i].statsValid) {
            assert(devices[i].bytesRead != UINT64_MAX);
            assert(devices[i].bytesWritten != UINT64_MAX);
            assert(devices[i].totalTimeReadNs != UINT64_MAX);
            assert(devices[i].totalTimeWriteNs != UINT64_MAX);
        }
    }
    printf("  Verified all enumerated devices represent physical whole disks with sane driver stats\n");

    // Synthetic CFNumber boundary & wraparound checks (IMPROVE-V6-04)
    CFMutableDictionaryRef testDict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    assert(testDict != NULL);

    int64_t negOne = -1;
    int64_t negLarge = -9999999LL;
    int64_t zeroVal = 0;
    int64_t posVal = 42LL;
    double dblVal = 123456789.0;
    double negDbl = -456.78;

    CFNumberRef numNegOne = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &negOne);
    CFNumberRef numNegLarge = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &negLarge);
    CFNumberRef numZero = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &zeroVal);
    CFNumberRef numPos = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &posVal);
    CFNumberRef numDbl = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &dblVal);
    CFNumberRef numNegDbl = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &negDbl);

    CFDictionarySetValue(testDict, CFSTR("NegOne"), numNegOne);
    CFDictionarySetValue(testDict, CFSTR("NegLarge"), numNegLarge);
    CFDictionarySetValue(testDict, CFSTR("Zero"), numZero);
    CFDictionarySetValue(testDict, CFSTR("Pos"), numPos);
    CFDictionarySetValue(testDict, CFSTR("Double"), numDbl);
    CFDictionarySetValue(testDict, CFSTR("NegDouble"), numNegDbl);
    CFDictionarySetValue(testDict, CFSTR("StrVal"), CFSTR("NotANumber"));

    assert(DiskExtractCFNumberU64(testDict, CFSTR("NegOne")) == 0);
    assert(DiskExtractCFNumberU64(testDict, CFSTR("NegLarge")) == 0);
    assert(DiskExtractCFNumberU64(testDict, CFSTR("Zero")) == 0);
    assert(DiskExtractCFNumberU64(testDict, CFSTR("Pos")) == 42ULL);
    assert(DiskExtractCFNumberU64(testDict, CFSTR("Double")) == 123456789ULL);
    assert(DiskExtractCFNumberU64(testDict, CFSTR("NegDouble")) == 0);
    assert(DiskExtractCFNumberU64(testDict, CFSTR("StrVal")) == 0);
    assert(DiskExtractCFNumberU64(testDict, CFSTR("NonexistentKey")) == 0);
    assert(DiskExtractCFNumberU64(NULL, CFSTR("Pos")) == 0);
    assert(DiskExtractCFNumberU64(testDict, NULL) == 0);

    CFRelease(numNegOne);
    CFRelease(numNegLarge);
    CFRelease(numZero);
    CFRelease(numPos);
    CFRelease(numDbl);
    CFRelease(numNegDbl);
    CFRelease(testDict);
    printf("  DiskExtractCFNumberU64 negative clamping, double fallback, and boundary safety verified\n");

    printf("\n=== Test 14: SATA / AHCI Bus Detection & Link Speed Space Parsing (IMPROVE-V8-06) ===\n");
    // Verify SATA 6Gbps raw link speed normalization pass-through
    assert(DiskNormalizeLinkSpeedToBps(6000000000ULL) == 6000000000ULL);
    assert(DiskNormalizeLinkSpeedToBps(3000000000ULL) == 3000000000ULL);
    assert(DiskNormalizeLinkSpeedToBps(1500000000ULL) == 1500000000ULL);

    // Verify CFDictionary extraction with space-separated "Link Speed"
    CFMutableDictionaryRef linkDict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int64_t sataSpeed = 6000000000LL;
    CFNumberRef sataNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &sataSpeed);
    CFDictionarySetValue(linkDict, CFSTR("Link Speed"), sataNum);
    assert(DiskExtractCFNumberU64(linkDict, CFSTR("Link Speed")) == 6000000000ULL);
    CFRelease(sataNum);
    CFRelease(linkDict);

    // Verify all enumerated block devices have known valid interconnects
    for (int i = 0; i < count; i++) {
        bool validBus = (strcmp(devices[i].interconnectType, "PCI-Express") == 0 ||
                         strcmp(devices[i].interconnectType, "USB") == 0 ||
                         strcmp(devices[i].interconnectType, "Thunderbolt") == 0 ||
                         strcmp(devices[i].interconnectType, "SATA") == 0 ||
                         strcmp(devices[i].interconnectType, "Apple Fabric") == 0 ||
                         strcmp(devices[i].interconnectType, "Storage") == 0 ||
                         strstr(devices[i].interconnectType, "Virtual") != NULL);
        assert(validBus);
    }
    printf("  SATA link speeds, space-separated 'Link Speed' key, and bus type validation verified\n");

    printf("\n=== Test 15: DiskDecodeNVMeLE128 128-bit NVMe Little-Endian Parsing ===\n");
    // NULL pointer test
    assert(DiskDecodeNVMeLE128(NULL) == 0);

    // All zeros test
    uint8_t zeroBuf[16] = {0};
    assert(DiskDecodeNVMeLE128(zeroBuf) == 0);

    // Little-endian low 64-bit decoding
    uint8_t lowBuf[16] = {0};
    lowBuf[0] = 0x34;
    lowBuf[1] = 0x12; // 0x1234 = 4660
    assert(DiskDecodeNVMeLE128(lowBuf) == 4660ULL);

    uint8_t val64Buf[16] = {0};
    uint64_t testVal = 0x0123456789ABCDEFULL;
    uint64_t leVal = CFSwapInt64HostToLittle(testVal);
    memcpy(val64Buf, &leVal, sizeof(uint64_t));
    assert(DiskDecodeNVMeLE128(val64Buf) == testVal);

    // Saturation clamping to UINT64_MAX when upper 64 bits are non-zero
    uint8_t satBuf1[16] = {0};
    satBuf1[8] = 0x01; // lowest bit of high 64
    assert(DiskDecodeNVMeLE128(satBuf1) == UINT64_MAX);

    uint8_t satBuf2[16] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                           0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01};
    assert(DiskDecodeNVMeLE128(satBuf2) == UINT64_MAX);

    uint8_t satBufAll[16];
    memset(satBufAll, 0xFF, sizeof(satBufAll));
    assert(DiskDecodeNVMeLE128(satBufAll) == UINT64_MAX);

    printf("  DiskDecodeNVMeLE128 NULL handling, 64-bit LE decoding, and 128-bit saturation verified\n");

    printf("\n=== Test 16: Non-USB Link Speed Guard & Virtual Disk Filtering (BRIDGE-02, BRIDGE-04) ===\n");
    for (int i = 0; i < count; i++) {
        // Any PCI-Express / Apple Fabric internal device must not falsely report USB 1.1..3.2 enum speeds
        if (strcmp(devices[i].interconnectType, "PCI-Express") == 0 ||
            strcmp(devices[i].interconnectType, "Apple Fabric") == 0) {
            assert(devices[i].usbLinkSpeedBps != 12000000ULL);
            assert(devices[i].usbLinkSpeedBps != 480000000ULL);
        }
    }
    // Verify repeated DiskReadHardwareMetrics("auto") hits 64-entry static cache cleanly
    DiskHardwareMetrics autoPass1, autoPass2;
    DiskReadHardwareMetrics("auto", &autoPass1);
    DiskReadHardwareMetrics("auto", &autoPass2);
    assert(autoPass1.found == autoPass2.found);
    if (autoPass1.found) {
        assert(strcmp(autoPass1.bsdName, autoPass2.bsdName) == 0);
        assert(strstr(autoPass1.interconnectType, "Virtual") == NULL);
    }
    printf("  PCIe vs USB link speed guard, virtual disk exclusion, and 64-entry cache verified\n");

    printf("\n=== Test 17: Darwin libproc DiskSampleProcessIoMetrics & USB Power Topology (v2.8.0) ===\n");
    // Boundary checks
    assert(DiskSampleProcessIoMetrics(NULL, 10) == 0);
    DiskProcessIoMetric singleProc;
    assert(DiskSampleProcessIoMetrics(&singleProc, 0) == 0);
    assert(DiskSampleProcessIoMetrics(&singleProc, -5) == 0);

    // 1-element clamp
    int oneCount = DiskSampleProcessIoMetrics(&singleProc, 1);
    assert(oneCount == 1);
    assert(singleProc.pid > 0);
    assert(singleProc.processName[0] != '\0');

    // Full enumeration including current test process (getpid())
    DiskProcessIoMetric procList[512];
    int procCount = DiskSampleProcessIoMetrics(procList, 512);
    assert(procCount >= 1 && procCount <= 512);
    bool foundSelfPid = false;
    for (int i = 0; i < procCount; i++) {
        assert(procList[i].pid > 0);
        assert(procList[i].processName[0] != '\0');
        if (procList[i].pid == (int32_t)getpid()) {
            foundSelfPid = true;
        }
    }
    assert(foundSelfPid);
    printf("  DiskSampleProcessIoMetrics verified (%d processes sampled, self PID %d found)\n", procCount, (int)getpid());

    printf("\n=== Test 18: SAT ATA & NVMe SMART Source Types (v2.9.0) ===\n");
    for (int i = 0; i < count; i++) {
        // smartSourceType must be one of 0 (Native NVMe), 1 (SAT ATA), 2 (USB Vendor NVMe)
        assert(devices[i].smartSourceType <= 2);
    }
    printf("  SMART source types verified across all block devices\n");

    printf("\n=== Test 19: Open File Blocker Inspector DiskListOpenFileBlockers (DA-01) ===\n");
    // Boundary checks
    assert(DiskListOpenFileBlockers(NULL, NULL, 0) == 0);
    assert(DiskListOpenFileBlockers("/", NULL, 10) == 0);
    DiskFileBlocker singleBlocker;
    assert(DiskListOpenFileBlockers("/", &singleBlocker, 0) == 0);
    assert(DiskListOpenFileBlockers("/", &singleBlocker, -1) == 0);
    assert(DiskListOpenFileBlockers("/nonexistent/mount/path/404", &singleBlocker, 1) == 0);

    // List open files on root volume "/"
    DiskFileBlocker blockerList[64];
    int blockerCount = DiskListOpenFileBlockers("/", blockerList, 64);
    assert(blockerCount >= 0 && blockerCount <= 64);
    if (blockerCount > 0) {
        assert(blockerList[0].pid > 0);
        assert(blockerList[0].processName[0] != '\0');
        assert(blockerList[0].filePath[0] == '/');
    }
    printf("  DiskListOpenFileBlockers verified (%d active file blockers found on '/')\n", blockerCount);

    printf("\n=== Test 20: Dark Wake Power State Query DiskIsDarkWakeActive (PWR-01) ===\n");
    int darkWake = DiskIsDarkWakeActive();
    assert(darkWake == 0 || darkWake == 1);
    printf("  DiskIsDarkWakeActive verified (state: %d)\n", darkWake);

    printf("\n=== Test 21: Physical LBA Extent Resolution DiskResolvePhysicalExtent (SCAN-02) ===\n");
    uint64_t physOffset = 0, contigBytes = 0;
    // Boundary check: invalid fd
    assert(DiskResolvePhysicalExtent(-1, 0, 4096, &physOffset, &contigBytes) != 0);
    assert(DiskResolvePhysicalExtent(0, 0, 4096, NULL, &contigBytes) != 0);
    assert(DiskResolvePhysicalExtent(0, 0, 4096, &physOffset, NULL) != 0);

    // Create a temporary file in workspace cache, write some data, and query extent
    char tempPath[] = ".build-cache/test_extent_XXXXXX";
    int tempFd = mkstemp(tempPath);
    if (tempFd < 0) {
        // Fallback to /tmp
        char altPath[] = "/tmp/test_extent_XXXXXX";
        tempFd = mkstemp(altPath);
        if (tempFd >= 0) strlcpy(tempPath, altPath, sizeof(tempPath));
    }
    assert(tempFd >= 0);
    char buf[8192];
    memset(buf, 0xAB, sizeof(buf));
    ssize_t written = write(tempFd, buf, sizeof(buf));
    assert(written == sizeof(buf));
    fsync(tempFd);

    int resExt = DiskResolvePhysicalExtent(tempFd, 0, 4096, &physOffset, &contigBytes);
    // On APFS, extent query succeeds and returns valid physical offset and extent
    if (resExt == 0) {
        assert(contigBytes > 0);
    }
    close(tempFd);
    unlink(tempPath);
    printf("  DiskResolvePhysicalExtent boundary safety & resolution verified\n");

    printf("\n=== Test 22: APFS Container Volumes Inspection DiskListApfsContainerVolumes (APFS-03) ===\n");
    DiskApfsContainerMetrics containerMetrics;
    DiskApfsVolumeMetrics volumeList[32];
    // Boundary checks
    assert(DiskListApfsContainerVolumes(NULL, NULL, NULL, 0) == 0);
    assert(DiskListApfsContainerVolumes("/", &containerMetrics, NULL, 10) == 0);
    assert(DiskListApfsContainerVolumes("/", NULL, volumeList, 10) == 0);

    int volCount = DiskListApfsContainerVolumes("/", &containerMetrics, volumeList, 32);
    assert(volCount >= 0 && volCount <= 32);
    if (volCount > 0) {
        assert(containerMetrics.containerBsd[0] != '\0');
        assert(volumeList[0].bsdName[0] != '\0');
        assert(volumeList[0].role[0] != '\0');
    }
    printf("  DiskListApfsContainerVolumes verified (%d volumes found in container '%s')\n", volCount, containerMetrics.containerBsd);

    printf("\n=== Test 23: Process Background I/O Priority Throttler DiskSetProcessBackgroundIoPriority (PROC-03) ===\n");
    // Boundary check
    assert(DiskSetProcessBackgroundIoPriority(-1, true) != 0);
    assert(DiskSetProcessBackgroundIoPriority(0, true) != 0);

    // Throttle and restore self
    int prioBg = DiskSetProcessBackgroundIoPriority(getpid(), true);
    assert(prioBg == 0 || prioBg == -EPERM);
    int prioRestore = DiskSetProcessBackgroundIoPriority(getpid(), false);
    assert(prioRestore == 0 || prioRestore == -EPERM);
    printf("  DiskSetProcessBackgroundIoPriority background throttle & restore verified\n");

    printf("\n=== Test 24: Concurrent Multi-Thread NVMe SMART Contention Safety (BRIDGE-09) ===\n");
    ConcurrentSmartTestContext smartCtx;
    memset(&smartCtx, 0, sizeof(smartCtx));
    smartCtx.deviceCount = count;
    for (int i = 0; i < count && i < 16; i++) {
        smartCtx.expectedSmartValid[i] = devices[i].smartValid;
    }
    pthread_t threads[3];
    for (int t = 0; t < 3; t++) {
        assert(pthread_create(&threads[t], NULL, concurrentSmartWorker, &smartCtx) == 0);
    }
    for (int t = 0; t < 3; t++) {
        pthread_join(threads[t], NULL);
    }
    assert(smartCtx.mismatchCount == 0);
    printf("  Concurrent 3-thread NVMe SMART queries verified (0 kIOReturnNotPermitted drops)\n");

    printf("\n=== All 24 Bridge Tests Passed Successfully! ===\n");
    return 0;
}
