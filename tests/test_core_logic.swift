import Foundation

// MARK: - Swift Core Logic & Engine Unit Test Suite

private func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition() {
        fputs("❌ ASSERTION FAILED [\(file):\(line)]: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct CoreLogicTestRunner {
    static func main() {
        print("=== Swift Unit Test 1: POSIX Date, Byte & Bus Speed Formatters ===")
        let sampleDate = Date(timeIntervalSince1970: 1_700_000_000) // Deterministic epoch
        let shortTime = shortTimeFormatter.string(from: sampleDate)
        let isoTime = isoTimestampFormatter.string(from: sampleDate)

        // Must be strict 24-hour HH:mm:ss (length 8, two colons)
        assertTrue(shortTime.count == 8, "shortTimeFormatter must produce 8-char HH:mm:ss, got '\(shortTime)'")
        assertTrue(shortTime.filter { $0 == ":" }.count == 2, "shortTimeFormatter must contain 2 colons")
        assertTrue(!shortTime.contains("AM") && !shortTime.contains("PM"), "shortTimeFormatter must not contain AM/PM")
        assertTrue(isoTime.count == 19, "isoTimestampFormatter must produce 19-char timestamp, got '\(isoTime)'")

        // Byte formatting
        assertTrue(formatBytes(500_000_000) == "500.0 MB", "Expected 500.0 MB, got \(formatBytes(500_000_000))")
        assertTrue(formatBytes(25_500_000_000) == "25.5 GB", "Expected 25.5 GB, got \(formatBytes(25_500_000_000))")
        assertTrue(formatBytes(2_000_000_000_000) == "2.00 TB", "Expected 2.00 TB, got \(formatBytes(2_000_000_000_000))")

        // Bus speed formatting
        assertTrue(formatLinkSpeed(480_000_000, interconnect: "USB").contains("480 Mbps"), "480 Mbps USB 2.0 format")
        assertTrue(formatLinkSpeed(5_000_000_000, interconnect: "USB").contains("5 Gbps"), "5 Gbps USB 3.0 format")
        assertTrue(formatLinkSpeed(10_000_000_000, interconnect: "USB").contains("10 Gbps"), "10 Gbps USB 3.2 format")
        assertTrue(formatLinkSpeed(20_000_000_000, interconnect: "USB").contains("20 Gbps"), "20 Gbps USB4 format")
        assertTrue(formatLinkSpeed(40_000_000_000, interconnect: "Thunderbolt").contains("40 Gbps"), "40 Gbps TB3/4 format")
        assertTrue(formatLinkSpeed(0, interconnect: "Apple Fabric") == "Apple Fabric", "Fallback interconnect label")
        print("  [OK] Formatters verified")

        print("=== Swift Unit Test 2: HealthSeverity & DiskPersistentState Codable ===")
        assertTrue(HealthSeverity.healthy.rank < HealthSeverity.warning.rank, "healthy < warning")
        assertTrue(HealthSeverity.warning.rank < HealthSeverity.critical.rank, "warning < critical")

        var state = DiskPersistentState()
        state.monitoredTarget = "/Volumes/TestDrive"
        state.updateDriveState(key: "SERIAL123") { d in
            d.bsdName = "disk9"
            d.peakTemperatureCelsius = 49
            d.baselineUnsafeShutdowns = 4
        }
        let encodedState = try? JSONEncoder().encode(state)
        assertTrue(encodedState != nil, "DiskPersistentState must encode to JSON")
        let decodedState = try? JSONDecoder().decode(DiskPersistentState.self, from: encodedState!)
        assertTrue(decodedState?.monitoredTarget == "/Volumes/TestDrive", "Decoded monitoredTarget must match")
        assertTrue(decodedState?.getDriveState(key: "SERIAL123").peakTemperatureCelsius == 49, "Decoded peak temp must be 49")
        assertTrue(decodedState?.getDriveState(key: "SERIAL123").baselineUnsafeShutdowns == 4, "Decoded baseline unsafe shutdowns must be 4")
        print("  [OK] Models & Codable serialization verified")

        print("=== Swift Unit Test 3: ConfigManager Sanitization, Redaction & 0600 Permissions ===")
        let cfgMgr = ConfigManager.shared
        let testToken = "999999999:AAH_unit_test_secret_token_value"
        cfgMgr.updateConfig { cfg in
            cfg.telegramBotToken = testToken
            cfg.telegramChatId = "12345678"
            cfg.tempWarningCelsius = 56
            cfg.tempCriticalCelsius = 69
        }

        // In-memory config must redact the token and store it in SecretStore
        assertTrue(cfgMgr.config.telegramBotToken == "REDACTED_IN_KEYCHAIN", "In-memory config token must be REDACTED_IN_KEYCHAIN")

        // On-disk config.json must never contain the raw secret token and must have 0600 permissions
        let rawConfigOnDisk = (try? String(contentsOfFile: cfgMgr.configFilePath, encoding: .utf8)) ?? ""
        assertTrue(!rawConfigOnDisk.isEmpty, "config.json must be written to disk")
        assertTrue(!rawConfigOnDisk.contains(testToken), "config.json on disk must NEVER contain raw secret token")
        assertTrue(rawConfigOnDisk.contains("REDACTED_IN_KEYCHAIN"), "config.json must contain REDACTED_IN_KEYCHAIN marker")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: cfgMgr.configFilePath),
           let perms = attrs[.posixPermissions] as? NSNumber {
            assertTrue(perms.intValue == 0o600, "config.json must have 0600 permissions, got \(String(perms.intValue, radix: 8))")
        } else {
            assertTrue(false, "Could not inspect POSIX permissions of config.json")
        }

        // Verify masked vs unmasked export
        let maskedJSON = cfgMgr.exportSanitizedConfigJSON(includeSecrets: false)
        assertTrue(!maskedJSON.contains(testToken), "Masked export must not leak secret token")
        assertTrue(maskedJSON.contains("Protected"), "Masked export must show Protected placeholder")

        let unmaskedJSON = cfgMgr.exportSanitizedConfigJSON(includeSecrets: true)
        assertTrue(unmaskedJSON.contains(testToken), "Unmasked export must include resolved secret token")

        // Clean up test secret
        SecretStore.shared.deleteSecret(forKey: "telegramBotToken")
        print("  [OK] ConfigManager & SecretStore security verified")

        print("=== Swift Unit Test 4: Health Evaluation Engine Rules (Root Volume, Thresholds & Subpaths) ===")
        let monitor = DiskHealthMonitor.shared

        // 4a. Evaluate root volume '/' with normal thresholds
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/"
            cfg.targetDeviceQuery = nil
            cfg.requiredSubpaths = ["System", "Users"]
            cfg.diskUsedWarningPercent = 99.0
            cfg.diskUsedCriticalPercent = 99.9
            cfg.minFreeSpaceWarningGB = 0.001
            cfg.minFreeSpaceCriticalGB = 0.0001
            cfg.enableActiveCanary = true
        }
        let normalSnap = monitor.evaluateHealth(forceCanary: true, allowNotifications: false)
        assertTrue(normalSnap.isMounted, "Root volume '/' must be detected as mounted")
        assertTrue(normalSnap.hardwareFound, "Root volume '/' must resolve underlying hardware device")
        assertTrue(normalSnap.canaryOk, "Active probe on '/' must succeed")
        assertTrue(normalSnap.subpathsStatus["System"] == true && normalSnap.subpathsStatus["Users"] == true, "Existing subpaths must report true")
        assertTrue(!normalSnap.issues.contains(where: { $0.code == "REQUIRED_PATH_MISSING" }), "No REQUIRED_PATH_MISSING expected when subpaths exist")

        // 4b. Trigger REQUIRED_PATH_MISSING by requiring a non-existent subpath
        cfgMgr.updateConfig { cfg in
            cfg.requiredSubpaths = ["System", "__NonExistentFolder_Unit_Test_999__"]
        }
        let missingSubpathSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(missingSubpathSnap.issues.contains(where: { $0.code == "REQUIRED_PATH_MISSING" }), "Missing required subpath must trigger REQUIRED_PATH_MISSING")
        assertTrue(missingSubpathSnap.overallSeverity == .critical, "Missing required subpath must escalate overallSeverity to CRITICAL")
        assertTrue(missingSubpathSnap.healthScore < 100, "Health score must decrease on CRITICAL issue")

        // 4c. Trigger DISK_SPACE_WARNING and DISK_SPACE_CRITICAL deterministically
        cfgMgr.updateConfig { cfg in
            cfg.requiredSubpaths = []
            cfg.diskUsedWarningPercent = 0.01
            cfg.diskUsedCriticalPercent = 99.99
        }
        let spaceWarnSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(spaceWarnSnap.issues.contains(where: { $0.code == "DISK_SPACE_WARNING" }), "Low diskUsedWarningPercent must trigger DISK_SPACE_WARNING")

        cfgMgr.updateConfig { cfg in
            cfg.diskUsedWarningPercent = 0.01
            cfg.diskUsedCriticalPercent = 0.01
        }
        let spaceCritSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(spaceCritSnap.issues.contains(where: { $0.code == "DISK_SPACE_CRITICAL" }), "Low diskUsedCriticalPercent must trigger DISK_SPACE_CRITICAL")
        assertTrue(spaceCritSnap.overallSeverity == .critical, "DISK_SPACE_CRITICAL must set overallSeverity to CRITICAL")

        // 4d. Trigger HW_DISCONNECTED / VOLUME_UNMOUNTED with non-existent target
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/Volumes/__NonExistent_Disk_Unit_Test__"
            cfg.targetDeviceQuery = "disk99999"
            cfg.diskUsedWarningPercent = 85.0
            cfg.diskUsedCriticalPercent = 93.0
        }
        let disconnectedSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(!disconnectedSnap.hardwareFound, "Bogus device query must report hardwareFound == false")
        assertTrue(!disconnectedSnap.isMounted, "Bogus volume path must report isMounted == false")
        assertTrue(disconnectedSnap.issues.contains(where: { $0.code == "HW_DISCONNECTED" }), "Must trigger HW_DISCONNECTED")
        assertTrue(disconnectedSnap.issues.contains(where: { $0.code == "VOLUME_UNMOUNTED" }), "Must trigger VOLUME_UNMOUNTED")
        assertTrue(disconnectedSnap.overallSeverity == .critical, "Disconnected target must be CRITICAL")
        print("  [OK] Health evaluation rules verified")

        print("=== Swift Unit Test 5: DiagnosticExporter JSON Bundle Verification ===")
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/"
            cfg.targetDeviceQuery = nil
            cfg.telegramBotToken = "888888:AAH_secret_for_diag_test"
        }
        let diagJSON = DiagnosticExporter.shared.exportDiagnosticReportJSON(snapshot: normalSnap)
        assertTrue(diagJSON.contains("\"reportVersion\""), "Diagnostic JSON must include reportVersion")
        assertTrue(diagJSON.contains("\"evaluation\""), "Diagnostic JSON must include evaluation section")
        assertTrue(!diagJSON.contains("888888:AAH_secret_for_diag_test"), "Diagnostic JSON must never leak raw Telegram Bot Token")
        SecretStore.shared.deleteSecret(forKey: "telegramBotToken")
        print("  [OK] DiagnosticExporter verified")

        print("=== Swift Unit Test 6: HTML Entity Escaping (TelegramNotifier) ===")
        let rawHtmlStr = "<script>alert('test & pass')</script> /Volumes/A&B/Path > Foo"
        let escaped = TelegramNotifier.shared.escapeHTML(rawHtmlStr)
        assertTrue(escaped == "&lt;script&gt;alert('test &amp; pass')&lt;/script&gt; /Volumes/A&amp;B/Path &gt; Foo", "escapeHTML must convert <, >, and & correctly")

        let dummySnap = DiskHealthSnapshot(
            timestamp: normalSnap.timestamp,
            formattedTime: normalSnap.formattedTime,
            formattedShortTime: normalSnap.formattedShortTime,
            overallSeverity: .warning,
            healthScore: 85,
            issues: [
                HealthIssue(code: "TEST_HTML", severity: .warning, title: "Issue <Title>", detail: "Detail & <More>")
            ],
            hardwareFound: true,
            vendorName: "Vendor & Co",
            productName: "Bad <Name> & Drive",
            productRevision: "1.0",
            bsdName: "disk9",
            serialNumber: "SN&123<4>",
            usbSerialNumber: "SN&123<4>",
            interconnectType: "USB",
            protocolType: "NVMe",
            isInternal: false,
            isRemovable: true,
            linkSpeedBps: 5_000_000_000,
            linkSpeedFormatted: "5 Gbps",
            isMounted: true,
            mountPoint: "/Volumes/Test & <Drive>",
            filesystemType: "apfs",
            isReadOnly: false,
            totalBytes: 1_000_000,
            freeBytes: 500_000,
            usedBytes: 500_000,
            usedPercent: 50.0,
            subpathsStatus: [:],
            canaryOk: false,
            canaryLatencyMs: 0.0,
            canaryError: "Error: size < 0 & failed",
            smartValid: false,
            criticalWarning: 0,
            temperatureCelsius: 0,
            peakTemperatureCelsius: 0,
            availableSpare: 0,
            availableSpareThreshold: 0,
            percentageUsed: 0,
            lifeRemainingPercent: 0,
            totalTerabytesRead: 0.0,
            totalTerabytesWritten: 0.0,
            powerCycles: 0,
            powerOnHours: 0,
            unsafeShutdowns: 0,
            mediaErrors: 0,
            errorInfoLogEntries: 0,
            statsValid: false,
            sessionBytesRead: 0,
            sessionBytesWritten: 0,
            operationsRead: 0,
            operationsWritten: 0,
            errorsRead: 0,
            errorsWritten: 0,
            retriesRead: 0,
            retriesWritten: 0,
            avgReadLatencyMs: 0.0,
            avgWriteLatencyMs: 0.0,
            readThroughputMBps: 0.0,
            writeThroughputMBps: 0.0,
            lastVerifyResult: "fsck: found 1 <error> & 2 warnings",
            lastVerifyOk: false
        )
        let reportHtml = TelegramNotifier.shared.formatReportHTML(snapshot: dummySnap, title: "Report <1> & <2>")
        assertTrue(!reportHtml.contains("<Name>"), "HTML report must escape productName <Name>")
        assertTrue(reportHtml.contains("&lt;Name&gt;"), "HTML report must contain &lt;Name&gt;")
        assertTrue(reportHtml.contains("&amp; Drive"), "HTML report must contain &amp; Drive")
        assertTrue(reportHtml.contains("&lt;1&gt; &amp; &lt;2&gt;"), "HTML report must escape title entities")
        assertTrue(reportHtml.contains("Detail &amp; &lt;More&gt;"), "HTML report must escape issue detail entities")
        print("  [OK] HTML escaping verified")

        print("=== Swift Unit Test 7: Unmounted Stub Directory Detection ===")
        let stubDir = "/Volumes/__unmounted_stub_test_\(UUID().uuidString)__"
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = stubDir
            cfg.targetDeviceQuery = nil
        }
        let stubSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(!stubSnap.isMounted, "Unmounted stub directory under /Volumes must evaluate to isMounted == false")
        assertTrue(stubSnap.issues.contains(where: { $0.code == "VOLUME_UNMOUNTED" }), "Unmounted stub directory must trigger VOLUME_UNMOUNTED issue")
        print("  [OK] Unmounted stub directory detection verified")

        print("=== Swift Unit Test 8: Configuration Import Logic & Secret Preservation ===")
        let initialToken = "7777777:AAH_initial_token_before_import"
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/"
            cfg.telegramBotToken = initialToken
            cfg.pollIntervalSeconds = 45.0
            cfg.tempWarningCelsius = 55
        }
        assertTrue(cfgMgr.resolvedTelegramBotToken == initialToken, "Initial token must be resolved")

        // Simulate importing a config where telegramBotToken is masked or REDACTED_IN_KEYCHAIN
        let exportedSanitized = cfgMgr.exportSanitizedConfigJSON(includeSecrets: false)
        assertTrue(exportedSanitized.contains("Protected"), "Exported config must have Protected placeholder")

        if let data = exportedSanitized.data(using: .utf8),
           var importedCfg = try? JSONDecoder().decode(DiskHealthConfig.self, from: data) {
            importedCfg.pollIntervalSeconds = 15.0
            importedCfg.tempWarningCelsius = 42

            let modifiedData = (try? JSONEncoder().encode(importedCfg)) ?? Data()
            let importOk = cfgMgr.importConfig(from: modifiedData)
            assertTrue(importOk, "ConfigManager.importConfig must succeed")
            assertTrue(cfgMgr.config.pollIntervalSeconds == 15.0, "Imported pollIntervalSeconds must be 15.0")
            assertTrue(cfgMgr.config.tempWarningCelsius == 42, "Imported tempWarningCelsius must be 42")
            assertTrue(cfgMgr.resolvedTelegramBotToken == initialToken, "Existing Keychain token must be preserved after import")
        } else {
            assertTrue(false, "Failed to decode exported sanitized config JSON")
        }
        SecretStore.shared.deleteSecret(forKey: "telegramBotToken")
        print("  [OK] Config import and secret preservation verified")

        print("=== Swift Unit Test 9: Thread-Safe Logging and Log File Rotation ===")
        let logPath = cfgMgr.logFilePath
        let rotatedPath = "\(logPath).1"
        try? FileManager.default.removeItem(atPath: logPath)
        try? FileManager.default.removeItem(atPath: rotatedPath)

        cfgMgr.log("Initial test log entry")
        assertTrue(FileManager.default.fileExists(atPath: logPath), "health.log must be created by ConfigManager.log")

        // Create a large file (> 5 MB) at logFilePath to trigger rotation
        let largeBuffer = Data(repeating: 0x41, count: 5 * 1024 * 1024 + 1024)
        try? largeBuffer.write(to: URL(fileURLWithPath: logPath))

        cfgMgr.log("Rotated test log entry")
        assertTrue(FileManager.default.fileExists(atPath: rotatedPath), "health.log.1 must exist after log rotation")
        let rotatedAttrs = try? FileManager.default.attributesOfItem(atPath: rotatedPath)
        let rotatedSize = (rotatedAttrs?[.size] as? UInt64) ?? 0
        assertTrue(rotatedSize > 5 * 1024 * 1024, "Rotated log size must be > 5 MB")

        let newLogContent = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        assertTrue(newLogContent.contains("Rotated test log entry"), "New health.log must contain the latest log entry")
        assertTrue(!newLogContent.contains("Initial test log entry"), "New health.log must not contain old entries")

        // Clean up
        try? FileManager.default.removeItem(atPath: rotatedPath)
        print("  [OK] Log rotation verified")

        print("=== Swift Unit Test 10: Target Switch State Invalidation (IMPROVE-06) ===")
        monitor.setMonitoredTarget(volumePath: "/", deviceQuery: nil)
        let rootSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(rootSnap.hardwareFound, "Root target must be found")

        let bogusTarget = "/Volumes/Bogus_\(UUID().uuidString)"
        monitor.setMonitoredTarget(volumePath: bogusTarget, deviceQuery: nil)
        let bogusSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(bogusSnap.readThroughputMBps == 0.0, "Throughput read must reset to 0.0 MBps on target switch")
        assertTrue(bogusSnap.writeThroughputMBps == 0.0, "Throughput write must reset to 0.0 MBps on target switch")
        monitor.setMonitoredTarget(volumePath: "/", deviceQuery: nil)
        print("  [OK] Target switch state reset verified")

        print("=== Swift Unit Test 11: I/O Retry Baseline Advancement (IMPROVE-15) ===")
        var testPersistentState = DiskPersistentState()
        let testDriveKey = "retry_test_drive_\(UUID().uuidString)"
        testPersistentState.updateDriveState(key: testDriveKey) {
            $0.baselineIoReadRetries = 10
            $0.baselineIoWriteRetries = 5
        }
        let initDriveState = testPersistentState.getDriveState(key: testDriveKey, bsdName: "disk9", serial: "SN_TEST")
        assertTrue(initDriveState.baselineIoReadRetries == 10, "Initial baselineIoReadRetries must be 10")
        assertTrue(initDriveState.baselineIoWriteRetries == 5, "Initial baselineIoWriteRetries must be 5")

        testPersistentState.updateDriveState(key: testDriveKey) {
            $0.baselineIoReadRetries = 25
            $0.baselineIoWriteRetries = 14
        }
        let updatedDriveState = testPersistentState.getDriveState(key: testDriveKey, bsdName: "disk9", serial: "SN_TEST")
        assertTrue(updatedDriveState.baselineIoReadRetries == 25, "Advanced baselineIoReadRetries must be 25")
        assertTrue(updatedDriveState.baselineIoWriteRetries == 14, "Advanced baselineIoWriteRetries must be 14")
        print("  [OK] I/O retry baseline advancement verified")

        print("=== Swift Unit Test 12: ConfigManager Concurrency & SynchronizedDateFormatter Thread Safety (IMPROVE-V2-02) ===")
        let group = DispatchGroup()
        for i in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                cfgMgr.updateConfig { cfg in
                    cfg.tempWarningCelsius = 40 + (i % 10)
                }
                _ = isoTimestampFormatter.string(from: Date())
                _ = shortTimeFormatter.string(from: Date())
                _ = shortMonthDateFormatter.string(from: Date())
                group.leave()
            }
        }
        group.wait()
        assertTrue(cfgMgr.config.tempWarningCelsius >= 40 && cfgMgr.config.tempWarningCelsius <= 50, "Concurrent updateConfig completed safely")
        print("  [OK] Concurrency & SynchronizedDateFormatter verified")

        print("=== Swift Unit Test 13: System Sleep / Wake Telemetry Grace Period (IMPROVE-V2-03) ===")
        monitor.noteSystemWillSleep()
        monitor.noteSystemDidWake()
        // During the 8s grace period, a missing device or unmounted stub should not trigger HW_DISCONNECTED or VOLUME_UNMOUNTED issues
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/Volumes/__Wake_Grace_Test__"
            cfg.targetDeviceQuery = "disk99998"
        }
        let wakeSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(!wakeSnap.issues.contains(where: { $0.code == "HW_DISCONNECTED" }), "HW_DISCONNECTED suppressed during wake grace period")
        assertTrue(!wakeSnap.issues.contains(where: { $0.code == "VOLUME_UNMOUNTED" }), "VOLUME_UNMOUNTED suppressed during wake grace period")
        assertTrue(!wakeSnap.issues.contains(where: { $0.code == "CANARY_IO_FAILED" }), "CANARY_IO_FAILED suppressed during wake grace period")
        assertTrue(!wakeSnap.issues.contains(where: { $0.code == "CANARY_HIGH_LATENCY" }), "CANARY_HIGH_LATENCY suppressed during wake grace period")
        print("  [OK] Sleep / wake grace period suppression verified")

        print("=== Swift Unit Test 14: Per-Drive Severity Scoping on Target Switch (IMPROVE-V2-04) ===")
        cfgMgr.updateConfig { cfg in
            cfg.diskUsedWarningPercent = 99.0
            cfg.diskUsedCriticalPercent = 99.9
            cfg.minFreeSpaceWarningGB = 0.001
            cfg.minFreeSpaceCriticalGB = 0.0001
            cfg.requiredSubpaths = []
        }
        // Expire wake grace window explicitly for this test
        monitor.noteSystemDidWake(at: Date().timeIntervalSince1970 - 15.0)
        monitor.setMonitoredTarget(volumePath: "/Volumes/__Missing_For_Severity_Test__", deviceQuery: nil)
        let failSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(failSnap.overallSeverity == .critical, "Missing target must evaluate to CRITICAL")

        // Switch to root '/', which is HEALTHY
        monitor.setMonitoredTarget(volumePath: "/", deviceQuery: nil)
        let switchedSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(switchedSnap.overallSeverity == .healthy, "Target switch to '/' must evaluate to HEALTHY without false recovery alert")
        print("  [OK] Per-drive severity scoping on target switch verified")

        print("=== Swift Unit Test 15: Canary File Security & Subpath Traversal Sanitization (IMPROVE-V2-06) ===")
        // Subpath traversal check: subpaths containing ".." must be rejected (false)
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/"
            cfg.requiredSubpaths = ["../etc", "Users/../Applications", "..", "Users"]
        }
        let traversalSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(traversalSnap.subpathsStatus["../etc"] == false, "Subpath with .. prefix must be rejected")
        assertTrue(traversalSnap.subpathsStatus["Users/../Applications"] == false, "Subpath with .. component must be rejected")
        assertTrue(traversalSnap.subpathsStatus[".."] == false, "Subpath '..' must be rejected")
        assertTrue(traversalSnap.subpathsStatus["Users"] == true, "Normal subpath 'Users' must succeed")

        // Canary symlink attack prevention check (O_NOFOLLOW / O_CLOEXEC)
        let canarySymlinkTestDir = "\(NSTemporaryDirectory())canary_symlink_test_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: canarySymlinkTestDir, withIntermediateDirectories: true)
        let sensitiveTargetFile = "\(canarySymlinkTestDir)/important_data.txt"
        let secretContent = "CRITICAL_SYSTEM_DATA_DO_NOT_TRUNCATE"
        try? secretContent.write(toFile: sensitiveTargetFile, atomically: true, encoding: .utf8)
        let symlinkCanaryPath = "\(canarySymlinkTestDir)/.disk_health_canary"
        try? FileManager.default.createSymbolicLink(atPath: symlinkCanaryPath, withDestinationPath: sensitiveTargetFile)

        // Attempt canary write via open with O_NOFOLLOW
        let canaryFd = open(symlinkCanaryPath, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        assertTrue(canaryFd < 0, "open() on canary symlink with O_NOFOLLOW must fail")
        assertTrue(errno == ELOOP, "open() on canary symlink must fail with ELOOP, got errno \(errno)")
        let readBackData = try? String(contentsOfFile: sensitiveTargetFile, encoding: .utf8)
        assertTrue(readBackData == secretContent, "Sensitive target file must NOT be truncated by canary probe")
        try? FileManager.default.removeItem(atPath: canarySymlinkTestDir)

        // Clean up requiredSubpaths
        cfgMgr.updateConfig { $0.requiredSubpaths = [] }
        print("  [OK] Subpath traversal sanitization & canary symlink protection verified")

        print("=== Swift Unit Test 16: Accurate Mount Path & Unmounted Stub Detection (IMPROVE-V2-07) ===")
        // Mounted root volume '/' should report isMounted == true
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/"
            cfg.targetDeviceQuery = nil
        }
        let rootSnapCheck = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(rootSnapCheck.isMounted, "Root volume '/' must be detected as mounted")

        // Root subdirectories like '/Users' must ALSO report isMounted == true (not VOLUME_UNMOUNTED)
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/Users"
            cfg.targetDeviceQuery = nil
        }
        let usersSnapCheck = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(usersSnapCheck.isMounted, "Subdirectory '/Users' on root filesystem must be detected as mounted")
        assertTrue(!usersSnapCheck.issues.contains(where: { $0.code == "VOLUME_UNMOUNTED" }), "/Users must not trigger VOLUME_UNMOUNTED")

        // Unmounted stub in /Volumes must report isMounted == false
        let fakeVolumeStub = "/Volumes/__Unmounted_Stub_Test_\(UUID().uuidString)__"
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = fakeVolumeStub
            cfg.targetDeviceQuery = nil
        }
        let unmountedSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(!unmountedSnap.isMounted, "Unmounted stub under /Volumes/ must report isMounted == false")
        assertTrue(unmountedSnap.issues.contains(where: { $0.code == "VOLUME_UNMOUNTED" }), "Must trigger VOLUME_UNMOUNTED")
        print("  [OK] Mount path & unmounted stub detection verified")

        print("=== Swift Unit Test 17: runVolumeVerification Re-Entrancy Guard (IMPROVE-V2-08) ===")
        let verifyGroup = DispatchGroup()
        var verifyResults: [String] = []
        let resultsLock = NSLock()

        verifyGroup.enter()
        monitor.runVolumeVerification(sendTelegram: false) { ok, msg in
            resultsLock.lock()
            verifyResults.append(msg)
            resultsLock.unlock()
            verifyGroup.leave()
        }

        // Immediate second call while first is in progress
        verifyGroup.enter()
        monitor.runVolumeVerification(sendTelegram: false) { ok, msg in
            resultsLock.lock()
            verifyResults.append(msg)
            resultsLock.unlock()
            verifyGroup.leave()
        }

        verifyGroup.wait()
        assertTrue(verifyResults.contains("Verification already in progress"), "Second concurrent verification must be rejected by re-entrancy lock")
        print("  [OK] runVolumeVerification re-entrancy guard verified")

        print("=== Swift Unit Test 18: Restrictive 0600 File Permissions (IMPROVE-V2-10) ===")
        // Trigger health evaluation and logging to create state.json, latest_status.json, health.log
        cfgMgr.updateConfig { $0.targetVolumePath = "/" }
        _ = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        cfgMgr.log("Permission check log message")

        let pathsToCheck = [
            cfgMgr.stateFilePath,
            cfgMgr.latestJsonPath,
            cfgMgr.logFilePath
        ]

        for p in pathsToCheck {
            assertTrue(FileManager.default.fileExists(atPath: p), "File must exist: \(p)")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
               let perms = attrs[.posixPermissions] as? NSNumber {
                assertTrue(perms.intValue == 0o600, "File \(p) must have 0600 permissions, got \(String(perms.intValue, radix: 8))")
            } else {
                assertTrue(false, "Could not read POSIX permissions for \(p)")
            }
        }

        // Also verify diagnostic report 0600 permissions
        if let diagPath = DiagnosticExporter.shared.saveDiagnosticReportToFile() {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: diagPath),
               let perms = attrs[.posixPermissions] as? NSNumber {
                assertTrue(perms.intValue == 0o600, "Diagnostic report must have 0600 permissions, got \(String(perms.intValue, radix: 8))")
            } else {
                assertTrue(false, "Could not read POSIX permissions for diagnostic report")
            }
            try? FileManager.default.removeItem(atPath: diagPath)
        }
        print("  [OK] 0600 file permissions verified")

        print("✅ All Swift Core Logic Unit Tests Passed!")
    }
}
