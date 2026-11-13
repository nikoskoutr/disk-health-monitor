// ============================================================================
// File: SettingsComponents.swift
// Module: Layer 4 (Presentation / Settings UI)
// Purpose: Reusable SwiftUI styling components (SettingsCard, MetricPill, FormRow)
//          providing consistent macOS design language across all preference tabs.
// Concurrency: Main thread (@MainActor / SwiftUI view graph).
// ============================================================================

import SwiftUI
import AppKit

// MARK: - Reusable Settings UI Components

/// Standardized card container grouping related preference controls.
struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    let content: Content

    init(title: String, icon: String, iconColor: Color = .accentColor, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(iconColor)
                    .frame(width: 16)
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                content
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    let control: Control

    init(title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

struct SettingsSliderRow: View {
    let title: String
    let subtitle: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formattedValue: String
    let badgeColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 205, alignment: .leading)

            Slider(
                value: Binding(
                    get: { value },
                    set: { rawVal in
                        let stepped = (rawVal / step).rounded() * step
                        let clamped = min(range.upperBound, max(range.lowerBound, stepped))
                        if clamped != value {
                            value = clamped
                        }
                    }
                ),
                in: range
            )
            .frame(maxWidth: .infinity)

            Text(formattedValue)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(badgeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(width: 64, alignment: .center)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(badgeColor.opacity(0.14))
                )
        }
    }
}

/// Shared attribute row rendered across SMART registers, kernel driver stats, and PHY telemetry.
struct SmartAttributeRow: View {
    let id: String
    let name: String
    let raw: String
    let status: String
    let isGood: Bool
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            Text(id)
                .font(.system(size: compact ? 10 : 10.5, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: compact ? 22 : 34, alignment: .leading)
            Text(name)
                .font(.system(size: compact ? 11 : 12, weight: compact ? .regular : .medium))
                .frame(width: compact ? nil : 220, alignment: .leading)
            if compact {
                Spacer()
                Text(raw)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isGood ? .primary : .red)
                Circle()
                    .fill(isGood ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
            } else {
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
        }
        .padding(.vertical, 2)
    }
}

/// Shared NVMe / S.M.A.R.T. register table reused across SmartInspectorTab and StatisticsAndInsightsTab.
struct SmartAttributesTableView: View {
    let disk: DiskHealthSnapshot
    let warningTempC: Int
    var compact: Bool = false

    var body: some View {
        if disk.smartValid {
            VStack(spacing: compact ? 5 : 6) {
                row(id: "01", name: "Critical Warning Byte", raw: String(format: "0x%02X", disk.criticalWarning), status: disk.criticalWarning == 0 ? "OK" : "ALERT", isGood: disk.criticalWarning == 0)
                row(id: "02", name: "Composite Temperature", raw: disk.temperatureKelvin > 0 ? "\(disk.temperatureCelsius) °C (\(disk.temperatureKelvin) K) • Peak: \(disk.peakTemperatureCelsius) °C" : "\(disk.temperatureCelsius) °C • Peak: \(disk.peakTemperatureCelsius) °C", status: "\(disk.temperatureCelsius)°C", isGood: disk.temperatureCelsius < warningTempC)
                row(id: "03", name: "Available Spare Capacity", raw: "\(disk.availableSpare)% (Threshold: \(disk.availableSpareThreshold)%)", status: "\(disk.availableSpare)%", isGood: disk.availableSpare > disk.availableSpareThreshold)
                row(id: "04", name: "Percentage Used (Wear Indicator)", raw: "\(disk.percentageUsed)% Used (\(disk.lifeRemainingPercent)% Remaining)", status: "\(disk.lifeRemainingPercent)% Left", isGood: disk.percentageUsed < 80)
                row(id: "05", name: "Data Units Read (512B x 1000)", raw: String(format: "%llu units (%.2f TB)", disk.dataUnitsRead, disk.totalTerabytesRead), status: "Info", isGood: true)
                row(id: "06", name: "Data Units Written (TBW)", raw: String(format: "%llu units (%.2f TB)", disk.dataUnitsWritten, disk.totalTerabytesWritten), status: "Info", isGood: true)
                row(id: "07", name: "Host Read Commands", raw: "\(disk.hostReadCommands)", status: "Info", isGood: true)
                row(id: "08", name: "Host Write Commands", raw: "\(disk.hostWriteCommands)", status: "Info", isGood: true)
                row(id: "09", name: "Controller Busy Time", raw: "\(disk.controllerBusyTime) min", status: "Info", isGood: true)
                row(id: "0A", name: "Power Cycles", raw: "\(disk.powerCycles) cycles", status: "Info", isGood: true)
                row(id: "0B", name: "Power-On Hours (POH)", raw: "\(disk.powerOnHours) hours (\(disk.powerOnHours / 24) days)", status: "Info", isGood: true)
                row(id: "0C", name: "Unsafe Shutdowns", raw: "\(disk.unsafeShutdowns) events", status: disk.unsafeShutdowns == 0 ? "0" : "\(disk.unsafeShutdowns)", isGood: true)
                row(id: "0D", name: "Media & Data Integrity Errors", raw: "\(disk.mediaErrors) errors", status: disk.mediaErrors == 0 ? "0 Errors" : "FAIL", isGood: disk.mediaErrors == 0)
                row(id: "0E", name: "Error Information Log Entries", raw: "\(disk.errorInfoLogEntries) entries", status: "\(disk.errorInfoLogEntries)", isGood: disk.errorInfoLogEntries == 0)
            }
        } else if disk.hasTemperature {
            VStack(alignment: .leading, spacing: 6) {
                row(id: "02", name: "Apple Silicon / Die Thermal Sensor", raw: "\(disk.temperatureCelsius) °C • Peak: \(disk.peakTemperatureCelsius) °C", status: "\(disk.temperatureCelsius)°C", isGood: disk.temperatureCelsius < warningTempC)
                Text("Full NVMe S.M.A.R.T. registers are unavailable on this bus/bridge (\(disk.interconnectType)). Die thermal monitoring and kernel I/O stats remain active.")
                    .font(.system(size: compact ? 11 : 12))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        } else {
            Text("Hardware S.M.A.R.T. telemetry is not supported on this bus/bridge (\(disk.interconnectType)). Kernel I/O statistics and active filesystem probes remain active.")
                .font(.system(size: compact ? 11 : 12))
                .foregroundColor(.secondary)
                .padding(.vertical, compact ? 4 : 6)
        }
    }

    @ViewBuilder
    private func row(id: String, name: String, raw: String, status: String, isGood: Bool) -> some View {
        SmartAttributeRow(id: id, name: name, raw: raw, status: status, isGood: isGood, compact: compact)
    }
}
