// ============================================================================
// File: DiskHealthBridge.c
// Module: Layer 1 (C11 / IOKit Hardware Bridge)
// Purpose: Implementation of Darwin IOKit storage registry traversal,
//          NVMe S.M.A.R.T. extraction, driver statistics, and mount resolution.
// Concurrency: Thread-safe; internal memoization ring buffer synchronized via
//              pthread_mutex_t (sStaticCacheMutex).
// ============================================================================

#define _GNU_SOURCE
#include "DiskHealthBridge.h"
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include <pthread.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/IOBlockStorageDevice.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <IOKit/storage/IOMedia.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

// ============================================================================
// MARK: - Static Registry Cache Structures & Invariants
// ============================================================================

/**
 * @brief Invariant hardware metadata memoized per IORegistryEntryID.
 * 
 * Hardware descriptors (vendor, product, serial number, interconnect type, link speed)
 * never change during the lifetime of a physical device attachment. Memoizing them
 * saves expensive CoreFoundation string allocations on every 30-second poll cycle.
 */
typedef struct {
    uint64_t entryId;               ///< Unique 64-bit kernel registry identifier (IORegistryEntryGetRegistryEntryID).
    char productName[128];          ///< Model name (e.g. "Samsung PSSD T7").
    char vendorName[128];           ///< Vendor name (e.g. "Samsung").
    char productRevision[64];       ///< Firmware version string.
    char bsdName[64];               ///< BSD name at initial capture (e.g. "disk6").
    char serialNumber[128];         ///< Hardware serial number.
    char interconnectType[64];      ///< Bus type (e.g. "USB", "PCI-Express").
    bool isInternal;                ///< Internal storage indicator.
    bool isRemovable;               ///< Removable media indicator.
    uint64_t linkSpeedBps;          ///< Normalized interconnect bandwidth in bits per second.
} StaticDeviceCacheEntry;

#define MAX_STATIC_CACHE_ENTRIES 64

/** Ring buffer storing static hardware descriptors for up to 64 block storage devices. */
static StaticDeviceCacheEntry sStaticCache[MAX_STATIC_CACHE_ENTRIES];
static int sStaticCacheCount = 0;
static int sStaticCacheNextIdx = 0;

/** Mutex synchronizing access to sStaticCache across concurrent engine / CLI threads. */
static pthread_mutex_t sStaticCacheMutex = PTHREAD_MUTEX_INITIALIZER;

/** Returns true if the device represents a virtual disk image or file-backed volume. */
static bool isVirtualDiskDevice(const DiskHardwareMetrics *metrics) {
    if (!metrics) return false;
    if (strcasestr(metrics->interconnectType, "Virtual") != NULL ||
        strcasestr(metrics->interconnectType, "File") != NULL) {
        return true;
    }
    if (strcasestr(metrics->productName, "Disk Image") != NULL ||
        strcasestr(metrics->vendorName, "Disk Image") != NULL) {
        return true;
    }
    return false;
}

// ============================================================================
// MARK: - CoreFoundation Safe Extraction Helpers
// ============================================================================

/**
 * @brief Safely copies a CFStringRef into a null-terminated UTF-8 C string buffer.
 * 
 * @param strRef CoreFoundation object reference to extract from.
 * @param buf Target C string buffer.
 * @param bufLen Size of target buffer in bytes.
 * @return True if conversion succeeded; false otherwise.
 * @note Always guarantees null-termination if bufLen > 0.
 */
static bool copyCFStringRefToBuffer(CFTypeRef strRef, char *buf, size_t bufLen) {
    if (!strRef || !buf || bufLen == 0) return false;
    if (CFGetTypeID(strRef) != CFStringGetTypeID()) return false;
    if (CFStringGetCString((CFStringRef)strRef, buf, (CFIndex)bufLen, kCFStringEncodingUTF8)) {
        buf[bufLen - 1] = '\0';
        return true;
    }
    buf[0] = '\0';
    return false;
}

/**
 * @brief Extracts a string property from a CFDictionary by key.
 * 
 * @param dict CFDictionaryRef containing properties.
 * @param key CFStringRef property key.
 * @param buf Target output buffer.
 * @param bufLen Target buffer capacity in bytes.
 * @return True if string was found and copied; false otherwise.
 */
static bool getCFString(CFDictionaryRef dict, CFStringRef key, char *buf, size_t bufLen) {
    if (!dict || !key || !buf || bufLen == 0) return false;
    buf[0] = '\0';
    CFTypeRef val = CFDictionaryGetValue(dict, key);
    return copyCFStringRefToBuffer(val, buf, bufLen);
}

/**
 * @brief Safely extracts a 64-bit unsigned integer from a CFDictionary.
 * 
 * Clamps negative signed values to 0 to prevent unsigned wrap-around.
 * 
 * @param dict CFDictionaryRef to inspect.
 * @param key CFStringRef key to look up.
 * @return 64-bit unsigned integer, or 0 if missing or negative.
 */
static uint64_t getCFNumberU64(CFDictionaryRef dict, CFStringRef key) {
    if (!dict || !key) return 0;
    CFTypeRef val = CFDictionaryGetValue(dict, key);
    if (val && CFGetTypeID(val) == CFNumberGetTypeID()) {
        int64_t signedNum = 0;
        if (CFNumberGetValue((CFNumberRef)val, kCFNumberSInt64Type, &signedNum)) {
            return signedNum < 0 ? 0 : (uint64_t)signedNum;
        }
        double dblNum = 0;
        if (CFNumberGetValue((CFNumberRef)val, kCFNumberDoubleType, &dblNum) && dblNum >= 0.0) {
            return (uint64_t)dblNum;
        }
    }
    return 0;
}

uint64_t DiskExtractCFNumberU64(CFDictionaryRef dict, CFStringRef key) {
    return getCFNumberU64(dict, key);
}

// ============================================================================
// MARK: - NVMe & Bus Decoding Utilities
// ============================================================================

uint64_t DiskDecodeNVMeLE128(const uint8_t *bytes) {
    if (!bytes) return 0;
    uint64_t low = 0;
    uint64_t high = 0;
    memcpy(&low, bytes, sizeof(uint64_t));
    memcpy(&high, bytes + sizeof(uint64_t), sizeof(uint64_t));
    // If upper 64 bits contain non-zero data, saturate at UINT64_MAX
    if (CFSwapInt64LittleToHost(high) != 0) {
        return UINT64_MAX;
    }
    return CFSwapInt64LittleToHost(low);
}

/** Internal wrapper for decoding NVMe 128-bit little-endian fields. */
static uint64_t nvmeLe128ToU64(const void *ptr) {
    return DiskDecodeNVMeLE128((const uint8_t *)ptr);
}

int32_t DiskConvertNVMeTemperature(uint16_t tempRaw) {
    if (tempRaw >= 233 && tempRaw <= 423) {
        // Valid Kelvin range: 233K (-40°C) to 423K (+150°C)
        return (int32_t)tempRaw - 273;
    } else if (tempRaw > 0 && tempRaw <= 150) {
        // Non-standard controller reporting directly in Celsius
        return (int32_t)tempRaw;
    } else {
        // 0 (unreported) or corrupt/sentinel value (e.g. 0xFFFF): default to nominal 0
        return 0;
    }
}

uint64_t DiskNormalizeLinkSpeedToBps(uint64_t rawSpeed) {
    switch (rawSpeed) {
        case 0: return 0;
        case 1: return 12000000ULL;       // USB 1.1 Full Speed (12 Mbps)
        case 2: return 480000000ULL;      // USB 2.0 High Speed (480 Mbps)
        case 3: return 5000000000ULL;     // USB 3.0 SuperSpeed (5 Gbps)
        case 4: return 10000000000ULL;    // USB 3.1/3.2 SuperSpeed+ (10 Gbps)
        case 5: return 20000000000ULL;    // USB 3.2 Gen 2x2 (20 Gbps)
        default:
            return rawSpeed;              // Native bps rate pass-through
    }
}

// ============================================================================
// MARK: - Registry Inspection: Parent & Child Traversal
// ============================================================================

/**
 * @brief Inspects parent chain in kIOServicePlane for USB / Thunderbolt / bus properties.
 * 
 * Invariant (SYS-06): USB and Thunderbolt controllers sit higher in the registry tree
 * than local PCIe/NVMe bridges. We allow USB / Thunderbolt parent nodes to take precedence
 * so external Thunderbolt NVMe enclosures are correctly identified as external buses.
 * 
 * @param entry Starting io_registry_entry_t to inspect.
 * @param outMetrics Metrics struct to update with link speed, serial number, and interconnect.
 */
static void inspectParentsForBusProperties(io_registry_entry_t entry, DiskHardwareMetrics *outMetrics) {
    io_registry_entry_t current = entry;
    IOObjectRetain(current);

    for (int depth = 0; depth < 16; depth++) {
        io_registry_entry_t parent = 0;
        kern_return_t kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
        if (kr != KERN_SUCCESS || parent == 0) {
            if (parent != 0) {
                IOObjectRelease(parent);
            }
            break;
        }

        // Parent service class name check for bus type classification (evaluated before LinkSpeed)
        bool isUSBParent = false;
        io_name_t className;
        if (IOObjectGetClass(parent, className) == KERN_SUCCESS) {
            if (strstr(className, "USB") != NULL) {
                strlcpy(outMetrics->interconnectType, "USB", sizeof(outMetrics->interconnectType));
                outMetrics->isInternal = false;
                isUSBParent = true;
            } else if (strstr(className, "Thunderbolt") != NULL) {
                strlcpy(outMetrics->interconnectType, "Thunderbolt", sizeof(outMetrics->interconnectType));
                outMetrics->isInternal = false;
            } else if (strstr(className, "DiskImage") != NULL || strstr(className, "HDIX") != NULL) {
                strlcpy(outMetrics->interconnectType, "Virtual Interface", sizeof(outMetrics->interconnectType));
                outMetrics->isInternal = false;
            } else if (outMetrics->interconnectType[0] == '\0') {
                if (strstr(className, "AHCI") != NULL || strstr(className, "SATA") != NULL) {
                    strlcpy(outMetrics->interconnectType, "SATA", sizeof(outMetrics->interconnectType));
                } else if (strstr(className, "PCI") != NULL || strstr(className, "NVMe") != NULL) {
                    strlcpy(outMetrics->interconnectType, "PCI-Express", sizeof(outMetrics->interconnectType));
                }
            }
        }

        // Interconnect Link Speed
        bool isExplicitUSBProperty = false;
        CFTypeRef linkSpeedRef = IORegistryEntryCreateCFProperty(parent, CFSTR("UsbLinkSpeed"), kCFAllocatorDefault, 0);
        if (linkSpeedRef) {
            isExplicitUSBProperty = true;
        } else {
            linkSpeedRef = IORegistryEntryCreateCFProperty(parent, CFSTR("Device Speed"), kCFAllocatorDefault, 0);
            if (linkSpeedRef) {
                isExplicitUSBProperty = true;
            }
        }
        if (!linkSpeedRef) {
            linkSpeedRef = IORegistryEntryCreateCFProperty(parent, CFSTR("LinkSpeed"), kCFAllocatorDefault, 0);
        }
        if (!linkSpeedRef) {
            linkSpeedRef = IORegistryEntryCreateCFProperty(parent, CFSTR("Link Speed"), kCFAllocatorDefault, 0);
        }
        if (linkSpeedRef) {
            if (CFGetTypeID(linkSpeedRef) == CFNumberGetTypeID() && outMetrics->linkSpeedBps == 0) {
                int64_t signedSpeed = 0;
                if (CFNumberGetValue((CFNumberRef)linkSpeedRef, kCFNumberSInt64Type, &signedSpeed) && signedSpeed > 0) {
                    bool isUSBContext = isExplicitUSBProperty || isUSBParent ||
                                        (strcasecmp(outMetrics->interconnectType, "USB") == 0);
                    // Only apply 1..5 USB enum code table when in a USB context; raw bps (>= 1 Mbps) always pass through
                    if (isUSBContext || signedSpeed >= 1000000LL) {
                        uint64_t bps = DiskNormalizeLinkSpeedToBps((uint64_t)signedSpeed);
                        if (bps > 0) {
                            outMetrics->linkSpeedBps = bps;
                            outMetrics->usbLinkSpeedBps = bps;
                        }
                    }
                }
            }
            CFRelease(linkSpeedRef);
        }

        // Hardware Serial Number
        if (outMetrics->serialNumber[0] == '\0') {
            CFTypeRef serialRef = IORegistryEntryCreateCFProperty(parent, CFSTR("USB Serial Number"), kCFAllocatorDefault, 0);
            if (!serialRef) {
                serialRef = IORegistryEntryCreateCFProperty(parent, CFSTR("kUSBSerialNumberString"), kCFAllocatorDefault, 0);
            }
            if (!serialRef) {
                serialRef = IORegistryEntryCreateCFProperty(parent, CFSTR("Serial Number"), kCFAllocatorDefault, 0);
            }
            if (serialRef) {
                if (copyCFStringRefToBuffer(serialRef, outMetrics->serialNumber, sizeof(outMetrics->serialNumber))) {
                    strlcpy(outMetrics->usbSerialNumber, outMetrics->serialNumber, sizeof(outMetrics->usbSerialNumber));
                }
                CFRelease(serialRef);
            }
        }

        IOObjectRelease(current);
        current = parent;
    }
    IOObjectRelease(current);
}

/**
 * @brief Recursively traverses children to locate IOBlockStorageDriver stats and whole-disk BSD Name.
 * 
 * Invariants:
 * 1. APFS Subtree Pruning (C11-01): AppleAPFSMedia nodes declare Whole = true. If we descended into
 *    virtual APFS containers, they would overwrite the physical drive's bsdName (e.g. disk0 -> disk3).
 *    Therefore, AppleAPFSContainerScheme, AppleAPFSContainer, AppleAPFSMedia, and AppleAPFSVolume
 *    are strictly pruned at the entry point of the recursive traversal.
 * 2. Bounded Recursion: Depth is strictly clamped to <= 12 levels to prevent stack overflow.
 * 
 * @param entry Starting io_registry_entry_t.
 * @param outMetrics Metrics struct to populate.
 * @param depth Current recursion depth (0 to 12).
 */
static void inspectChildrenForDriverStatsRecursive(io_registry_entry_t entry, DiskHardwareMetrics *outMetrics, int depth) {
    if (!entry || !outMetrics || depth > 12) return;
    if (outMetrics->statsValid && outMetrics->bsdName[0] != '\0') return;

    io_iterator_t childIter = 0;
    if (IORegistryEntryGetChildIterator(entry, kIOServicePlane, &childIter) != KERN_SUCCESS || !childIter) {
        return;
    }

    io_registry_entry_t child;
    while ((child = IOIteratorNext(childIter)) != 0) {
        // Prune synthesized APFS container subtrees completely so we never descend into
        // virtual AppleAPFSMedia (Whole=true) or virtual container statistics.
        if (IOObjectConformsTo(child, "AppleAPFSContainerScheme") ||
            IOObjectConformsTo(child, "AppleAPFSContainer") ||
            IOObjectConformsTo(child, "AppleAPFSMedia") ||
            IOObjectConformsTo(child, "AppleAPFSVolume")) {
            IOObjectRelease(child);
            continue;
        }

        // Look for Driver Statistics dictionary on IOBlockStorageDriver
        if (!outMetrics->statsValid && IOObjectConformsTo(child, "IOBlockStorageDriver")) {
            CFTypeRef statsRef = IORegistryEntryCreateCFProperty(child, CFSTR("Statistics"), kCFAllocatorDefault, 0);
            if (statsRef) {
                if (CFGetTypeID(statsRef) == CFDictionaryGetTypeID()) {
                    CFDictionaryRef stats = (CFDictionaryRef)statsRef;
                    outMetrics->statsValid = true;
                    outMetrics->bytesRead = getCFNumberU64(stats, CFSTR("Bytes (Read)"));
                    outMetrics->bytesWritten = getCFNumberU64(stats, CFSTR("Bytes (Write)"));
                    outMetrics->operationsRead = getCFNumberU64(stats, CFSTR("Operations (Read)"));
                    outMetrics->operationsWritten = getCFNumberU64(stats, CFSTR("Operations (Write)"));
                    outMetrics->errorsRead = getCFNumberU64(stats, CFSTR("Errors (Read)"));
                    outMetrics->errorsWritten = getCFNumberU64(stats, CFSTR("Errors (Write)"));
                    outMetrics->retriesRead = getCFNumberU64(stats, CFSTR("Retries (Read)"));
                    outMetrics->retriesWritten = getCFNumberU64(stats, CFSTR("Retries (Write)"));
                    outMetrics->totalTimeReadNs = getCFNumberU64(stats, CFSTR("Total Time (Read)"));
                    outMetrics->totalTimeWriteNs = getCFNumberU64(stats, CFSTR("Total Time (Write)"));
                }
                CFRelease(statsRef);
            }
        }

        // Look for physical IOMedia node containing BSD Name (Whole == true and not AppleAPFSMedia)
        if (IOObjectConformsTo(child, "IOMedia") && outMetrics->bsdName[0] == '\0') {
            CFTypeRef wholeRef = IORegistryEntryCreateCFProperty(child, CFSTR("Whole"), kCFAllocatorDefault, 0);
            bool isWhole = false;
            if (wholeRef) {
                if (CFGetTypeID(wholeRef) == CFBooleanGetTypeID()) {
                    isWhole = CFBooleanGetValue((CFBooleanRef)wholeRef);
                }
                CFRelease(wholeRef);
            }

            if (isWhole) {
                CFTypeRef bsdRef = IORegistryEntryCreateCFProperty(child, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
                if (bsdRef) {
                    copyCFStringRefToBuffer(bsdRef, outMetrics->bsdName, sizeof(outMetrics->bsdName));
                    CFRelease(bsdRef);
                }
            }
        }

        if (!(outMetrics->statsValid && outMetrics->bsdName[0] != '\0')) {
            inspectChildrenForDriverStatsRecursive(child, outMetrics, depth + 1);
        }

        IOObjectRelease(child);
        if (outMetrics->statsValid && outMetrics->bsdName[0] != '\0') {
            break;
        }
    }
    IOObjectRelease(childIter);
}

/** Helper starting recursive child driver inspection at depth 0. */
static void inspectChildrenForDriverStats(io_registry_entry_t service, DiskHardwareMetrics *outMetrics) {
    inspectChildrenForDriverStatsRecursive(service, outMetrics, 0);
}

// ============================================================================
// MARK: - Metrics Extraction & NVMe S.M.A.R.T. Plugin
// ============================================================================

/**
 * @brief Populates hardware descriptors, NVMe SMART, and driver stats for an IOBlockStorageDevice.
 * 
 * Invariant (UAT2-03): sStaticCache memoizes invariant strings (productName, vendorName, serialNumber,
 * interconnectType, linkSpeedBps) but DELIBERATELY OMITS restoring bsdName on cache hit.
 * inspectChildrenForDriverStats is ALWAYS called on every evaluation to query the live IOMedia child
 * node. This prevents the stale BSD name defect when an external USB disk is replugged and assigned
 * a new BSD name (e.g. disk6 -> disk7) while retaining its same serial number.
 * 
 * @param service io_service_t pointing to an IOBlockStorageDevice.
 * @param outMetrics Pointer to DiskHardwareMetrics to populate.
 */
static void populateMetricsFromBlockStorageDevice(io_service_t service, DiskHardwareMetrics *outMetrics) {
    if (!service || !outMetrics) return;
    memset(outMetrics, 0, sizeof(DiskHardwareMetrics));
    outMetrics->found = true;

    uint64_t entryId = 0;
    bool hasEntryId = (IORegistryEntryGetRegistryEntryID(service, &entryId) == KERN_SUCCESS && entryId != 0);
    bool cacheHit = false;

    if (hasEntryId) {
        pthread_mutex_lock(&sStaticCacheMutex);
        for (int i = 0; i < sStaticCacheCount; i++) {
            if (sStaticCache[i].entryId == entryId) {
                strlcpy(outMetrics->productName, sStaticCache[i].productName, sizeof(outMetrics->productName));
                strlcpy(outMetrics->vendorName, sStaticCache[i].vendorName, sizeof(outMetrics->vendorName));
                strlcpy(outMetrics->productRevision, sStaticCache[i].productRevision, sizeof(outMetrics->productRevision));
                strlcpy(outMetrics->serialNumber, sStaticCache[i].serialNumber, sizeof(outMetrics->serialNumber));
                strlcpy(outMetrics->usbSerialNumber, sStaticCache[i].serialNumber, sizeof(outMetrics->usbSerialNumber));
                strlcpy(outMetrics->interconnectType, sStaticCache[i].interconnectType, sizeof(outMetrics->interconnectType));
                outMetrics->isInternal = sStaticCache[i].isInternal;
                outMetrics->isRemovable = sStaticCache[i].isRemovable;
                outMetrics->linkSpeedBps = sStaticCache[i].linkSpeedBps;
                outMetrics->usbLinkSpeedBps = sStaticCache[i].linkSpeedBps;
                cacheHit = true;
                break;
            }
        }
        pthread_mutex_unlock(&sStaticCacheMutex);
    }

    if (!cacheHit) {
        // 1. Device Characteristics
        CFTypeRef charsRef = IORegistryEntryCreateCFProperty(service, CFSTR("Device Characteristics"), kCFAllocatorDefault, 0);
        if (charsRef) {
            if (CFGetTypeID(charsRef) == CFDictionaryGetTypeID()) {
                CFDictionaryRef chars = (CFDictionaryRef)charsRef;
                getCFString(chars, CFSTR("Product Name"), outMetrics->productName, sizeof(outMetrics->productName));
                getCFString(chars, CFSTR("Vendor Name"), outMetrics->vendorName, sizeof(outMetrics->vendorName));
                getCFString(chars, CFSTR("Product Revision Level"), outMetrics->productRevision, sizeof(outMetrics->productRevision));
                getCFString(chars, CFSTR("Serial Number"), outMetrics->serialNumber, sizeof(outMetrics->serialNumber));
                strlcpy(outMetrics->usbSerialNumber, outMetrics->serialNumber, sizeof(outMetrics->usbSerialNumber));

                char removableStr[32] = {0};
                if (getCFString(chars, CFSTR("Removable Media"), removableStr, sizeof(removableStr))) {
                    if (strcasecmp(removableStr, "Yes") == 0 || strcasecmp(removableStr, "True") == 0) {
                        outMetrics->isRemovable = true;
                    }
                }
            }
            CFRelease(charsRef);
        }

        // 2. Protocol Characteristics
        CFTypeRef protoRef = IORegistryEntryCreateCFProperty(service, CFSTR("Protocol Characteristics"), kCFAllocatorDefault, 0);
        if (protoRef) {
            if (CFGetTypeID(protoRef) == CFDictionaryGetTypeID()) {
                CFDictionaryRef proto = (CFDictionaryRef)protoRef;
                getCFString(proto, CFSTR("Physical Interconnect"), outMetrics->interconnectType, sizeof(outMetrics->interconnectType));
                char location[64] = {0};
                if (getCFString(proto, CFSTR("Physical Interconnect Location"), location, sizeof(location))) {
                    if (strcasecmp(location, "Internal") == 0) {
                        outMetrics->isInternal = true;
                    } else if (strcasecmp(location, "External") == 0) {
                        outMetrics->isInternal = false;
                    }
                }
            }
            CFRelease(protoRef);
        }

        // Class name check for internal NVMe / Apple fabric / VirtIO VM disks
        io_name_t deviceClassName;
        if (IOObjectGetClass(service, deviceClassName) == KERN_SUCCESS) {
            if (strstr(deviceClassName, "AppleANS") != NULL ||
                strstr(deviceClassName, "EmbeddedNVMe") != NULL ||
                strstr(deviceClassName, "VirtIO") != NULL) {
                outMetrics->isInternal = true;
                if (outMetrics->interconnectType[0] == '\0') {
                    strlcpy(outMetrics->interconnectType, "PCI-Express", sizeof(outMetrics->interconnectType));
                }
            }
        }

        // 3. Inspect parents for bus speed, serial number, and interconnect fallback
        inspectParentsForBusProperties(service, outMetrics);
    }

    // 4. Always inspect children for driver statistics and live BSD Name (UAT2-03)
    inspectChildrenForDriverStats(service, outMetrics);

    if (!cacheHit) {
        // If interconnectType is still unset, default based on known clues
        if (outMetrics->interconnectType[0] == '\0') {
            if (outMetrics->linkSpeedBps > 0) {
                strlcpy(outMetrics->interconnectType, "USB", sizeof(outMetrics->interconnectType));
            } else if (outMetrics->isInternal) {
                strlcpy(outMetrics->interconnectType, "PCI-Express", sizeof(outMetrics->interconnectType));
            } else {
                strlcpy(outMetrics->interconnectType, "Storage", sizeof(outMetrics->interconnectType));
            }
        }

        // Default isInternal if still unset
        if (!outMetrics->isInternal) {
            if (strcasecmp(outMetrics->interconnectType, "USB") == 0 ||
                strcasecmp(outMetrics->interconnectType, "Thunderbolt") == 0 ||
                outMetrics->isRemovable) {
                outMetrics->isInternal = false;
            } else if (strcasecmp(outMetrics->interconnectType, "Virtual Interface") == 0 ||
                       strcmp(outMetrics->bsdName, "disk0") == 0) {
                outMetrics->isInternal = true;
            }
        }

        if (hasEntryId && outMetrics->bsdName[0] != '\0' && !isVirtualDiskDevice(outMetrics)) {
            pthread_mutex_lock(&sStaticCacheMutex);
            StaticDeviceCacheEntry *slot = NULL;
            for (int i = 0; i < sStaticCacheCount; i++) {
                if (sStaticCache[i].entryId == entryId) {
                    slot = &sStaticCache[i];
                    break;
                }
            }
            if (!slot) {
                slot = &sStaticCache[sStaticCacheNextIdx];
                sStaticCacheNextIdx = (sStaticCacheNextIdx + 1) % MAX_STATIC_CACHE_ENTRIES;
                if (sStaticCacheCount < MAX_STATIC_CACHE_ENTRIES) sStaticCacheCount++;
            }
            slot->entryId = entryId;
            strlcpy(slot->productName, outMetrics->productName, sizeof(slot->productName));
            strlcpy(slot->vendorName, outMetrics->vendorName, sizeof(slot->vendorName));
            strlcpy(slot->productRevision, outMetrics->productRevision, sizeof(slot->productRevision));
            strlcpy(slot->bsdName, outMetrics->bsdName, sizeof(slot->bsdName));
            strlcpy(slot->serialNumber, outMetrics->serialNumber, sizeof(slot->serialNumber));
            strlcpy(slot->interconnectType, outMetrics->interconnectType, sizeof(slot->interconnectType));
            slot->isInternal = outMetrics->isInternal;
            slot->isRemovable = outMetrics->isRemovable;
            slot->linkSpeedBps = outMetrics->linkSpeedBps;
            pthread_mutex_unlock(&sStaticCacheMutex);
        }
    }

    // 5. Read NVMe SMART data via NVMeSMARTLib.plugin
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(
        service,
        kIONVMeSMARTUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );

    if (kr == kIOReturnSuccess && plugin) {
        strlcpy(outMetrics->protocolType, "NVMe", sizeof(outMetrics->protocolType));
        IONVMeSMARTInterface **smart = NULL;
        HRESULT hr = (*plugin)->QueryInterface(
            plugin,
            CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID),
            (LPVOID *)&smart
        );

        if (hr == S_OK && smart) {
            NVMeSMARTData data;
            memset(&data, 0, sizeof(data));
            if ((*smart)->SMARTReadData(smart, &data) == kIOReturnSuccess) {
                outMetrics->smartValid = true;
                outMetrics->criticalWarning = data.CRITICAL_WARNING;

                uint16_t tempRaw = CFSwapInt16LittleToHost(data.TEMPERATURE);
                outMetrics->temperatureKelvin = (int32_t)tempRaw;
                outMetrics->temperatureCelsius = DiskConvertNVMeTemperature(tempRaw);

                outMetrics->availableSpare = data.AVAILABLE_SPARE;
                outMetrics->availableSpareThreshold = data.AVAILABLE_SPARE_THRESHOLD;
                outMetrics->percentageUsed = data.PERCENTAGE_USED;

                // Safely convert full 128-bit little-endian fields to 64-bit integers with saturation
                outMetrics->dataUnitsRead = nvmeLe128ToU64(&data.DATA_UNITS_READ);
                outMetrics->dataUnitsWritten = nvmeLe128ToU64(&data.DATA_UNITS_WRITTEN);
                outMetrics->hostReadCommands = nvmeLe128ToU64(&data.HOST_READ_COMMANDS);
                outMetrics->hostWriteCommands = nvmeLe128ToU64(&data.HOST_WRITE_COMMANDS);
                outMetrics->controllerBusyTime = nvmeLe128ToU64(&data.CONTROLLER_BUSY_TIME);
                outMetrics->powerCycles = nvmeLe128ToU64(&data.POWER_CYCLES);
                outMetrics->powerOnHours = nvmeLe128ToU64(&data.POWER_ON_HOURS);
                outMetrics->unsafeShutdowns = nvmeLe128ToU64(&data.UNSAFE_SHUTDOWNS);
                outMetrics->mediaErrors = nvmeLe128ToU64(&data.MEDIA_ERRORS);
                outMetrics->errorInfoLogEntries = nvmeLe128ToU64(&data.NUM_ERROR_INFO_LOG_ENTRIES);
            }
            (*smart)->Release(smart);
        }
        IODestroyPlugInInterface(plugin);
    } else {
        if (outMetrics->protocolType[0] == '\0') {
            strlcpy(outMetrics->protocolType, "SCSI/Block", sizeof(outMetrics->protocolType));
        }
    }
}

// ============================================================================
// MARK: - Block Device Resolution (APFS Containers, Slices & Snapshots)
// ============================================================================

/**
 * @brief Recursively traverses parent chain in kIOServicePlane to locate physical IOBlockStorageDevice.
 * 
 * Handles complex APFS synthesized container schemes where virtual volumes link through
 * intermediate AppleAPFSContainer and AppleAPFSMedia nodes before reaching the physical partition.
 * 
 * @param entry Starting io_registry_entry_t.
 * @param depth Current recursion depth (clamped to <= 24).
 * @return Retained io_service_t pointing to the physical IOBlockStorageDevice, or 0 if not found.
 * @note Caller is responsible for releasing returned io_service_t via IOObjectRelease.
 */
static io_service_t findParentBlockStorageDeviceRecursive(io_registry_entry_t entry, int depth) {
    if (!entry || depth > 24) return 0;

    if (IOObjectConformsTo(entry, "IOBlockStorageDevice")) {
        IOObjectRetain(entry);
        return entry;
    }

    io_iterator_t parentIter = 0;
    if (IORegistryEntryGetParentIterator(entry, kIOServicePlane, &parentIter) != KERN_SUCCESS || !parentIter) {
        return 0;
    }

    io_service_t foundDevice = 0;
    io_registry_entry_t parent;
    while ((parent = IOIteratorNext(parentIter)) != 0) {
        foundDevice = findParentBlockStorageDeviceRecursive(parent, depth + 1);
        IOObjectRelease(parent);
        if (foundDevice != 0) {
            break;
        }
    }
    IOObjectRelease(parentIter);
    return foundDevice;
}

/**
 * @brief Locates the physical IOBlockStorageDevice for a whole disk, slice, or APFS snapshot.
 * 
 * @param rawBsdName BSD name (e.g. "disk0", "disk3s1", "/dev/disk4", "com.apple.os.update-...@/dev/disk3s1s1").
 * @return Retained io_service_t pointing to physical device, or 0 if unresolved.
 * @note Caller must release returned service via IOObjectRelease.
 */
static io_service_t findBlockStorageDeviceByBSDName(const char *rawBsdName) {
    if (!rawBsdName || rawBsdName[0] == '\0') return 0;
    if (strlen(rawBsdName) >= MAXPATHLEN) return 0;

    const char *bsdName = rawBsdName;
    if (strncmp(bsdName, "/dev/", 5) == 0) {
        bsdName += 5;
    }

    // Handle APFS snapshot mount names like "com.apple.os.update-...@/dev/disk3s1s1" or "disk3s1s1"
    const char *atSign = strchr(bsdName, '@');
    if (atSign != NULL) {
        bsdName = atSign + 1;
        if (strncmp(bsdName, "/dev/", 5) == 0) {
            bsdName += 5;
        }
    }

    char cleanBsd[128] = {0};
    strlcpy(cleanBsd, bsdName, sizeof(cleanBsd));

    CFMutableDictionaryRef matching = IOBSDNameMatching(kIOMainPortDefault, 0, cleanBsd);
    if (!matching) return 0;

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) return 0;

    io_service_t blockDevice = findParentBlockStorageDeviceRecursive(service, 0);
    IOObjectRelease(service);
    return blockDevice;
}

// ============================================================================
// MARK: - Public API Implementations
// ============================================================================

int DiskListAllDevices(DiskHardwareMetrics *outArray, int maxCount) {
    if (!outArray || maxCount <= 0) return 0;

    CFMutableDictionaryRef matching = IOServiceMatching("IOBlockStorageDevice");
    if (!matching) return 0;

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != KERN_SUCCESS) {
        return 0;
    }

    int count = 0;
    io_service_t service;
    while (count < maxCount && (service = IOIteratorNext(iter)) != 0) {
        populateMetricsFromBlockStorageDevice(service, &outArray[count]);
        if (outArray[count].found) {
            count++;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
    return count;
}

void DiskReadHardwareMetrics(const char *targetIdentifier, DiskHardwareMetrics *outMetrics) {
    if (!outMetrics) return;
    memset(outMetrics, 0, sizeof(DiskHardwareMetrics));

    // 1. If target is a filesystem path (e.g. "/Volumes/MyDrive" or "/"), resolve via statfs
    if (targetIdentifier && targetIdentifier[0] == '/' && strncmp(targetIdentifier, "/dev/", 5) != 0) {
        struct statfs sfs;
        if (statfs(targetIdentifier, &sfs) == 0 && sfs.f_mntfromname[0] != '\0') {
            io_service_t dev = findBlockStorageDeviceByBSDName(sfs.f_mntfromname);
            if (dev != 0) {
                populateMetricsFromBlockStorageDevice(dev, outMetrics);
                IOObjectRelease(dev);
                return;
            }
        }
    }

    // 2. If target is a BSD name (e.g. "disk6", "disk7s1", "/dev/disk4")
    if (targetIdentifier && (strncmp(targetIdentifier, "/dev/disk", 9) == 0 || strncmp(targetIdentifier, "disk", 4) == 0)) {
        io_service_t dev = findBlockStorageDeviceByBSDName(targetIdentifier);
        if (dev != 0) {
            populateMetricsFromBlockStorageDevice(dev, outMetrics);
            IOObjectRelease(dev);
            return;
        }
    }

    // 3. If target is empty, NULL, or "auto": pick the first external device (or first internal if no external)
    bool isAuto = (!targetIdentifier || targetIdentifier[0] == '\0' || strcmp(targetIdentifier, "auto") == 0);

    CFMutableDictionaryRef matching = IOServiceMatching("IOBlockStorageDevice");
    if (!matching) return;

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != KERN_SUCCESS) {
        return;
    }

    io_service_t service;
    DiskHardwareMetrics firstDevice;
    memset(&firstDevice, 0, sizeof(firstDevice));
    bool foundFirst = false;

    DiskHardwareMetrics substringMatch;
    memset(&substringMatch, 0, sizeof(substringMatch));
    bool foundSubstring = false;

    const char *query = targetIdentifier;
    if (query && strncmp(query, "/dev/", 5) == 0) {
        query += 5;
    }

    while ((service = IOIteratorNext(iter)) != 0) {
        DiskHardwareMetrics metrics;
        populateMetricsFromBlockStorageDevice(service, &metrics);

        if (metrics.found) {
            bool isVirtual = isVirtualDiskDevice(&metrics);
            if (!foundFirst && !isVirtual) {
                firstDevice = metrics;
                foundFirst = true;
            }

            if (isAuto) {
                // In auto mode, prefer physical external device (skip virtual DMGs)
                if (!metrics.isInternal && !isVirtual) {
                    *outMetrics = metrics;
                    IOObjectRelease(service);
                    break;
                }
            } else {
                // 1. Exact match on BSD Name or Serial Number takes immediate priority
                if ((metrics.bsdName[0] != '\0' && (strcasecmp(metrics.bsdName, targetIdentifier) == 0 || strcasecmp(metrics.bsdName, query) == 0)) ||
                    (metrics.serialNumber[0] != '\0' && strcasecmp(metrics.serialNumber, targetIdentifier) == 0)) {
                    *outMetrics = metrics;
                    IOObjectRelease(service);
                    break;
                }
                // 2. Otherwise record first substring match on Product, Vendor, Serial, or non-disk BSD query
                if (!foundSubstring &&
                    ((metrics.productName[0] != '\0' && strcasestr(metrics.productName, targetIdentifier) != NULL) ||
                     (metrics.vendorName[0] != '\0' && strcasestr(metrics.vendorName, targetIdentifier) != NULL) ||
                     (metrics.serialNumber[0] != '\0' && strcasestr(metrics.serialNumber, targetIdentifier) != NULL) ||
                     (strncmp(query, "disk", 4) != 0 && metrics.bsdName[0] != '\0' && strcasestr(metrics.bsdName, query) != NULL))) {
                    substringMatch = metrics;
                    foundSubstring = true;
                }
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);

    if (!isAuto && !outMetrics->found && foundSubstring) {
        *outMetrics = substringMatch;
    }

    // If auto mode and no external drive was found, fallback to the first device (e.g. internal drive)
    if (isAuto && !outMetrics->found && foundFirst) {
        *outMetrics = firstDevice;
    }
}

bool DiskFindMountForBlockDevice(const char *deviceBsdName, char *outMountPoint, size_t maxLen) {
    if (!deviceBsdName || deviceBsdName[0] == '\0' || !outMountPoint || maxLen == 0) return false;
    outMountPoint[0] = '\0';

    const char *cleanTargetBsd = deviceBsdName;
    if (strncmp(cleanTargetBsd, "/dev/", 5) == 0) cleanTargetBsd += 5;
    if (cleanTargetBsd[0] == '\0') return false;

    io_service_t targetDev = findBlockStorageDeviceByBSDName(cleanTargetBsd);
    if (targetDev == 0) return false;

    // Fast path (OPT2-02): Stack-allocated buffer for up to 64 mount points eliminates heap allocation.
    struct statfs stackFs[64];
    struct statfs *fsList = stackFs;
    int allocMounts = 64;
    int count = getfsstat(fsList, (int)sizeof(stackFs), MNT_NOWAIT);
    if (count >= allocMounts) {
        int numMounts = getfsstat(NULL, 0, MNT_NOWAIT);
        if (numMounts > allocMounts) {
            allocMounts = numMounts + 4;
            struct statfs *heapFs = calloc((size_t)allocMounts, sizeof(struct statfs));
            if (heapFs) {
                fsList = heapFs;
                count = getfsstat(fsList, (int)(sizeof(struct statfs) * allocMounts), MNT_NOWAIT);
            }
        }
    }
    if (count <= 0) {
        if (fsList != stackFs) free(fsList);
        IOObjectRelease(targetDev);
        return false;
    }
    if (count > allocMounts) {
        count = allocMounts;
    }
    bool found = false;
    int bestScore = -1;
    uint64_t bestCapacity = 0;

    for (int i = 0; i < count; i++) {
        const char *fromName = fsList[i].f_mntfromname;
        if (!fromName || fromName[0] == '\0') continue;
        if (strncmp(fromName, "/dev/", 5) != 0) continue; // Skip non-device filesystems (devfs, autofs, nfs)

        const char *cleanFrom = fromName + 5;
        const char *atSign = strchr(cleanFrom, '@');
        if (atSign != NULL) {
            cleanFrom = atSign + 1;
            if (strncmp(cleanFrom, "/dev/", 5) == 0) cleanFrom += 5;
        }

        // 1. Exact partition slice or snapshot name match takes absolute priority (score 10)
        bool isExactSliceMatch = (strcmp(cleanFrom, cleanTargetBsd) == 0);
        bool isSameDevice = false;
        const char *mountPath = fsList[i].f_mntonname;

        int candidateScore = 1;
        uint64_t candidateCapacity = (uint64_t)fsList[i].f_blocks * (uint64_t)fsList[i].f_bsize;
        bool isWritable = ((fsList[i].f_flags & MNT_RDONLY) == 0);
        bool isEfiOrRecovery = (strstr(mountPath, "EFI") != NULL || strstr(mountPath, "Recovery") != NULL || strstr(mountPath, "Preboot") != NULL);

        if (isExactSliceMatch) {
            candidateScore = 10;
        } else if (strcmp(mountPath, "/") == 0) {
            candidateScore = 6; // Root filesystem takes absolute whole-disk priority
        } else if (strncmp(mountPath, "/Volumes/", 9) == 0 && !isEfiOrRecovery) {
            candidateScore = isWritable ? 5 : 4; // Prefer writable external user volumes
        } else if (strcmp(mountPath, "/System/Volumes/Data") == 0) {
            candidateScore = 3; // Data volume
        } else if (isEfiOrRecovery) {
            candidateScore = 1; // Hidden helper / EFI / Recovery partition on same physical disk
        } else if (strncmp(mountPath, "/System/Volumes/", 16) == 0) {
            candidateScore = 0; // System container helpers
        }

        // Skip expensive IOKit parent traversal if this mount cannot beat our current best
        if (candidateScore < bestScore) {
            continue;
        }
        if (candidateScore == bestScore && candidateCapacity <= bestCapacity) {
            continue;
        }

        if (isExactSliceMatch) {
            isSameDevice = true;
        } else {
            io_service_t dev = findBlockStorageDeviceByBSDName(fromName);
            if (dev != 0) {
                isSameDevice = IOObjectIsEqualTo(dev, targetDev);
                IOObjectRelease(dev);
            }
        }

        if (isExactSliceMatch || isSameDevice) {
            if (candidateScore > bestScore || (candidateScore == bestScore && candidateCapacity > bestCapacity)) {
                bestScore = candidateScore;
                bestCapacity = candidateCapacity;
                strlcpy(outMountPoint, mountPath, maxLen);
                found = true;
                if (candidateScore == 10) {
                    break;
                }
            }
        }
    }

    if (fsList != stackFs) free(fsList);
    IOObjectRelease(targetDev);
    return found;
}
