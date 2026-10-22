import SwiftUI
import AppKit

// MARK: - SwiftUI Menu Bar Dashboard Card

struct DashboardMenuView: View {
    @ObservedObject var monitor: DiskHealthMonitor
    @ObservedObject var configMgr: ConfigManager = ConfigManager.shared

    var body: some View {
        let multi = monitor.publishedMultiSnapshot ?? monitor.currentMultiSnapshot
        let activeSnap = multi?.disks.first(where: { $0.driveKey == monitor.selectedDashboardDriveKey }) ?? monitor.publishedSnapshot ?? monitor.currentSnapshot
        if let snap = activeSnap {
            let cfg = configMgr.config
            VStack(alignment: .leading, spacing: 10) {
                // Multi-Disk Horizontal Switcher (when multiple disks are monitored)
                if let multi = multi, multi.disks.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(multi.disks) { disk in
                                let isSelected = (disk.driveKey == monitor.selectedDashboardDriveKey) ||
                                                 (monitor.selectedDashboardDriveKey.isEmpty && disk.driveKey == multi.primarySnapshot?.driveKey)
                                Button(action: {
                                    monitor.selectedDashboardDriveKey = disk.driveKey
                                }) {
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(statusColor(disk.overallSeverity))
                                            .frame(width: 7, height: 7)
                                        Text(disk.bsdName.isEmpty ? disk.productName : disk.bsdName)
                                            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                        if disk.smartValid {
                                            Text("\(disk.temperatureCelsius)°C")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1)
                        .padding(.bottom, 2)
                    }
                    Divider()
                }

                // Header
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(statusColor(snap.overallSeverity).opacity(0.18))
                            .frame(width: 38, height: 38)
                        Image(systemName: statusIconName(snap.overallSeverity))
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(statusColor(snap.overallSeverity))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("\(snap.vendorName) \(snap.productName)")
                                .font(.system(size: 13, weight: .bold))
                                .lineLimit(1)
                            if !snap.bsdName.isEmpty {
                                Text(snap.bsdName)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.18))
                                    .cornerRadius(4)
                            }
                        }
                        Text("\(snap.interconnectType) • \(snap.linkSpeedFormatted)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text("\(snap.overallSeverity.rawValue) \(snap.healthScore)%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(statusColor(snap.overallSeverity))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor(snap.overallSeverity).opacity(0.15))
                        .cornerRadius(6)
                }

                Divider()

                // Capacity Bar
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(snap.isMounted ? "Volume: \(snap.mountPoint) (\(snap.isReadOnly ? "Read-Only" : "R/W"))" : "Volume Unmounted")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        if snap.isMounted {
                            Text(String(format: "%.1f%% Used", snap.usedPercent))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 7)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(capacityColor(snap.usedPercent))
                                .frame(width: max(4, geo.size.width * CGFloat(min(100.0, max(0.0, snap.usedPercent)) / 100.0)), height: 7)
                        }
                    }
                    .frame(height: 7)

                    if snap.isMounted {
                        HStack {
                            Text("Used: \(formatBytes(snap.usedBytes))")
                            Spacer()
                            if snap.purgeableBytes > 0 {
                                Text("Avail: \(formatBytes(snap.freeBytes)) (\(formatBytes(snap.purgeableBytes)) purgeable)")
                            } else {
                                Text("Free: \(formatBytes(snap.freeBytes)) / \(formatBytes(snap.totalBytes))")
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    }
                }

                // 2x2 Telemetry Grid with Visual Gauges
                HStack(spacing: 8) {
                    metricTile(
                        icon: "thermometer.medium",
                        title: "TEMPERATURE",
                        value: snap.smartValid ? "\(snap.temperatureCelsius)°C" : "N/A",
                        subtitle: snap.smartValid ? "Peak: \(snap.peakTemperatureCelsius)°C (Warn \(cfg.tempWarningCelsius)°C)" : "No SMART",
                        tint: snap.temperatureCelsius >= cfg.tempWarningCelsius ? .orange : .green,
                        progress: snap.smartValid ? min(1.0, max(0.0, Double(snap.temperatureCelsius) / Double(max(1, cfg.tempCriticalCelsius)))) : nil,
                        progressColor: snap.temperatureCelsius >= cfg.tempCriticalCelsius ? .red : (snap.temperatureCelsius >= cfg.tempWarningCelsius ? .orange : .green)
                    )
                    metricTile(
                        icon: "bolt.heart.fill",
                        title: "SSD LIFESPAN",
                        value: snap.smartValid ? "\(snap.lifeRemainingPercent)% Left" : "N/A",
                        subtitle: snap.smartValid ? "Est: \(snap.estimatedRemainingLifeFormatted) • Spare: \(snap.availableSpare)%" : "No SMART",
                        tint: .blue,
                        progress: snap.smartValid ? min(1.0, max(0.0, Double(snap.lifeRemainingPercent) / 100.0)) : nil,
                        progressColor: snap.lifeRemainingPercent < 20 ? .red : (snap.lifeRemainingPercent < 50 ? .orange : .blue)
                    )
                }

                HStack(spacing: 8) {
                    metricTile(
                        icon: "internaldrive.fill",
                        title: "LIFETIME TBW / READ",
                        value: snap.smartValid ? String(format: "%.2f TBW", snap.totalTerabytesWritten) : "N/A",
                        subtitle: snap.smartValid ? String(format: "%.2f TB R • %.1f GB/d • %lluh", snap.totalTerabytesRead, snap.dailyTerabytesWritten * 1000.0, snap.powerOnHours) : "No SMART",
                        tint: .purple
                    )
                    metricTile(
                        icon: "waveform.path.ecg",
                        title: "I/O & CANARY PROBE",
                        value: "\(snap.errorsRead + snap.errorsWritten + snap.mediaErrors) Errors",
                        subtitle: snap.canaryOk ? String(format: "Canary: %.1f ms • OK", snap.canaryLatencyMs) : "Canary: FAILED",
                        tint: (snap.canaryOk && (snap.errorsRead + snap.errorsWritten + snap.mediaErrors == 0)) ? .green : .red
                    )
                }

                // Live I/O Performance Strip
                if snap.statsValid {
                    HStack(spacing: 6) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(String(format: "I/O: R %.1f / W %.1f MB/s", snap.readThroughputMBps, snap.writeThroughputMBps))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 4)
                        Text(String(format: "Latency: %.1fms R / %.1fms W", snap.avgReadLatencyMs, snap.avgWriteLatencyMs))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                }

                // Active Issues List
                if !snap.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(snap.issues) { issue in
                            HStack(alignment: .top, spacing: 6) {
                                Text(issue.severity.emoji)
                                    .font(.system(size: 11))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(issue.title)
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(issue.detail)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(7)
                }

                // Footer SMART Summary
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Cycles: \(snap.powerCycles)")
                        Spacer()
                        Text("Unsafe: \(snap.unsafeShutdowns)")
                        Spacer()
                        Text("Media Err: \(snap.mediaErrors)")
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                    HStack {
                        Text("FS: \(monitor.isVerifyingVolume ? "Verifying Volume..." : snap.lastVerifyResult)")
                            .lineLimit(1)
                        Spacer()
                        Text("Updated \(snap.formattedShortTime)")
                    }
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(width: 385)
        } else {
            Text("Loading Storage Telemetry...")
                .padding()
                .frame(width: 385)
        }
    }

    private func metricTile(icon: String, title: String, value: String, subtitle: String, tint: Color, progress: Double? = nil, progressColor: Color = .blue) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
                .lineLimit(1)

            if let prog = progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(progressColor)
                            .frame(width: max(2, geo.size.width * CGFloat(prog)), height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.top, 1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.10))
        .cornerRadius(8)
    }

    private func statusColor(_ severity: HealthSeverity) -> Color {
        switch severity {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func statusIconName(_ severity: HealthSeverity) -> String {
        switch severity {
        case .healthy: return "externaldrive.fill.badge.checkmark"
        case .warning: return "externaldrive.trianglebadge.exclamationmark"
        case .critical: return "externaldrive.fill.badge.xmark"
        }
    }

    private func capacityColor(_ pct: Double) -> Color {
        if pct >= 92 { return .red }
        if pct >= 82 { return .orange }
        return .blue
    }
}
