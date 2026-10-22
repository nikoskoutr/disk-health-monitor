import SwiftUI
import AppKit

// MARK: - Native macOS Multi-Disk Statistics & Comparative Insights Tab

struct StatisticsAndInsightsTab: View {
    @ObservedObject var monitor: DiskHealthMonitor
    @ObservedObject var configMgr: ConfigManager = ConfigManager.shared

    private var currentMulti: MultiDiskHealthSnapshot? {
        monitor.publishedMultiSnapshot ?? monitor.currentMultiSnapshot
    }

    private var activeDisks: [DiskHealthSnapshot] {
        if let multi = currentMulti, !multi.disks.isEmpty {
            return multi.disks
        }
        if let single = monitor.publishedSnapshot ?? monitor.currentSnapshot {
            return [single]
        }
        return []
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                // 1. Fleet Health Summary Header Card
                fleetSummaryCard

                // 2. Drive Lifetime & Endurance Comparison
                enduranceComparisonCard

                // 3. Operating Thermal Profile Comparison
                thermalProfileCard

                // 4. Kernel Driver Latency & Canary Performance
                latencyAndPerformanceCard

                // 5. Per-Drive Raw S.M.A.R.T. Register Breakdown
                smartRegisterBreakdownCard
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - 1. Fleet Summary Card

    @ViewBuilder
    private var fleetSummaryCard: some View {
        SettingsCard(title: "Storage Fleet Health Overview", icon: "square.grid.2x2.fill", iconColor: .blue) {
            let disks = activeDisks
            let worstSeverity = currentMulti?.overallSeverity ?? (disks.first?.overallSeverity ?? .healthy)
            let worstScore = currentMulti?.worstHealthScore ?? (disks.first?.healthScore ?? 100)
            let avgScore = currentMulti?.averageHealthScore ?? (disks.first?.healthScore ?? 100)
            let totalTBW = disks.reduce(0.0) { $0 + $1.totalTerabytesWritten }
            let maxTemp = disks.map(\.temperatureCelsius).max() ?? 0

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(disks.count) Storage Device\(disks.count == 1 ? "" : "s") Monitored")
                            .font(.system(size: 14, weight: .bold))
                        Text(configMgr.config.monitorAllDisks
                             ? "Mode: Automatic Full-Fleet Monitoring (All Connected Disks)"
                             : (configMgr.config.monitoredTargets.count > 1 ? "Mode: Selective Multi-Disk Target List" : "Mode: Single Target"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        DispatchQueue.global(qos: .userInitiated).async {
                            _ = monitor.evaluateAllMonitoredDisks(forceCanary: true, allowNotifications: false)
                        }
                    }) {
                        Label("Refresh Fleet", systemImage: "arrow.clockwise")
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    insightStatPill(
                        title: "FLEET STATUS",
                        value: "\(worstSeverity.rawValue) (\(worstScore)%)",
                        color: statusColor(worstSeverity)
                    )
                    insightStatPill(
                        title: "AVERAGE HEALTH",
                        value: "\(avgScore) / 100",
                        color: avgScore >= 90 ? .green : (avgScore >= 75 ? .orange : .red)
                    )
                    insightStatPill(
                        title: "COMBINED TBW",
                        value: String(format: "%.2f TB", totalTBW),
                        color: .purple
                    )
                    insightStatPill(
                        title: "PEAK FLEET TEMP",
                        value: "\(maxTemp) °C",
                        color: maxTemp >= configMgr.config.tempCriticalCelsius ? .red : (maxTemp >= configMgr.config.tempWarningCelsius ? .orange : .teal)
                    )
                }
            }
        }
    }

    // MARK: - 2. Drive Endurance Comparison Card

    @ViewBuilder
    private var enduranceComparisonCard: some View {
        SettingsCard(title: "SSD Lifetime & Endurance Projections", icon: "hourglass.badge.plus", iconColor: .green) {
            VStack(spacing: 12) {
                ForEach(activeDisks) { disk in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(disk.vendorName) \(disk.productName)")
                                .font(.system(size: 12, weight: .semibold))
                            if !disk.bsdName.isEmpty {
                                Text(disk.bsdName)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.18))
                                    .cornerRadius(4)
                            }
                            Spacer()
                            Text(disk.smartValid ? disk.estimatedRemainingLifeFormatted : "Non-SMART Bus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(disk.smartValid ? .blue : .secondary)
                        }

                        if disk.smartValid {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.secondary.opacity(0.18))
                                        .frame(height: 6)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(wearColor(disk.percentageUsed))
                                        .frame(width: max(4, geo.size.width * CGFloat(min(100, disk.percentageUsed)) / 100.0), height: 6)
                                }
                            }
                            .frame(height: 6)

                            HStack {
                                Text("Wear: \(disk.percentageUsed)% (\(disk.lifeRemainingPercent)% Left)")
                                Spacer()
                                Text(String(format: "Burn: %.2f GB/day • Written: %.2f TB (POH: %lluh)",
                                            disk.dailyTerabytesWritten * 1000.0,
                                            disk.totalTerabytesWritten,
                                            disk.powerOnHours))
                            }
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        }

                        if disk.id != activeDisks.last?.id {
                            Divider().padding(.top, 4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 3. Operating Thermal Profile Comparison

    @ViewBuilder
    private var thermalProfileCard: some View {
        let warnTemp = configMgr.config.tempWarningCelsius
        let critTemp = configMgr.config.tempCriticalCelsius

        SettingsCard(title: "Operating Thermal Profile Comparison", icon: "thermometer.medium", iconColor: .orange) {
            VStack(spacing: 10) {
                ForEach(activeDisks) { disk in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(disk.vendorName) \(disk.productName) (\(disk.bsdName))")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            if disk.smartValid {
                                Text("\(disk.temperatureCelsius) °C")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(tempColor(disk.temperatureCelsius, warn: warnTemp, crit: critTemp))
                                Text("(Peak: \(disk.peakTemperatureCelsius) °C)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            } else {
                                Text("No Temp Sensor")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }

                        if disk.smartValid {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.secondary.opacity(0.18))
                                        .frame(height: 6)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(tempColor(disk.temperatureCelsius, warn: warnTemp, crit: critTemp))
                                        .frame(width: max(4, geo.size.width * CGFloat(min(100, max(0, disk.temperatureCelsius))) / 100.0), height: 6)
                                }
                            }
                            .frame(height: 6)
                        }

                        if disk.id != activeDisks.last?.id {
                            Divider().padding(.top, 4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 4. Kernel Latency & Canary Performance

    @ViewBuilder
    private var latencyAndPerformanceCard: some View {
        SettingsCard(title: "Kernel I/O Latency & Canary Filesystem Probe", icon: "waveform.path.ecg", iconColor: .teal) {
            VStack(spacing: 10) {
                ForEach(activeDisks) { disk in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(disk.vendorName) \(disk.productName) (\(disk.bsdName))")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            if disk.canaryOk {
                                Text(String(format: "Canary: %.2f ms", disk.canaryLatencyMs))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.green)
                            } else if disk.isMounted {
                                Text("Canary: \(disk.canaryError)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.orange)
                            }
                        }

                        HStack(spacing: 16) {
                            if disk.statsValid {
                                Text(String(format: "Kernel Latency: %.2f ms Read / %.2f ms Write", disk.avgReadLatencyMs, disk.avgWriteLatencyMs))
                                Text(String(format: "Errors: %llu R / %llu W", disk.errorsRead, disk.errorsWritten))
                                Text("Retries: \(disk.retriesRead + disk.retriesWritten)")
                            } else {
                                Text("Kernel driver statistics unavailable")
                            }
                            Spacer()
                            if disk.smartValid {
                                Text("Unsafe: \(disk.unsafeShutdowns)")
                                Text("Media: \(disk.mediaErrors)")
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                        if disk.id != activeDisks.last?.id {
                            Divider().padding(.top, 4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 5. Per-Drive Raw S.M.A.R.T. Register Breakdown

    @ViewBuilder
    private var smartRegisterBreakdownCard: some View {
        SettingsCard(title: "Per-Drive Hardware Register Inspection", icon: "cpu.fill", iconColor: .purple) {
            VStack(alignment: .leading, spacing: 8) {
                if activeDisks.count > 1 {
                    HStack {
                        Text("Select Monitored Drive:")
                            .font(.system(size: 11, weight: .medium))
                        Picker("", selection: Binding(
                            get: {
                                if monitor.selectedDashboardDriveKey.isEmpty {
                                    return activeDisks.first?.driveKey ?? ""
                                }
                                return monitor.selectedDashboardDriveKey
                            },
                            set: { monitor.selectedDashboardDriveKey = $0 }
                        )) {
                            ForEach(activeDisks) { d in
                                Text(d.displayLabel).tag(d.driveKey)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 280)
                        Spacer()
                    }
                    Divider()
                }

                let targetDisk = activeDisks.first(where: { $0.driveKey == monitor.selectedDashboardDriveKey }) ?? activeDisks.first
                if let disk = targetDisk, disk.smartValid {
                    VStack(spacing: 5) {
                        smartRow(id: "01", name: "Critical Warning Bitmask", raw: String(format: "0x%02X", disk.criticalWarning), ok: disk.criticalWarning == 0)
                        smartRow(id: "02", name: "Composite Temperature", raw: "\(disk.temperatureCelsius) °C (Peak: \(disk.peakTemperatureCelsius) °C)", ok: disk.temperatureCelsius < configMgr.config.tempWarningCelsius)
                        smartRow(id: "03", name: "Available Spare Capacity", raw: "\(disk.availableSpare)% (Threshold: \(disk.availableSpareThreshold)%)", ok: disk.availableSpare > disk.availableSpareThreshold)
                        smartRow(id: "04", name: "Percentage Used (Wear)", raw: "\(disk.percentageUsed)% Used (\(disk.lifeRemainingPercent)% Left)", ok: disk.percentageUsed < 80)
                        smartRow(id: "05", name: "Data Units Read", raw: String(format: "%llu units (%.2f TB)", disk.dataUnitsRead, disk.totalTerabytesRead), ok: true)
                        smartRow(id: "06", name: "Data Units Written (TBW)", raw: String(format: "%llu units (%.2f TB)", disk.dataUnitsWritten, disk.totalTerabytesWritten), ok: true)
                        smartRow(id: "07", name: "Host Read Commands", raw: "\(disk.hostReadCommands)", ok: true)
                        smartRow(id: "08", name: "Host Write Commands", raw: "\(disk.hostWriteCommands)", ok: true)
                        smartRow(id: "09", name: "Controller Busy Time", raw: "\(disk.controllerBusyTime) min", ok: true)
                        smartRow(id: "0A", name: "Power Cycles", raw: "\(disk.powerCycles) cycles", ok: true)
                        smartRow(id: "0B", name: "Power-On Hours (POH)", raw: "\(disk.powerOnHours) hours (\(disk.powerOnHours / 24) days)", ok: true)
                        smartRow(id: "0C", name: "Unsafe Shutdowns", raw: "\(disk.unsafeShutdowns) events", ok: true)
                        smartRow(id: "0D", name: "Media & Data Integrity Errors", raw: "\(disk.mediaErrors) errors", ok: disk.mediaErrors == 0)
                        smartRow(id: "0E", name: "Error Information Log Entries", raw: "\(disk.errorInfoLogEntries) entries", ok: disk.errorInfoLogEntries == 0)
                    }
                } else {
                    Text("Hardware S.M.A.R.T. telemetry is not supported on this bus/device.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Component Helpers

    private func smartRow(id: String, name: String, raw: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Text(id)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 22, alignment: .leading)
            Text(name)
                .font(.system(size: 11))
            Spacer()
            Text(raw)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(ok ? .primary : .red)
            Circle()
                .fill(ok ? Color.green : Color.red)
                .frame(width: 6, height: 6)
        }
        .padding(.vertical, 2)
    }

    private func insightStatPill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
        .cornerRadius(6)
    }

    private func statusColor(_ severity: HealthSeverity) -> Color {
        switch severity {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func wearColor(_ used: UInt8) -> Color {
        if used >= 90 { return .red }
        if used >= 75 { return .orange }
        return .green
    }

    private func tempColor(_ temp: Int, warn: Int, crit: Int) -> Color {
        if temp >= crit { return .red }
        if temp >= warn { return .orange }
        return .green
    }
}
