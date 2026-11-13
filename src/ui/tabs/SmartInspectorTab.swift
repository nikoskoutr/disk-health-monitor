// ============================================================================
// File: SmartInspectorTab.swift
// Module: Layer 4 (Presentation / Settings Tabs)
// Purpose: Hardware inspection tab displaying comprehensive NVMe S.M.A.R.T.
//          attributes, controller counters, wear percentages, and IOBlockStorage stats.
// Concurrency: Main thread (@MainActor / SwiftUI view graph).
// ============================================================================

import SwiftUI
import AppKit

/// Inspection tab rendering detailed raw NVMe SMART metrics and IOBlockStorageDriver statistics.
struct SmartInspectorTab: View {
    @ObservedObject var monitor: DiskHealthMonitor

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            let multi = monitor.publishedMultiSnapshot
            let targetSnap = multi?.disks.first(where: { $0.driveKey == monitor.selectedDashboardDriveKey }) ?? monitor.publishedSnapshot
            if let snap = targetSnap {
                VStack(alignment: .leading, spacing: 14) {
                    if let multi = multi, multi.disks.count > 1 {
                        HStack {
                            Text("Inspect Drive:")
                                .font(.system(size: 11, weight: .semibold))
                            Picker("", selection: Binding(
                                get: {
                                    if monitor.selectedDashboardDriveKey.isEmpty {
                                        return multi.disks.first?.driveKey ?? ""
                                    }
                                    return monitor.selectedDashboardDriveKey
                                },
                                set: { monitor.selectDashboardDrive(key: $0) }
                            )) {
                                ForEach(multi.disks) { d in
                                    Text(d.displayLabel).tag(d.driveKey)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 280)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    }

                    SettingsCard(title: "Physical Controller & Endurance Summary", icon: "cpu.fill", iconColor: .blue) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(snap.vendorName) \(snap.productName)")
                                    .font(.system(size: 14, weight: .bold))
                                Text("BSD: \(snap.bsdName.isEmpty ? "offline" : snap.bsdName) • Bus: \(snap.interconnectType) (\(snap.linkSpeedFormatted))\(snap.linkWidthLanes > 0 ? " [x\(snap.linkWidthLanes) Lanes]" : "") • Rev: \(snap.productRevision.isEmpty ? "N/A" : snap.productRevision)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text("Serial: \(snap.serialNumber.isEmpty ? "N/A" : snap.serialNumber)\(snap.usbCurrentAvailableMa > 0 || snap.usbCurrentRequiredMa > 0 ? " • USB Power: \(snap.usbCurrentRequiredMa)mA req / \(snap.usbCurrentAvailableMa)mA avail" : "")")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: {
                                DispatchQueue.global(qos: .userInitiated).async {
                                    _ = DiskHealthMonitor.shared.evaluateAllMonitoredDisks(forceCanary: false, allowNotifications: false)
                                }
                            }) {
                                Label("Refresh SMART", systemImage: "arrow.clockwise")
                            }
                        }

                        Divider()

                        HStack(spacing: 12) {
                            inspectorStatPill(title: "ESTIMATED SSD LIFE", value: snap.estimatedRemainingLifeFormatted, color: .blue)
                            inspectorStatPill(title: "DAILY WRITE BURN", value: snap.smartValid ? String(format: "%.2f GB/day", snap.dailyTerabytesWritten * 1000.0) : "N/A", color: .purple)
                            inspectorStatPill(title: "HEALTH SCORE", value: "\(snap.healthScore) / 100 (\(snap.overallSeverity.rawValue))", color: snap.overallSeverity == .healthy ? .green : (snap.overallSeverity == .warning ? .orange : .red))
                        }
                    }

                    SettingsCard(title: "Raw NVMe / S.M.A.R.T. Attributes", icon: "list.bullet.rectangle.portrait.fill", iconColor: .teal) {
                        SmartAttributesTableView(
                            disk: snap,
                            warningTempC: ConfigManager.shared.currentConfig.tempWarningCelsius,
                            compact: false
                        )
                    }

                    SettingsCard(title: "IOBlockStorageDriver Kernel Telemetry", icon: "waveform.path.ecg", iconColor: .orange) {
                        if snap.statsValid {
                            VStack(spacing: 6) {
                                SmartAttributeRow(id: "IO-1", name: "Session Bytes Read / Written", raw: "\(formatBytes(snap.sessionBytesRead)) Read / \(formatBytes(snap.sessionBytesWritten)) Written", status: "Active", isGood: true)
                                SmartAttributeRow(id: "IO-2", name: "Session Read / Write Operations", raw: "\(snap.operationsRead) R / \(snap.operationsWritten) W ops", status: "Active", isGood: true)
                                SmartAttributeRow(id: "IO-3", name: "Average Driver I/O Latency", raw: String(format: "%.2f ms Read / %.2f ms Write", snap.avgReadLatencyMs, snap.avgWriteLatencyMs), status: max(snap.avgReadLatencyMs, snap.avgWriteLatencyMs) < 50.0 ? "Nominal" : "Elevated", isGood: max(snap.avgReadLatencyMs, snap.avgWriteLatencyMs) < 50.0)
                                SmartAttributeRow(id: "IO-4", name: "Kernel Driver Read / Write Errors", raw: "\(snap.errorsRead) Read / \(snap.errorsWritten) Write", status: (snap.errorsRead + snap.errorsWritten) == 0 ? "0 Errors" : "ALERT", isGood: (snap.errorsRead + snap.errorsWritten) == 0)
                                SmartAttributeRow(id: "IO-5", name: "Kernel Driver Read / Write Retries", raw: "\(snap.retriesRead) Read / \(snap.retriesWritten) Write", status: "\(snap.retriesRead + snap.retriesWritten)", isGood: (snap.retriesRead + snap.retriesWritten) == 0)
                            }
                        } else {
                            Text("Kernel block storage driver statistics unavailable for this device.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }

                    SettingsCard(title: "Bus & PHY Signal Integrity (USB / PCIe / Thunderbolt)", icon: "cable.connector.horizontal", iconColor: .purple) {
                        VStack(spacing: 6) {
                            SmartAttributeRow(id: "PHY-1", name: "Physical Layer / Port CRC Errors", raw: "\(snap.busErrorCount) error packets", status: snap.busErrorCount == 0 ? "0 Errors" : "\(snap.busErrorCount) ERR", isGood: snap.busErrorCount == 0)
                            SmartAttributeRow(id: "PHY-2", name: "Bus / Port Recovery Resets", raw: "\(snap.busResetCount) link recovery resets", status: snap.busResetCount == 0 ? "0 Resets" : "\(snap.busResetCount) WARN", isGood: snap.busResetCount == 0)
                        }
                    }

                    if !snap.damagedExtents.isEmpty {
                        SettingsCard(title: "Pinpointed Bad Extents (Physical LBA Mapping)", icon: "exclamationmark.triangle.fill", iconColor: .red) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(snap.damagedExtents) { ext in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(ext.filePath)
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                .foregroundColor(.red)
                                                .lineLimit(1)
                                            Text("Logical Offset: \(ext.logicalOffset) • Physical LBA: 0x\(String(ext.physicalLbaOffset, radix: 16, uppercase: true)) • Size: \(formatBytes(ext.contiguousBytes))")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Text("CORRUPTED")
                                            .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                                            .foregroundColor(.red)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.red.opacity(0.12)))
                                    }
                                    .padding(.vertical, 2)
                                    if ext.id != snap.damagedExtents.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(8)
            } else {
                Text("Evaluating hardware telemetry...")
                    .padding()
            }
        }
    }

    private func inspectorStatPill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.10)))
    }
}
