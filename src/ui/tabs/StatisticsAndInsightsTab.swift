// ============================================================================
// File: StatisticsAndInsightsTab.swift
// Module: Layer 4 (Presentation / Settings Tabs)
// Purpose: Fleet analytics tab rendering multi-disk health cards, throughput gauges,
//          endurance summaries, and detailed hardware comparison tables.
// Concurrency: Main thread (@MainActor / SwiftUI view graph).
// ============================================================================

import SwiftUI
import AppKit

// MARK: - Native macOS Multi-Disk Statistics & Comparative Insights Tab

/// Fleet insights tab comparing health, throughput, endurance, and bus speeds across all drives.
struct StatisticsAndInsightsTab: View {
    @ObservedObject var monitor: DiskHealthMonitor
    @ObservedObject var configMgr: ConfigManager = ConfigManager.shared
    @ObservedObject var viewModel: SettingsViewModel

    private var currentMulti: MultiDiskHealthSnapshot? {
        monitor.publishedMultiSnapshot
    }

    private var activeDisks: [DiskHealthSnapshot] {
        if let multi = currentMulti, !multi.disks.isEmpty {
            return multi.disks
        }
        if let single = monitor.publishedSnapshot {
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

                // 5. Historical Telemetry Ring Buffer & Sparklines
                historicalTrendSparklinesCard

                // 6. 90-Day Rolling Forecasts & Long-Term Trend Model (HIST-01)
                rollingForecastCard

                // 7. APFS Container Space-Sharing & Volume Roles (APFS-03)
                apfsContainerCard

                // 8. APFS Local Snapshots (APFS-02)
                apfsSnapshotsCard

                // 9. Per-Drive Raw S.M.A.R.T. Register Breakdown
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
            let smartDisks = disks.filter(\.smartValid)
            let maxTemp = smartDisks.map(\.temperatureCelsius).max()

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
                        value: maxTemp != nil ? "\(maxTemp!) °C" : "N/A",
                        color: (maxTemp ?? 0) >= configMgr.config.tempCriticalCelsius ? .red : ((maxTemp ?? 0) >= configMgr.config.tempWarningCelsius ? .orange : .teal)
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

    // MARK: - 6. APFS Local Snapshots Inventory & Pruning (APFS-02)

    @ViewBuilder
    private var apfsSnapshotsCard: some View {
        SettingsCard(title: "APFS Local Snapshots & Retention (Time Machine)", icon: "camera.metering.matrix", iconColor: .teal) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Time Machine Snapshots")
                            .font(.system(size: 13, weight: .semibold))
                        Text(viewModel.apfsSnapshots.isEmpty ? "No active local snapshots found on root volume." : "\(viewModel.apfsSnapshots.count) local snapshot\(viewModel.apfsSnapshots.count == 1 ? "" : "s") retaining historical volume state.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    HStack(spacing: 8) {
                        Button(action: { viewModel.loadApfsSnapshots() }) {
                            HStack(spacing: 4) {
                                if viewModel.isLoadingSnapshots {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("Scan Snapshots")
                            }
                            .font(.system(size: 11))
                        }
                        .disabled(viewModel.isLoadingSnapshots)

                        Button(action: { viewModel.thinApfsSnapshots(targetGB: 20) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                Text("Thin Snapshots (20 GB)")
                            }
                            .font(.system(size: 11))
                        }
                        .disabled(viewModel.isLoadingSnapshots || viewModel.apfsSnapshots.isEmpty)
                    }
                }

                if let status = viewModel.snapshotThinningStatus {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.accentColor)
                        Text(status)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor.opacity(0.1)))
                }

                if !viewModel.apfsSnapshots.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.apfsSnapshots.prefix(5)) { snap in
                            HStack {
                                Text(snap.snapshotName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                Text(snap.formattedAge)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.04)))
                }
            }
        }
    }

    // MARK: - 5. Historical Telemetry Ring Buffer & Trend Sparklines

    @ViewBuilder
    private var historicalTrendSparklinesCard: some View {
        SettingsCard(title: "Historical Telemetry Trends & Rate-of-Change (history.json)", icon: "chart.xyaxis.line", iconColor: .indigo) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(activeDisks) { disk in
                    let points = TelemetryHistoryStore.shared.points(forDriveKey: disk.driveKey)
                    let rates = TelemetryHistoryStore.shared.computeRateMetrics(for: disk)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(disk.vendorName) \(disk.productName) (\(disk.bsdName))")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(points.count) samples • 24h Burn: \(String(format: "%.2f TB/day", rates.terabytesWrittenLast24h)) • Drop: \(String(format: "%.2f GB/hr", rates.freeSpaceDropGBPerHour))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        if points.count >= 2 {
                            let recent = Array(points.suffix(36))
                            HStack(spacing: 12) {
                                sparklineStrip(
                                    title: "TEMP (°C)",
                                    values: recent.map { Double($0.temperatureCelsius) },
                                    minBound: 20.0,
                                    maxBound: 85.0,
                                    tint: .orange
                                )
                                sparklineStrip(
                                    title: "HEALTH SCORE",
                                    values: recent.map { Double($0.healthScore) },
                                    minBound: 0.0,
                                    maxBound: 100.0,
                                    tint: .green
                                )
                                sparklineStrip(
                                    title: "USED SPACE (%)",
                                    values: recent.map(\.usedPercent),
                                    minBound: 0.0,
                                    maxBound: 100.0,
                                    tint: .blue
                                )
                            }
                        } else {
                            Text("Collecting time-series points (sampled every 5 minutes or on severity change)...")
                                .font(.system(size: 10.5))
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

    private func sparklineStrip(title: String, values: [Double], minBound: Double, maxBound: Double, tint: Color) -> some View {
        let minVal = values.min() ?? minBound
        let maxVal = values.max() ?? maxBound
        let lo = min(minBound, minVal)
        let hi = max(maxBound, maxVal, lo + 1.0)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "min %.0f / max %.0f", minVal, maxVal))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, val in
                    let norm = max(0.12, min(1.0, (val - lo) / (hi - lo)))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(tint.opacity(0.8))
                        .frame(width: 4, height: CGFloat(norm * 24.0))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 24)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.08)))
    }

    // MARK: - 6. 90-Day Rolling Forecasts & Long-Term Trend Model (HIST-01)

    @ViewBuilder
    private var rollingForecastCard: some View {
        SettingsCard(title: "90-Day Rolling Forecasts & Wear Regression (HIST-01)", icon: "chart.line.uptrend.xyaxis", iconColor: .blue) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(activeDisks) { disk in
                    let sampleCount = TelemetryHistoryStore.shared.points(forDriveKey: disk.driveKey).count
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(disk.vendorName) \(disk.productName) (\(disk.bsdName))")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("Archive: \(sampleCount) samples")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        HStack(spacing: 8) {
                            forecastMetricPill(
                                title: "7-DAY BURN",
                                value: String(format: "%.2f GB/d", disk.rolling7dTerabytesWrittenPerDay * 1000.0),
                                sub: "Short-term rate",
                                color: .purple
                            )
                            forecastMetricPill(
                                title: "30-DAY REGRESSION",
                                value: String(format: "%.2f GB/d", disk.rolling30dTerabytesWrittenPerDay * 1000.0),
                                sub: "OLS trend slope",
                                color: .blue
                            )
                            forecastMetricPill(
                                title: "P95 LATENCY",
                                value: String(format: "%.1f ms", disk.p95WriteLatencyMs),
                                sub: "Tail latency",
                                color: disk.p95WriteLatencyMs > 50.0 ? .orange : .green
                            )
                            forecastMetricPill(
                                title: "P95 THERMAL",
                                value: "\(disk.p95TemperatureCelsius) °C",
                                sub: "Peak operating",
                                color: disk.p95TemperatureCelsius >= configMgr.config.tempWarningCelsius ? .orange : .teal
                            )
                            forecastMetricPill(
                                title: "ESTIMATED LIFE",
                                value: disk.estimatedRemainingLifeFormatted,
                                sub: "Based on wear",
                                color: .indigo
                            )
                        }

                        if disk.id != activeDisks.last?.id {
                            Divider().padding(.top, 4)
                        }
                    }
                }
            }
        }
    }

    private func forecastMetricPill(title: String, value: String, sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
            Text(sub)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.08)))
    }

    // MARK: - 7. APFS Container Space-Sharing & Volume Roles (APFS-03)

    @ViewBuilder
    private var apfsContainerCard: some View {
        let containers = activeDisks.compactMap { disk -> (DiskHealthSnapshot, ApfsContainerFleetMetrics)? in
            guard let cont = disk.apfsContainer else { return nil }
            return (disk, cont)
        }

        if !containers.isEmpty {
            SettingsCard(title: "APFS Container Space-Sharing & Volume Roles (APFS-03)", icon: "square.stack.3d.down.right.fill", iconColor: .teal) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(containers, id: \.0.id) { disk, container in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("\(container.containerBsd.isEmpty ? "Container" : container.containerBsd) on \(disk.vendorName) \(disk.productName)")
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text("Pool: \(formatBytes(container.totalCapacityBytes)) • Free: \(formatBytes(container.freeSpaceBytes)) (\(String(format: "%.1f%%", container.freePercent)) free)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            // Horizontal Allocation Bar
                            GeometryReader { geo in
                                HStack(spacing: 1) {
                                    let total = max(1, container.totalCapacityBytes)
                                    ForEach(container.volumes) { vol in
                                        let width = max(4, CGFloat(vol.usedBytes) / CGFloat(total) * geo.size.width)
                                        Rectangle()
                                            .fill(roleColor(vol.role))
                                            .frame(width: width)
                                    }
                                    let freeWidth = max(2, CGFloat(container.freeSpaceBytes) / CGFloat(total) * geo.size.width)
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.2))
                                        .frame(width: freeWidth)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .frame(height: 12)

                            // Volume Table
                            VStack(spacing: 4) {
                                ForEach(container.volumes) { vol in
                                    HStack {
                                        Circle()
                                            .fill(roleColor(vol.role))
                                            .frame(width: 6, height: 6)
                                        Text(vol.name.isEmpty ? vol.bsdName : vol.name)
                                            .font(.system(size: 11, weight: .medium))
                                            .frame(width: 140, alignment: .leading)
                                            .lineLimit(1)
                                        Text("(\(vol.bsdName))")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .frame(width: 65, alignment: .leading)
                                        Text(vol.role)
                                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(roleColor(vol.role))
                                            .frame(width: 80, alignment: .leading)
                                        Spacer()
                                        Text("\(formatBytes(vol.usedBytes)) (\(String(format: "%.1f%%", vol.percentOfContainer(total: container.totalCapacityBytes))))")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.vertical, 1)
                                }
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))

                            if disk.id != containers.last?.0.id {
                                Divider().padding(.top, 4)
                            }
                        }
                    }
                }
            }
        }
    }

    private func roleColor(_ role: String) -> Color {
        switch role.lowercased() {
        case "data": return .blue
        case "system": return .indigo
        case "vm": return .orange
        case "recovery": return .purple
        case "preboot": return .mint
        default: return .teal
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
                            set: { monitor.selectDashboardDrive(key: $0) }
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
