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
        uint64_t num = 0;
        CFNumberGetValue((CFNumberRef)val, kCFNumberSInt64Type, &num);
        return num;
    }
    return 0;
}


// Safely decode 128-bit little-endian NVMe counter to 64-bit unsigned integer
static uint64_t nvmeLe128ToU64(const void *ptr) {
    if (!ptr) return 0;
    uint64_t val = 0;
    memcpy(&val, ptr, sizeof(uint64_t));
    return CFSwapInt64LittleToHost(val);
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
        if (linkSpeedRef) {
            if (CFGetTypeID(linkSpeedRef) == CFNumberGetTypeID() && outMetrics->linkSpeedBps == 0) {
                uint64_t speed = 0;
                CFNumberGetValue((CFNumberRef)linkSpeedRef, kCFNumberSInt64Type, &speed);
                if (speed > 0) {
                    outMetrics->linkSpeedBps = speed;
                    outMetrics->usbLinkSpeedBps = speed;
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
                    strncpy(outMetrics->usbSerialNumber, outMetrics->serialNumber, sizeof(outMetrics->usbSerialNumber) - 1);
                }
                CFRelease(serialRef);
            }
        }

        // Check if parent service name indicates bus type
        io_name_t className;
        if (IOObjectGetClass(parent, className) == KERN_SUCCESS) {
            if (outMetrics->interconnectType[0] == '\0') {
                if (strstr(className, "USB") != NULL) {
                    strncpy(outMetrics->interconnectType, "USB", sizeof(outMetrics->interconnectType) - 1);
                } else if (strstr(className, "Thunderbolt") != NULL) {
                    strncpy(outMetrics->interconnectType, "Thunderbolt", sizeof(outMetrics->interconnectType) - 1);
                } else if (strstr(className, "PCI") != NULL || strstr(className, "NVMe") != NULL) {
                    strncpy(outMetrics->interconnectType, "PCI-Express", sizeof(outMetrics->interconnectType) - 1);
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

// Inspect children recursively for IOBlockStorageDriver statistics and BSD Name (e.g. disk6, disk0)
static void inspectChildrenForDriverStats(io_registry_entry_t service, DiskHardwareMetrics *outMetrics) {
    io_iterator_t childIter = 0;
    if (IORegistryEntryCreateIterator(service, kIOServicePlane, kIORegistryIterateRecursively, &childIter) != KERN_SUCCESS || !childIter) {
        return;
    }

    io_registry_entry_t child;
    while ((child = IOIteratorNext(childIter)) != 0) {
        // Look for Driver Statistics dictionary
        if (!outMetrics->statsValid) {
            CFDictionaryRef stats = IORegistryEntryCreateCFProperty(child, CFSTR("Statistics"), kCFAllocatorDefault, 0);
            if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
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
                CFRelease(stats);
            }
        }

        // Look for IOMedia node containing BSD Name (the first Whole media is the physical whole disk)
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
    }
    IOObjectRelease(childIter);
}

// Populate all hardware, SMART, driver, and bus metrics from an IOBlockStorageDevice service
static void populateMetricsFromBlockStorageDevice(io_service_t service, DiskHardwareMetrics *outMetrics) {
    if (!service || !outMetrics) return;
    memset(outMetrics, 0, sizeof(DiskHardwareMetrics));
    outMetrics->found = true;

    // 1. Device Characteristics
    CFDictionaryRef chars = IORegistryEntryCreateCFProperty(service, CFSTR("Device Characteristics"), kCFAllocatorDefault, 0);
    if (chars && CFGetTypeID(chars) == CFDictionaryGetTypeID()) {
        getCFString(chars, CFSTR("Product Name"), outMetrics->productName, sizeof(outMetrics->productName));
        getCFString(chars, CFSTR("Vendor Name"), outMetrics->vendorName, sizeof(outMetrics->vendorName));
        getCFString(chars, CFSTR("Product Revision Level"), outMetrics->productRevision, sizeof(outMetrics->productRevision));
        getCFString(chars, CFSTR("Serial Number"), outMetrics->serialNumber, sizeof(outMetrics->serialNumber));
        strncpy(outMetrics->usbSerialNumber, outMetrics->serialNumber, sizeof(outMetrics->usbSerialNumber) - 1);

        char removableStr[32] = {0};
        if (getCFString(chars, CFSTR("Removable Media"), removableStr, sizeof(removableStr))) {
            if (strcasecmp(removableStr, "Yes") == 0 || strcasecmp(removableStr, "True") == 0) {
                outMetrics->isRemovable = true;
            }
        }
        CFRelease(chars);
    }

    // 2. Protocol Characteristics
    CFDictionaryRef proto = IORegistryEntryCreateCFProperty(service, CFSTR("Protocol Characteristics"), kCFAllocatorDefault, 0);
    if (proto && CFGetTypeID(proto) == CFDictionaryGetTypeID()) {
        getCFString(proto, CFSTR("Physical Interconnect"), outMetrics->interconnectType, sizeof(outMetrics->interconnectType));
        char location[64] = {0};
        if (getCFString(proto, CFSTR("Physical Interconnect Location"), location, sizeof(location))) {
            if (strcasecmp(location, "Internal") == 0) {
                outMetrics->isInternal = true;
            } else if (strcasecmp(location, "External") == 0) {
                outMetrics->isInternal = false;
            }
        }
        CFRelease(proto);
    }

    // Class name check for internal NVMe / Apple fabric
    io_name_t deviceClassName;
    if (IOObjectGetClass(service, deviceClassName) == KERN_SUCCESS) {
        if (strstr(deviceClassName, "AppleANS") != NULL || strstr(deviceClassName, "EmbeddedNVMe") != NULL) {
            outMetrics->isInternal = true;
            if (outMetrics->interconnectType[0] == '\0') {
                strncpy(outMetrics->interconnectType, "PCI-Express", sizeof(outMetrics->interconnectType) - 1);
            }
        }
    }

    // 3. Inspect parents for bus speed, serial number, and interconnect fallback
    inspectParentsForBusProperties(service, outMetrics);

    // If interconnectType is still unset, default based on known clues
    if (outMetrics->interconnectType[0] == '\0') {
        if (outMetrics->linkSpeedBps > 0) {
            strncpy(outMetrics->interconnectType, "USB", sizeof(outMetrics->interconnectType) - 1);
        } else if (outMetrics->isInternal) {
            strncpy(outMetrics->interconnectType, "PCI-Express", sizeof(outMetrics->interconnectType) - 1);
        } else {
            strncpy(outMetrics->interconnectType, "Storage", sizeof(outMetrics->interconnectType) - 1);
        }
    }

    // Default isInternal if still unset
    if (!outMetrics->isInternal) {
        if (strcasecmp(outMetrics->interconnectType, "USB") == 0 ||
            strcasecmp(outMetrics->interconnectType, "Thunderbolt") == 0 ||
            outMetrics->isRemovable) {
            outMetrics->isInternal = false;
        }
    }

    // 4. Inspect children for driver statistics and BSD Name
    inspectChildrenForDriverStats(service, outMetrics);

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
        strncpy(outMetrics->protocolType, "NVMe", sizeof(outMetrics->protocolType) - 1);
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
                if (tempRaw >= 250) {
                    outMetrics->temperatureCelsius = (int32_t)tempRaw - 273;
                } else {
                    outMetrics->temperatureCelsius = (int32_t)tempRaw;
                }

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
            strncpy(outMetrics->protocolType, "SCSI/Block", sizeof(outMetrics->protocolType) - 1);
        }
    }
}

// Locate physical IOBlockStorageDevice for an APFS volume, snapshot, partition slice, or whole-disk BSD name
static io_service_t findBlockStorageDeviceByBSDName(const char *rawBsdName) {
    if (!rawBsdName || rawBsdName[0] == '\0') return 0;

    const char *bsdName = rawBsdName;
    if (strncmp(bsdName, "/dev/", 5) == 0) {
        bsdName += 5;
    }

    CFMutableDictionaryRef matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName);
    if (!matching) return 0;

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service) return 0;

    // Traverse up kIOServicePlane parent chain until reaching IOBlockStorageDevice
    io_registry_entry_t current = service;
    IOObjectRetain(current);
    io_service_t blockDevice = 0;

    for (int depth = 0; depth < 20; depth++) {
        if (IOObjectConformsTo(current, "IOBlockStorageDevice")) {
            blockDevice = current;
            IOObjectRetain(blockDevice);
            break;
        }

        io_registry_entry_t parent = 0;
        if (IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS || parent == 0) {
            break;
        }
        IOObjectRelease(current);
        current = parent;
    }

    IOObjectRelease(current);
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
                // Match against substring: Product Name, Vendor Name, Serial Number, or BSD Name
                if ((metrics.productName[0] != '\0' && strcasestr(metrics.productName, targetIdentifier) != NULL) ||
                    (metrics.vendorName[0] != '\0' && strcasestr(metrics.vendorName, targetIdentifier) != NULL) ||
                    (metrics.serialNumber[0] != '\0' && strcasestr(metrics.serialNumber, targetIdentifier) != NULL) ||
                    (metrics.bsdName[0] != '\0' && strcasestr(metrics.bsdName, targetIdentifier) != NULL)) {
                    *outMetrics = metrics;
                    IOObjectRelease(service);
                    break;
                }
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iter);

    // If auto mode and no external drive was found, fallback to the first device (e.g. internal drive)
    if (isAuto && !outMetrics->found && foundFirst) {
        *outMetrics = firstDevice;
    }
}

// Fast helper to extract BSD name from an IOBlockStorageDevice without loading SMART plugins
static bool getBlockDeviceBSDName(io_service_t service, char *outBsd, size_t maxLen) {
    if (!service || !outBsd || maxLen == 0) return false;
    outBsd[0] = '\0';

    io_iterator_t iter = 0;
    if (IORegistryEntryCreateIterator(service, kIOServicePlane, kIORegistryIterateRecursively, &iter) != KERN_SUCCESS || !iter) {
        return false;
    }

    io_registry_entry_t entry;
    bool found = false;
    while ((entry = IOIteratorNext(iter)) != 0) {
        if (IOObjectConformsTo(entry, "IOMedia")) {
            CFTypeRef wholeRef = IORegistryEntryCreateCFProperty(entry, CFSTR("Whole"), kCFAllocatorDefault, 0);
            bool isWhole = false;
            if (wholeRef) {
                if (CFGetTypeID(wholeRef) == CFBooleanGetTypeID()) {
                    isWhole = CFBooleanGetValue((CFBooleanRef)wholeRef);
                }
                CFRelease(wholeRef);
            }
            if (isWhole || outBsd[0] == '\0') {
                CFTypeRef bsdRef = IORegistryEntryCreateCFProperty(entry, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
                if (bsdRef) {
                    if (CFGetTypeID(bsdRef) == CFStringGetTypeID()) {
                        CFStringGetCString((CFStringRef)bsdRef, outBsd, (CFIndex)maxLen, kCFStringEncodingUTF8);
                        found = true;
                    }
                    CFRelease(bsdRef);
                }
                if (isWhole) {
                    IOObjectRelease(entry);
                    break;
                }
            }
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iter);
    return found;
}

// Find the mounted filesystem path for a block storage device (resolving APFS containers and partitions)
bool DiskFindMountForBlockDevice(const char *deviceBsdName, char *outMountPoint, size_t maxLen) {
    if (!deviceBsdName || !outMountPoint || maxLen == 0) return false;
    outMountPoint[0] = '\0';

    const char *cleanTargetBsd = deviceBsdName;
    if (strncmp(cleanTargetBsd, "/dev/", 5) == 0) cleanTargetBsd += 5;

    int numMounts = getfsstat(NULL, 0, MNT_NOWAIT);
    if (numMounts <= 0) return false;

    struct statfs *fsList = malloc(sizeof(struct statfs) * numMounts);
    if (!fsList) return false;

    int count = getfsstat(fsList, (int)(sizeof(struct statfs) * numMounts), MNT_NOWAIT);
    bool found = false;
    int bestScore = -1;

    for (int i = 0; i < count; i++) {
        const char *fromName = fsList[i].f_mntfromname;
        if (!fromName || fromName[0] == '\0') continue;
        if (strncmp(fromName, "/dev/", 5) != 0) continue; // Skip non-device filesystems (devfs, autofs, nfs)

        io_service_t dev = findBlockStorageDeviceByBSDName(fromName);
        if (dev != 0) {
            char hwBsd[64] = {0};
            getBlockDeviceBSDName(dev, hwBsd, sizeof(hwBsd));
            IOObjectRelease(dev);

            const char *cleanHwBsd = hwBsd;
            if (strncmp(cleanHwBsd, "/dev/", 5) == 0) cleanHwBsd += 5;

            if (strcmp(cleanHwBsd, cleanTargetBsd) == 0) {
                const char *mountPath = fsList[i].f_mntonname;
                // Prioritize user-facing mounts:
                // /Volumes/* = 3 (external disk volume)
                // / = 2 (system root)
                // /System/Volumes/Data = 1
                // Other /System/Volumes/* = 0 (hidden system partitions)
                int score = 1;
                if (strcmp(mountPath, "/") == 0) {
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
                    strncpy(outMountPoint, mountPath, maxLen - 1);
                    outMountPoint[maxLen - 1] = '\0';
                    found = true;
                    if (score == 4) {
                        // Root volume is found
                        break;
                    }
                }
            }
        }
    }

    free(fsList);
    return found;
}
