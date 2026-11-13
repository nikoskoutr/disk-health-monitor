// ============================================================================
// File: DiskProcessBridge.c
// Module: Layer 1 (C11 / Darwin libproc Bridge)
// Purpose: Process I/O telemetry, per-mount open file blocker inspection,
//          TOCTOU-hardened signal verification, and background I/O throttling.
// Concurrency: Thread-safe; zero shared mutable global state.
// ============================================================================

#define _GNU_SOURCE
#include "DiskHealthBridge.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>

// ============================================================================
// MARK: - Process Disk I/O Telemetry via Darwin libproc (proc_pid_rusage)
// ============================================================================

int DiskSampleProcessIoMetrics(DiskProcessIoMetric *outArray, int maxCount) {
    if (!outArray || maxCount <= 0) return 0;

    int numBytes = proc_listallpids(NULL, 0);
    if (numBytes <= 0) return 0;

    size_t pidCapacity = (size_t)(numBytes / (int)sizeof(pid_t)) + 64;
    pid_t stackPids[512];
    pid_t *pids = stackPids;
    if (pidCapacity > 512) {
        pids = (pid_t *)calloc(pidCapacity, sizeof(pid_t));
        if (!pids) return 0;
    }

    int actualBytes = proc_listallpids(pids, (int)(pidCapacity * sizeof(pid_t)));
    if (actualBytes <= 0) {
        if (pids != stackPids) free(pids);
        return 0;
    }

    int pidCount = actualBytes / (int)sizeof(pid_t);
    int populated = 0;

    for (int i = 0; i < pidCount && populated < maxCount; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;

        struct rusage_info_v4 ru;
        memset(&ru, 0, sizeof(ru));
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ru) != 0) {
            continue;
        }

        // Include processes with non-zero disk I/O or the current process itself
        if (ru.ri_diskio_bytesread == 0 && ru.ri_diskio_byteswritten == 0 && pid != getpid()) {
            continue;
        }

        DiskProcessIoMetric *entry = &outArray[populated];
        memset(entry, 0, sizeof(DiskProcessIoMetric));
        entry->pid = (int32_t)pid;
        entry->diskBytesRead = ru.ri_diskio_bytesread;
        entry->diskBytesWritten = ru.ri_diskio_byteswritten;

        char nameBuf[128] = {0};
        if (proc_name(pid, nameBuf, sizeof(nameBuf) - 1) > 0 && nameBuf[0] != '\0') {
            strlcpy(entry->processName, nameBuf, sizeof(entry->processName));
        } else {
            snprintf(entry->processName, sizeof(entry->processName), "pid-%d", (int)pid);
        }
        populated++;
    }

    if (pids != stackPids) free(pids);
    return populated;
}

// ============================================================================
// MARK: - Open File Blocker Inspector (DA-01)
// ============================================================================

static size_t normalizeMountPrefix(const char *mountPath, char *normOut, size_t normCap) {
    if (!mountPath || !normOut || normCap == 0) return 0;
    strlcpy(normOut, mountPath, normCap);
    size_t len = strlen(normOut);
    while (len > 1 && normOut[len - 1] == '/') {
        normOut[--len] = '\0';
    }
    return len;
}

static bool pathMatchesMount(const char *filePath, const char *normMount, size_t mountLen) {
    if (!filePath || filePath[0] == '\0' || !normMount || mountLen == 0) return false;
    if (strcmp(normMount, "/") == 0) {
        return true;
    }
    if (strncmp(filePath, normMount, mountLen) == 0 &&
        (filePath[mountLen] == '/' || filePath[mountLen] == '\0')) {
        return true;
    }
    // Handle APFS firmlinked user/temp paths when inspecting /System/Volumes/Data
    if (strcmp(normMount, "/System/Volumes/Data") == 0) {
        if (strncmp(filePath, "/Users/", 7) == 0 ||
            strncmp(filePath, "/private/var/folders/", 21) == 0) {
            return true;
        }
    }
    return false;
}

static void inspectPidOpenFilesOnMount(
    pid_t pid,
    const char *normMount,
    size_t mountLen,
    DiskFileBlocker *outList,
    int maxCount,
    int *ioPopulated
) {
    if (pid <= 0 || pid == getpid() || !outList || !ioPopulated || *ioPopulated >= maxCount) {
        return;
    }

    int numFdsBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (numFdsBytes <= 0) return;

    int fdCount = numFdsBytes / (int)sizeof(struct proc_fdinfo);
    if (fdCount <= 0) return;

    struct proc_fdinfo stackFdList[128];
    struct proc_fdinfo *fdList = stackFdList;
    if ((size_t)fdCount > 128) {
        fdList = (struct proc_fdinfo *)calloc((size_t)fdCount, sizeof(struct proc_fdinfo));
        if (!fdList) return;
    }

    int readFdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fdList, (int)(fdCount * sizeof(struct proc_fdinfo)));
    int actualFds = (readFdBytes > 0) ? (readFdBytes / (int)sizeof(struct proc_fdinfo)) : 0;

    char procNameBuf[128] = {0};
    uint64_t procStartTimeSec = 0;
    bool fetchedProcInfo = false;

    for (int j = 0; j < actualFds && *ioPopulated < maxCount; j++) {
        if (fdList[j].proc_fdtype != PROX_FDTYPE_VNODE) continue;

        struct vnode_fdinfowithpath vnodeInfo;
        memset(&vnodeInfo, 0, sizeof(vnodeInfo));
        int vnodeRet = proc_pidfdinfo(pid, fdList[j].proc_fd, PROC_PIDFDVNODEPATHINFO, &vnodeInfo, sizeof(vnodeInfo));
        if (vnodeRet < (int)sizeof(vnodeInfo)) continue;

        const char *filePath = vnodeInfo.pvip.vip_path;
        if (!pathMatchesMount(filePath, normMount, mountLen)) continue;

        if (!fetchedProcInfo) {
            struct proc_bsdinfo bsd;
            memset(&bsd, 0, sizeof(bsd));
            if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, (int)sizeof(bsd)) == (int)sizeof(bsd)) {
                procStartTimeSec = (uint64_t)bsd.pbi_start_tvsec;
                const char *bestName = (bsd.pbi_name[0] != '\0') ? bsd.pbi_name : bsd.pbi_comm;
                if (bestName && bestName[0] != '\0') {
                    strlcpy(procNameBuf, bestName, sizeof(procNameBuf));
                }
            }
            if (procNameBuf[0] == '\0') {
                if (proc_name(pid, procNameBuf, sizeof(procNameBuf) - 1) <= 0 || procNameBuf[0] == '\0') {
                    snprintf(procNameBuf, sizeof(procNameBuf), "pid-%d", (int)pid);
                }
            }
            fetchedProcInfo = true;
        }

        DiskFileBlocker *entry = &outList[*ioPopulated];
        memset(entry, 0, sizeof(DiskFileBlocker));
        entry->pid = (int32_t)pid;
        strlcpy(entry->processName, procNameBuf, sizeof(entry->processName));
        strlcpy(entry->filePath, filePath, sizeof(entry->filePath));
        entry->fd = fdList[j].proc_fd;
        entry->startTimeSec = procStartTimeSec;
        (*ioPopulated)++;
    }

    if (fdList != stackFdList) free(fdList);
}

int DiskListOpenFileBlockers(const char *mountPath, DiskFileBlocker *outList, int maxCount) {
    if (!mountPath || mountPath[0] == '\0' || !outList || maxCount <= 0) return 0;

    char normMount[1024] = {0};
    size_t mountLen = normalizeMountPrefix(mountPath, normMount, sizeof(normMount));
    if (mountLen == 0) return 0;

    int numBytes = proc_listallpids(NULL, 0);
    if (numBytes <= 0) return 0;

    size_t pidCapacity = (size_t)(numBytes / (int)sizeof(pid_t)) + 64;
    pid_t stackPids[512];
    pid_t *pids = stackPids;
    if (pidCapacity > 512) {
        pids = (pid_t *)calloc(pidCapacity, sizeof(pid_t));
        if (!pids) return 0;
    }

    int actualBytes = proc_listallpids(pids, (int)(pidCapacity * sizeof(pid_t)));
    if (actualBytes <= 0) {
        if (pids != stackPids) free(pids);
        return 0;
    }

    int pidCount = actualBytes / (int)sizeof(pid_t);
    int populated = 0;

    for (int i = 0; i < pidCount && populated < maxCount; i++) {
        inspectPidOpenFilesOnMount(pids[i], normMount, mountLen, outList, maxCount, &populated);
    }

    if (pids != stackPids) free(pids);
    return populated;
}

int DiskListProcessOpenFilesOnMount(pid_t pid, const char *mountPath, DiskFileBlocker *outList, int maxCount) {
    if (pid <= 0 || !mountPath || mountPath[0] == '\0' || !outList || maxCount <= 0) return 0;

    char normMount[1024] = {0};
    size_t mountLen = normalizeMountPrefix(mountPath, normMount, sizeof(normMount));
    if (mountLen == 0) return 0;

    int populated = 0;
    inspectPidOpenFilesOnMount(pid, normMount, mountLen, outList, maxCount, &populated);
    return populated;
}

// ============================================================================
// MARK: - Process Identity & Priority Control (PROC-03)
// ============================================================================

bool DiskVerifyProcessForSignal(pid_t pid, const char *expectedName, bool requireCurrentUid, bool *outIsZombie) {
    if (outIsZombie) *outIsZombie = false;
    if (pid <= 100 || pid == getpid()) return false;

    struct proc_bsdinfo bsd;
    memset(&bsd, 0, sizeof(bsd));
    int ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, (int)sizeof(bsd));
    if (ret != (int)sizeof(bsd)) return false;

    if (bsd.pbi_status == 5 /* SZOMB */) {
        if (outIsZombie) *outIsZombie = true;
        return false;
    }
    if (requireCurrentUid && getuid() != 0 && bsd.pbi_uid != getuid()) {
        return false;
    }
    if (expectedName && expectedName[0] != '\0') {
        if (bsd.pbi_name[0] != '\0') {
            if (strcmp(bsd.pbi_name, expectedName) != 0) {
                return false;
            }
        } else if (strncmp(bsd.pbi_comm, expectedName, MAXCOMLEN) != 0) {
            return false;
        }
    }
    return true;
}

bool DiskVerifyBlockerForTermination(
    pid_t pid,
    uint64_t expectedStartTimeSec,
    const char *expectedName,
    const char *mountPath,
    bool *outIsZombie
) {
    if (!DiskVerifyProcessForSignal(pid, expectedName, true, outIsZombie)) {
        return false;
    }

    struct proc_bsdinfo bsd;
    memset(&bsd, 0, sizeof(bsd));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, (int)sizeof(bsd)) != (int)sizeof(bsd)) {
        return false;
    }

    if (bsd.pbi_uid < 501) {
        return false;
    }
    if (expectedStartTimeSec == 0 || (uint64_t)bsd.pbi_start_tvsec != expectedStartTimeSec) {
        return false;
    }
    if (mountPath && mountPath[0] != '\0') {
        DiskFileBlocker tmp;
        if (DiskListProcessOpenFilesOnMount(pid, mountPath, &tmp, 1) <= 0) {
            return false;
        }
    }
    return true;
}

bool DiskIsSafeUserSpaceProcess(pid_t pid) {
    if (pid <= 100 || pid == getpid()) return false;
    struct proc_bsdinfo bsd;
    memset(&bsd, 0, sizeof(bsd));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, (int)sizeof(bsd)) != (int)sizeof(bsd)) {
        return false;
    }
    if (bsd.pbi_uid < 501) return false;
    if (getuid() != 0 && bsd.pbi_uid != getuid()) return false;

    char execPath[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, execPath, sizeof(execPath)) <= 0) return false;
    if (strncmp(execPath, "/System/", 8) == 0 ||
        strncmp(execPath, "/usr/sbin/", 10) == 0 ||
        strncmp(execPath, "/usr/libexec/", 13) == 0 ||
        strncmp(execPath, "/sbin/", 6) == 0) {
        return false;
    }
    return true;
}

int DiskSetProcessBackgroundIoPriority(pid_t pid, bool enable) {
    if (pid <= 0) return -EINVAL;
    int res = setpriority(PRIO_DARWIN_PROCESS, (id_t)pid, enable ? PRIO_DARWIN_BG : 0);
    if (res != 0) {
        if (pid == getpid()) {
            if (setpriority(PRIO_DARWIN_THREAD, 0, enable ? PRIO_DARWIN_BG : 0) == 0) {
                return 0;
            }
        }
        return -errno;
    }
    return 0;
}
