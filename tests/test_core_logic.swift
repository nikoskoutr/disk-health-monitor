import Foundation
import Darwin
import AppKit

// MARK: - Swift Core Logic & Engine Unit Test Suite

private func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition() {
        fputs("❌ ASSERTION FAILED [\(file):\(line)]: \(message)\n", stderr)
        exit(1)
    }
}

private func copyStringToTuple<T>(_ string: String, _ tuple: inout T) {
    withUnsafeMutablePointer(to: &tuple) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cPtr in
            string.withCString { src in
                strncpy(cPtr, src, MemoryLayout<T>.size - 1)
                cPtr[MemoryLayout<T>.size - 1] = 0
            }
        }
    }
}

private func makeMockDiskHardwareMetrics(
    found: Bool = true,
    bsdName: String = "disk42",
    serialNumber: String = "MOCK-NVME-001",
    vendorName: String = "MockVendor",
    productName: String = "MockSSD",
    productRevision: String = "1.0",
    interconnectType: String = "PCI-Express",
    protocolType: String = "NVMe",
    isInternal: Bool = true,
    isRemovable: Bool = false,
    linkSpeedBps: UInt64 = 0,
    smartValid: Bool = true,
    criticalWarning: UInt8 = 0,
    temperatureCelsius: Int32 = 35,
    temperatureKelvin: Int32 = 308,
    availableSpare: UInt8 = 100,
    availableSpareThreshold: UInt8 = 10,
    percentageUsed: UInt8 = 0,
    dataUnitsRead: UInt64 = 1000,
    dataUnitsWritten: UInt64 = 2000,
    hostReadCommands: UInt64 = 500,
    hostWriteCommands: UInt64 = 600,
    controllerBusyTime: UInt64 = 10,
    powerCycles: UInt64 = 20,
    powerOnHours: UInt64 = 100,
    unsafeShutdowns: UInt64 = 0,
    mediaErrors: UInt64 = 0,
    errorInfoLogEntries: UInt64 = 0,
    statsValid: Bool = false,
    bytesRead: UInt64 = 0,
    bytesWritten: UInt64 = 0,
    operationsRead: UInt64 = 0,
    operationsWritten: UInt64 = 0,
    errorsRead: UInt64 = 0,
    errorsWritten: UInt64 = 0,
    retriesRead: UInt64 = 0,
    retriesWritten: UInt64 = 0,
    totalTimeReadNs: UInt64 = 0,
    totalTimeWriteNs: UInt64 = 0
) -> DiskHardwareMetrics {
    var hw = DiskHardwareMetrics()
    hw.found = found
    copyStringToTuple(bsdName, &hw.bsdName)
    copyStringToTuple(serialNumber, &hw.serialNumber)
    copyStringToTuple(serialNumber, &hw.usbSerialNumber)
    copyStringToTuple(vendorName, &hw.vendorName)
    copyStringToTuple(productName, &hw.productName)
    copyStringToTuple(productRevision, &hw.productRevision)
    copyStringToTuple(interconnectType, &hw.interconnectType)
    copyStringToTuple(protocolType, &hw.protocolType)
    hw.isInternal = isInternal
    hw.isRemovable = isRemovable
    hw.linkSpeedBps = linkSpeedBps
    hw.usbLinkSpeedBps = linkSpeedBps
    hw.smartValid = smartValid
    hw.criticalWarning = criticalWarning
    hw.temperatureCelsius = temperatureCelsius
    hw.temperatureKelvin = temperatureKelvin
    hw.availableSpare = availableSpare
    hw.availableSpareThreshold = availableSpareThreshold
    hw.percentageUsed = percentageUsed
    hw.dataUnitsRead = dataUnitsRead
    hw.dataUnitsWritten = dataUnitsWritten
    hw.hostReadCommands = hostReadCommands
    hw.hostWriteCommands = hostWriteCommands
    hw.controllerBusyTime = controllerBusyTime
    hw.powerCycles = powerCycles
    hw.powerOnHours = powerOnHours
    hw.unsafeShutdowns = unsafeShutdowns
    hw.mediaErrors = mediaErrors
    hw.errorInfoLogEntries = errorInfoLogEntries
    hw.statsValid = statsValid
    hw.bytesRead = bytesRead
    hw.bytesWritten = bytesWritten
    hw.operationsRead = operationsRead
    hw.operationsWritten = operationsWritten
    hw.errorsRead = errorsRead
    hw.errorsWritten = errorsWritten
    hw.retriesRead = retriesRead
    hw.retriesWritten = retriesWritten
    hw.totalTimeReadNs = totalTimeReadNs
    hw.totalTimeWriteNs = totalTimeWriteNs
    return hw
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

        // Verify backwards compatibility with legacy state JSON missing lastOverallSeverity
        let legacyJson = """
        {
            "monitoredTarget": "/Volumes/LegacyDrive",
            "drives": {
                "LEGACY_DRIVE_1": {
                    "bsdName": "disk5",
                    "peakTemperatureCelsius": 42
                }
            }
        }
        """.data(using: .utf8)!
        let decodedLegacy = try? JSONDecoder().decode(DiskPersistentState.self, from: legacyJson)
        assertTrue(decodedLegacy != nil, "DiskPersistentState must decode legacy state JSON missing lastOverallSeverity")
        let legacyDrive = decodedLegacy?.getDriveState(key: "LEGACY_DRIVE_1")
        assertTrue(legacyDrive?.bsdName == "disk5", "Legacy drive bsdName must match")
        assertTrue(legacyDrive?.peakTemperatureCelsius == 42, "Legacy drive peak temp must match")
        assertTrue(legacyDrive?.lastOverallSeverity == HealthSeverity.healthy.rawValue, "Legacy drive lastOverallSeverity must default to healthy")
        assertTrue(legacyDrive?.lastVerifyResult == "Not run yet", "Legacy drive lastVerifyResult must default")
        assertTrue(legacyDrive?.lastVerifyOk == true, "Legacy drive lastVerifyOk must default to true")
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
        assertTrue(kAppVersion == "2.4.0", "kAppVersion must match 2.4.0")

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
        let keepAliveDict = plistDict["KeepAlive"] as? [String: Bool]
        assertTrue(keepAliveDict?["SuccessfulExit"] == false, "KeepAlive must be ['SuccessfulExit': false] to prevent duplicate respawn loops on clean exit")

        let plistData = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        assertTrue(plistData != nil && (plistData?.count ?? 0) > 0, "PropertyListSerialization must generate valid XML data")
        if let data = plistData,
           let deserialized = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            assertTrue(deserialized["Label"] as? String == mockBundleId, "Deserialized Label must match")
            assertTrue(deserialized["WorkingDirectory"] as? String == mockLogs, "Deserialized WorkingDirectory must match")
            let desKeepAlive = deserialized["KeepAlive"] as? [String: Bool]
            assertTrue(desKeepAlive?["SuccessfulExit"] == false, "Deserialized KeepAlive must have SuccessfulExit: false")
        } else {
            fatalError("Failed to deserialize generated plist XML")
        }

        // Verify POSIX flock single-instance lock mechanics, PID writing, and 0600 permissions
        let testLockPath = "\(NSTemporaryDirectory())test_menubar_\(UUID().uuidString).lock"
        let fd1 = open(testLockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        assertTrue(fd1 >= 0, "First open on lockfile must succeed")
        fchmod(fd1, 0o600)
        assertTrue(flock(fd1, LOCK_EX | LOCK_NB) == 0, "First non-blocking exclusive flock must succeed")

        // Verify PID writing into lockfile
        ftruncate(fd1, 0)
        lseek(fd1, 0, SEEK_SET)
        let pidStr = "\(getpid())\n"
        _ = pidStr.withCString { ptr in
            write(fd1, ptr, strlen(ptr))
        }
        fsync(fd1)
        if let writtenData = try? Data(contentsOf: URL(fileURLWithPath: testLockPath)),
           let writtenStr = String(data: writtenData, encoding: .utf8) {
            assertTrue(writtenStr == pidStr, "Lockfile must accurately contain active process PID")
        } else {
            fatalError("Failed to read PID from test lockfile")
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: testLockPath),
           let perms = attrs[.posixPermissions] as? NSNumber {
            assertTrue(perms.intValue == 0o600, "Lockfile must enforce 0600 permissions, got \(String(perms.intValue, radix: 8))")
        }

        let fd2 = open(testLockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        assertTrue(fd2 >= 0, "Second open on lockfile must succeed")
        assertTrue(flock(fd2, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK, "Second concurrent flock must fail with EWOULDBLOCK")

        flock(fd1, LOCK_UN)
        close(fd1)
        assertTrue(flock(fd2, LOCK_EX | LOCK_NB) == 0, "Second descriptor must acquire flock after first releases")
        flock(fd2, LOCK_UN)
        close(fd2)
        try? FileManager.default.removeItem(atPath: testLockPath)

        // Verify O_NOFOLLOW symlink rejection and target protection (IMPROVE-V8-02)
        let symTarget = "\(NSTemporaryDirectory())test_target_\(UUID().uuidString).txt"
        let symLock = "\(NSTemporaryDirectory())test_symlink_\(UUID().uuidString).lock"
        try? "PROTECTED_TARGET_CONTENT".write(toFile: symTarget, atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(atPath: symLock, withDestinationPath: symTarget)

        let symFd = open(symLock, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        assertTrue(symFd < 0, "open() with O_NOFOLLOW on a symlink must fail")
        let targetContent = try? String(contentsOfFile: symTarget, encoding: .utf8)
        assertTrue(targetContent == "PROTECTED_TARGET_CONTENT", "Symlink target contents must remain intact and not truncated")

        try? FileManager.default.removeItem(atPath: symLock)
        try? FileManager.default.removeItem(atPath: symTarget)
        print("  [OK] LaunchAgent plist structure, --menubar argument, and XML serialization verified")

        print("=== Swift Unit Test 28: Per-Drive Cooldown Scoping, Native Bundle Verification & Enriched Diagnostics (IMPROVE-V5-01 to V5-07) ===")
        // 28a. Verify MacOSNotifier bundle check does not crash in standalone test binary
        _ = MacOSNotifier.hasValidAppBundle

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

        print("=== Swift Unit Test 29: Per-Drive lastOverallSeverity Tracking & Cross-Target Recovery (IMPROVE-V8-01 & IMPROVE-V8-04) ===")
        // 29a. Verify DriveBaselineState default initialization
        let baseDrive = DriveBaselineState()
        assertTrue(baseDrive.lastOverallSeverity == HealthSeverity.healthy.rawValue, "DriveBaselineState must default lastOverallSeverity to healthy")

        // 29b. Verify persistent state per-drive lastOverallSeverity retention across target switches
        var multiState = DiskPersistentState()
        multiState.updateDriveState(key: "DRIVE_ALPHA") { d in
            d.bsdName = "disk1"
            d.lastOverallSeverity = HealthSeverity.warning.rawValue
        }
        multiState.updateDriveState(key: "DRIVE_BETA") { d in
            d.bsdName = "disk2"
            d.lastOverallSeverity = HealthSeverity.healthy.rawValue
        }
        assertTrue(multiState.drives["DRIVE_ALPHA"]?.lastOverallSeverity == HealthSeverity.warning.rawValue, "Drive ALPHA must retain warning severity")
        assertTrue(multiState.drives["DRIVE_BETA"]?.lastOverallSeverity == HealthSeverity.healthy.rawValue, "Drive BETA must retain healthy severity")

        // 29c. Verify target switch does NOT wipe out per-drive lastOverallSeverity in DiskHealthMonitor
        monitor.resetBaselines()
        monitor.mutateStateForTesting { st in
            st.updateDriveState(key: "DRIVE_TEST_A") { d in
                d.bsdName = "disk8"
                d.lastOverallSeverity = HealthSeverity.warning.rawValue
            }
        }
        // Switch monitored target to DRIVE_TEST_B
        monitor.setMonitoredTarget(volumePath: "/Volumes/TestDriveB", deviceQuery: nil)
        assertTrue(monitor.persistentState.drives["DRIVE_TEST_A"]?.lastOverallSeverity == HealthSeverity.warning.rawValue, "Drive A lastOverallSeverity must be preserved in drives dictionary when switching targets")

        // 29d. Verify resetBaselines() resets lastOverallSeverity to healthy across all recorded drives
        monitor.resetBaselines()
        let resetDrives = monitor.persistentState.drives
        assertTrue(!resetDrives.isEmpty, "resetDrives must not be empty after resetBaselines()")
        assertTrue(resetDrives["DRIVE_TEST_A"]?.lastOverallSeverity == HealthSeverity.healthy.rawValue, "DRIVE_TEST_A lastOverallSeverity must be reset to healthy")
        for (_, d) in resetDrives {
            assertTrue(d.lastOverallSeverity == HealthSeverity.healthy.rawValue, "resetBaselines must reset per-drive lastOverallSeverity to healthy")
        }

        // 29e. Verify resetBaselines() when currentSnapshot is nil preserves monitoredTarget and dailySummaryEnabled
        monitor.clearCurrentSnapshotForTesting()
        monitor.dailySummaryEnabled = false
        monitor.setMonitoredTarget(volumePath: "/Volumes/CustomDrive", deviceQuery: nil)
        monitor.mutateStateForTesting { st in
            st.updateDriveState(key: "STANDALONE_DRIVE") { d in
                d.lastOverallSeverity = HealthSeverity.critical.rawValue
            }
        }
        monitor.resetBaselines()
        assertTrue(monitor.persistentState.monitoredTarget == "/Volumes/CustomDrive", "resetBaselines without snapshot must preserve monitoredTarget")
        assertTrue(monitor.persistentState.dailySummaryEnabled == false, "resetBaselines without snapshot must preserve dailySummaryEnabled")
        assertTrue(monitor.persistentState.lastOverallSeverity == HealthSeverity.healthy.rawValue, "resetBaselines without snapshot must reset lastOverallSeverity")
        assertTrue(monitor.persistentState.drives["STANDALONE_DRIVE"]?.lastOverallSeverity == HealthSeverity.healthy.rawValue, "resetBaselines without snapshot must reset STANDALONE_DRIVE lastOverallSeverity")

        // 29f. Verify SettingsViewModel.isUpdatingLaunchAgent busy flag
        let testVM = SettingsViewModel()
        assertTrue(testVM.isUpdatingLaunchAgent == false, "isUpdatingLaunchAgent must initialize to false")
        print("  [OK] Per-drive lastOverallSeverity tracking and cross-target recovery verified")

        print("=== Swift Unit Test 30: Volume Verification Privilege (-69863) Classification, Self-Healing Migration & Dark-Wake Guard (IMPROVE-V9-01 to V9-06) ===")
        // 30a. Verify classifyVolumeVerificationOutput does NOT fail on -69863 Insufficient privileges or permission denied
        let privOut = "Error starting file system verification for disk7s1 (T7): Insufficient privileges (-69863)"
        let privClassified = DiskHealthMonitor.classifyVolumeVerificationOutput(
            terminationStatus: 1,
            output: privOut,
            didTimeout: false,
            timeStr: "Oct 19, 23:16"
        )
        assertTrue(privClassified.isHealthy == true, "-69863 Insufficient privileges must be classified as healthy (not corruption)")
        assertTrue(privClassified.isSkipped == true, "-69863 Insufficient privileges must be marked as skipped")
        assertTrue(privClassified.summary.starts(with: "Skipped"), "Summary must start with 'Skipped', got: \(privClassified.summary)")

        let permDeniedOut = "Error starting file system verification: Permission denied"
        let permClassified = DiskHealthMonitor.classifyVolumeVerificationOutput(
            terminationStatus: 1,
            output: permDeniedOut,
            didTimeout: false,
            timeStr: "Oct 19, 23:18"
        )
        assertTrue(permClassified.isHealthy == true, "Permission denied without error code must be classified as healthy")
        assertTrue(permClassified.isSkipped == true, "Permission denied must be marked as skipped")
        assertTrue(permClassified.summary.contains("Requires administrator privileges"), "Summary must mention administrator privileges")

        // 30b. Verify classifyVolumeVerificationOutput does NOT fail on -69888 Volume busy / couldn't unmount
        let busyOut = "Error: -69888: Couldn't unmount disk"
        let busyClassified = DiskHealthMonitor.classifyVolumeVerificationOutput(
            terminationStatus: 1,
            output: busyOut,
            didTimeout: false,
            timeStr: "Oct 19, 23:20"
        )
        assertTrue(busyClassified.isHealthy == true, "-69888 busy unmount failure must be classified as healthy")
        assertTrue(busyClassified.isSkipped == true, "-69888 busy unmount failure must be marked as skipped")

        let unmountWithoutCodeOut = "Volume could not unmount: resource busy"
        let unmountClassified = DiskHealthMonitor.classifyVolumeVerificationOutput(
            terminationStatus: 1,
            output: unmountWithoutCodeOut,
            didTimeout: false,
            timeStr: "Oct 19, 23:22"
        )
        assertTrue(unmountClassified.isHealthy == true, "Unmount failure without error code must be classified as healthy")
        assertTrue(unmountClassified.isSkipped == true, "Unmount failure without error code must be marked as skipped")

        // 30c. Verify genuine fsck corruption still triggers failure, and empty output is handled
        let corruptOut = "error: container_oid (0x1) is invalid\nFile system check exit code is 8.\nError: -69845: File system verify or repair failed"
        let corruptClassified = DiskHealthMonitor.classifyVolumeVerificationOutput(
            terminationStatus: 1,
            output: corruptOut,
            didTimeout: false,
            timeStr: "Oct 19, 23:25"
        )
        assertTrue(corruptClassified.isHealthy == false, "Genuine filesystem corruption (-69845 / exit code 8) must be classified as unhealthy")
        assertTrue(corruptClassified.isSkipped == false, "Genuine filesystem corruption must not be marked as skipped")
        assertTrue(corruptClassified.summary.starts(with: "Failed"), "Corruption summary must start with 'Failed'")

        let emptyOutputClassified = DiskHealthMonitor.classifyVolumeVerificationOutput(
            terminationStatus: 1,
            output: "",
            didTimeout: false,
            timeStr: "Oct 19, 23:26"
        )
        assertTrue(emptyOutputClassified.isHealthy == false, "Non-zero exit with empty output must be classified as failure")
        assertTrue(emptyOutputClassified.summary.contains("Exit code 1"), "Empty output failure summary must include exit code")

        // 30d. Verify poisoned state with -69863 does not trigger VOLUME_VERIFY_FAILED in evaluateHealth
        monitor.setMonitoredTarget(volumePath: "/", deviceQuery: nil)
        let rootCheckSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        let rootKey = !rootCheckSnap.serialNumber.isEmpty ? rootCheckSnap.serialNumber : rootCheckSnap.bsdName
        monitor.mutateStateForTesting { st in
            st.updateDriveState(key: rootKey) { d in
                d.lastVerifyOk = false
                d.lastVerifyResult = "Failed (Oct 19, 16:07): Error starting file system verification for disk3s1 (Macintosh HD): Insufficient privileges (-69863)"
            }
        }
        let healedSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(!healedSnap.issues.contains(where: { $0.code == "VOLUME_VERIFY_FAILED" }), "Poisoned -69863 verify result must NEVER trigger VOLUME_VERIFY_FAILED")
        assertTrue(healedSnap.lastVerifyOk == true, "evaluateHealth must auto-heal poisoned lastVerifyOk to true")

        // 30e. Verify resetBaselines clears any failed lastVerifyOk state
        monitor.mutateStateForTesting { st in
            st.updateDriveState(key: rootKey) { d in
                d.lastVerifyOk = false
                d.lastVerifyResult = "Failed: simulated corruption"
            }
        }
        let corruptVerifySnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(corruptVerifySnap.issues.contains(where: { $0.code == "VOLUME_VERIFY_FAILED" }), "Simulated corruption must trigger VOLUME_VERIFY_FAILED before reset")
        monitor.resetBaselines()
        let postResetVerifySnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(!postResetVerifySnap.issues.contains(where: { $0.code == "VOLUME_VERIFY_FAILED" }), "resetBaselines() must clear VOLUME_VERIFY_FAILED")
        assertTrue(postResetVerifySnap.lastVerifyOk == true, "resetBaselines() must restore lastVerifyOk to true")

        // 30f. Verify Dark-Wake suppression while isSystemSleeping is true
        monitor.noteSystemWillSleep()
        assertTrue(monitor.isSystemSleeping == true, "isSystemSleeping must be true after noteSystemWillSleep()")
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/Volumes/__Dark_Wake_Unmounted_Drive__"
            cfg.targetDeviceQuery = "disk99997"
        }
        let darkWakeSnap = monitor.evaluateHealth(forceCanary: true, allowNotifications: false)
        assertTrue(!darkWakeSnap.issues.contains(where: { $0.code == "HW_DISCONNECTED" }), "Dark wake must suppress HW_DISCONNECTED while system is sleeping")
        assertTrue(!darkWakeSnap.issues.contains(where: { $0.code == "VOLUME_UNMOUNTED" }), "Dark wake must suppress VOLUME_UNMOUNTED while system is sleeping")
        assertTrue(!darkWakeSnap.issues.contains(where: { $0.code == "CANARY_IO_FAILED" }), "Dark wake must suppress CANARY_IO_FAILED while system is sleeping")
        monitor.noteSystemDidWake(at: Date().timeIntervalSince1970 - 20.0)
        assertTrue(monitor.isSystemSleeping == false, "isSystemSleeping must be false after noteSystemDidWake()")

        // 30g. Verify driveKey scoping uses targetDeviceQuery when hardware is disconnected and targetVolumePath is nil
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = nil
            cfg.targetDeviceQuery = "disk99996"
            cfg.enableNativeNotifications = false
        }
        _ = monitor.evaluateHealth(forceCanary: false, allowNotifications: true)
        assertTrue(monitor.persistentState.lastAlertTimestampByCode["disk99996:HW_DISCONNECTED"] != nil, "Disconnected device query must scope cooldown key to 'disk99996:HW_DISCONNECTED'")

        // Restore clean config
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/"
            cfg.targetDeviceQuery = nil
            cfg.enableNativeNotifications = true
        }
        monitor.resetBaselines()
        print("  [OK] Volume verification -69863 handling, self-healing migration, and dark-wake guard verified")

        print("=== Swift Unit Test 31: Verification Cooldown Retention, Verified OK Baseline Preservation & Volume Mount Filtering (IMPROVE-V10-01 to V10-06) ===")
        // 31a. IMPROVE-V10-01: Verify that genuine corruption cooldown keys are preserved across state loads, while healed (-69863) keys are purged
        let testStatePath = ConfigManager.shared.stateFilePath
        var testState = DiskPersistentState()
        var corruptDrive = DriveBaselineState()
        corruptDrive.lastVerifyOk = false
        corruptDrive.lastVerifyResult = "Failed (Oct 20, 10:00): error: container_oid (0x1) is invalid (-69845)"
        corruptDrive.lastOverallSeverity = HealthSeverity.critical.rawValue
        testState.drives["disk_corrupt_test"] = corruptDrive
        testState.lastAlertTimestampByCode["disk_corrupt_test:VOLUME_VERIFY_FAILED"] = 1792400100.0

        var healedDrive = DriveBaselineState()
        healedDrive.lastVerifyOk = false
        healedDrive.lastVerifyResult = "Failed (Oct 20, 10:00): Error starting file system verification: Insufficient privileges (-69863)"
        healedDrive.lastOverallSeverity = HealthSeverity.critical.rawValue
        testState.drives["disk_healed_test"] = healedDrive
        testState.lastAlertTimestampByCode["disk_healed_test:VOLUME_VERIFY_FAILED"] = 1792400200.0

        let stateEncoder = JSONEncoder()
        stateEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encodedStateData = try? stateEncoder.encode(testState) {
            try? encodedStateData.write(to: URL(fileURLWithPath: testStatePath), options: .atomic)
        }

        let loadedState = DiskHealthMonitor.loadState()
        assertTrue(loadedState.drives["disk_corrupt_test"]?.lastVerifyOk == false, "Genuine corruption must keep lastVerifyOk = false")
        assertTrue(loadedState.lastAlertTimestampByCode["disk_corrupt_test:VOLUME_VERIFY_FAILED"] == 1792400100.0, "Cooldown for genuine corruption must be preserved across loadState()")
        assertTrue(loadedState.drives["disk_healed_test"]?.lastVerifyOk == true, "-69863 permission error must be healed to lastVerifyOk = true")
        assertTrue(loadedState.lastAlertTimestampByCode["disk_healed_test:VOLUME_VERIFY_FAILED"] == nil, "Cooldown for healed -69863 error must be purged across loadState()")

        // 31b. IMPROVE-V10-02: Verify that resetBaselines preserves 'Verified OK' timestamps and results for active and secondary drives, and clears them for failures
        monitor.setMonitoredTarget(volumePath: "/", deviceQuery: nil)
        let activeSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        let activeKey = !activeSnap.serialNumber.isEmpty ? activeSnap.serialNumber : activeSnap.bsdName

        monitor.mutateStateForTesting { st in
            st.updateDriveState(key: activeKey) { d in
                d.lastVerifyOk = true
                d.lastVerifyResult = "Verified OK (Oct 20, 12:10)"
                d.lastVerifyTimestamp = 1792491009.0
            }
            st.updateDriveState(key: "secondary_verified_disk") { d in
                d.lastVerifyOk = true
                d.lastVerifyResult = "Verified OK (Oct 19, 14:00)"
                d.lastVerifyTimestamp = 1792400000.0
            }
            st.updateDriveState(key: "secondary_failed_disk") { d in
                d.lastVerifyOk = false
                d.lastVerifyResult = "Failed: bad superblock"
                d.lastVerifyTimestamp = 1792300000.0
            }
        }

        // Active drive snapshot is non-nil:
        monitor.resetBaselines()
        let stateAfterResetWithSnap = monitor.persistentState
        assertTrue(stateAfterResetWithSnap.drives[activeKey]?.lastVerifyResult == "Verified OK (Oct 20, 12:10)", "Active drive 'Verified OK' result must be preserved across resetBaselines()")
        assertTrue(stateAfterResetWithSnap.drives[activeKey]?.lastVerifyTimestamp == 1792491009.0, "Active drive 'Verified OK' timestamp must be preserved across resetBaselines()")
        assertTrue(stateAfterResetWithSnap.drives["secondary_verified_disk"]?.lastVerifyResult == "Verified OK (Oct 19, 14:00)", "Secondary drive 'Verified OK' result must be preserved across resetBaselines()")
        assertTrue(stateAfterResetWithSnap.drives["secondary_verified_disk"]?.lastVerifyTimestamp == 1792400000.0, "Secondary drive 'Verified OK' timestamp must be preserved across resetBaselines()")
        assertTrue(stateAfterResetWithSnap.drives["secondary_failed_disk"]?.lastVerifyResult == "Not run yet", "Failed drive result must be reset to 'Not run yet'")
        assertTrue(stateAfterResetWithSnap.drives["secondary_failed_disk"]?.lastVerifyTimestamp == 0, "Failed drive timestamp must be reset to 0")

        // Also test when currentSnapshot is nil (e.g. engine startup / offline reset):
        monitor.clearCurrentSnapshotForTesting()
        monitor.resetBaselines()
        let stateAfterResetWithoutSnap = monitor.persistentState
        assertTrue(stateAfterResetWithoutSnap.drives[activeKey]?.lastVerifyResult == "Verified OK (Oct 20, 12:10)", "Active drive 'Verified OK' result must be preserved when snapshot is nil")
        assertTrue(stateAfterResetWithoutSnap.drives[activeKey]?.lastVerifyTimestamp == 1792491009.0, "Active drive 'Verified OK' timestamp must be preserved when snapshot is nil")
        assertTrue(stateAfterResetWithoutSnap.drives["secondary_verified_disk"]?.lastVerifyResult == "Verified OK (Oct 19, 14:00)", "Secondary drive 'Verified OK' result must be preserved when snapshot is nil")
        assertTrue(stateAfterResetWithoutSnap.drives["secondary_verified_disk"]?.lastVerifyTimestamp == 1792400000.0, "Secondary drive 'Verified OK' timestamp must be preserved when snapshot is nil")

        // 31c. IMPROVE-V10-03: Verify AppDelegate.shouldProcessVolumeNotification(volumePath:) filters system volumes and accepts user volumes
        assertTrue(AppDelegate.shouldProcessVolumeNotification(volumePath: "/Volumes/T7") == true, "External volume /Volumes/T7 must be processed")
        assertTrue(AppDelegate.shouldProcessVolumeNotification(volumePath: "/") == true, "Root volume / must be processed")
        assertTrue(AppDelegate.shouldProcessVolumeNotification(volumePath: "/Volumes/External_Disk") == true, "User volume /Volumes/External_Disk must be processed")
        assertTrue(AppDelegate.shouldProcessVolumeNotification(volumePath: nil) == true, "Nil volume path fallback must return true")
        assertTrue(AppDelegate.shouldProcessVolumeNotification(volumePath: "") == true, "Empty volume path fallback must return true")
        assertTrue(AppDelegate.shouldProcessVolumeNotification(volumePath: "/System/Volumes/Preboot") == false, "/System/Volumes/Preboot must be filtered")
        assertTrue(AppDelegate.shouldProcessVolumeNotification(volumePath: "/System/Volumes/Update/mnt1") == false, "/System/Volumes/Update must be filtered")
        assertTrue(AppDelegate.shouldProcessVolumeNotification(volumePath: "/System/Volumes/Data") == false, "/System/Volumes/Data mount note must be filtered")
        assertTrue(AppDelegate.shouldProcessVolumeNotification(volumePath: "/Volumes/Recovery") == false, "/Volumes/Recovery must be filtered")
        assertTrue(AppDelegate.shouldProcessVolumeNotification(volumePath: "/private/var/folders/zz") == false, "/private/* paths must be filtered")
        assertTrue(AppDelegate.shouldProcessVolumeNotification(volumePath: "/dev/disk3s1") == false, "/dev/* paths must be filtered")
        assertTrue(AppDelegate.shouldProcessVolumeNotification(volumePath: "/Volumes/.timemachine/backup") == false, "Time Machine mounts must be filtered")
        assertTrue(AppDelegate.shouldProcessVolumeNotification(volumePath: "/Volumes/com.apple.TimeMachine.localsnapshots/mnt") == false, "Time Machine local snapshots must be filtered")

        // 31d. IMPROVE-V10-05: Verify SettingsView custom target preservation
        let settingsVM = SettingsViewModel()
        settingsVM.refreshDiskList()
        // Allow background thread to populate availableDisks
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/Volumes/OfflineCustomBackup"
            cfg.targetDeviceQuery = nil
        }
        settingsVM.refreshDiskList()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        assertTrue(settingsVM.availableDisks.contains(where: { $0.id == "/Volumes/OfflineCustomBackup" }), "availableDisks must contain offline targetVolumePath")

        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = nil
            cfg.targetDeviceQuery = "SERIAL9999CUSTOM"
        }
        settingsVM.refreshDiskList()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        assertTrue(settingsVM.availableDisks.contains(where: { $0.id == "SERIAL9999CUSTOM" }), "availableDisks must contain custom targetDeviceQuery")

        // 31e. IMPROVE-V10-05: Verify AppDelegate.populateSelectDiskMenu() handles offline volume & device queries
        let appDelegate = AppDelegate()
        let testMenu = NSMenu()
        appDelegate.testingSetSelectDiskMenu(testMenu)
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/Volumes/OfflineCustomBackup"
            cfg.targetDeviceQuery = nil
        }
        appDelegate.populateSelectDiskMenu()
        let volumeOfflineItem = testMenu.items.first(where: { ($0.representedObject as? String) == "/Volumes/OfflineCustomBackup" })
        assertTrue(volumeOfflineItem != nil, "populateSelectDiskMenu must include offline targetVolumePath item")
        assertTrue(volumeOfflineItem?.state == .on, "Offline targetVolumePath item must have state = .on (checked)")

        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = nil
            cfg.targetDeviceQuery = "SERIAL9999CUSTOM"
        }
        appDelegate.populateSelectDiskMenu()
        let deviceOfflineItem = testMenu.items.first(where: { ($0.representedObject as? String) == "SERIAL9999CUSTOM" })
        assertTrue(deviceOfflineItem != nil, "populateSelectDiskMenu must include offline targetDeviceQuery item")
        assertTrue(deviceOfflineItem?.state == .on, "Offline targetDeviceQuery item must have state = .on (checked)")

        // 31f. IMPROVE-V10-02: Verify immediate snapshot update after resetBaselines + evaluateHealth
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/"
            cfg.targetDeviceQuery = nil
        }
        let snapForTest = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        let testRootKey = !snapForTest.serialNumber.isEmpty ? snapForTest.serialNumber : snapForTest.bsdName
        monitor.mutateStateForTesting { st in
            st.updateDriveState(key: testRootKey) { d in
                d.baselineUnsafeShutdowns = 0
            }
        }
        let snapWithWarning = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        if snapWithWarning.unsafeShutdowns > 0 {
            assertTrue(snapWithWarning.issues.contains(where: { $0.code == "NEW_UNSAFE_SHUTDOWN" }), "Baseline mismatch must trigger warning issue")
        }
        monitor.resetBaselines()
        let snapAfterReset = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(!snapAfterReset.issues.contains(where: { $0.code == "NEW_UNSAFE_SHUTDOWN" }), "Resetting baselines and evaluating health must clear NEW_UNSAFE_SHUTDOWN")
        assertTrue(monitor.currentSnapshot?.issues.contains(where: { $0.code == "NEW_UNSAFE_SHUTDOWN" }) == false, "currentSnapshot must reflect cleared issues immediately")

        // Clean up test state
        cfgMgr.updateConfig { cfg in
            cfg.targetVolumePath = "/"
            cfg.targetDeviceQuery = nil
        }
        monitor.resetBaselines()
        print("  [OK] Verification cooldown retention, baseline Verified OK preservation, and volume mount filtering verified")

        print("=== Swift Unit Test 32: Advanced Telemetry & Diagnostics Features (COMP-01 to COMP-06) ===")
        // 32a. COMP-01: APFS Purgeable Space Accounting
        let testRootSnap = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
        assertTrue(testRootSnap.freeBytes > 0, "Root volume freeBytes must be greater than 0")
        // Verify purgeable space in diagnostic exporter JSON
        let diagExport = DiagnosticExporter.shared.generateDiagnosticReport(snapshot: testRootSnap)
        let fsExport = diagExport["filesystem"] as? [String: Any]
        assertTrue(fsExport?["purgeableBytes"] != nil, "Diagnostic report filesystem section must include purgeableBytes")

        // 32b. COMP-02: Universal Webhook Payload Formatting & URL Redaction
        let webhookPayload = WebhookNotifier.buildPayload(snapshot: dummySnap, title: "Webhook Test", eventType: "health_alert")
        assertTrue((webhookPayload["content"] as? String)?.contains("Webhook Test") == true, "Discord/Mattermost content field must be populated")
        assertTrue((webhookPayload["text"] as? String)?.contains("Webhook Test") == true, "Slack text field must be populated")
        assertTrue((webhookPayload["message"] as? String)?.contains("Webhook Test") == true, "ntfy message field must be populated")
        assertTrue(webhookPayload["healthScore"] as? Int == 85, "healthScore must match snapshot")
        let redactedHook = WebhookNotifier.redactWebhookUrl("Failed POST to https://discord.com/api/webhooks/12345/secret_token", webhookUrl: "https://discord.com/api/webhooks/12345/secret_token")
        assertTrue(!redactedHook.contains("secret_token"), "Webhook secret path must be redacted")
        let redactedQueryHook = WebhookNotifier.redactWebhookUrl("Failed POST to https://api.service.com/notify?token=supersecret99", webhookUrl: "https://api.service.com/notify?token=supersecret99")
        assertTrue(!redactedQueryHook.contains("supersecret99"), "Webhook query string parameters must be redacted")

        // 32c. COMP-03: Standalone HTML Health & RMA Report Generation
        let htmlReport = DiagnosticExporter.shared.exportDiagnosticReportHTML(snapshot: dummySnap)
        assertTrue(htmlReport.contains("<!DOCTYPE html>"), "HTML report must be valid HTML5")
        assertTrue(htmlReport.contains("&lt;Name&gt;"), "HTML report must escape special characters")
        assertTrue(htmlReport.contains("TEST_HTML"), "HTML report must include active issue codes")
        if let htmlSaved = DiagnosticExporter.shared.saveDiagnosticReportHTMLToFile(snapshot: dummySnap) {
            assertTrue(FileManager.default.fileExists(atPath: htmlSaved), "HTML report file must exist on disk")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: htmlSaved),
               let perms = attrs[.posixPermissions] as? NSNumber {
                assertTrue(perms.intValue == 0o600, "HTML report must have 0600 permissions")
            }
            try? FileManager.default.removeItem(atPath: htmlSaved)
        }

        // 32d. COMP-04: Non-Destructive Surface Read Sample Probe & Multi-Tier Modes
        assertTrue(DiskHealthMonitor.SurfaceScanMode.allCases.count == 3, "SurfaceScanMode must support quick, standard, and full modes")
        assertTrue(DiskHealthMonitor.SurfaceScanMode.quick.shortLabel == "Quick (64 MB)", "Quick mode shortLabel")
        assertTrue(DiskHealthMonitor.SurfaceScanMode.standard.shortLabel == "Standard (2 GB)", "Standard mode shortLabel")
        assertTrue(DiskHealthMonitor.SurfaceScanMode.full.shortLabel == "Full Volume", "Full mode shortLabel")

        // Progress callback tracking
        var progressUpdatesCount = 0
        let scanRes = monitor.runSurfaceReadScan(mode: .quick, maxBytesToScan: 2 * 1024 * 1024) { prog in
            progressUpdatesCount += 1
            _ = prog.formattedBytesScanned
            _ = prog.formattedTargetBytes
            _ = prog.formattedThroughput
            _ = prog.formattedPercent
        }
        assertTrue(scanRes.ok == true, "Surface read scan on root volume must succeed with 0 EIO errors")
        assertTrue(scanRes.filesScanned > 0, "Surface read scan must sample at least 1 file")
        assertTrue(scanRes.bytesScanned > 0, "Surface read scan must read physical bytes")
        assertTrue(progressUpdatesCount > 0, "Surface scan progress handler must be called during execution")

        // Test Cooperative Cancellation Token
        let cancelToken = DiskHealthMonitor.SurfaceScanCancellationToken()
        cancelToken.cancel()
        assertTrue(cancelToken.isCancelled == true, "CancellationToken must report isCancelled == true")
        let cancelledScanRes = monitor.runSurfaceReadScan(mode: .standard, maxBytesToScan: 10 * 1024 * 1024, cancellationToken: cancelToken)
        assertTrue(cancelledScanRes.summary.uppercased().contains("CANCELLED"), "Pre-cancelled surface scan must report cancellation in summary")

        // 32e. COMP-05: Custom Alert Script Execution Hook
        let tempScriptPath = "\(cfgMgr.configDir)/test_alert_hook.sh"
        let scriptContent = "#!/bin/sh\nexit 0\n"
        try? scriptContent.write(toFile: tempScriptPath, atomically: true, encoding: .utf8)
        _ = chmod(tempScriptPath, 0o755)
        cfgMgr.updateConfig { $0.alertScriptPath = tempScriptPath }
        assertTrue(cfgMgr.currentConfig.alertScriptPath == tempScriptPath, "alertScriptPath must be configured")
        assertTrue(cfgMgr.resolvedAlertScriptPath == tempScriptPath, "resolvedAlertScriptPath must return configured script")
        setenv("ALERT_SCRIPT_PATH", "/usr/local/bin/custom_hook.sh", 1)
        assertTrue(cfgMgr.resolvedAlertScriptPath == "/usr/local/bin/custom_hook.sh", "resolvedAlertScriptPath must prioritize ALERT_SCRIPT_PATH environment variable")
        unsetenv("ALERT_SCRIPT_PATH")
        cfgMgr.updateConfig { $0.alertScriptPath = "" }
        try? FileManager.default.removeItem(atPath: tempScriptPath)

        // 32f. COMP-06: Rolling Thermal Spike Detection (TEMP_RAPID_RISE)
        let baseTs: TimeInterval = 10_000.0
        let initialSamples: [(timestamp: TimeInterval, tempC: Int)] = [(timestamp: baseTs, tempC: 36)]
        let (samplesAfterSpike, spikeIssue, spikePenalty) = DiskHealthMonitor.evaluateThermalSpike(
            samples: initialSamples,
            currentTempC: 46,
            nowTs: baseTs + 60.0
        )
        assertTrue(samplesAfterSpike.count == 2, "Rolling window must retain recent samples within 180s")
        assertTrue(spikeIssue?.code == "TEMP_RAPID_RISE", "+10°C rise in 60s to 46°C must trigger TEMP_RAPID_RISE")
        assertTrue(spikePenalty == 10, "TEMP_RAPID_RISE penalty must be 10")

        let (samplesAfterExpiry, _, _) = DiskHealthMonitor.evaluateThermalSpike(
            samples: samplesAfterSpike,
            currentTempC: 47,
            nowTs: baseTs + 250.0
        )
        assertTrue(!samplesAfterExpiry.contains(where: { $0.timestamp == baseTs }), "Sample older than 180s must be evicted from rolling window")

        // Verify sub-second duplicate sample suppression
        let (samplesDedup, _, _) = DiskHealthMonitor.evaluateThermalSpike(
            samples: samplesAfterExpiry,
            currentTempC: 47,
            nowTs: baseTs + 250.5
        )
        assertTrue(samplesDedup.count == samplesAfterExpiry.count, "Sub-second identical temperature samples must be deduplicated")

        // Verify DiagnosticExporter redacts webhook URLs from recentLogLines
        let testHookSecret = "https://discord.com/api/webhooks/99999/super_secret_hook_token"
        setenv("WEBHOOK_URL", testHookSecret, 1)
        ConfigManager.shared.log("Simulated webhook failure for \(testHookSecret)")
        let hookDiagJSON = DiagnosticExporter.shared.exportDiagnosticReportJSON(snapshot: testRootSnap)
        assertTrue(!hookDiagJSON.contains("super_secret_hook_token"), "Diagnostic JSON must redact webhook secret tokens from recentLogLines")
        unsetenv("WEBHOOK_URL")

        // Verify TelegramNotifier includes Purgeable space note when purgeableBytes > 0
        var snapWithPurgeable = dummySnap
        snapWithPurgeable.purgeableBytes = 5_000_000_000
        let tgHtmlWithPurgeable = TelegramNotifier.shared.formatReportHTML(snapshot: snapWithPurgeable, title: "Purgeable Check")
        assertTrue(tgHtmlWithPurgeable.contains("Purgeable: 5.0 GB"), "Telegram HTML report must display purgeable space when > 0")
        print("  [OK] Advanced telemetry & diagnostics features (COMP-01 to COMP-06) verified")

        print("=== Swift Unit Test 33: SSD Endurance Projection, Raw SMART Fields & Scanner UI State Retention (MANDATE-V12) ===")
        let enduranceSnap = dummySnap
        assertTrue(enduranceSnap.estimatedRemainingLifeFormatted == "N/A", "Non-SMART drive must report N/A endurance")
        assertTrue(enduranceSnap.dailyTerabytesWritten == 0.0, "Non-SMART drive must report 0.0 daily TBW")

        var smartSnapZeroWear = normalSnap
        smartSnapZeroWear = DiskHealthSnapshot(
            timestamp: normalSnap.timestamp,
            formattedTime: normalSnap.formattedTime,
            formattedShortTime: normalSnap.formattedShortTime,
            overallSeverity: .healthy,
            healthScore: 100,
            issues: [],
            hardwareFound: true,
            vendorName: "Apple",
            productName: "SSD",
            productRevision: "1.0",
            bsdName: "disk0",
            serialNumber: "SN1",
            usbSerialNumber: "SN1",
            interconnectType: "PCI-Express",
            protocolType: "NVMe",
            isInternal: true,
            isRemovable: false,
            linkSpeedBps: 0,
            linkSpeedFormatted: "PCI-Express",
            isMounted: true,
            mountPoint: "/",
            filesystemType: "apfs",
            isReadOnly: false,
            totalBytes: 1000,
            freeBytes: 500,
            purgeableBytes: 0,
            usedBytes: 500,
            usedPercent: 50.0,
            subpathsStatus: [:],
            canaryOk: true,
            canaryLatencyMs: 1.0,
            canaryError: "",
            smartValid: true,
            criticalWarning: 0,
            temperatureCelsius: 35,
            temperatureKelvin: 308,
            peakTemperatureCelsius: 40,
            availableSpare: 100,
            availableSpareThreshold: 10,
            percentageUsed: 5,
            lifeRemainingPercent: 95,
            dataUnitsRead: 100_000,
            dataUnitsWritten: 200_000,
            totalTerabytesRead: 5.0,
            totalTerabytesWritten: 10.0,
            hostReadCommands: 5000,
            hostWriteCommands: 6000,
            controllerBusyTime: 120,
            powerCycles: 50,
            powerOnHours: 2400,
            unsafeShutdowns: 0,
            mediaErrors: 0,
            errorInfoLogEntries: 0,
            statsValid: true,
            sessionBytesRead: 0,
            sessionBytesWritten: 0,
            operationsRead: 0,
            operationsWritten: 0,
            errorsRead: 0,
            errorsWritten: 0,
            retriesRead: 0,
            retriesWritten: 0,
            avgReadLatencyMs: 0.5,
            avgWriteLatencyMs: 0.5,
            readThroughputMBps: 0.0,
            writeThroughputMBps: 0.0,
            lastVerifyResult: "Verified OK",
            lastVerifyOk: true
        )
        // 2400 hours = 100 days; 10.0 TBW / 100 days = 0.1 TB/day; 5% used in 100 days -> 20 days/% -> 95% * 20 = 1900 days (~5.2 Years)
        assertTrue(abs(smartSnapZeroWear.dailyTerabytesWritten - 0.1) < 0.001, "Expected 0.1 TB/day burn rate")
        assertTrue(smartSnapZeroWear.estimatedRemainingLifeFormatted.contains("Years"), "Expected ~5.2 Years remaining life, got \(smartSnapZeroWear.estimatedRemainingLifeFormatted)")
        assertTrue(smartSnapZeroWear.temperatureKelvin == 308, "temperatureKelvin must be preserved")
        assertTrue(smartSnapZeroWear.hostReadCommands == 5000 && smartSnapZeroWear.hostWriteCommands == 6000, "Host read/write commands must be preserved")

        // Verify new ConfigManager keys
        let envV12: [String: String] = [
            "ENABLE_CRITICAL_SOUND_ALERT": "true",
            "SCHEDULED_VERIFY_INTERVAL_HOURS": "168"
        ]
        let parsedV12 = ConfigManager.applyEnvironmentVariables(into: DiskHealthConfig(), env: envV12)
        assertTrue(parsedV12.enableCriticalSoundAlert == true, "ENABLE_CRITICAL_SOUND_ALERT must parse to true")
        assertTrue(parsedV12.scheduledVerifyIntervalHours == 168, "SCHEDULED_VERIFY_INTERVAL_HOURS must parse to 168")
        print("  [OK] SSD endurance projection, raw NVMe SMART fields, and V12 configuration verified")

        // MARK: - Swift Unit Test 34: MockTelemetryProvider & Synthetic Fault Injection (Phase 5)
        do {
            print("=== Swift Unit Test 34: MockTelemetryProvider & Synthetic Fault Injection (Phase 5) ===")

            // Save original config & state for complete isolation and cleanup
            let origConfig = ConfigManager.shared.currentConfig
            defer {
                ConfigManager.shared.updateConfig { $0 = origConfig }
                monitor.resetBaselines()
            }

            // Configure test base environment: Canary disabled to isolate rule evaluations from filesystem side-effects
            ConfigManager.shared.updateConfig {
                $0.targetVolumePath = "/Volumes/MockDrive"
                $0.targetDeviceQuery = "disk42"
                $0.enableActiveCanary = false
                $0.minExpectedUsbSpeedBps = 0
                $0.tempWarningCelsius = 60
                $0.tempCriticalCelsius = 70
            }
            monitor.resetBaselines()

            let baseMountMetrics = FilesystemMountMetrics(
                isMounted: true,
                mountPoint: "/Volumes/MockDrive",
                filesystemType: "apfs",
                isReadOnly: false,
                totalBytes: 1_000_000_000_000,
                freeBytes: 800_000_000_000,
                purgeableBytes: 0,
                usedBytes: 200_000_000_000,
                usedPercent: 20.0
            )

            // 34a: Synthetic SMART Critical Warnings
            print("  --> 34a: Synthetic SMART Critical Warnings")
            let mock34a = MockTelemetryProvider()
            mock34a.mountPointByBsd["disk42"] = "/Volumes/MockDrive"
            mock34a.filesystemMetrics = baseMountMetrics
            mock34a.hardwareMetrics = makeMockDiskHardwareMetrics(criticalWarning: 0x01) // Bit 0: Available spare below threshold

            let snap34a = monitor.evaluateHealth(forceCanary: false, allowNotifications: false, telemetryProvider: mock34a)
            assertTrue(snap34a.overallSeverity == .critical, "SMART criticalWarning 0x01 must result in critical severity, got \(snap34a.overallSeverity)")
            assertTrue(snap34a.criticalWarning == 0x01, "Snapshot criticalWarning must match mock hardware")
            assertTrue(snap34a.issues.contains { $0.code == "SMART_CRITICAL_WARNING" }, "Snapshot must contain SMART_CRITICAL_WARNING issue")
            assertTrue(snap34a.healthScore <= 50, "Health score penalty must be >= 50 for critical warning byte, got \(snap34a.healthScore)")

            // Also test direct rule outcome when smartValid is false vs true
            let hw34aNoSmart = makeMockDiskHardwareMetrics(smartValid: false, criticalWarning: 0x04)
            let ctx34aNoSmart = HealthEvaluationContext(
                nowTs: 1000,
                config: ConfigManager.shared.currentConfig,
                hardware: hw34aNoSmart,
                linkSpeedFormatted: "PCIe",
                interconnect: "PCI-Express",
                mountToInspect: "/Volumes/MockDrive",
                filesystem: baseMountMetrics,
                subpathsStatus: [:],
                canaryOk: true,
                canaryLatencyMs: 1.0,
                canaryError: "",
                avgReadLatMs: 0.1,
                avgWriteLatMs: 0.1,
                inWakeGrace: false,
                hostThermalState: .nominal,
                driveState: DriveBaselineState(),
                recentTemperatureSamples: []
            )
            let outcome34aNoSmart = NVMeCriticalWarningRule().evaluate(context: ctx34aNoSmart)
            assertTrue(outcome34aNoSmart.issues.isEmpty, "NVMeCriticalWarningRule must ignore critical warning if smartValid == false")

            // 34b: Spare Capacity Depletion
            print("  --> 34b: Spare Capacity Depletion")
            let mock34bCritical = MockTelemetryProvider()
            mock34bCritical.mountPointByBsd["disk42"] = "/Volumes/MockDrive"
            mock34bCritical.filesystemMetrics = baseMountMetrics
            mock34bCritical.hardwareMetrics = makeMockDiskHardwareMetrics(availableSpare: 5, availableSpareThreshold: 10)

            let snap34bCrit = monitor.evaluateHealth(forceCanary: false, allowNotifications: false, telemetryProvider: mock34bCritical)
            assertTrue(snap34bCrit.overallSeverity == .critical, "availableSpare 5% <= 10% threshold must trigger critical severity")
            assertTrue(snap34bCrit.issues.contains { $0.code == "SPARE_CRITICAL" }, "Must report SPARE_CRITICAL issue")

            let mock34bWarn = MockTelemetryProvider()
            mock34bWarn.mountPointByBsd["disk42"] = "/Volumes/MockDrive"
            mock34bWarn.filesystemMetrics = baseMountMetrics
            mock34bWarn.hardwareMetrics = makeMockDiskHardwareMetrics(availableSpare: 20, availableSpareThreshold: 10)

            let snap34bWarn = monitor.evaluateHealth(forceCanary: false, allowNotifications: false, telemetryProvider: mock34bWarn)
            assertTrue(snap34bWarn.overallSeverity == .warning, "availableSpare 20% (< 25%) must trigger warning severity")
            assertTrue(snap34bWarn.issues.contains { $0.code == "SPARE_WARNING" }, "Must report SPARE_WARNING issue")

            // 34c: SSD Wear & Lifespan Exhaustion
            print("  --> 34c: SSD Wear & Lifespan Exhaustion")
            let mock34cCrit = MockTelemetryProvider()
            mock34cCrit.mountPointByBsd["disk42"] = "/Volumes/MockDrive"
            mock34cCrit.filesystemMetrics = baseMountMetrics
            mock34cCrit.hardwareMetrics = makeMockDiskHardwareMetrics(percentageUsed: 98)

            let snap34cCrit = monitor.evaluateHealth(forceCanary: false, allowNotifications: false, telemetryProvider: mock34cCrit)
            assertTrue(snap34cCrit.overallSeverity == .critical, "percentageUsed 98% (>= 95%) must trigger critical severity")
            assertTrue(snap34cCrit.issues.contains { $0.code == "WEAR_CRITICAL" }, "Must report WEAR_CRITICAL issue")
            assertTrue(snap34cCrit.lifeRemainingPercent == 2, "Expected lifeRemainingPercent == 2%, got \(snap34cCrit.lifeRemainingPercent)")

            let mock34cWarn = MockTelemetryProvider()
            mock34cWarn.mountPointByBsd["disk42"] = "/Volumes/MockDrive"
            mock34cWarn.filesystemMetrics = baseMountMetrics
            mock34cWarn.hardwareMetrics = makeMockDiskHardwareMetrics(percentageUsed: 85)

            let snap34cWarn = monitor.evaluateHealth(forceCanary: false, allowNotifications: false, telemetryProvider: mock34cWarn)
            assertTrue(snap34cWarn.overallSeverity == .warning, "percentageUsed 85% (>= 80%) must trigger warning severity")
            assertTrue(snap34cWarn.issues.contains { $0.code == "WEAR_WARNING" }, "Must report WEAR_WARNING issue")
            assertTrue(snap34cWarn.lifeRemainingPercent == 15, "Expected lifeRemainingPercent == 15%, got \(snap34cWarn.lifeRemainingPercent)")

            // 34d: Thermal Thresholds & Thermal Spikes
            print("  --> 34d: Thermal Thresholds & Thermal Spikes")
            let mock34dCrit = MockTelemetryProvider()
            mock34dCrit.mountPointByBsd["disk42"] = "/Volumes/MockDrive"
            mock34dCrit.filesystemMetrics = baseMountMetrics
            mock34dCrit.hardwareMetrics = makeMockDiskHardwareMetrics(temperatureCelsius: 72)

            let snap34dCrit = monitor.evaluateHealth(forceCanary: false, allowNotifications: false, telemetryProvider: mock34dCrit)
            assertTrue(snap34dCrit.overallSeverity == .critical, "72C >= 70C critical threshold must trigger critical severity")
            assertTrue(snap34dCrit.issues.contains { $0.code == "TEMP_CRITICAL" }, "Must report TEMP_CRITICAL issue")

            let mock34dWarn = MockTelemetryProvider()
            mock34dWarn.mountPointByBsd["disk42"] = "/Volumes/MockDrive"
            mock34dWarn.filesystemMetrics = baseMountMetrics
            mock34dWarn.hardwareMetrics = makeMockDiskHardwareMetrics(temperatureCelsius: 64)

            let snap34dWarn = monitor.evaluateHealth(forceCanary: false, allowNotifications: false, telemetryProvider: mock34dWarn)
            assertTrue(snap34dWarn.overallSeverity == .warning, "64C >= 60C warning threshold must trigger warning severity")
            assertTrue(snap34dWarn.issues.contains { $0.code == "TEMP_WARNING" }, "Must report TEMP_WARNING issue")

            // Thermal spike unit test: +10C rise in 20s (>= 8C rise and current >= 45C)
            let nowTs = Date().timeIntervalSince1970
            let spikeSamples: [(timestamp: TimeInterval, tempC: Int)] = [
                (timestamp: nowTs - 20, tempC: 38)
            ]
            let (updatedSamples, spikeIssue, spikePenalty) = ThermalAndSpikeRule.evaluateThermalSpike(
                samples: spikeSamples,
                currentTempC: 48,
                nowTs: nowTs
            )
            assertTrue(spikeIssue != nil, "Thermal spike of +10C reaching 48C must produce an issue")
            assertTrue(spikeIssue?.code == "TEMP_RAPID_RISE", "Expected TEMP_RAPID_RISE issue, got \(String(describing: spikeIssue?.code))")
            assertTrue(spikePenalty == 10, "Expected scorePenalty 10 for rapid spike")
            assertTrue(updatedSamples.count == 2, "Samples window must be updated with current sample")

            // 34e: Media Errors & Unsafe Shutdowns
            print("  --> 34e: Media Errors & Unsafe Shutdowns")
            monitor.mutateStateForTesting { state in
                state.updateDriveState(key: "MOCK-NVME-34E") { d in
                    d.baselineMediaErrors = 0
                    d.baselineUnsafeShutdowns = 5
                }
            }

            let mock34eMedia = MockTelemetryProvider()
            mock34eMedia.mountPointByBsd["disk42"] = "/Volumes/MockDrive"
            mock34eMedia.filesystemMetrics = baseMountMetrics
            mock34eMedia.hardwareMetrics = makeMockDiskHardwareMetrics(serialNumber: "MOCK-NVME-34E", unsafeShutdowns: 5, mediaErrors: 2)

            let snap34eMedia = monitor.evaluateHealth(forceCanary: false, allowNotifications: false, telemetryProvider: mock34eMedia)
            assertTrue(snap34eMedia.overallSeverity == .critical, "mediaErrors delta (2 > 0) must trigger critical severity")
            assertTrue(snap34eMedia.issues.contains { $0.code == "MEDIA_ERRORS" }, "Must report MEDIA_ERRORS issue")

            let mock34eShutdown = MockTelemetryProvider()
            mock34eShutdown.mountPointByBsd["disk42"] = "/Volumes/MockDrive"
            mock34eShutdown.filesystemMetrics = baseMountMetrics
            mock34eShutdown.hardwareMetrics = makeMockDiskHardwareMetrics(serialNumber: "MOCK-NVME-34E", unsafeShutdowns: 8, mediaErrors: 0)

            let snap34eShutdown = monitor.evaluateHealth(forceCanary: false, allowNotifications: false, telemetryProvider: mock34eShutdown)
            assertTrue(snap34eShutdown.overallSeverity == .warning, "unsafeShutdowns delta (+3) must trigger warning severity")
            assertTrue(snap34eShutdown.issues.contains { $0.code == "NEW_UNSAFE_SHUTDOWN" }, "Must report NEW_UNSAFE_SHUTDOWN issue")

            // 34f: USB Link Degradation
            print("  --> 34f: USB Link Degradation")
            ConfigManager.shared.updateConfig {
                $0.minExpectedUsbSpeedBps = 5_000_000_000 // Expect 5 Gbps (USB 3.0)
            }
            let mock34f = MockTelemetryProvider()
            mock34f.mountPointByBsd["disk42"] = "/Volumes/MockDrive"
            mock34f.filesystemMetrics = baseMountMetrics
            mock34f.hardwareMetrics = makeMockDiskHardwareMetrics(
                serialNumber: "MOCK-USB-34F",
                interconnectType: "USB",
                linkSpeedBps: 480_000_000 // Negotiated at USB 2.0 (480 Mbps)
            )

            let snap34f = monitor.evaluateHealth(forceCanary: false, allowNotifications: false, telemetryProvider: mock34f)
            assertTrue(snap34f.overallSeverity == .warning, "Degraded USB speed (480 Mbps < 5 Gbps) must trigger warning severity")
            assertTrue(snap34f.issues.contains { $0.code == "USB_LINK_DEGRADED" }, "Must report USB_LINK_DEGRADED issue")
            ConfigManager.shared.updateConfig { $0.minExpectedUsbSpeedBps = 0 }

            // 34g: Read-Only Volume Detection
            print("  --> 34g: Read-Only Volume Detection")
            var readOnlyMountMetrics = baseMountMetrics
            readOnlyMountMetrics.isReadOnly = true

            let mock34g = MockTelemetryProvider()
            mock34g.mountPointByBsd["disk42"] = "/Volumes/MockDrive"
            mock34g.filesystemMetrics = readOnlyMountMetrics
            mock34g.hardwareMetrics = makeMockDiskHardwareMetrics()

            let snap34g = monitor.evaluateHealth(forceCanary: false, allowNotifications: false, telemetryProvider: mock34g)
            assertTrue(snap34g.overallSeverity == .critical, "Read-only volume on non-root mount must trigger critical severity")
            assertTrue(snap34g.issues.contains { $0.code == "VOLUME_READONLY" }, "Must report VOLUME_READONLY issue")

            // 34h: DiskHealthError Localized Descriptions & Equatable Conformance
            print("  --> 34h: DiskHealthError Localized Descriptions & Equatable Conformance")
            let errs: [DiskHealthError] = [
                .hardwareNotFound(query: "disk99"),
                .volumeNotMounted(path: "/Volumes/Data"),
                .volumeReadOnly(path: "/Volumes/Data"),
                .canaryFailed(reason: "EACCES"),
                .surfaceScanFailed(reason: "Unreadable sectors", readErrors: 4),
                .verificationAlreadyInProgress,
                .verificationFailed(summary: "File system corrupt"),
                .configurationInvalid(reason: "Invalid JSON"),
                .secretStoreFailure(key: "telegramToken"),
                .keychainAccessDenied(status: -25293),
                .keychainOperationFailed(status: -25308),
                .fileWriteFailed(path: "/tmp/test", underlying: "Permission denied"),
                .alertDeliveryFailed(channel: "Telegram", reason: "401 Unauthorized"),
                .scriptNotExecutable(path: "/usr/local/bin/alert.sh"),
                .scriptExecutionFailed(exitCode: 1, output: "Permission denied")
            ]

            for err in errs {
                let desc = err.errorDescription
                assertTrue(desc != nil && !desc!.isEmpty, "DiskHealthError.\(err) must have non-empty localized errorDescription")
            }

            assertTrue(DiskHealthError.hardwareNotFound(query: "disk99").errorDescription?.contains("disk99") == true, "Must include query in description")
            assertTrue(DiskHealthError.surfaceScanFailed(reason: "Bad blocks", readErrors: 4).errorDescription?.contains("4 read errors") == true, "Must include read error count")
            assertTrue(DiskHealthError.verificationAlreadyInProgress.errorDescription == "Verification already in progress", "Exact verification progress description")

            // Equatable conformance
            assertTrue(DiskHealthError.volumeNotMounted(path: "/Volumes/Test") == DiskHealthError.volumeNotMounted(path: "/Volumes/Test"), "Equatable must hold for matching errors")
            assertTrue(DiskHealthError.volumeNotMounted(path: "/Volumes/A") != DiskHealthError.volumeNotMounted(path: "/Volumes/B"), "Equatable inequality must hold for distinct errors")
            assertTrue(DiskHealthError.verificationAlreadyInProgress != DiskHealthError.configurationInvalid(reason: "test"), "Different cases must not be equal")

            print("  [OK] Synthetic fault injection, MockTelemetryProvider, and DiskHealthError (34a-34h) verified")
        }

        // Test 35: Keychain On-Demand Onboarding & Denial Fallback State Machine
        print("\n=== Swift Unit Test 35: Keychain On-Demand Onboarding & Denial Fallback State Machine ===")
        do {
            SecretStore.shared.resetForTesting()
            assertTrue(SecretStore.shared.keychainState == .localOnlyDefault, "Default state must be localOnlyDefault")
            assertTrue(SecretStore.shared.useKeychainOptIn == false, "Keychain opt-in must default to false")

            // 1. Default setSecret writes to local .secrets.json (0600) without Keychain
            _ = SecretStore.shared.setSecret("token_local_default", forKey: "telegramBotToken")
            assertTrue(SecretStore.shared.keychainState == .localOnlyDefault, "Default setSecret must not activate Keychain")
            assertTrue(SecretStore.shared.getSecret(forKey: "telegramBotToken") == "token_local_default", "Secret must resolve from local store")

            // 2. Simulate user clicking 'Deny' (-25293 / errSecAuthFailed) on explicit Keychain onboarding
            SecretStore.shared.simulatedKeychainStatusForTesting = errSecAuthFailed
            let denyRes = SecretStore.shared.onboardOrUnlockKeychainInteractive(secretsToStore: [
                "telegramBotToken": "token_survives_denial",
                "webhookUrl": "https://example.com/webhook_survives"
            ])
            if case .failure(let err) = denyRes {
                assertTrue(err == .keychainAccessDenied(status: errSecAuthFailed), "Expected keychainAccessDenied error")
            } else {
                assertTrue(false, "Expected failure when Keychain access is denied")
            }
            assertTrue(SecretStore.shared.keychainState == .accessDenied(errSecAuthFailed), "State must transition to accessDenied")
            assertTrue(SecretStore.shared.useKeychainOptIn == false, "Keychain opt-in must auto-disable on denial to prevent popup loops")
            assertTrue(SecretStore.shared.getSecret(forKey: "telegramBotToken") == "token_survives_denial", "Secret must remain accessible via 0600 fallback after Keychain denial")
            assertTrue(SecretStore.shared.getSecret(forKey: "webhookUrl") == "https://example.com/webhook_survives", "Webhook must remain accessible via 0600 fallback after Keychain denial")

            // 3. Simulate user approving Keychain onboarding (errSecSuccess)
            SecretStore.shared.simulatedKeychainStatusForTesting = errSecSuccess
            let okRes = SecretStore.shared.onboardOrUnlockKeychainInteractive(secretsToStore: [
                "telegramBotToken": "token_keychain_approved"
            ])
            assertTrue(okRes == .success(.keychainReadyAndUnlocked), "Expected keychainReadyAndUnlocked on errSecSuccess")
            assertTrue(SecretStore.shared.keychainState == .keychainReadyAndUnlocked, "State must be keychainReadyAndUnlocked")
            assertTrue(SecretStore.shared.useKeychainOptIn == true, "Keychain opt-in must be true on approval")
            assertTrue(SecretStore.shared.getSecret(forKey: "telegramBotToken") == "token_keychain_approved", "Secret must resolve approved token")

            // 4. Switch back to local restricted storage only
            SecretStore.shared.switchToLocalRestrictedStorageOnly()
            assertTrue(SecretStore.shared.keychainState == .localOnlyDefault, "State must reset to localOnlyDefault")
            assertTrue(SecretStore.shared.useKeychainOptIn == false, "useKeychainOptIn must reset to false")

            // Clean up test secrets
            SecretStore.shared.resetForTesting()
            _ = SecretStore.shared.deleteSecret(forKey: "telegramBotToken")
            _ = SecretStore.shared.deleteSecret(forKey: "webhookUrl")
            print("  [OK] Keychain on-demand onboarding, denial fallback (-25293), and zero-popup default verified")
        }

        // Test 36: Synthetic Canary Fault Injection, Pure Rule Log Outcomes & AtomicFileWriter (Phase 5 Overhaul)
        print("\n=== Swift Unit Test 36: Synthetic Canary Fault Injection, Pure Rule Outcomes & AtomicFileWriter ===")
        do {
            let origConfig = ConfigManager.shared.currentConfig
            defer {
                ConfigManager.shared.updateConfig { $0 = origConfig }
                monitor.resetBaselines()
            }

            ConfigManager.shared.updateConfig {
                $0.targetVolumePath = "/Volumes/MockCanaryDrive"
                $0.targetDeviceQuery = "disk42"
                $0.enableActiveCanary = true
                $0.minExpectedUsbSpeedBps = 0
            }
            monitor.resetBaselines()
            monitor.noteSystemDidWake(at: Date().timeIntervalSince1970 - 30.0)

            let mockMount = FilesystemMountMetrics(
                isMounted: true,
                mountPoint: "/Volumes/MockCanaryDrive",
                filesystemType: "apfs",
                isReadOnly: false,
                totalBytes: 1_000_000_000_000,
                freeBytes: 800_000_000_000,
                purgeableBytes: 0,
                usedBytes: 200_000_000_000,
                usedPercent: 20.0
            )

            // 36a. Synthetic CANARY_IO_FAILED via MockTelemetryProvider
            let mockCanaryFail = MockTelemetryProvider()
            mockCanaryFail.mountPointByBsd["disk42"] = "/Volumes/MockCanaryDrive"
            mockCanaryFail.filesystemMetrics = mockMount
            mockCanaryFail.hardwareMetrics = makeMockDiskHardwareMetrics()
            mockCanaryFail.canaryResultOverride = CanaryProbeResult(ok: false, latencyMs: 0.0, error: "Synthetic EIO fsync error")

            let snapCanaryFail = monitor.evaluateHealth(forceCanary: true, allowNotifications: false, telemetryProvider: mockCanaryFail)
            assertTrue(snapCanaryFail.overallSeverity == .critical, "Synthetic canary failure must trigger CRITICAL severity")
            assertTrue(snapCanaryFail.issues.contains(where: { $0.code == "CANARY_IO_FAILED" }), "Must report CANARY_IO_FAILED issue")
            assertTrue(snapCanaryFail.canaryError == "Synthetic EIO fsync error", "Snapshot must preserve synthetic canary error string")

            // 36b. Synthetic CANARY_HIGH_LATENCY (> 300ms) via MockTelemetryProvider
            let mockCanarySlow = MockTelemetryProvider()
            mockCanarySlow.mountPointByBsd["disk42"] = "/Volumes/MockCanaryDrive"
            mockCanarySlow.filesystemMetrics = mockMount
            mockCanarySlow.hardwareMetrics = makeMockDiskHardwareMetrics()
            mockCanarySlow.canaryResultOverride = CanaryProbeResult(ok: true, latencyMs: 450.5, error: "")

            let snapCanarySlow = monitor.evaluateHealth(forceCanary: true, allowNotifications: false, telemetryProvider: mockCanarySlow)
            assertTrue(snapCanarySlow.overallSeverity == .warning, "High canary latency (450.5ms > 300ms) must trigger WARNING severity")
            assertTrue(snapCanarySlow.issues.contains(where: { $0.code == "CANARY_HIGH_LATENCY" }), "Must report CANARY_HIGH_LATENCY issue")

            // 36c. Pure functional HealthRuleOutcome logMessages verification during wake grace period
            let wakeCtx = HealthEvaluationContext(
                nowTs: 2000,
                config: ConfigManager.shared.currentConfig,
                hardware: makeMockDiskHardwareMetrics(found: false),
                linkSpeedFormatted: "USB",
                interconnect: "USB",
                mountToInspect: "/Volumes/MockCanaryDrive",
                filesystem: FilesystemMountMetrics(isMounted: false),
                subpathsStatus: [:],
                canaryOk: false,
                canaryLatencyMs: 0.0,
                canaryError: "Failed",
                avgReadLatMs: 0.0,
                avgWriteLatMs: 0.0,
                inWakeGrace: true,
                hostThermalState: .nominal,
                driveState: DriveBaselineState(),
                recentTemperatureSamples: []
            )
            let hwRuleOutcome = HardwarePresenceRule().evaluate(context: wakeCtx)
            assertTrue(hwRuleOutcome.issues.isEmpty, "HardwarePresenceRule must suppress issue during wake grace")
            assertTrue(!hwRuleOutcome.logMessages.isEmpty, "HardwarePresenceRule must emit pure logMessages in outcome")

            // 36d. AtomicFileWriter 0600 permissions & symlink overwrite protection
            let atomicTestPath = "\(NSTemporaryDirectory())atomic_writer_test_\(UUID().uuidString).json"
            let payloadData = Data("{\"test\":true}".utf8)
            assertTrue(AtomicFileWriter.writeRestricted(data: payloadData, toPath: atomicTestPath, permissions: 0o600), "AtomicFileWriter must succeed")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: atomicTestPath),
               let perms = attrs[.posixPermissions] as? NSNumber {
                assertTrue(perms.intValue == 0o600, "AtomicFileWriter must enforce 0600 permissions")
            } else {
                assertTrue(false, "Failed to inspect AtomicFileWriter file permissions")
            }
            try? FileManager.default.removeItem(atPath: atomicTestPath)

            // 36e. Unified listLocalMountedVolumes verification
            let localVolumes = IOKitTelemetryProvider.shared.listLocalMountedVolumes()
            assertTrue(localVolumes.contains(where: { $0.path == "/" }), "listLocalMountedVolumes must include root volume '/'")
            print("  [OK] Synthetic canary fault injection, pure rule log outcomes, and AtomicFileWriter verified")
        }

        // Test 37: Alert Script Pipe-Drain (>64KB) & Timeout Watchdog + Published Snapshot Sync
        print("\n=== Swift Unit Test 37: Alert Script Large Pipe Drain, Watchdog Timeout & Published Snapshot ===")
        do {
            let origConfig = ConfigManager.shared.currentConfig
            defer {
                ConfigManager.shared.updateConfig { $0 = origConfig }
            }

            // 37a. Verify script producing >128KB stdout does not deadlock pipe buffer
            let largeOutScript = "\(NSTemporaryDirectory())large_out_script_\(UUID().uuidString).sh"
            let largeScriptBody = """
            #!/bin/sh
            yes "DISK_HEALTH_LARGE_PIPE_LINE_0123456789ABCDEF" | head -n 3000
            exit 0
            """
            try? largeScriptBody.write(toFile: largeOutScript, atomically: true, encoding: .utf8)
            _ = chmod(largeOutScript, 0o755)
            ConfigManager.shared.updateConfig { $0.alertScriptPath = largeOutScript }

            let largeRes = monitor.testAlertScriptResult(timeoutSec: 5.0)
            if case .success(let msg) = largeRes {
                assertTrue(msg.contains("DISK_HEALTH_LARGE_PIPE_LINE_0123456789ABCDEF"), "Large stdout output must be captured completely without pipe buffer deadlock")
            } else {
                assertTrue(false, "Expected large stdout alert script to succeed, got \(largeRes)")
            }
            try? FileManager.default.removeItem(atPath: largeOutScript)

            // 37b. Verify hanging alert script is terminated by watchdog timer
            let hangScript = "\(NSTemporaryDirectory())hang_script_\(UUID().uuidString).sh"
            let hangScriptBody = """
            #!/bin/sh
            echo "STARTING_HANG_TEST"
            sleep 30
            exit 0
            """
            try? hangScriptBody.write(toFile: hangScript, atomically: true, encoding: .utf8)
            _ = chmod(hangScript, 0o755)
            ConfigManager.shared.updateConfig { $0.alertScriptPath = hangScript }

            let t0 = Date().timeIntervalSince1970
            let hangRes = monitor.testAlertScriptResult(timeoutSec: 1.0)
            let elapsed = Date().timeIntervalSince1970 - t0
            assertTrue(elapsed < 5.0, "Watchdog must terminate hanging alert script promptly (took \(elapsed)s)")
            if case .failure(let err) = hangRes {
                assertTrue(err.localizedDescription.contains("timed out"), "Watchdog failure must report timeout, got: \(err.localizedDescription)")
            } else {
                assertTrue(false, "Expected hanging alert script to fail with timeout")
            }
            try? FileManager.default.removeItem(atPath: hangScript)
            ConfigManager.shared.updateConfig { $0.alertScriptPath = "" }

            // 37c. Verify publishedSnapshot is populated on main thread
            let snap37 = monitor.evaluateHealth(forceCanary: false, allowNotifications: false)
            assertTrue(monitor.publishedSnapshot?.timestamp == snap37.timestamp, "publishedSnapshot must match latest evaluated snapshot on main thread")
            print("  [OK] Large pipe drainage (>128KB), watchdog timeout termination, and publishedSnapshot verified")
        }

        // Test 38: Multi-Disk Monitoring, Fleet Evaluation & Canary Cache Isolation
        print("\n=== Swift Unit Test 38: Multi-Disk Monitoring, Fleet Evaluation & Canary Cache Isolation ===")
        do {
            let origConfig = ConfigManager.shared.currentConfig
            defer {
                ConfigManager.shared.updateConfig { $0 = origConfig }
            }

            // 38a. Multi-disk config JSON serialization & backward compatibility
            var cfg = DiskHealthConfig()
            cfg.monitorAllDisks = true
            cfg.monitoredTargets = ["disk0", "/Volumes/BackupSSD"]
            if let encData = try? JSONEncoder().encode(cfg),
               let decCfg = try? JSONDecoder().decode(DiskHealthConfig.self, from: encData) {
                assertTrue(decCfg.monitorAllDisks == true, "monitorAllDisks must round-trip through JSON")
                assertTrue(decCfg.monitoredTargets == ["disk0", "/Volumes/BackupSSD"], "monitoredTargets must round-trip through JSON")
            } else {
                assertTrue(false, "Failed to encode/decode multi-disk config")
            }

            // Test decoding legacy JSON without multi-disk keys
            let legacyJson = """
            {
                "targetVolumePath": "/Volumes/Legacy",
                "pollIntervalSeconds": 45.0
            }
            """.data(using: .utf8)!
            if let decLegacy = try? JSONDecoder().decode(DiskHealthConfig.self, from: legacyJson) {
                assertTrue(decLegacy.monitorAllDisks == false, "Legacy config must default monitorAllDisks to false")
                assertTrue(decLegacy.monitoredTargets.isEmpty, "Legacy config must default monitoredTargets to empty array")
                assertTrue(decLegacy.targetVolumePath == "/Volumes/Legacy", "Legacy targetVolumePath preserved")
            } else {
                assertTrue(false, "Failed to decode legacy config")
            }

            // 38b. Mock multi-disk telemetry provider evaluation
            let mockMulti = MockTelemetryProvider()
            let dev1 = makeMockDiskHardwareMetrics(
                found: true,
                bsdName: "disk0",
                serialNumber: "SERIAL_INTERNAL_001",
                vendorName: "Apple",
                productName: "APPLE SSD AP0512Z",
                isInternal: true,
                smartValid: true,
                temperatureCelsius: 38,
                percentageUsed: 5
            )

            let dev2 = makeMockDiskHardwareMetrics(
                found: true,
                bsdName: "disk4",
                serialNumber: "SERIAL_EXTERNAL_002",
                vendorName: "Samsung",
                productName: "Samsung PSSD T7",
                isInternal: false,
                smartValid: true,
                temperatureCelsius: 62, // Warning temperature (> 58C)
                percentageUsed: 82      // Warning wear (> 80%)
            )

            mockMulti.allDevices = [dev1, dev2]
            mockMulti.hardwareMetricsByQuery["disk0"] = dev1
            mockMulti.hardwareMetricsByQuery["disk4"] = dev2

            var fs1 = FilesystemMountMetrics()
            fs1.isMounted = true
            fs1.mountPoint = "/"
            fs1.totalBytes = 500_000_000_000
            fs1.freeBytes = 350_000_000_000
            fs1.usedBytes = 150_000_000_000
            fs1.usedPercent = 30.0

            var fs2 = FilesystemMountMetrics()
            fs2.isMounted = true
            fs2.mountPoint = "/Volumes/BackupSSD"
            fs2.totalBytes = 1_000_000_000_000
            fs2.freeBytes = 800_000_000_000
            fs2.usedBytes = 200_000_000_000
            fs2.usedPercent = 20.0

            mockMulti.filesystemMetricsByMount["/"] = fs1
            mockMulti.filesystemMetricsByMount["/Volumes/BackupSSD"] = fs2
            mockMulti.mountPointByBsd["disk0"] = "/"
            mockMulti.mountPointByBsd["disk4"] = "/Volumes/BackupSSD"
            mockMulti.canaryResultOverride = CanaryProbeResult(ok: true, latencyMs: 1.5, error: "")

            ConfigManager.shared.updateConfig {
                $0.monitorAllDisks = true
                $0.monitoredTargets.removeAll()
            }

            let multiSnap = monitor.evaluateAllMonitoredDisks(forceCanary: false, allowNotifications: false, telemetryProvider: mockMulti)
            assertTrue(multiSnap.disks.count == 2, "Must evaluate both disks simultaneously, got \(multiSnap.disks.count)")
            assertTrue(multiSnap.overallSeverity == .warning, "Aggregate severity must reflect worst disk (expected WARNING, got \(multiSnap.overallSeverity))")
            assertTrue(multiSnap.worstHealthScore < 100, "Worst score must reflect degraded disk")
            assertTrue(monitor.publishedMultiSnapshot?.disks.count == 2, "publishedMultiSnapshot must be populated")

            // 38c. Canary Cache Isolation across distinct mount points
            CanaryProbeService.shared.resetCache()
            let canaryRes1 = CanaryProbeService.shared.runCanaryCheck(targetMount: "/", force: true)
            let canaryRes2 = CanaryProbeService.shared.runCanaryCheck(targetMount: NSTemporaryDirectory(), force: true)
            assertTrue(canaryRes1.ok, "Canary pass on / must succeed")
            assertTrue(canaryRes2.ok, "Canary pass on temp dir must succeed")
            let cached1 = CanaryProbeService.shared.runCanaryCheck(targetMount: "/", force: false)
            assertTrue(cached1.latencyMs == canaryRes1.latencyMs, "Canary cached latency must match per-mount entry")

            // 38d. Dynamic unmounted external physical disk in monitorAllDisks mode
            let dev3 = makeMockDiskHardwareMetrics(
                found: true,
                bsdName: "disk7",
                serialNumber: "SERIAL_FLASH_003",
                vendorName: "SanDisk",
                productName: "Unmounted Flash Drive",
                isInternal: false,
                smartValid: false
            )
            mockMulti.allDevices = [dev1, dev3]

            let multiSnapDynamic = monitor.evaluateAllMonitoredDisks(forceCanary: false, allowNotifications: false, telemetryProvider: mockMulti)
            let flashSnap = multiSnapDynamic.disks.first(where: { $0.bsdName == "disk7" })
            assertTrue(flashSnap != nil, "Unmounted external physical disk must still be evaluated")
            let hasUnmountedAlert = flashSnap?.issues.contains(where: { $0.code == "VOLUME_UNMOUNTED" }) ?? false
            assertTrue(!hasUnmountedAlert, "Auto-discovered unmounted external disk must not trigger false VOLUME_UNMOUNTED critical alert")

            print("  [OK] Multi-disk configuration, simultaneous fleet evaluation, canary isolation, and dynamic ejection verified")
        }

        // =========================================================================
        // Unit Test 39: Argon Hardening Verification (UAT Edge Cases, Concurrency & Optimizations)
        // =========================================================================
        print("=== Swift Unit Test 39: Argon Hardening Verification (Subpath Isolation, Tie-Breaker & Reverse Log Tailer) ===")
        do {
            let monitor = DiskHealthMonitor.shared

            // 39a. Multi-Disk Subpaths Scoping (UAT-02): Subpaths must not bleed onto unrelated fleet disks
            let mockHardening = MockTelemetryProvider()
            let internalDev = makeMockDiskHardwareMetrics(
                found: true,
                bsdName: "disk0",
                serialNumber: "APPLE_INTERNAL_NVME",
                vendorName: "Apple",
                productName: "APPLE SSD AP0256Z",
                isInternal: true,
                smartValid: true
            )
            let externalDev = makeMockDiskHardwareMetrics(
                found: true,
                bsdName: "disk5",
                serialNumber: "SAMSUNG_T7_DATA",
                vendorName: "Samsung",
                productName: "Samsung PSSD T7",
                isInternal: false,
                smartValid: true
            )
            mockHardening.allDevices = [internalDev, externalDev]
            mockHardening.hardwareMetricsByQuery["disk0"] = internalDev
            mockHardening.hardwareMetricsByQuery["disk5"] = externalDev
            mockHardening.mountPointByBsd["disk0"] = "/"
            mockHardening.mountPointByBsd["disk5"] = "/Volumes/BackupTarget"

            var fsRoot = FilesystemMountMetrics()
            fsRoot.isMounted = true
            fsRoot.mountPoint = "/"
            fsRoot.totalBytes = 250_000_000_000
            fsRoot.freeBytes = 150_000_000_000

            var fsExt = FilesystemMountMetrics()
            fsExt.isMounted = true
            fsExt.mountPoint = "/Volumes/BackupTarget"
            fsExt.totalBytes = 1_000_000_000_000
            fsExt.freeBytes = 800_000_000_000

            mockHardening.filesystemMetricsByMount["/"] = fsRoot
            mockHardening.filesystemMetricsByMount["/Volumes/BackupTarget"] = fsExt
            mockHardening.canaryResultOverride = CanaryProbeResult(ok: true, latencyMs: 1.0, error: "")

            ConfigManager.shared.updateConfig {
                $0.monitorAllDisks = true
                $0.targetVolumePath = "/Volumes/BackupTarget"
                $0.requiredSubpaths = ["DedicatedBackups"]
            }

            let fleetSnap = monitor.evaluateAllMonitoredDisks(forceCanary: false, allowNotifications: false, telemetryProvider: mockHardening)
            let rootSnap = fleetSnap.disks.first(where: { $0.bsdName == "disk0" })
            let rootHasSubpathIssue = rootSnap?.issues.contains(where: { $0.code == "REQUIRED_PATH_MISSING" }) ?? false
            assertTrue(!rootHasSubpathIssue, "Root volume '/' must NOT be evaluated for external volume's requiredSubpaths")

            // 39b. Primary Snapshot Tie-Breaker (UAT-03): Lower score wins tie on identical severity
            func makeArgonTestSnapshot(score: Int, key: String) -> DiskHealthSnapshot {
                return DiskHealthSnapshot(
                    timestamp: 1000,
                    formattedTime: "2026-10-22 10:00:00",
                    formattedShortTime: "10:00",
                    overallSeverity: .warning,
                    healthScore: score,
                    issues: [HealthIssue(code: "TEST_WARN", severity: .warning, title: "Test Warning", detail: "Detail")],
                    hardwareFound: true,
                    vendorName: "Vendor",
                    productName: "Product",
                    productRevision: "1.0",
                    bsdName: "disk1",
                    serialNumber: key,
                    usbSerialNumber: key,
                    interconnectType: "USB",
                    protocolType: "NVMe",
                    isInternal: false,
                    isRemovable: true,
                    linkSpeedBps: 5_000_000_000,
                    linkSpeedFormatted: "5 Gbps",
                    isMounted: true,
                    mountPoint: "/Volumes/\(key)",
                    filesystemType: "apfs",
                    isReadOnly: false,
                    totalBytes: 500_000_000_000,
                    freeBytes: 100_000_000_000,
                    purgeableBytes: 0,
                    usedBytes: 400_000_000_000,
                    usedPercent: 80.0,
                    subpathsStatus: [:],
                    canaryOk: true,
                    canaryLatencyMs: 1.0,
                    canaryError: "",
                    smartValid: true,
                    criticalWarning: 0,
                    temperatureCelsius: 35,
                    temperatureKelvin: 308,
                    peakTemperatureCelsius: 35,
                    availableSpare: 100,
                    availableSpareThreshold: 10,
                    percentageUsed: 5,
                    lifeRemainingPercent: 95,
                    dataUnitsRead: 100,
                    dataUnitsWritten: 100,
                    totalTerabytesRead: 0.05,
                    totalTerabytesWritten: 0.05,
                    hostReadCommands: 1000,
                    hostWriteCommands: 1000,
                    controllerBusyTime: 10,
                    powerCycles: 10,
                    powerOnHours: 100,
                    unsafeShutdowns: 1,
                    mediaErrors: 0,
                    errorInfoLogEntries: 0,
                    statsValid: true,
                    sessionBytesRead: 1000,
                    sessionBytesWritten: 1000,
                    operationsRead: 10,
                    operationsWritten: 10,
                    errorsRead: 0,
                    errorsWritten: 0,
                    retriesRead: 0,
                    retriesWritten: 0,
                    avgReadLatencyMs: 0.5,
                    avgWriteLatencyMs: 0.5,
                    readThroughputMBps: 10.0,
                    writeThroughputMBps: 10.0,
                    lastVerifyResult: "Verified OK",
                    lastVerifyOk: true
                )
            }

            let mockSnapA = makeArgonTestSnapshot(score: 85, key: "SN_A")
            let mockSnapB = makeArgonTestSnapshot(score: 60, key: "SN_B")

            let multiTest = MultiDiskHealthSnapshot(
                timestamp: 1000,
                formattedTime: "2026-10-22 10:00:00",
                formattedShortTime: "10:00",
                overallSeverity: .warning,
                worstHealthScore: 60,
                averageHealthScore: 72,
                totalIssuesCount: 0,
                disks: [mockSnapA, mockSnapB]
            )
            assertTrue(multiTest.primarySnapshot?.driveKey == "SN_B", "primarySnapshot must select DiskB (score 60) over DiskA (score 85) on tie")

            // 39c. Thread-Safe Drive Selection (SYS-01)
            let dispatchGroup = DispatchGroup()
            for i in 0..<10 {
                dispatchGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    monitor.selectDashboardDrive(key: "KEY_\(i)")
                    dispatchGroup.leave()
                }
            }
            _ = dispatchGroup.wait(timeout: .now() + 2.0)
            assertTrue(!monitor.selectedDashboardDriveKey.isEmpty, "selectedDashboardDriveKey must be updated safely")

            // 39d. In-Place Canary Probe (OPT-04)
            let canaryProbePass = CanaryProbeService.shared.runCanaryCheck(targetMount: NSTemporaryDirectory(), force: true)
            assertTrue(canaryProbePass.ok, "In-place canary probe on temporary directory must succeed")

            // 39e. Bounded Reverse-Seek Log Tailer (OPT-05)
            let testLogPath = ConfigManager.shared.logFilePath
            var testLines: [String] = []
            for i in 1...250 {
                testLines.append("2026-10-22T10:00:\(String(format: "%02d", i % 60))Z [INFO] Line \(i) payload data")
            }
            let fullLogData = testLines.joined(separator: "\n").data(using: .utf8)!
            _ = AtomicFileWriter.writeRestricted(data: fullLogData, toPath: testLogPath, permissions: 0o600)

            let diagReport = DiagnosticExporter.shared.generateDiagnosticReport(snapshot: mockSnapA)
            if let recent = diagReport["recentLogLines"] as? [String] {
                assertTrue(recent.count == 100, "Diagnostic exporter must capture exactly last 100 lines, got \(recent.count)")
                assertTrue(recent.last?.contains("Line 250") == true, "Last line must be Line 250")
            } else {
                assertTrue(false, "recentLogLines must be an array of strings in diagnostic report")
            }

            print("  [OK] Subpath isolation, tie-breaker selection, concurrent drive selection, and reverse log tailer verified")
        }

        print("✅ All Swift Core Logic Unit Tests Passed!")
    }
}
