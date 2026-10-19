#include <stdio.h>
#include <string.h>
#include <assert.h>
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

    printf("\n=== All Bridge Tests Passed Successfully! ===\n");
    return 0;
}
