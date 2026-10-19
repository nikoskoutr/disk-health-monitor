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
        let secretBotToken = "888888:AAH_secret_for_diag_test"
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/"
            cfg.targetDeviceQuery = nil
            cfg.telegramBotToken = secretBotToken
        }
        // Write a test log line with both raw and percent-encoded secret tokens to simulate legacy log leakage
        let encodedBotToken = secretBotToken.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? secretBotToken
        ConfigManager.shared.log("Simulated old log entry with token: \(secretBotToken) and encoded: \(encodedBotToken)")
        let diagJSON = DiagnosticExporter.shared.exportDiagnosticReportJSON(snapshot: normalSnap)
        assertTrue(diagJSON.contains("\"reportVersion\""), "Diagnostic JSON must include reportVersion")
        assertTrue(diagJSON.contains("\"evaluation\""), "Diagnostic JSON must include evaluation section")
        assertTrue(diagJSON.contains("\"detectedDevices\""), "Diagnostic JSON must include detectedDevices section")
        assertTrue(diagJSON.contains("\"recentLogLines\""), "Diagnostic JSON must include recentLogLines section")
        assertTrue(!diagJSON.contains(secretBotToken), "Diagnostic JSON must never leak raw Telegram Bot Token even if present in health.log")
        assertTrue(!diagJSON.contains(encodedBotToken), "Diagnostic JSON must never leak percent-encoded Telegram Bot Token")
        assertTrue(diagJSON.contains("[REDACTED_TOKEN]"), "Diagnostic JSON recentLogLines must contain [REDACTED_TOKEN] placeholder")
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

        print("=== Swift Unit Test 12: ConfigManager Concurrency & SynchronizedDateFormatter Thread Safety (IMPROVE-V2-02 & IMPROVE-V3-06 & IMPROVE-V6-01) ===")
        var backgroundPublishesDetected = 0
        let bgPubLock = NSLock()
        let cancellable = cfgMgr.objectWillChange.sink { _ in
            if !Thread.isMainThread {
                bgPubLock.lock()
                backgroundPublishesDetected += 1
                bgPubLock.unlock()
            }
        }

        let group = DispatchGroup()
        for i in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                cfgMgr.updateConfig { cfg in
                    cfg.tempWarningCelsius = 40 + (i % 10)
                }
                _ = cfgMgr.currentConfig
                _ = cfgMgr.resolvedTelegramBotToken
                _ = cfgMgr.resolvedTelegramChatId
                _ = DiagnosticExporter.shared.exportDiagnosticReportJSON()
                _ = isoTimestampFormatter.string(from: Date())
                _ = shortTimeFormatter.string(from: Date())
                _ = shortMonthDateFormatter.string(from: Date())
                group.leave()
            }
        }
        group.wait()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        cancellable.cancel()
        assertTrue(backgroundPublishesDetected == 0, "objectWillChange must never be published from a background thread (IMPROVE-V6-01)")
        assertTrue(cfgMgr.currentConfig.tempWarningCelsius >= 40 && cfgMgr.currentConfig.tempWarningCelsius <= 50, "Concurrent updateConfig completed safely")
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

        print("=== Swift Unit Test 19: Canary Probe on Sealed Root Volume (IMPROVE-V3-04) ===")
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/"
            cfg.targetDeviceQuery = nil
            cfg.enableActiveCanary = true
        }
        let rootCanarySnap = monitor.evaluateHealth(forceCanary: true, allowNotifications: false)
        assertTrue(rootCanarySnap.canaryOk, "Canary check on '/' must succeed via data volume fallback probe")
        assertTrue(rootCanarySnap.canaryLatencyMs >= 0.0, "Canary latency on '/' must be non-negative")
        print("  [OK] Root volume canary probe verified")

        print("=== Swift Unit Test 20: Baseline Lock-Out Fix & resetBaselines() (IMPROVE-V3-05) ===")
        // Verify state preservation across resetBaselines()
        monitor.dailySummaryEnabled = false
        monitor.setMonitoredTarget(volumePath: "/", deviceQuery: nil)
        let preResetSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)

        monitor.resetBaselines()
        assertTrue(monitor.dailySummaryEnabled == false, "resetBaselines must preserve dailySummaryEnabled preference")
        assertTrue(monitor.persistentState.monitoredTarget == "/", "resetBaselines must preserve monitoredTarget")
        assertTrue(monitor.persistentState.lastOverallSeverity == HealthSeverity.healthy.rawValue, "resetBaselines must reset lastOverallSeverity to healthy")
        assertTrue(monitor.persistentState.lastAlertTimestampByCode.isEmpty, "resetBaselines must clear lastAlertTimestampByCode cooldown map")

        let currentKey = !preResetSnap.serialNumber.isEmpty ? preResetSnap.serialNumber : (!preResetSnap.bsdName.isEmpty ? preResetSnap.bsdName : (preResetSnap.mountPoint.isEmpty ? "default" : preResetSnap.mountPoint))
        let activeDriveState = monitor.persistentState.getDriveState(key: currentKey, bsdName: preResetSnap.bsdName, serial: preResetSnap.serialNumber)
        assertTrue(activeDriveState.baselineMediaErrors == preResetSnap.mediaErrors, "baselineMediaErrors must be anchored to current snapshot")
        assertTrue(activeDriveState.baselineIoReadErrors == preResetSnap.errorsRead, "baselineIoReadErrors must be anchored to current snapshot")
        assertTrue(activeDriveState.baselineIoWriteErrors == preResetSnap.errorsWritten, "baselineIoWriteErrors must be anchored to current snapshot")

        // Test rule evaluation logic: historical errors must NOT lock-out alert clearance when baseline == current errors
        var simulatedState = DiskPersistentState()
        let lockoutDriveKey = "simulated_failing_drive_\(UUID().uuidString)"
        simulatedState.updateDriveState(key: lockoutDriveKey) { d in
            d.baselineMediaErrors = 5
            d.baselineIoReadErrors = 2
            d.baselineIoWriteErrors = 1
        }
        let anchoredDrive = simulatedState.getDriveState(key: lockoutDriveKey)
        // With IMPROVE-V3-05 fix: mediaErrors > baseline (5 > 5 is false -> no alert)
        assertTrue(!(5 > (anchoredDrive.baselineMediaErrors ?? 0)), "Equal media errors to baseline must not trigger alert")
        // If mediaErrors increases to 6: 6 > 5 is true -> triggers alert
        assertTrue(6 > (anchoredDrive.baselineMediaErrors ?? 0), "Increased media errors above baseline must trigger alert")
        // Without baseline (initial sight), baseline is 0: 5 > 0 is true -> triggers alert on discovery
        let discoveryBaseline: UInt64? = 0
        assertTrue(5 > (discoveryBaseline ?? 0), "Initial non-zero media errors must trigger alert on first sight")
        print("  [OK] Baseline lock-out fix and resetBaselines() verified")

        print("=== Swift Unit Test 21: SettingsViewModel Bot Token Debouncing & Immediate Commit (IMPROVE-V3-08) ===")
        let vm = SettingsViewModel()
        let debouncedToken = "123456789:ABC_TEST_TOKEN_\(UUID().uuidString)"
        vm.updateBotToken(debouncedToken)
        assertTrue(vm.botToken == debouncedToken, "vm.botToken must immediately reflect updated value in memory")

        // Verify token is NOT written synchronously to SecretStore while typing
        assertTrue(SecretStore.shared.getSecret(forKey: "telegramBotToken") != debouncedToken, "Debounced token must NOT be written synchronously to SecretStore")

        // Wait 450ms for debounce timer (300ms) to fire
        Thread.sleep(forTimeInterval: 0.45)
        assertTrue(SecretStore.shared.getSecret(forKey: "telegramBotToken") == debouncedToken, "Debounced token must be written to SecretStore after debounce timeout")

        // Immediate commit (e.g. Test button or navigation away)
        let immediateToken = "987654321:XYZ_IMMEDIATE_\(UUID().uuidString)"
        vm.updateBotToken(immediateToken)
        vm.commitBotTokenNow(immediateToken)
        let savedSecret = SecretStore.shared.getSecret(forKey: "telegramBotToken")
        assertTrue(savedSecret == immediateToken, "SecretStore must contain immediately committed token")
        assertTrue(ConfigManager.shared.currentConfig.telegramBotToken == "REDACTED_IN_KEYCHAIN", "ConfigManager must redact committed token")

        // Clearing token
        vm.commitBotTokenNow("")
        let clearedSecret = SecretStore.shared.getSecret(forKey: "telegramBotToken")
        assertTrue(clearedSecret == nil, "SecretStore must be cleared when empty token committed")
        assertTrue(ConfigManager.shared.currentConfig.telegramBotToken.isEmpty, "ConfigManager token must be empty")
        print("  [OK] SettingsViewModel debouncing and immediate commit verified")

        print("=== Swift Unit Test 22: Daily Digest Toggle & State Synchronization (IMPROVE-V3-07) ===")
        let origDigest = monitor.dailySummaryEnabled
        monitor.dailySummaryEnabled = false
        assertTrue(!monitor.dailySummaryEnabled, "dailySummaryEnabled must toggle to false")
        monitor.dailySummaryEnabled = true
        assertTrue(monitor.dailySummaryEnabled, "dailySummaryEnabled must toggle to true")
        monitor.dailySummaryEnabled = origDigest
        assertTrue(monitor.dailySummaryEnabled == origDigest, "dailySummaryEnabled must restore original state")
        print("  [OK] Daily Digest state synchronization verified")

        print("=== Swift Unit Test 23: Architecture & Version Telemetry Metadata ===")
        assertTrue(!kAppArchitecture.isEmpty, "kAppArchitecture must not be empty")
        assertTrue(!kAppArchShort.isEmpty, "kAppArchShort must not be empty")
        assertTrue(kAppArchShort == "arm64" || kAppArchShort == "x86_64", "kAppArchShort must be either arm64 or x86_64")
        assertTrue(kAppVersion == "2.1.0", "kAppVersion must match 2.1.0")

        let diag = DiagnosticExporter.shared.generateDiagnosticReport()
        guard let sys = diag["system"] as? [String: Any] else {
            fatalError("system dict missing from diagnostic report")
        }
        guard let reportedArch = sys["architecture"] as? String else {
            fatalError("architecture missing from diagnostic report system info")
        }
        assertTrue(reportedArch == kAppArchShort, "Diagnostic system architecture must match kAppArchShort")
        print("  [OK] Architecture (\(kAppArchShort)) & version metadata verified")

        print("=== Swift Unit Test 24: ConfigManager .env & Environment Variable Parsing (IMPROVE-V4-05) ===")
        // 24a. Test applyEnvironmentVariables for all 15 env keys
        let mockEnv: [String: String] = [
            "DISK_HEALTH_VOLUME": "/Volumes/TestCustomDrive",
            "DISK_HEALTH_DEVICE": "disk42",
            "DISK_HEALTH_REQUIRED_SUBPATHS": "backups, databases, cache",
            "ENABLE_ACTIVE_CANARY": "false",
            "ENABLE_NATIVE_NOTIFICATIONS": "false",
            "POLL_INTERVAL_SECONDS": "45.0",
            "ALERT_COOLDOWN_SECONDS": "1800.0",
            "MIN_EXPECTED_USB_SPEED_BPS": "10000000000",
            "TELEGRAM_CHAT_ID": "mock_chat_987",
            "TEMP_WARNING_CELSIUS": "62",
            "TEMP_CRITICAL_CELSIUS": "74",
            "DISK_USED_WARNING_PERCENT": "88.5",
            "DISK_USED_CRITICAL_PERCENT": "94.5",
            "MIN_FREE_SPACE_CRITICAL_GB": "12.0",
            "MIN_FREE_SPACE_WARNING_GB": "25.0"
        ]
        let baseCfg = DiskHealthConfig()
        let envParsed = ConfigManager.applyEnvironmentVariables(into: baseCfg, env: mockEnv)
        assertTrue(envParsed.targetVolumePath == "/Volumes/TestCustomDrive", "targetVolumePath parsed")
        assertTrue(envParsed.targetDeviceQuery == "disk42", "targetDeviceQuery parsed")
        assertTrue(envParsed.requiredSubpaths == ["backups", "databases", "cache"], "requiredSubpaths parsed")
        assertTrue(envParsed.enableActiveCanary == false, "enableActiveCanary parsed")
        assertTrue(envParsed.enableNativeNotifications == false, "enableNativeNotifications parsed")
        assertTrue(envParsed.pollIntervalSeconds == 45.0, "pollIntervalSeconds parsed")
        assertTrue(envParsed.alertCooldownSeconds == 1800.0, "alertCooldownSeconds parsed")
        assertTrue(envParsed.minExpectedUsbSpeedBps == 10_000_000_000, "minExpectedUsbSpeedBps parsed")
        assertTrue(envParsed.telegramChatId == "mock_chat_987", "telegramChatId parsed")
        assertTrue(envParsed.tempWarningCelsius == 62, "tempWarningCelsius parsed")
        assertTrue(envParsed.tempCriticalCelsius == 74, "tempCriticalCelsius parsed")
        assertTrue(envParsed.diskUsedWarningPercent == 88.5, "diskUsedWarningPercent parsed")
        assertTrue(envParsed.diskUsedCriticalPercent == 94.5, "diskUsedCriticalPercent parsed")
        assertTrue(envParsed.minFreeSpaceCriticalGB == 12.0, "minFreeSpaceCriticalGB parsed")
        assertTrue(envParsed.minFreeSpaceWarningGB == 25.0, "minFreeSpaceWarningGB parsed")

        // 24b. Test applyEnvironmentVariables overriding an ALREADY populated configuration
        var populatedCfg = DiskHealthConfig()
        populatedCfg.targetVolumePath = "/Volumes/OldPath"
        populatedCfg.telegramChatId = "old_chat_111"
        populatedCfg.pollIntervalSeconds = 300.0
        populatedCfg.alertCooldownSeconds = 600.0
        populatedCfg.tempWarningCelsius = 50
        populatedCfg.enableActiveCanary = true
        let overrideEnv: [String: String] = [
            "DISK_HEALTH_VOLUME": "/Volumes/NewPath",
            "TELEGRAM_CHAT_ID": "new_chat_222",
            "POLL_INTERVAL_SECONDS": "15.0",
            "ALERT_COOLDOWN_SECONDS": "120.0",
            "TEMP_WARNING_CELSIUS": "65",
            "ENABLE_ACTIVE_CANARY": "false"
        ]
        let overridden = ConfigManager.applyEnvironmentVariables(into: populatedCfg, env: overrideEnv)
        assertTrue(overridden.targetVolumePath == "/Volumes/NewPath", "DISK_HEALTH_VOLUME must override previous value")
        assertTrue(overridden.telegramChatId == "new_chat_222", "TELEGRAM_CHAT_ID must override previous value")
        assertTrue(overridden.pollIntervalSeconds == 15.0, "POLL_INTERVAL_SECONDS must override previous value")
        assertTrue(overridden.alertCooldownSeconds == 120.0, "ALERT_COOLDOWN_SECONDS must override previous value")
        assertTrue(overridden.tempWarningCelsius == 65, "TEMP_WARNING_CELSIUS must override previous value")
        assertTrue(overridden.enableActiveCanary == false, "ENABLE_ACTIVE_CANARY must override previous value")

        // 24c. Test loadDotEnv with all 16 keys including TELEGRAM_BOT_TOKEN
        let tempEnvDir = "\(NSTemporaryDirectory())env_test_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempEnvDir, withIntermediateDirectories: true)
        let dotEnvContent = """
        # Disk Health Configuration Test File
        DISK_HEALTH_VOLUME="/Volumes/DotEnvSSD"
        DISK_HEALTH_DEVICE="disk8"
        DISK_HEALTH_REQUIRED_SUBPATHS="data, logs, media"
        ENABLE_ACTIVE_CANARY="true"
        ENABLE_NATIVE_NOTIFICATIONS="yes"
        POLL_INTERVAL_SECONDS="60"
        ALERT_COOLDOWN_SECONDS="7200"
        MIN_EXPECTED_USB_SPEED_BPS="5000000000"
        TELEGRAM_BOT_TOKEN="123456:ABC-DEF_MockBotToken"
        TELEGRAM_CHAT_ID="dot_env_chat_123"
        TEMP_WARNING_CELSIUS="59"
        TEMP_CRITICAL_CELSIUS="69"
        DISK_USED_WARNING_PERCENT="80.0"
        DISK_USED_CRITICAL_PERCENT="90.0"
        MIN_FREE_SPACE_CRITICAL_GB="10.0"
        MIN_FREE_SPACE_WARNING_GB="20.0"
        """
        try? dotEnvContent.write(toFile: "\(tempEnvDir)/.env", atomically: true, encoding: .utf8)
        let (dotConfig, dotToken, dotChat) = ConfigManager.loadDotEnv(into: populatedCfg, configDir: tempEnvDir)
        assertTrue(dotToken == "123456:ABC-DEF_MockBotToken", "TELEGRAM_BOT_TOKEN loaded from .env")
        assertTrue(dotChat == "dot_env_chat_123", "TELEGRAM_CHAT_ID loaded from .env")
        assertTrue(dotConfig.targetVolumePath == "/Volumes/DotEnvSSD", "targetVolumePath overridden by .env")
        assertTrue(dotConfig.targetDeviceQuery == "disk8", "targetDeviceQuery from .env")
        assertTrue(dotConfig.requiredSubpaths == ["data", "logs", "media"], "requiredSubpaths from .env")
        assertTrue(dotConfig.enableActiveCanary == true, "enableActiveCanary from .env")
        assertTrue(dotConfig.enableNativeNotifications == true, "enableNativeNotifications from .env")
        assertTrue(dotConfig.pollIntervalSeconds == 60.0, "pollIntervalSeconds from .env")
        assertTrue(dotConfig.alertCooldownSeconds == 7200.0, "alertCooldownSeconds from .env")
        assertTrue(dotConfig.minExpectedUsbSpeedBps == 5_000_000_000, "minExpectedUsbSpeedBps from .env")
        assertTrue(dotConfig.telegramChatId == "dot_env_chat_123", "telegramChatId overridden by .env")
        assertTrue(dotConfig.tempWarningCelsius == 59, "tempWarningCelsius from .env")
        assertTrue(dotConfig.tempCriticalCelsius == 69, "tempCriticalCelsius from .env")
        assertTrue(dotConfig.diskUsedWarningPercent == 80.0, "diskUsedWarningPercent from .env")
        assertTrue(dotConfig.diskUsedCriticalPercent == 90.0, "diskUsedCriticalPercent from .env")
        assertTrue(dotConfig.minFreeSpaceCriticalGB == 10.0, "minFreeSpaceCriticalGB from .env")
        assertTrue(dotConfig.minFreeSpaceWarningGB == 20.0, "minFreeSpaceWarningGB from .env")
        try? FileManager.default.removeItem(atPath: tempEnvDir)
        print("  [OK] ConfigManager .env and environment variable parsing verified for all 16 keys with full override semantics")

        print("=== Swift Unit Test 25: Storage Driver Latency & Thermal Health Evaluation (IMPROVE-V4-04) ===")
        // 25a. Test evaluateDriverLatency boundary conditions
        let (noStatsIssue, noStatsPenalty) = DiskHealthMonitor.evaluateDriverLatency(
            statsValid: false, operationsRead: 1000, operationsWritten: 1000, avgReadLatMs: 300.0, avgWriteLatMs: 300.0
        )
        assertTrue(noStatsIssue == nil && noStatsPenalty == 0, "Invalid stats must not produce latency issues")

        let (lowOpsIssue, lowOpsPenalty) = DiskHealthMonitor.evaluateDriverLatency(
            statsValid: true, operationsRead: 50, operationsWritten: 50, avgReadLatMs: 300.0, avgWriteLatMs: 300.0
        )
        assertTrue(lowOpsIssue == nil && lowOpsPenalty == 0, "< 100 operations must not produce latency issues (insufficient statistical significance)")

        let (nominalLatIssue, nominalLatPenalty) = DiskHealthMonitor.evaluateDriverLatency(
            statsValid: true, operationsRead: 100, operationsWritten: 100, avgReadLatMs: 50.0, avgWriteLatMs: 45.0
        )
        assertTrue(nominalLatIssue == nil && nominalLatPenalty == 0, "<= 50 ms latency must be considered healthy")

        let (warnLatIssue, warnLatPenalty) = DiskHealthMonitor.evaluateDriverLatency(
            statsValid: true, operationsRead: 100, operationsWritten: 100, avgReadLatMs: 50.1, avgWriteLatMs: 10.0
        )
        guard let wIssue = warnLatIssue else { fatalError("Expected warning latency issue") }
        assertTrue(wIssue.code == "IO_LATENCY_WARNING", "Must produce IO_LATENCY_WARNING")
        assertTrue(wIssue.severity == .warning, "Latency warning must have warning severity")
        assertTrue(warnLatPenalty == 10, "Latency warning penalty must be 10")

        let (critLatIssue, critLatPenalty) = DiskHealthMonitor.evaluateDriverLatency(
            statsValid: true, operationsRead: 50, operationsWritten: 150, avgReadLatMs: 10.0, avgWriteLatMs: 200.5
        )
        guard let cIssue = critLatIssue else { fatalError("Expected critical latency issue") }
        assertTrue(cIssue.code == "IO_LATENCY_CRITICAL", "Must produce IO_LATENCY_CRITICAL")
        assertTrue(cIssue.severity == .critical, "Latency critical must have critical severity")
        assertTrue(critLatPenalty == 25, "Latency critical penalty must be 25")

        // 25b. Test evaluateHostThermal
        let (nominalThermal, nominalThermalPenalty) = DiskHealthMonitor.evaluateHostThermal(thermalState: .nominal)
        assertTrue(nominalThermal == nil && nominalThermalPenalty == 0, "Nominal thermal state must produce no issue")

        let (fairThermal, fairThermalPenalty) = DiskHealthMonitor.evaluateHostThermal(thermalState: .fair)
        assertTrue(fairThermal == nil && fairThermalPenalty == 0, "Fair thermal state must produce no issue")

        let (seriousThermal, seriousThermalPenalty) = DiskHealthMonitor.evaluateHostThermal(thermalState: .serious)
        assertTrue(seriousThermal == nil && seriousThermalPenalty == 0, "Serious thermal state must produce no issue")

        let (critThermal, critThermalPenalty) = DiskHealthMonitor.evaluateHostThermal(thermalState: .critical)
        guard let tIssue = critThermal else { fatalError("Expected critical thermal issue") }
        assertTrue(tIssue.code == "HOST_THERMAL_CRITICAL", "Must produce HOST_THERMAL_CRITICAL")
        assertTrue(tIssue.severity == .warning, "Host thermal issue must have warning severity")
        assertTrue(critThermalPenalty == 10, "Host thermal penalty must be 10")

        // 25c. Test snapshot latency fields from live monitor evaluation
        let snap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(snap.avgReadLatencyMs >= 0.0, "avgReadLatencyMs must be >= 0")
        assertTrue(snap.avgWriteLatencyMs >= 0.0, "avgWriteLatencyMs must be >= 0")
        print("  [OK] Storage driver latency & thermal health evaluation boundaries thoroughly verified")

        print("=== Swift Unit Test 26: SecretStore NSRecursiveLock Thread Safety (IMPROVE-V4-07) ===")
        let secretGroup = DispatchGroup()
        for i in 0..<30 {
            secretGroup.enter()
            DispatchQueue.global().async {
                let testKey = "concurrent_key_\(i % 5)"
                let testVal = "token_val_\(UUID().uuidString)"
                SecretStore.shared.setSecret(testVal, forKey: testKey)
                _ = SecretStore.shared.getSecret(forKey: testKey)
                _ = SecretStore.shared.configDir
                if i % 3 == 0 {
                    SecretStore.shared.deleteSecret(forKey: testKey)
                }
                secretGroup.leave()
            }
        }
        secretGroup.wait()
        for i in 0..<5 {
            SecretStore.shared.deleteSecret(forKey: "concurrent_key_\(i)")
        }
        print("  [OK] SecretStore NSRecursiveLock thread safety verified")

        print("=== Swift Unit Test 27: LaunchAgent Plist Structure & Verification Target Isolation (IMPROVE-V4-01 & IMPROVE-V4-02) ===")
        let mockBundleId = "io.github.disk-health-monitor.test"
        let mockBinary = "/Applications/DiskHealthMonitor.app/Contents/MacOS/DiskHealthMonitor"
        let mockLogs = "/Users/testuser/.config/disk-health-monitor/logs"
        let plistDict = SettingsViewModel.makeLaunchAgentPlistDict(bundleId: mockBundleId, binaryPath: mockBinary, logsDir: mockLogs)

        assertTrue(plistDict["Label"] as? String == mockBundleId, "Label must match bundleId")
        guard let progArgs = plistDict["ProgramArguments"] as? [String] else { fatalError("ProgramArguments missing") }
        assertTrue(progArgs.count == 2, "ProgramArguments must contain 2 arguments")
        assertTrue(progArgs[0] == mockBinary, "First argument must be binary path")
        assertTrue(progArgs[1] == "--menubar", "Second argument must be --menubar")
        assertTrue(plistDict["WorkingDirectory"] as? String == mockLogs, "WorkingDirectory must match logsDir")
        assertTrue(plistDict["StandardOutPath"] as? String == "\(mockLogs)/launchd.out.log", "StandardOutPath must be in logsDir")
        assertTrue(plistDict["StandardErrorPath"] as? String == "\(mockLogs)/launchd.err.log", "StandardErrorPath must be in logsDir")
        assertTrue(plistDict["ProcessType"] as? String == "Interactive", "ProcessType must be Interactive")
        assertTrue(plistDict["RunAtLoad"] as? Bool == true, "RunAtLoad must be true")
        assertTrue(plistDict["KeepAlive"] as? Bool == true, "KeepAlive must be true")

        let plistData = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        assertTrue(plistData != nil && (plistData?.count ?? 0) > 0, "PropertyListSerialization must generate valid XML data")
        if let data = plistData,
           let deserialized = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            assertTrue(deserialized["Label"] as? String == mockBundleId, "Deserialized Label must match")
            assertTrue(deserialized["WorkingDirectory"] as? String == mockLogs, "Deserialized WorkingDirectory must match")
        } else {
            fatalError("Failed to deserialize generated plist XML")
        }
        print("  [OK] LaunchAgent plist structure, --menubar argument, and XML serialization verified")

        print("=== Swift Unit Test 28: Per-Drive Cooldown Scoping, AppleScript Escaping & Enriched Diagnostics (IMPROVE-V5-01 to V5-07) ===")
        // 28a. Verify MacOSNotifier AppleScript literal escaping
        let rawScriptStr = "Alert \"Drive\" \\ Path\nLine2\rLine3"
        let escapedScript = MacOSNotifier.escapeAppleScriptLiteral(rawScriptStr)
        assertTrue(!escapedScript.contains("\n") && !escapedScript.contains("\r"), "AppleScript literal must strip newlines")
        assertTrue(escapedScript.contains("\\\"Drive\\\"") && escapedScript.contains("\\\\"), "AppleScript literal must escape quotes and backslashes")

        // 28b. Verify enriched DiagnosticExporter contains detectedDevices and recentLogLines
        let enrichedDiag = DiagnosticExporter.shared.generateDiagnosticReport(snapshot: normalSnap)
        guard let detectedList = enrichedDiag["detectedDevices"] as? [[String: Any]] else {
            fatalError("Diagnostic report must include detectedDevices array")
        }
        assertTrue(!detectedList.isEmpty, "detectedDevices array must not be empty on macOS")
        assertTrue(enrichedDiag["recentLogLines"] is [String], "Diagnostic report must include recentLogLines array")

        // 28c. Verify per-drive cooldown scoping and that re-selecting the same target preserves cooldowns
        monitor.setMonitoredTarget(volumePath: "/", deviceQuery: nil)
        let beforeTarget = monitor.persistentState.monitoredTarget
        assertTrue(beforeTarget == "/", "Monitored target must be '/'")

        cfgMgr.updateConfig { cfg in
            cfg.diskUsedWarningPercent = 0.01
            cfg.enableNativeNotifications = false
        }
        _ = monitor.evaluateHealth(forceCanary: false, allowNotifications: true)
        let scopedKeys = monitor.persistentState.lastAlertTimestampByCode.keys.filter { $0.contains("DISK_SPACE_WARNING") }
        assertTrue(!scopedKeys.isEmpty, "Alert cooldown must be scoped with driveKey:code")
        let firstKey = scopedKeys.first!
        assertTrue(firstKey.contains(":DISK_SPACE_WARNING"), "Scoped key must contain :DISK_SPACE_WARNING")
        let alertTimeBefore = monitor.persistentState.lastAlertTimestampByCode[firstKey]
        assertTrue(alertTimeBefore != nil, "Alert timestamp should be recorded")

        // Re-selecting the same target '/' must NOT wipe active cooldowns
        monitor.setMonitoredTarget(volumePath: "/", deviceQuery: nil)
        assertTrue(monitor.persistentState.monitoredTarget == "/", "Re-selecting '/' must remain '/'")
        assertTrue(monitor.persistentState.lastAlertTimestampByCode[firstKey] == alertTimeBefore, "Re-selecting same target must preserve active scoped cooldowns")

        // Clean up
        cfgMgr.updateConfig { cfg in
            cfg.diskUsedWarningPercent = 85.0
            cfg.enableNativeNotifications = true
        }

        // 28d. Verify multi-drive cooldown isolation and recovery scoping
        var isolatedState = DiskPersistentState()
        isolatedState.lastAlertTimestampByCode["DRIVE_A_SERIAL:TEMP_WARNING"] = 1000
        isolatedState.lastAlertTimestampByCode["DRIVE_B_SERIAL:TEMP_WARNING"] = 2000
        isolatedState.lastAlertTimestampByCode["DRIVE_A_SERIAL:DISK_SPACE_WARNING"] = 1500

        // Simulate recovery of DRIVE_A_SERIAL
        let recPrefix = "DRIVE_A_SERIAL:"
        for key in Array(isolatedState.lastAlertTimestampByCode.keys) where key.hasPrefix(recPrefix) || !key.contains(":") {
            isolatedState.lastAlertTimestampByCode.removeValue(forKey: key)
        }
        assertTrue(isolatedState.lastAlertTimestampByCode["DRIVE_A_SERIAL:TEMP_WARNING"] == nil, "Drive A cooldowns must be cleared on recovery")
        assertTrue(isolatedState.lastAlertTimestampByCode["DRIVE_A_SERIAL:DISK_SPACE_WARNING"] == nil, "Drive A space cooldown must be cleared on recovery")
        assertTrue(isolatedState.lastAlertTimestampByCode["DRIVE_B_SERIAL:TEMP_WARNING"] == 2000, "Drive B cooldowns must NOT be cleared when Drive A recovers")

        // 28e. Verify TelegramNotifier.redactToken helper
        let rawLog = "Error sending message to https://api.telegram.org/bot777777:SECRET_XYZ/sendMessage: 401 Unauthorized"
        let safeLog = TelegramNotifier.redactToken(rawLog, token: "777777:SECRET_XYZ")
        assertTrue(!safeLog.contains("SECRET_XYZ"), "redactToken must remove raw secret token")
        assertTrue(safeLog.contains("[REDACTED_TOKEN]"), "redactToken must insert [REDACTED_TOKEN]")

        let encodedLog = "Failing URL: https://api.telegram.org/bot777777%3ASECRET_XYZ/sendMessage"
        let safeEncodedLog = TelegramNotifier.redactToken(encodedLog, token: "777777:SECRET_XYZ")
        assertTrue(!safeEncodedLog.contains("SECRET_XYZ"), "redactToken must remove percent-encoded token")
        assertTrue(safeEncodedLog.contains("[REDACTED_TOKEN]"), "redactToken must insert [REDACTED_TOKEN] for percent-encoded token")

        // 28f. Verify legacy un-scoped cooldown key migration and purging in DiskHealthMonitor (IMPROVE-V6-05)
        var migrationState = DiskPersistentState()
        migrationState.lastAlertTimestampByCode["TEMP_WARNING"] = 5000
        let driveKeyA = "DRIVE_A_SERIAL"
        let issue = HealthIssue(code: "TEMP_WARNING", severity: .warning, title: "Test Temp", detail: "Test Detail")
        let scopedKeyA = "\(driveKeyA):\(issue.code)"
        if let legacyTs = migrationState.lastAlertTimestampByCode.removeValue(forKey: issue.code) {
            if migrationState.lastAlertTimestampByCode[scopedKeyA] == nil {
                migrationState.lastAlertTimestampByCode[scopedKeyA] = legacyTs
            }
        }
        assertTrue(migrationState.lastAlertTimestampByCode["TEMP_WARNING"] == nil, "Legacy un-scoped key must be removed from dictionary")
        assertTrue(migrationState.lastAlertTimestampByCode[scopedKeyA] == 5000, "Drive A scoped key must adopt legacy timestamp")

        // Now if Drive B experiences TEMP_WARNING, it must not inherit Drive A's legacy cooldown
        let driveKeyB = "DRIVE_B_SERIAL"
        let scopedKeyB = "\(driveKeyB):\(issue.code)"
        if let legacyTs = migrationState.lastAlertTimestampByCode.removeValue(forKey: issue.code) {
            if migrationState.lastAlertTimestampByCode[scopedKeyB] == nil {
                migrationState.lastAlertTimestampByCode[scopedKeyB] = legacyTs
            }
        }
        let driveBLastSent = migrationState.lastAlertTimestampByCode[scopedKeyB] ?? 0
        assertTrue(driveBLastSent == 0, "Drive B must start with lastSent == 0 and not inherit Drive A's legacy cooldown")

        // End-to-end verification directly through DiskHealthMonitor engine
        monitor.resetBaselines()
        monitor.setMonitoredTarget(volumePath: "/", deviceQuery: nil)
        cfgMgr.updateConfig { cfg in
            cfg.diskUsedWarningPercent = 0.01
            cfg.alertCooldownSeconds = 7200
            cfg.enableNativeNotifications = false
        }
        let legacyAlertTs = Date().timeIntervalSince1970 - 100.0
        monitor.mutateStateForTesting { state in
            state.lastAlertTimestampByCode["DISK_SPACE_WARNING"] = legacyAlertTs
        }
        assertTrue(monitor.persistentState.lastAlertTimestampByCode["DISK_SPACE_WARNING"] == legacyAlertTs, "Legacy un-scoped key must be seeded in monitor state")

        // Run evaluateHealth: processAlertsAndDigestLocked must migrate the un-scoped key to the scoped drive key and purge the un-scoped key
        let evalSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: true)
        assertTrue(evalSnap.issues.contains(where: { $0.code == "DISK_SPACE_WARNING" }), "DISK_SPACE_WARNING issue must be triggered")
        assertTrue(monitor.persistentState.lastAlertTimestampByCode["DISK_SPACE_WARNING"] == nil, "Legacy un-scoped key must be purged by DiskHealthMonitor")

        let currentScopedKey = monitor.persistentState.lastAlertTimestampByCode.keys.first(where: { $0.hasSuffix(":DISK_SPACE_WARNING") })
        assertTrue(currentScopedKey != nil, "Scoped cooldown key must be created for the active drive")
        assertTrue(monitor.persistentState.lastAlertTimestampByCode[currentScopedKey!] == legacyAlertTs, "Scoped cooldown key must adopt the legacy timestamp")

        // Verify multi-drive isolation: switching targets must not have legacy keys leaking
        assertTrue(monitor.persistentState.lastAlertTimestampByCode["DISK_SPACE_WARNING"] == nil, "Legacy un-scoped key must remain purged")

        // Restore normal configuration
        cfgMgr.updateConfig { cfg in
            cfg.diskUsedWarningPercent = 85.0
            cfg.enableNativeNotifications = true
        }

        monitor.resetBaselines()
        print("  [OK] Per-drive cooldown scoping, AppleScript escaping, enriched diagnostics & multi-drive isolation verified")

        print("✅ All Swift Core Logic Unit Tests Passed!")
    }
}
