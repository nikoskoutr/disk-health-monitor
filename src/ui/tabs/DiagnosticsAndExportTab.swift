// ============================================================================
// File: DiagnosticsAndExportTab.swift
// Module: Layer 4 (Presentation / Settings Tabs)
// Purpose: Diagnostics tab managing JSON/HTML report generation, non-destructive
//          surface scanning controls, volume verification, and log rotation.
// Concurrency: Main thread (@MainActor / SwiftUI view graph).
// ============================================================================

import SwiftUI
import AppKit

/// Preference tab managing diagnostics exports, surface scans, and verification.
struct DiagnosticsAndExportTab: View {
    @ObservedObject var configMgr: ConfigManager
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var monitor: DiskHealthMonitor

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: "Active Storage & Log Locations", icon: "folder.fill", iconColor: .blue) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Configuration File")
                                .font(.system(size: 13, weight: .medium))
                            Text(configMgr.configFilePath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.selectFile(configMgr.configFilePath, inFileViewerRootedAtPath: configMgr.configDir)
                        }) {
                            Text("Reveal in Finder")
                                .frame(width: 128)
                        }
                    }

                    Divider()

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Runtime Logs Directory")
                                .font(.system(size: 13, weight: .medium))
                            Text(configMgr.logsDir)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.open(URL(fileURLWithPath: configMgr.logsDir))
                        }) {
                            Text("Open Logs Folder")
                                .frame(width: 128)
                        }
                    }
                }

                SettingsCard(title: "Configuration & Telemetry Exports", icon: "square.and.arrow.up.fill", iconColor: .green) {
                    SettingsRow(
                        title: "Export Sanitized Configuration",
                        subtitle: "Save a shareable copy of config.json with sensitive tokens masked."
                    ) {
                        Button(action: {
                            viewModel.exportConfigAction()
                        }) {
                            Text("Export Config...")
                                .frame(width: 128)
                        }
                    }

                    Divider()

                    SettingsRow(
                        title: "Import Configuration Profile",
                        subtitle: "Restore configuration settings from an exported JSON profile."
                    ) {
                        Button(action: {
                            viewModel.importConfigAction()
                        }) {
                            Text("Import Config...")
                                .frame(width: 128)
                        }
                    }

                    Divider()

                    SettingsRow(
                        title: "Export Full Diagnostic Report (JSON / HTML)",
                        subtitle: "Generate a JSON diagnostic bundle or standalone HTML RMA report."
                    ) {
                        HStack(spacing: 8) {
                            Button(action: {
                                viewModel.exportDiagnosticReportAction()
                            }) {
                                Text("Export JSON...")
                            }
                            Button(action: {
                                viewModel.exportHtmlReportAction()
                            }) {
                                Text("Export HTML...")
                            }
                        }
                    }

                    Divider()

                    SettingsRow(
                        title: "Inspect Historical Event Log",
                        subtitle: "Open logs/health.log in your default log or text viewer."
                    ) {
                        Button(action: {
                            NSWorkspace.shared.open(URL(fileURLWithPath: configMgr.logFilePath))
                        }) {
                            Text("View Health Log")
                                .frame(width: 128)
                        }
                    }
                }

                SettingsCard(title: "Physical Media Surface Scan", icon: "waveform.path.badge.plus", iconColor: .blue) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Non-Destructive Surface Read Scanner (F_NOCACHE)")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Bypasses unified buffer cache to verify physical flash/media blocks for latent EIO read errors.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if viewModel.isRunningSurfaceScan {
                                Button(action: {
                                    viewModel.cancelSurfaceScanAction()
                                }) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "xmark.circle.fill")
                                        Text("Stop Scan")
                                    }
                                    .foregroundColor(.red)
                                    .frame(width: 132)
                                }
                            } else {
                                Button(action: {
                                    viewModel.runSurfaceScanAction()
                                }) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "play.fill")
                                        Text("Run Surface Scan")
                                    }
                                    .frame(width: 132)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: $viewModel.selectedSurfaceScanMode) {
                                ForEach(DiskHealthMonitor.SurfaceScanMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .disabled(viewModel.isRunningSurfaceScan)

                            Text(viewModel.selectedSurfaceScanMode.modeDescription)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let prog = viewModel.surfaceScanProgress {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(viewModel.isRunningSurfaceScan ? "⚡ Live: \(prog.formattedThroughput)" : "⚡ Avg: \(prog.formattedThroughput)")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text("Files: \(prog.filesScanned) | \(prog.formattedBytesScanned) / \(prog.formattedTargetBytes) (\(prog.formattedPercent))")
                                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    if viewModel.isRunningSurfaceScan, let eta = prog.formattedETA {
                                        Text("• ETA: \(eta)")
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundColor(.blue)
                                    }
                                }

                                ProgressView(value: viewModel.isRunningSurfaceScan ? min(1.0, max(0.0, prog.fractionCompleted)) : 1.0, total: 1.0)
                                    .progressViewStyle(LinearProgressViewStyle())

                                if viewModel.isRunningSurfaceScan && !prog.currentFile.isEmpty {
                                    Text("Reading: \(prog.currentFile)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.07)))
                        }

                        if let summary = viewModel.lastSurfaceScanSummary {
                            HStack(alignment: .center, spacing: 8) {
                                Image(systemName: viewModel.lastSurfaceScanOk ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(viewModel.lastSurfaceScanOk ? .green : .red)
                                Text(summary)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill((viewModel.lastSurfaceScanOk ? Color.green : Color.red).opacity(0.12)))
                        }
                    }
                }

                SettingsCard(title: "File System Integrity Verification", icon: "checkmark.shield.fill", iconColor: .teal) {
                    SettingsRow(
                        title: "Verify Volume File System (diskutil verifyVolume)",
                        subtitle: "Last Status: \(monitor.publishedSnapshot?.lastVerifyResult ?? "Not run yet")"
                    ) {
                        Button(action: {
                            viewModel.runVolumeVerificationAction()
                        }) {
                            HStack(spacing: 6) {
                                if viewModel.isVerifyingVolumeInSettings || monitor.isVerifyingVolume {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Verifying...")
                                } else {
                                    Image(systemName: "checkmark.shield")
                                    Text("Verify Volume")
                                }
                            }
                            .frame(width: 128)
                        }
                        .disabled(viewModel.isVerifyingVolumeInSettings || monitor.isVerifyingVolume)
                    }
                }

                SettingsCard(title: "State & Baseline Maintenance", icon: "arrow.counterclockwise.circle.fill", iconColor: .orange) {
                    SettingsRow(
                        title: "Reset Persistent Baselines",
                        subtitle: "Clear recorded peak temperatures, baseline error counters, and alert cooldown timers."
                    ) {
                        Button(action: {
                            DiskHealthMonitor.shared.resetBaselines()
                            _ = DiskHealthMonitor.shared.evaluateAllMonitoredDisks(forceCanary: false, allowNotifications: false)
                            viewModel.diagnosticsStatusMsg = "Baselines and persistent state reset to clean defaults."
                        }) {
                            Text("Reset Baselines")
                                .frame(width: 128)
                        }
                    }

                    if let msg = viewModel.diagnosticsStatusMsg {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(msg)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.12)))
                    }
                }
            }
            .padding(8)
        }
    }
}
