// ============================================================================
// File: GeneralSettingsTab.swift
// Module: Layer 4 (Presentation / Settings Tabs)
// Purpose: General configuration tab managing target disk selection, multi-disk
//          monitoring toggle, subpaths, and background launchd daemon setup.
// Concurrency: Main thread (@MainActor / SwiftUI view graph).
// ============================================================================

import SwiftUI
import AppKit

/// Preference tab managing drive targets, background launchd agent, and polling interval.
struct GeneralSettingsTab: View {
    @ObservedObject var configMgr: ConfigManager
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard(title: "Monitored Storage Target", icon: "externaldrive.fill.badge.checkmark", iconColor: .blue) {
                    SettingsRow(
                        title: "Monitor All Connected Disks",
                        subtitle: "Automatically detect and monitor hardware health for all internal SSDs and external storage devices simultaneously."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { configMgr.config.monitorAllDisks },
                            set: { val in
                                configMgr.setMonitorAllDisks(val)
                                DispatchQueue.global(qos: .userInitiated).async {
                                    _ = DiskHealthMonitor.shared.evaluateAllMonitoredDisks(forceCanary: false, allowNotifications: false)
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    if !configMgr.config.monitorAllDisks {
                        Divider()

                        SettingsRow(
                            title: "Target Drive or Volume",
                            subtitle: "Choose a specific physical disk, mounted volume, or automatic external detection."
                        ) {
                            Picker("", selection: Binding(
                                get: {
                                    if let v = configMgr.config.targetVolumePath, !v.isEmpty { return v }
                                    if let d = configMgr.config.targetDeviceQuery, !d.isEmpty { return d }
                                    return "auto"
                                },
                                set: { newVal in
                                    if newVal == "auto" {
                                        DiskHealthMonitor.shared.setMonitoredTarget(volumePath: nil, deviceQuery: nil)
                                    } else if newVal.hasPrefix("/") {
                                        DiskHealthMonitor.shared.setMonitoredTarget(volumePath: newVal, deviceQuery: nil)
                                    } else {
                                        DiskHealthMonitor.shared.setMonitoredTarget(volumePath: nil, deviceQuery: newVal)
                                    }
                                }
                            )) {
                                Text("Auto-detect First External Volume").tag("auto")
                                Divider()
                                ForEach(viewModel.availableDisks, id: \.id) { disk in
                                    Text(disk.name).tag(disk.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 260)
                        }
                    }
                }

                SettingsCard(title: "Sampling & Active Health Probes", icon: "waveform.path.ecg", iconColor: .green) {
                    SettingsSliderRow(
                        title: "Background Poll Interval",
                        subtitle: "S.M.A.R.T. & I/O telemetry refresh rate",
                        value: Binding(
                            get: { configMgr.config.pollIntervalSeconds },
                            set: { val in configMgr.updateConfig { $0.pollIntervalSeconds = val } }
                        ),
                        range: 10...300,
                        step: 5,
                        formattedValue: "\(Int(configMgr.config.pollIntervalSeconds))s",
                        badgeColor: .blue
                    )

                    Divider()

                    SettingsRow(
                        title: "Active Filesystem Canary Probe",
                        subtitle: "Periodically writes and verifies a test marker (.disk_health_canary) to measure I/O latency and detect APFS freezes."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { configMgr.config.enableActiveCanary },
                            set: { val in configMgr.updateConfig { $0.enableActiveCanary = val } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsRow(
                        title: "Scheduled Background Volume Verification",
                        subtitle: "Automatically run non-destructive diskutil verifyVolume checks in the background."
                    ) {
                        Picker("", selection: Binding(
                            get: { configMgr.config.scheduledVerifyIntervalHours },
                            set: { val in configMgr.updateConfig { $0.scheduledVerifyIntervalHours = val } }
                        )) {
                            Text("Manual Only (Disabled)").tag(0)
                            Text("Every 24 Hours (Daily)").tag(24)
                            Text("Every 7 Days (Weekly)").tag(168)
                            Text("Every 30 Days (Monthly)").tag(720)
                        }
                        .labelsHidden()
                        .frame(width: 210)
                    }
                }

                SettingsCard(title: "System Startup & Background Service", icon: "power.circle.fill", iconColor: .purple) {
                    SettingsRow(
                        title: "macOS LaunchAgent Service",
                        subtitle: viewModel.launchAgentInstalled
                            ? "Active — Disk Health Monitor starts automatically when you log in."
                            : "Not installed — application only runs when launched manually."
                    ) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(viewModel.launchAgentInstalled ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Button(viewModel.launchAgentInstalled ? "Uninstall Service" : "Register Service") {
                                viewModel.toggleLaunchAgent()
                            }
                            .controlSize(.regular)
                            .disabled(viewModel.isUpdatingLaunchAgent)
                        }
                    }
                }
            }
            .padding(8)
        }
        .onAppear {
            viewModel.refreshDiskList()
            viewModel.checkLaunchAgent()
        }
    }
}
