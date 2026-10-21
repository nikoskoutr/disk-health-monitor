#ifndef DISK_HEALTH_BRIDGE_H
#define DISK_HEALTH_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool found;
    char productName[128];
    char vendorName[128];
    char productRevision[64];
    char bsdName[64];
    char serialNumber[128];
    char usbSerialNumber[128];      // Kept for backward compatibility
    char interconnectType[64];      // "USB", "PCI-Express", "Thunderbolt", "SATA", etc.
    char protocolType[64];          // "NVMe", "SCSI", "ATA", etc.
    bool isInternal;
    bool isRemovable;
    uint64_t linkSpeedBps;
    uint64_t usbLinkSpeedBps;       // Kept for backward compatibility

    // NVMe SMART Data
    bool smartValid;
    uint8_t criticalWarning;
    int32_t temperatureCelsius;
    int32_t temperatureKelvin;
    uint8_t availableSpare;
    uint8_t availableSpareThreshold;
    uint8_t percentageUsed;
    uint64_t dataUnitsRead;
    uint64_t dataUnitsWritten;
    uint64_t hostReadCommands;
    uint64_t hostWriteCommands;
    uint64_t controllerBusyTime;
    uint64_t powerCycles;
    uint64_t powerOnHours;
    uint64_t unsafeShutdowns;
    uint64_t mediaErrors;
    uint64_t errorInfoLogEntries;

    // IOBlockStorageDriver Statistics
    bool statsValid;
    uint64_t bytesRead;
    uint64_t bytesWritten;
    uint64_t operationsRead;
    uint64_t operationsWritten;
    uint64_t errorsRead;
    uint64_t errorsWritten;
    uint64_t retriesRead;
    uint64_t retriesWritten;
    uint64_t totalTimeReadNs;
    uint64_t totalTimeWriteNs;
} DiskHardwareMetrics;

// Read hardware telemetry for a targeted drive or auto-detect
void DiskReadHardwareMetrics(const char *targetIdentifier, DiskHardwareMetrics *outMetrics);

// Enumerate all block storage devices on the system
int DiskListAllDevices(DiskHardwareMetrics *outArray, int maxCount);

// Find the mounted filesystem path for a block storage device (resolving APFS containers and partitions)
bool DiskFindMountForBlockDevice(const char *deviceBsdName, char *outMountPoint, size_t maxLen);

// Convert raw 16-bit NVMe composite temperature to Celsius with boundary validation
int32_t DiskConvertNVMeTemperature(uint16_t tempRaw);

// Safely decode 128-bit little-endian NVMe counter to 64-bit unsigned integer with UINT64_MAX saturation
uint64_t DiskDecodeNVMeLE128(const uint8_t *bytes);

// Normalize IOKit USB link speed or discrete speed code to bits per second
uint64_t DiskNormalizeLinkSpeedToBps(uint64_t rawSpeed);

// Safely extract a 64-bit unsigned integer from a CFDictionary, clamping negative numbers to 0
uint64_t DiskExtractCFNumberU64(CFDictionaryRef dict, CFStringRef key);

#ifdef __cplusplus
}
#endif

#endif // DISK_HEALTH_BRIDGE_H
