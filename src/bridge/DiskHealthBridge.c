#define _GNU_SOURCE
#include "DiskHealthBridge.h"
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/IOBlockStorageDevice.h>
#include <IOKit/storage/IOBlockStorageDriver.h>
#include <IOKit/storage/IOMedia.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

static bool getCFString(CFDictionaryRef dict, CFStringRef key, char *buf, size_t bufLen) {
    if (!dict || !key || !buf || bufLen == 0) return false;
    CFTypeRef val = CFDictionaryGetValue(dict, key);
    if (val && CFGetTypeID(val) == CFStringGetTypeID()) {
        return CFStringGetCString((CFStringRef)val, buf, (CFIndex)bufLen, kCFStringEncodingUTF8);
    }
    return false;
}

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

// Safely decode 128-bit little-endian NVMe counter to 64-bit unsigned integer
static uint64_t nvmeLe128ToU64(const void *ptr) {
    if (!ptr) return 0;
    const uint8_t *bytes = (const uint8_t *)ptr;
    uint64_t low = 0;
    uint64_t high = 0;
    memcpy(&low, bytes, sizeof(uint64_t));
    memcpy(&high, bytes + sizeof(uint64_t), sizeof(uint64_t));
    if (CFSwapInt64LittleToHost(high) != 0) {
        return UINT64_MAX;
    }
    return CFSwapInt64LittleToHost(low);
}

// Convert raw 16-bit NVMe composite temperature to Celsius with boundary validation
int32_t DiskConvertNVMeTemperature(uint16_t tempRaw) {
    if (tempRaw >= 233 && tempRaw <= 423) {
        // Valid Kelvin range: 233K (-40°C) to 423K (+150°C)
        return (int32_t)tempRaw - 273;
    } else if (tempRaw > 0 && tempRaw <= 150) {
        // Non-standard controller reporting directly in Celsius
        return (int32_t)tempRaw;
    } else {
        // 0 (unreported) or corrupt/sentinel value (e.g. 0xFFFF): default to safe nominal 0
        return 0;
    }
}

// Convert IOKit USB "Device Speed" enum or raw bps to bits per second
uint64_t DiskNormalizeLinkSpeedToBps(uint64_t rawSpeed) {
    switch (rawSpeed) {
        case 0: return 0;
        case 1: return 12000000ULL;       // USB 1.1 Full Speed (12 Mbps)
        case 2: return 480000000ULL;      // USB 2.0 High Speed (480 Mbps)
        case 3: return 5000000000ULL;     // USB 3.0 SuperSpeed (5 Gbps)
        case 4: return 10000000000ULL;    // USB 3.1/3.2 SuperSpeed+ (10 Gbps)
        case 5: return 20000000000ULL;    // USB 3.2 Gen 2x2 (20 Gbps)
        default:
            return rawSpeed;
    }
}

// Inspect parent chain for USB / Thunderbolt / Interconnect properties
static void inspectParentsForBusProperties(io_registry_entry_t entry, DiskHardwareMetrics *outMetrics) {
    io_registry_entry_t current = entry;
    IOObjectRetain(current);

    for (int depth = 0; depth < 16; depth++) {
        io_registry_entry_t parent = 0;
        if (IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS || parent == 0) {
            break;
        }

        // Link speed
        CFTypeRef linkSpeedRef = IORegistryEntryCreateCFProperty(parent, CFSTR("UsbLinkSpeed"), kCFAllocatorDefault, 0);
        if (!linkSpeedRef) {
            linkSpeedRef = IORegistryEntryCreateCFProperty(parent, CFSTR("LinkSpeed"), kCFAllocatorDefault, 0);
        }
        if (!linkSpeedRef) {
            linkSpeedRef = IORegistryEntryCreateCFProperty(parent, CFSTR("Link Speed"), kCFAllocatorDefault, 0);
        }
        if (!linkSpeedRef) {
            linkSpeedRef = IORegistryEntryCreateCFProperty(parent, CFSTR("Device Speed"), kCFAllocatorDefault, 0);
        }
        if (linkSpeedRef) {
            if (CFGetTypeID(linkSpeedRef) == CFNumberGetTypeID() && outMetrics->linkSpeedBps == 0) {
                int64_t signedSpeed = 0;
                if (CFNumberGetValue((CFNumberRef)linkSpeedRef, kCFNumberSInt64Type, &signedSpeed) && signedSpeed > 0) {
                    uint64_t bps = DiskNormalizeLinkSpeedToBps((uint64_t)signedSpeed);
                    if (bps > 0) {
                        outMetrics->linkSpeedBps = bps;
                        outMetrics->usbLinkSpeedBps = bps;
                    }
                }
            }
            CFRelease(linkSpeedRef);
        }

        // Serial number
        if (outMetrics->serialNumber[0] == '\0') {
            CFTypeRef serialRef = IORegistryEntryCreateCFProperty(parent, CFSTR("USB Serial Number"), kCFAllocatorDefault, 0);
            if (!serialRef) {
                serialRef = IORegistryEntryCreateCFProperty(parent, CFSTR("kUSBSerialNumberString"), kCFAllocatorDefault, 0);
            }
            if (!serialRef) {
                serialRef = IORegistryEntryCreateCFProperty(parent, CFSTR("Serial Number"), kCFAllocatorDefault, 0);
            }
            if (serialRef) {
                if (CFGetTypeID(serialRef) == CFStringGetTypeID()) {
                    CFStringGetCString((CFStringRef)serialRef, outMetrics->serialNumber, sizeof(outMetrics->serialNumber), kCFStringEncodingUTF8);
                    strlcpy(outMetrics->usbSerialNumber, outMetrics->serialNumber, sizeof(outMetrics->usbSerialNumber));
                }
                CFRelease(serialRef);
            }
        }

        // Check if parent service name indicates bus type
        io_name_t className;
        if (IOObjectGetClass(parent, className) == KERN_SUCCESS) {
            if (outMetrics->interconnectType[0] == '\0') {
                if (strstr(className, "USB") != NULL) {
                    strlcpy(outMetrics->interconnectType, "USB", sizeof(outMetrics->interconnectType));
                } else if (strstr(className, "Thunderbolt") != NULL) {
                    strlcpy(outMetrics->interconnectType, "Thunderbolt", sizeof(outMetrics->interconnectType));
                } else if (strstr(className, "AHCI") != NULL || strstr(className, "SATA") != NULL) {
                    strlcpy(outMetrics->interconnectType, "SATA", sizeof(outMetrics->interconnectType));
                } else if (strstr(className, "PCI") != NULL || strstr(className, "NVMe") != NULL) {
                    strlcpy(outMetrics->interconnectType, "PCI-Express", sizeof(outMetrics->interconnectType));
                }
            }
        }

        IOObjectRelease(current);
        current = parent;

        if (outMetrics->linkSpeedBps > 0 && outMetrics->serialNumber[0] != '\0' && outMetrics->interconnectType[0] != '\0') {
            break;
        }
    }
    IOObjectRelease(current);
}

// Inspect children for IOBlockStorageDriver statistics and physical whole-disk BSD Name (e.g. disk0, disk4)
static void inspectChildrenForDriverStats(io_registry_entry_t service, DiskHardwareMetrics *outMetrics) {
    io_iterator_t childIter = 0;
    if (IORegistryEntryCreateIterator(service, kIOServicePlane, kIORegistryIterateRecursively, &childIter) != KERN_SUCCESS || !childIter) {
        return;
    }

    io_registry_entry_t child;
    while ((child = IOIteratorNext(childIter)) != 0) {
        // Stop descending into synthesized APFS containers so we never confuse AppleAPFSMedia (Whole=true)
        // or virtual container statistics with the physical IOBlockStorageDriver and physical IOMedia.
        if (IOObjectConformsTo(child, "AppleAPFSContainerScheme") ||
            IOObjectConformsTo(child, "AppleAPFSContainer") ||
            IOObjectConformsTo(child, "AppleAPFSMedia")) {
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
                    if (CFGetTypeID(bsdRef) == CFStringGetTypeID()) {
                        CFStringGetCString((CFStringRef)bsdRef, outMetrics->bsdName, sizeof(outMetrics->bsdName), kCFStringEncodingUTF8);
                    }
                    CFRelease(bsdRef);
                }
            }
        }

        IOObjectRelease(child);
        if (outMetrics->statsValid && outMetrics->bsdName[0] != '\0') {
            break;
        }
    }
    IOObjectRelease(childIter);
}

// Populate all hardware, SMART, driver, and bus metrics from an IOBlockStorageDevice service
static void populateMetricsFromBlockStorageDevice(io_service_t service, DiskHardwareMetrics *outMetrics) {
    if (!service || !outMetrics) return;
    memset(outMetrics, 0, sizeof(DiskHardwareMetrics));
    outMetrics->found = true;

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

    // 4. Inspect children for driver statistics and BSD Name
    inspectChildrenForDriverStats(service, outMetrics);

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

                // Safely convert full 128-bit little-endian fields to 64-bit integers
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

// Recursively traverse all parents in kIOServicePlane (handles APFS containers with multiple parent links)
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

// Locate physical IOBlockStorageDevice for an APFS volume, snapshot, partition slice, or whole-disk BSD name
static io_service_t findBlockStorageDeviceByBSDName(const char *rawBsdName) {
    if (!rawBsdName || rawBsdName[0] == '\0') return 0;

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

    CFMutableDictionaryRef matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName);
    if (!matching) return 0;

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) return 0;

    io_service_t blockDevice = findParentBlockStorageDeviceRecursive(service, 0);
    IOObjectRelease(service);
    return blockDevice;
}

// Enumerate all block storage devices on the system
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
    while ((service = IOIteratorNext(iter)) != 0 && count < maxCount) {
        populateMetricsFromBlockStorageDevice(service, &outArray[count]);
        if (outArray[count].found) {
            count++;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);
    return count;
}

// Read metrics for a targeted identifier (mount path, BSD name, substring query, or auto)
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
            if (!foundFirst) {
                firstDevice = metrics;
                foundFirst = true;
            }

            if (isAuto) {
                // In auto mode, prefer external device
                if (!metrics.isInternal) {
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

// Find the mounted filesystem path for a block storage device (resolving APFS containers and partitions)
bool DiskFindMountForBlockDevice(const char *deviceBsdName, char *outMountPoint, size_t maxLen) {
    if (!deviceBsdName || deviceBsdName[0] == '\0' || !outMountPoint || maxLen == 0) return false;
    outMountPoint[0] = '\0';

    const char *cleanTargetBsd = deviceBsdName;
    if (strncmp(cleanTargetBsd, "/dev/", 5) == 0) cleanTargetBsd += 5;
    if (cleanTargetBsd[0] == '\0') return false;

    io_service_t targetDev = findBlockStorageDeviceByBSDName(cleanTargetBsd);
    if (targetDev == 0) return false;

    int numMounts = getfsstat(NULL, 0, MNT_NOWAIT);
    if (numMounts <= 0) {
        IOObjectRelease(targetDev);
        return false;
    }

    int allocMounts = numMounts + 4;
    struct statfs *fsList = calloc((size_t)allocMounts, sizeof(struct statfs));
    if (!fsList) {
        IOObjectRelease(targetDev);
        return false;
    }

    int count = getfsstat(fsList, (int)(sizeof(struct statfs) * allocMounts), MNT_NOWAIT);
    bool found = false;
    int bestScore = -1;

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

        io_service_t dev = findBlockStorageDeviceByBSDName(fromName);
        if (dev != 0) {
            bool isSameDevice = IOObjectIsEqualTo(dev, targetDev);
            IOObjectRelease(dev);

            if (isExactSliceMatch || isSameDevice) {
                const char *mountPath = fsList[i].f_mntonname;
                // Prioritize mounts:
                // Exact slice match = 10 (target was a partition slice like disk3s5 or disk7s1)
                // / = 4 (system root)
                // /Volumes/* = 3 (external disk volume)
                // /System/Volumes/Data = 2
                // Other mounts = 1
                // Hidden /System/Volumes/* or /Volumes/Recovery = 0
                int score = 1;
                if (isExactSliceMatch) {
                    score = 10;
                } else if (strcmp(mountPath, "/") == 0) {
                    score = 4; // Root filesystem is highest priority
                } else if (strncmp(mountPath, "/Volumes/", 9) == 0 && strcmp(mountPath, "/Volumes/Recovery") != 0) {
                    score = 3; // External user volume
                } else if (strcmp(mountPath, "/System/Volumes/Data") == 0) {
                    score = 2; // Data volume
                } else if (strncmp(mountPath, "/System/Volumes/", 16) == 0 || strcmp(mountPath, "/Volumes/Recovery") == 0) {
                    score = 0; // Hidden internal / recovery volumes
                }

                if (score > bestScore) {
                    bestScore = score;
                    strlcpy(outMountPoint, mountPath, maxLen);
                    found = true;
                    if (score == 10) {
                        break;
                    }
                }
            }
        }
    }

    free(fsList);
    IOObjectRelease(targetDev);
    return found;
}
