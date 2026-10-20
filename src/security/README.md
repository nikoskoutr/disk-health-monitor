# Security & Process Mutual Exclusion (`src/security/`)

This directory implements secure credential management for sensitive tokens and POSIX-level process mutual exclusion for the menu bar agent.

---

## Files

### 1. [`SecretStore.swift`](SecretStore.swift)
Provides a thread-safe unified key-value interface (`setSecret`, `getSecret`, `deleteSecret`) backed by an `NSRecursiveLock` and a two-tier storage architecture:

1. **Primary Tier — macOS Keychain (`Security.framework`)**:
   - Manages generic password items (`kSecClassGenericPassword`) under service `io.github.disk-health-monitor`.
   - Uses `kSecAttrAccessibleAfterFirstUnlock` accessibility policy, allowing background `launchd` daemons to read credentials after initial login.
2. **Fallback Tier — Restricted `0600` File (`.secrets.json`)**:
   - In headless SSH sessions or CI environments where the macOS Keychain is locked or unavailable (`errSecInteractionNotAllowed`), credentials fall back to `~/.config/disk-health-monitor/.secrets.json`.
   - File permissions are strictly enforced to POSIX `0600` (`rw-------`, owner-only).
   - Deleting a secret purges it from both the Keychain and fallback store simultaneously.

---

### 2. [`SingleInstanceLock.swift`](SingleInstanceLock.swift)
Guarantees single-instance execution for the menu bar daemon without restricting concurrent CLI operations:
- **POSIX Non-Blocking `flock`**:
  - Opens `~/.config/disk-health-monitor/menubar.lock` with atomic flags `O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC` and permissions `0600`.
  - Attempts an exclusive non-blocking lock (`flock(fd, LOCK_EX | LOCK_NB)`). If held by an existing instance, the new GUI process exits cleanly with status 0.
- **PID Registration**:
  - Writes the current process ID (`getpid()`) to the lock file followed by `fsync(2)` for diagnostic tracking in `launchctl` and Activity Monitor.
- **Headless Invocations Unrestricted**:
  - Standalone CLI commands (`--status`, `--json`, `--check`, `--surface-scan`, `--export-*`) execute without acquiring this lock, enabling parallel automation.
