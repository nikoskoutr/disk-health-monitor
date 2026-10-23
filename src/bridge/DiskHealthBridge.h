// ============================================================================
// File: DiskHealthBridge.h
// Module: Layer 1 (C11 / IOKit Hardware Bridge)
// Purpose: Low-level C11 declarations for IOKit storage registry traversal,
//          NVMe S.M.A.R.T. extraction, driver statistics, and mount resolution.
// Concurrency: Thread-safe; internal memoization synchronized via pthread_mutex_t.
// ============================================================================

#ifndef DISK_HEALTH_BRIDGE_H
#define DISK_HEALTH_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Raw hardware telemetry and S.M.A.R.T. metrics captured from IOKit.
 * 
 * Aggregates hardware descriptors, NVMe Base Specification 1.4+ health counters,
 * and IOBlockStorageDriver low-level driver statistics for a single physical drive.
 */
typedef struct {
    bool found;                         ///< True if the physical block storage device was located in IORegistry.
    char productName[128];              ///< Commercial product/model designation (e.g. "APPLE SSD AP0256Z").
    char vendorName[128];               ///< Storage controller vendor name (e.g. "Apple", "Samsung").
    char productRevision[64];           ///< Firmware / hardware revision string.
    char bsdName[64];                   ///< Darwin kernel BSD name for the whole disk (e.g. "disk0").
    char serialNumber[128];             ///< Drive hardware serial number.
    char usbSerialNumber[128];          ///< Backward-compatibility mirror of serialNumber.
    char interconnectType[64];          ///< Bus type (e.g. "Apple Fabric", "PCI-Express", "USB", "Thunderbolt", "SATA").
    char protocolType[64];              ///< Transport protocol (e.g. "NVMe", "SCSI", "ATA").
    bool isInternal;                    ///< True for built-in Apple Silicon / Intel internal storage.
    bool isRemovable;                   ///< True for hot-pluggable external storage media.
    uint64_t linkSpeedBps;              ///< Physical interconnect link bandwidth normalized to bits per second (bps).
    uint64_t usbLinkSpeedBps;           ///< Backward-compatibility mirror of linkSpeedBps.

    // ========================================================================
    // NVMe Base Specification 1.4+ S.M.A.R.T. / Health Information Log
    // ========================================================================
    bool smartValid;                    ///< True if IONVMeSMARTUserClient successfully returned SMART logs.
    uint8_t criticalWarning;            ///< Bitmask of critical warnings (0x01: spare below threshold, 0x02: temp, etc.).
    int32_t temperatureCelsius;         ///< Composite controller temperature in degrees Celsius (validated & clamped).
    int32_t temperatureKelvin;          ///< Raw composite temperature in Kelvin as reported by NVMe controller.
    uint8_t availableSpare;             ///< Remaining spare capacity as a percentage (0% - 100%).
    uint8_t availableSpareThreshold;    ///< Minimum spare threshold where critical warning triggers (typically 10%).
    uint8_t percentageUsed;             ///< Vendor-declared wear percentage (0% = new; >= 100% = warranty exceeded).
    uint64_t dataUnitsRead;             ///< Cumulative data units read (1 unit = 1,000 * 512-byte sectors = 512,000 bytes).
    uint64_t dataUnitsWritten;          ///< Cumulative data units written (1 unit = 1,000 * 512-byte sectors = 512,000 bytes).
    uint64_t hostReadCommands;          ///< Total read I/O commands processed by the NVMe controller.
    uint64_t hostWriteCommands;         ///< Total write I/O commands processed by the NVMe controller.
    uint64_t controllerBusyTime;        ///< Total minutes the controller was actively processing I/O commands.
    uint64_t powerCycles;               ///< Cumulative count of power on/off cycles.
    uint64_t powerOnHours;              ///< Cumulative hours the drive has been in active operational power states.
    uint64_t unsafeShutdowns;           ///< Count of abrupt shutdowns without prior flush/shutdown notification.
    uint64_t mediaErrors;               ///< Unrecoverable read/write media data integrity errors.
    uint64_t errorInfoLogEntries;       ///< Cumulative number of entries logged to the NVMe Error Information log.

    // ========================================================================
    // IOBlockStorageDriver Kernel Performance & Reliability Statistics
    // ========================================================================
    bool statsValid;                    ///< True if IOBlockStorageDriver "Statistics" dictionary was present.
    uint64_t bytesRead;                 ///< Lifetime raw bytes read via kernel block storage driver.
    uint64_t bytesWritten;              ///< Lifetime raw bytes written via kernel block storage driver.
    uint64_t operationsRead;            ///< Cumulative read I/O operation count handled by driver.
    uint64_t operationsWritten;         ///< Cumulative write I/O operation count handled by driver.
    uint64_t errorsRead;                ///< Cumulative driver read I/O errors reported to Darwin kernel.
    uint64_t errorsWritten;             ///< Cumulative driver write I/O errors reported to Darwin kernel.
    uint64_t retriesRead;               ///< Cumulative driver read retry attempts.
    uint64_t retriesWritten;            ///< Cumulative driver write retry attempts.
    uint64_t totalTimeReadNs;           ///< Cumulative nanoseconds spent servicing read I/O requests.
    uint64_t totalTimeWriteNs;          ///< Cumulative nanoseconds spent servicing write I/O requests.
} DiskHardwareMetrics;

/**
 * @brief Reads low-level hardware telemetry and SMART health metrics for a target drive.
 * 
 * If @p targetIdentifier is NULL or "auto", the bridge queries the root filesystem ("/")
 * to resolve the primary system boot drive. Otherwise, it accepts a BSD name (e.g. "disk0",
 * "/dev/disk0"), a product model substring, or a serial number.
 * 
 * @param targetIdentifier Targeted drive identifier, or NULL for auto-detection.
 * @param outMetrics Pointer to pre-allocated DiskHardwareMetrics struct to populate.
 * @note Thread-safe. Uses an internal 32-entry static cache for invariant hardware strings.
 */
void DiskReadHardwareMetrics(const char *targetIdentifier, DiskHardwareMetrics *outMetrics);

/**
 * @brief Enumerates all physical whole block storage devices attached to the system.
 * 
 * Queries IOKit for IOBlockStorageDevice services, filters out virtual APFS containers
 * and RAM disks, and populates up to @p maxCount devices in @p outArray.
 * 
 * @param outArray Pointer to array of DiskHardwareMetrics structs.
 * @param maxCount Maximum number of elements to populate in @p outArray.
 * @return Number of physical devices found and populated.
 * @note Thread-safe.
 */
int DiskListAllDevices(DiskHardwareMetrics *outArray, int maxCount);

/**
 * @brief Resolves the mounted VFS filesystem path for a target physical block device.
 * 
 * Traverses Darwin getfsstat(2) mount entries, resolving APFS synthesized container schemes,
 * volume partition slices, and CoreStorage physical stores back to their physical root.
 * 
 * @param deviceBsdName Darwin whole-disk BSD name (e.g. "disk0").
 * @param outMountPoint Output buffer to store resolved mount path (e.g. "/" or "/Volumes/T7").
 * @param maxLen Capacity of @p outMountPoint buffer in bytes.
 * @return True if a valid mount point was successfully resolved; false otherwise.
 * @note Thread-safe. Implements stackFs[64] fast path to eliminate heap allocation.
 */
bool DiskFindMountForBlockDevice(const char *deviceBsdName, char *outMountPoint, size_t maxLen);

/**
 * @brief Converts a raw 16-bit NVMe composite temperature reading to degrees Celsius.
 * 
 * Validates that the raw temperature in Kelvin falls within physical operational limits
 * (233 K to 423 K, corresponding to -40°C to +150°C), clamping out-of-bounds readings.
 * 
 * @param tempRaw Raw 16-bit little-endian temperature from NVMe SMART payload in Kelvin.
 * @return Temperature in degrees Celsius, or 0 if invalid/unreported.
 */
int32_t DiskConvertNVMeTemperature(uint16_t tempRaw);

/**
 * @brief Safely decodes a 128-bit little-endian NVMe counter to a 64-bit unsigned integer.
 * 
 * Reads 16 raw bytes in little-endian byte order. If the upper 64 bits contain non-zero
 * values, the counter saturates safely at UINT64_MAX to prevent numeric overflow.
 * 
 * @param bytes Pointer to 16 contiguous bytes representing the 128-bit LE counter.
 * @return Decoded 64-bit value, or UINT64_MAX if upper bits overflow, or 0 if bytes is NULL.
 */
uint64_t DiskDecodeNVMeLE128(const uint8_t *bytes);

/**
 * @brief Normalizes raw IOKit link speed representations or speed codes to bits per second (bps).
 * 
 * Decodes discrete USB speed codes (1: Full Speed 12 Mbps, 2: High Speed 480 Mbps,
 * 3: SuperSpeed 5 Gbps, 4: SuperSpeed+ 10 Gbps, 5: USB4 20 Gbps) and passes
 * raw bit-rate values directly through.
 * 
 * @param rawSpeed Raw speed integer from IOKit properties.
 * @return Normalized bandwidth in bits per second (bps).
 */
uint64_t DiskNormalizeLinkSpeedToBps(uint64_t rawSpeed);

/**
 * @brief Safely extracts a 64-bit unsigned integer from a CoreFoundation dictionary.
 * 
 * Handles negative signed values by clamping to 0, preventing signed wrap-around
 * when interpreting kernel driver metrics.
 * 
 * @param dict CFDictionaryRef containing storage driver properties.
 * @param key CFStringRef dictionary key to query.
 * @return Extracted 64-bit unsigned value, or 0 if missing or negative.
 */
uint64_t DiskExtractCFNumberU64(CFDictionaryRef dict, CFStringRef key);

#ifdef __cplusplus
}
#endif

#endif // DISK_HEALTH_BRIDGE_H
