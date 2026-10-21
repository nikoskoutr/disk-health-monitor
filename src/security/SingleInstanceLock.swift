import Foundation
import Darwin

// MARK: - Single-Instance Menu Bar Lock (POSIX flock)

final class SingleInstanceLock: @unchecked Sendable {
    static let shared = SingleInstanceLock()
    private var lockFd: Int32 = -1
    private let stateLock = NSLock()

    var lockFilePath: String {
        "\(ConfigManager.shared.configDir)/menubar.lock"
    }

    var isHoldingLock: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lockFd >= 0
    }

    @discardableResult
    func tryAcquire(customPath: String? = nil) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        if lockFd >= 0 {
            return true
        }

        let path = customPath ?? lockFilePath
        let parentDir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return false
        }
        fchmod(fd, 0o600)

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }

        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        let pidStr = "\(getpid())\n"
        _ = pidStr.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }
        fsync(fd)

        lockFd = fd
        return true
    }

    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }

        if lockFd >= 0 {
            flock(lockFd, LOCK_UN)
            close(lockFd)
            lockFd = -1
        }
    }
}
