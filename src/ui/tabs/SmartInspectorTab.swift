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
                                Text("BSD: \(snap.bsdName.isEmpty ? "offline" : snap.bsdName) • Bus: \(snap.interconnectType) (\(snap.linkSpeedFormatted)) • Rev: \(snap.productRevision.isEmpty ? "N/A" : snap.productRevision)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text("Serial: \(snap.serialNumber.isEmpty ? "N/A" : snap.serialNumber)")
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
                        if snap.smartValid {
                            VStack(spacing: 6) {
                                smartAttributeRow(id: "01", name: "Critical Warning Byte", raw: String(format: "0x%02X", snap.criticalWarning), status: snap.criticalWarning == 0 ? "OK" : "ALERT", isGood: snap.criticalWarning == 0)
                                smartAttributeRow(id: "02", name: "Composite Temperature", raw: "\(snap.temperatureCelsius) °C (\(snap.temperatureKelvin) K) • Peak: \(snap.peakTemperatureCelsius) °C", status: "\(snap.temperatureCelsius)°C", isGood: snap.temperatureCelsius < ConfigManager.shared.currentConfig.tempWarningCelsius)
                                smartAttributeRow(id: "03", name: "Available Spare Capacity", raw: "\(snap.availableSpare)% (Threshold: \(snap.availableSpareThreshold)%)", status: "\(snap.availableSpare)%", isGood: snap.availableSpare > snap.availableSpareThreshold)
                                smartAttributeRow(id: "04", name: "Percentage Used (Wear Indicator)", raw: "\(snap.percentageUsed)% Used (\(snap.lifeRemainingPercent)% Remaining)", status: "\(snap.lifeRemainingPercent)% Left", isGood: snap.percentageUsed < 80)
                                smartAttributeRow(id: "05", name: "Data Units Read (512B x 1000)", raw: String(format: "%llu units (%.2f TB)", snap.dataUnitsRead, snap.totalTerabytesRead), status: "Info", isGood: true)
                                smartAttributeRow(id: "06", name: "Data Units Written (TBW)", raw: String(format: "%llu units (%.2f TB)", snap.dataUnitsWritten, snap.totalTerabytesWritten), status: "Info", isGood: true)
                                smartAttributeRow(id: "07", name: "Host Read Commands", raw: "\(snap.hostReadCommands)", status: "Info", isGood: true)
                                smartAttributeRow(id: "08", name: "Host Write Commands", raw: "\(snap.hostWriteCommands)", status: "Info", isGood: true)
                                smartAttributeRow(id: "09", name: "Controller Busy Time", raw: "\(snap.controllerBusyTime) min", status: "Info", isGood: true)
                                smartAttributeRow(id: "0A", name: "Power Cycles", raw: "\(snap.powerCycles) cycles", status: "Info", isGood: true)
                                smartAttributeRow(id: "0B", name: "Power-On Hours (POH)", raw: "\(snap.powerOnHours) hours (\(snap.powerOnHours / 24) days)", status: "Info", isGood: true)
                                smartAttributeRow(id: "0C", name: "Unsafe Shutdowns", raw: "\(snap.unsafeShutdowns) events", status: snap.unsafeShutdowns == 0 ? "0" : "\(snap.unsafeShutdowns)", isGood: true)
                                smartAttributeRow(id: "0D", name: "Media & Data Integrity Errors", raw: "\(snap.mediaErrors) errors", status: snap.mediaErrors == 0 ? "0 Errors" : "FAIL", isGood: snap.mediaErrors == 0)
                                smartAttributeRow(id: "0E", name: "Error Information Log Entries", raw: "\(snap.errorInfoLogEntries) entries", status: "\(snap.errorInfoLogEntries)", isGood: snap.errorInfoLogEntries == 0)
                            }
                        } else {
                            Text("Hardware S.M.A.R.T. telemetry is not supported on this bus/bridge (\(snap.interconnectType)). Kernel I/O statistics and active filesystem probes remain active.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .padding(.vertical, 6)
                        }
                    }

                    SettingsCard(title: "IOBlockStorageDriver Kernel Telemetry", icon: "waveform.path.ecg", iconColor: .orange) {
                        if snap.statsValid {
                            VStack(spacing: 6) {
                                smartAttributeRow(id: "IO-1", name: "Session Bytes Read / Written", raw: "\(formatBytes(snap.sessionBytesRead)) Read / \(formatBytes(snap.sessionBytesWritten)) Written", status: "Active", isGood: true)
                                smartAttributeRow(id: "IO-2", name: "Session Read / Write Operations", raw: "\(snap.operationsRead) R / \(snap.operationsWritten) W ops", status: "Active", isGood: true)
                                smartAttributeRow(id: "IO-3", name: "Average Driver I/O Latency", raw: String(format: "%.2f ms Read / %.2f ms Write", snap.avgReadLatencyMs, snap.avgWriteLatencyMs), status: max(snap.avgReadLatencyMs, snap.avgWriteLatencyMs) < 50.0 ? "Nominal" : "Elevated", isGood: max(snap.avgReadLatencyMs, snap.avgWriteLatencyMs) < 50.0)
                                smartAttributeRow(id: "IO-4", name: "Kernel Driver Read / Write Errors", raw: "\(snap.errorsRead) Read / \(snap.errorsWritten) Write", status: (snap.errorsRead + snap.errorsWritten) == 0 ? "0 Errors" : "ALERT", isGood: (snap.errorsRead + snap.errorsWritten) == 0)
                                smartAttributeRow(id: "IO-5", name: "Kernel Driver Read / Write Retries", raw: "\(snap.retriesRead) Read / \(snap.retriesWritten) Write", status: "\(snap.retriesRead + snap.retriesWritten)", isGood: (snap.retriesRead + snap.retriesWritten) == 0)
                            }
                        } else {
                            Text("Kernel block storage driver statistics unavailable for this device.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
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

    private func smartAttributeRow(id: String, name: String, raw: String, status: String, isGood: Bool) -> some View {
        HStack(spacing: 10) {
            Text(id)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 220, alignment: .leading)
            Text(raw)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            Text(status)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundColor(isGood ? .green : .red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill((isGood ? Color.green : Color.red).opacity(0.14)))
        }
        .padding(.vertical, 2)
    }
}
