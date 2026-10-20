#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <sys/param.h>
#include <sys/mount.h>
#include "DiskHealthBridge.h"

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

    printf("\n=== All Bridge Tests Passed Successfully! ===\n");
    return 0;
}
