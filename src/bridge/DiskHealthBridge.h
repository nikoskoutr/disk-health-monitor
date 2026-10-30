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
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#endif

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
    uint32_t usbCurrentAvailableMa;     ///< USB bus current available to device in milliamperes (mA), or 0 if N/A.
    uint32_t usbCurrentRequiredMa;      ///< USB current requested/allocated by device in milliamperes (mA), or 0 if N/A.
    uint32_t linkWidthLanes;            ///< Active PCIe / Thunderbolt lane width (e.g. 1, 2, 4), or 0 if N/A.

    // ========================================================================
    // NVMe Base Specification 1.4+ S.M.A.R.T. / Health Information Log
    // ========================================================================
    bool smartValid;                    ///< True if IONVMeSMARTUserClient successfully returned SMART logs.
    uint8_t smartSourceType;            ///< Source: 0 = Native NVMe, 1 = SAT ATA (0x85), 2 = USB Vendor NVMe.
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
    uint32_t busErrorCount;             ///< Cumulative hardware PHY/link error counter (USB/Thunderbolt).
    uint32_t busResetCount;             ///< Cumulative bus/port reset counter.
} DiskHardwareMetrics;

typedef struct {
    char bsdName[64];                   ///< Volume BSD name (e.g. "disk3s5").
    char name[128];                     ///< Volume display name (e.g. "Macintosh HD", "Data").
    char role[64];                      ///< Volume role ("Data", "System", "VM", "Preboot", "Recovery", "Update", "User").
    uint64_t totalBytes;                ///< Total capacity allocated or available to volume.
    uint64_t usedBytes;                 ///< Bytes physically consumed by volume.
    uint64_t freeBytes;                 ///< Free space available in shared container pool.
    bool isEncrypted;                   ///< True if FileVault / APFS encryption is active.
} DiskApfsVolumeMetrics;

typedef struct {
    char containerBsd[64];              ///< Container BSD name (e.g. "disk3").
    uint64_t totalCapacityBytes;        ///< Total physical pool capacity of the APFS container.
    uint64_t freeSpaceBytes;            ///< Shared free space remaining in container.
    uint32_t volumeCount;               ///< Number of APFS volumes in this container.
} DiskApfsContainerMetrics;

/**
 * @brief Reads low-level hardware telemetry and SMART health metrics for a target drive.
 * 
 * If @p targetIdentifier is NULL or "auto", the bridge selects the first connected external
 * physical disk, falling back to the primary internal system disk if no external drive is attached.
 * Otherwise, it accepts a mount path (e.g. "/Volumes/MySSD"), a BSD name (e.g. "disk0",
 * "/dev/disk0"), a product model substring, or a serial number.
 * 
 * @param targetIdentifier Targeted drive identifier, or NULL/"auto" for auto-detection.
 * @param outMetrics Pointer to pre-allocated DiskHardwareMetrics struct to populate.
 * @note Thread-safe. Uses an internal 64-entry static cache for invariant hardware strings.
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
 * @brief Per-process disk I/O byte counters captured via Darwin libproc (proc_pid_rusage).
 */
typedef struct {
    int32_t pid;                        ///< POSIX process identifier.
    char processName[128];              ///< Executable process name (from proc_name).
    uint64_t diskBytesRead;             ///< Cumulative logical/physical bytes read from disk by process.
    uint64_t diskBytesWritten;          ///< Cumulative logical/physical bytes written to disk by process.
} DiskProcessIoMetric;

/**
 * @brief Enumerates active processes with non-zero disk I/O activity via Darwin libproc.
 *
 * Uses proc_listallpids and proc_pid_rusage (RUSAGE_INFO_V4) to capture cumulative disk read
 * and write byte counters for accessible processes without requiring root privileges for user tasks.
 *
 * @param outArray Pre-allocated array of DiskProcessIoMetric structs to populate.
 * @param maxCount Maximum number of entries to write into @p outArray.
 * @return Number of processes populated in @p outArray (0 on invalid arguments).
 * @note Thread-safe. Zero dynamic memory leaks.
 */
int DiskSampleProcessIoMetrics(DiskProcessIoMetric *outArray, int maxCount);

/**
 * @brief Describes an active process holding open file descriptors on a volume mount.
 */
typedef struct {
    int32_t pid;                        ///< Process ID holding the open file descriptor.
    char processName[128];              ///< Executable process name (from proc_name).
    char filePath[512];                 ///< Resolved absolute file path on the targeted mount.
    int32_t fd;                         ///< Open file descriptor index.
} DiskFileBlocker;

/**
 * @brief Lists active processes holding open file descriptors on a specific volume mount path.
 *
 * Uses Darwin <libproc.h> (proc_listallpids, PROC_PIDLISTFDS, and PROC_PIDFDVNODEPATHINFO)
 * to locate all processes actively holding open file handles pointing inside mountPath.
 *
 * @param mountPath Target mount directory (e.g. "/Volumes/T7" or "/").
 * @param outList Pre-allocated array of DiskFileBlocker structs.
 * @param maxCount Maximum number of entries to populate.
 * @return Number of open file blockers populated (or 0 if none/error).
 */
int DiskListOpenFileBlockers(const char *mountPath, DiskFileBlocker *outList, int maxCount);

/**
 * @brief Checks whether the macOS system is currently in Dark Wake (Power Nap) state.
 *
 * Inspects system display and power session state to detect if display is asleep
 * while system is awake, allowing background daemons to avoid waking external mechanical drives.
 *
 * @return 1 if Dark Wake / display-sleep state is active, 0 if display is active or on error.
 */
int DiskIsDarkWakeActive(void);

/**
 * @brief Resolves logical file offset and extent length to underlying physical disk LBA/byte offset (SCAN-02).
 *
 * Uses Darwin fcntl(F_LOG2PHYS_EXT) to query kernel block extents.
 *
 * @param fd Open file descriptor to query.
 * @param logicalOffset Byte offset within the file.
 * @param length Extent length in bytes to query.
 * @param outPhysOffset Output pointer for physical byte offset on the raw block device.
 * @param outContigBytes Output pointer for contiguous bytes available at this extent.
 * @return 0 on success, negative errno on failure.
 */
int DiskResolvePhysicalExtent(int fd, off_t logicalOffset, off_t length, uint64_t *outPhysOffset, uint64_t *outContigBytes);

/**
 * @brief Enumerates APFS volume roles and capacity sharing for a container (APFS-03).
 *
 * @param targetBsdOrMount Container BSD name (e.g. "disk3"), slice ("disk3s1"), or mount ("/").
 * @param outContainer Pointer to container summary struct to populate.
 * @param outVolumes Pre-allocated array of DiskApfsVolumeMetrics structs.
 * @param maxVolumes Maximum number of volume structs to populate.
 * @return Number of volumes populated.
 */
int DiskListApfsContainerVolumes(const char *targetBsdOrMount, DiskApfsContainerMetrics *outContainer, DiskApfsVolumeMetrics *outVolumes, int maxVolumes);

/**
 * @brief Downgrades or restores a process's scheduling and disk I/O tier (PROC-03).
 *
 * Uses Darwin setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG) to throttle runaway I/O.
 *
 * @param pid Process ID to adjust.
 * @param enable True to throttle into background I/O tier; false to restore normal tier.
 * @return 0 on success, negative errno on failure.
 */
int DiskSetProcessBackgroundIoPriority(pid_t pid, bool enable);

#ifdef __APPLE__
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
#endif

#ifdef __cplusplus
}
#endif

#endif // DISK_HEALTH_BRIDGE_H
