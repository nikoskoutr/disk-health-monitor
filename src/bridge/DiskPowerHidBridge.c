// ============================================================================
// File: DiskPowerHidBridge.c
// Module: Layer 1 (C11 / Power Session & Apple Silicon HID Thermal Bridge)
// Purpose: Dark Wake detection via CoreGraphics session dictionary and
//          Apple Silicon NAND die temperature fallback via IOHIDEventSystem.
// Concurrency: Thread-safe via pthread_once_t and pthread_mutex_t.
// ============================================================================

#define _GNU_SOURCE
#include "DiskHealthBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>
#include <time.h>

// ============================================================================
// MARK: - Dark Wake Power State (PWR-01)
// ============================================================================

typedef CFDictionaryRef (*CGSessionCopyCurrentDictionaryFn)(void);
static CGSessionCopyCurrentDictionaryFn sCgSessionFn = NULL;
static pthread_once_t sDarkWakeResolveOnce = PTHREAD_ONCE_INIT;

static void resolveDarkWakeSymbolsOnce(void) {
    sCgSessionFn = (CGSessionCopyCurrentDictionaryFn)dlsym(RTLD_DEFAULT, "CGSessionCopyCurrentDictionary");
}

int DiskIsDarkWakeActive(void) {
    pthread_once(&sDarkWakeResolveOnce, resolveDarkWakeSymbolsOnce);
    if (!sCgSessionFn) return 0;

    CFDictionaryRef sessionDict = sCgSessionFn();
    if (!sessionDict) return 0;

    int isDark = 0;
    CFBooleanRef onConsole = (CFBooleanRef)CFDictionaryGetValue(sessionDict, CFSTR("kCGSSessionOnConsoleKey"));
    if (!onConsole) {
        onConsole = (CFBooleanRef)CFDictionaryGetValue(sessionDict, CFSTR("kCGSessionOnConsoleKey"));
    }

    if (onConsole && CFGetTypeID(onConsole) == CFBooleanGetTypeID()) {
        if (!CFBooleanGetValue(onConsole)) {
            isDark = 1;
        }
    }

    CFRelease(sessionDict);
    return isDark;
}

// ============================================================================
// MARK: - Apple Silicon Storage Die Temperature (IOHIDEventSystem Fallback)
// ============================================================================

typedef void* (*IOHIDCreateFunc)(CFAllocatorRef);
typedef void (*IOHIDSetMatchingFunc)(void*, CFDictionaryRef);
typedef CFArrayRef (*IOHIDCopyServicesFunc)(void*);
typedef CFTypeRef (*IOHIDCopyPropertyFunc)(void*, CFStringRef);
typedef void* (*IOHIDCopyEventFunc)(void*, int64_t, int32_t, int64_t);
typedef double (*IOHIDGetFloatFunc)(void*, int64_t);

static IOHIDCreateFunc sHidCreate = NULL;
static IOHIDSetMatchingFunc sHidSetMatching = NULL;
static IOHIDCopyServicesFunc sHidCopyServices = NULL;
static IOHIDCopyPropertyFunc sHidCopyProperty = NULL;
static IOHIDCopyEventFunc sHidCopyEvent = NULL;
static IOHIDGetFloatFunc sHidGetFloat = NULL;
static pthread_once_t sHidResolveOnce = PTHREAD_ONCE_INIT;
static pthread_mutex_t sHidCacheMutex = PTHREAD_MUTEX_INITIALIZER;
static uint64_t sLastHidSampleTimeNs = 0;
static int32_t sCachedHidDieTemp = 0; // >0: valid C; -1: negative-cached unavailable; 0: uninitialized

static void resolveHidSymbolsOnce(void) {
    sHidCreate = (IOHIDCreateFunc)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateSimpleClient");
    if (!sHidCreate) {
        sHidCreate = (IOHIDCreateFunc)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    }
    sHidSetMatching = (IOHIDSetMatchingFunc)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientSetMatching");
    sHidCopyServices = (IOHIDCopyServicesFunc)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
    sHidCopyProperty = (IOHIDCopyPropertyFunc)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
    sHidCopyEvent = (IOHIDCopyEventFunc)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyEvent");
    sHidGetFloat = (IOHIDGetFloatFunc)dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
}

int32_t DiskReadAppleSiliconStorageDieTemperature(void) {
    pthread_once(&sHidResolveOnce, resolveHidSymbolsOnce);
    if (!sHidCreate || !sHidCopyServices || !sHidCopyProperty || !sHidCopyEvent || !sHidGetFloat) {
        return 0;
    }

    uint64_t nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    const uint64_t kPositiveTtlNs = 5000000000ULL;   // 5s cache for valid readings
    const uint64_t kNegativeTtlNs = 60000000000ULL;  // 60s negative cache on Intel/VMs

    pthread_mutex_lock(&sHidCacheMutex);
    if (sLastHidSampleTimeNs > 0 && nowNs >= sLastHidSampleTimeNs) {
        uint64_t elapsed = nowNs - sLastHidSampleTimeNs;
        if (sCachedHidDieTemp > 0 && elapsed < kPositiveTtlNs) {
            int32_t cached = sCachedHidDieTemp;
            pthread_mutex_unlock(&sHidCacheMutex);
            return cached;
        }
        if (sCachedHidDieTemp < 0 && elapsed < kNegativeTtlNs) {
            pthread_mutex_unlock(&sHidCacheMutex);
            return 0;
        }
    }
    pthread_mutex_unlock(&sHidCacheMutex);

    void *client = sHidCreate(kCFAllocatorDefault);
    if (!client) return 0;

    int page = 0xFF00, usage = 0x0005;
    CFNumberRef numPage = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef numUsage = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    if (numPage && numUsage && sHidSetMatching) {
        const void *keys[2] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
        const void *vals[2] = { numPage, numUsage };
        CFDictionaryRef matching = CFDictionaryCreate(
            kCFAllocatorDefault, keys, vals, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
        );
        if (matching) {
            sHidSetMatching(client, matching);
            CFRelease(matching);
        }
    }
    if (numPage) CFRelease(numPage);
    if (numUsage) CFRelease(numUsage);

    CFArrayRef services = sHidCopyServices(client);
    int32_t maxTemp = 0;
    if (services) {
        CFIndex count = CFArrayGetCount(services);
        for (CFIndex i = 0; i < count; i++) {
            void *service = (void *)CFArrayGetValueAtIndex(services, i);
            CFTypeRef prop = sHidCopyProperty(service, CFSTR("Product"));
            if (!prop) continue;
            if (CFGetTypeID(prop) == CFStringGetTypeID()) {
                char buf[128] = {0};
                if (CFStringGetCString((CFStringRef)prop, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                    if (strstr(buf, "NAND") != NULL || strstr(buf, "Storage") != NULL || strstr(buf, "SSD") != NULL) {
                        void *event = sHidCopyEvent(service, 15 /* kIOHIDEventTypeTemperature */, 0, 0);
                        if (event) {
                            double t = sHidGetFloat(event, 15 << 16);
                            CFRelease(event);
                            if (t > 0.0 && t < 150.0) {
                                int32_t rounded = (int32_t)(t + 0.5);
                                if (rounded > maxTemp) maxTemp = rounded;
                            }
                        }
                    }
                }
            }
            CFRelease(prop);
        }
        CFRelease(services);
    }
    CFRelease(client);

    pthread_mutex_lock(&sHidCacheMutex);
    sCachedHidDieTemp = (maxTemp > 0) ? maxTemp : -1;
    sLastHidSampleTimeNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    pthread_mutex_unlock(&sHidCacheMutex);

    return maxTemp;
}
