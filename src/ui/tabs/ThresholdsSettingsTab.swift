import SwiftUI
import AppKit

struct ThresholdsSettingsTab: View {
    @ObservedObject var configMgr: ConfigManager

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsCard(title: "Thermal Thresholds (S.M.A.R.T.)", icon: "thermometer.medium", iconColor: .orange) {
                    SettingsSliderRow(
                        title: "Temperature Warning",
                        subtitle: "Triggers yellow elevated thermal alert",
                        value: Binding(
                            get: { Double(configMgr.config.tempWarningCelsius) },
                            set: { val in
                                let v = Int(val)
                                configMgr.updateConfig {
                                    $0.tempWarningCelsius = v
                                    if v >= $0.tempCriticalCelsius {
                                        $0.tempCriticalCelsius = min(95, v + 1)
                                    }
                                }
                            }
                        ),
                        range: 40...80,
                        step: 1,
                        formattedValue: "\(configMgr.config.tempWarningCelsius)°C",
                        badgeColor: .orange
                    )

                    Divider()

                    SettingsSliderRow(
                        title: "Temperature Critical",
                        subtitle: "Triggers critical overheating alert",
                        value: Binding(
                            get: { Double(configMgr.config.tempCriticalCelsius) },
                            set: { val in
                                let v = Int(val)
                                configMgr.updateConfig {
                                    $0.tempCriticalCelsius = v
                                    if v <= $0.tempWarningCelsius {
                                        $0.tempWarningCelsius = max(40, v - 1)
                                    }
                                }
                            }
                        ),
                        range: 50...95,
                        step: 1,
                        formattedValue: "\(configMgr.config.tempCriticalCelsius)°C",
                        badgeColor: .red
                    )
                }

                SettingsCard(title: "Volume Capacity & Free Space", icon: "internaldrive.fill", iconColor: .blue) {
                    SettingsSliderRow(
                        title: "Disk Used Warning",
                        subtitle: "Warn when volume usage reaches %",
                        value: Binding(
                            get: { configMgr.config.diskUsedWarningPercent },
                            set: { val in
                                configMgr.updateConfig {
                                    $0.diskUsedWarningPercent = val
                                    if val >= $0.diskUsedCriticalPercent {
                                        $0.diskUsedCriticalPercent = min(99.0, val + 1.0)
                                    }
                                }
                            }
                        ),
                        range: 50...98,
                        step: 1,
                        formattedValue: String(format: "%.0f%%", configMgr.config.diskUsedWarningPercent),
                        badgeColor: .orange
                    )

                    Divider()

                    SettingsSliderRow(
                        title: "Disk Used Critical",
                        subtitle: "Critical alert when usage reaches %",
                        value: Binding(
                            get: { configMgr.config.diskUsedCriticalPercent },
                            set: { val in
                                configMgr.updateConfig {
                                    $0.diskUsedCriticalPercent = val
                                    if val <= $0.diskUsedWarningPercent {
                                        $0.diskUsedWarningPercent = max(50.0, val - 1.0)
                                    }
                                }
                            }
                        ),
                        range: 60...99,
                        step: 1,
                        formattedValue: String(format: "%.0f%%", configMgr.config.diskUsedCriticalPercent),
                        badgeColor: .red
                    )

                    Divider()

                    HStack(spacing: 16) {
                        SettingsRow(
                            title: "Min Free Warning",
                            subtitle: "Low space warning floor"
                        ) {
                            HStack(spacing: 6) {
                                Text("\(Int(configMgr.config.minFreeSpaceWarningGB)) GB")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .frame(width: 62, alignment: .center)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.14)))

                                Stepper("", value: Binding(
                                    get: { Int(configMgr.config.minFreeSpaceWarningGB) },
                                    set: { val in
                                        configMgr.updateConfig {
                                            $0.minFreeSpaceWarningGB = Double(val)
                                            if Double(val) <= $0.minFreeSpaceCriticalGB {
                                                $0.minFreeSpaceCriticalGB = max(1.0, Double(val) - 5.0)
                                            }
                                        }
                                    }
                                ), in: 5...250, step: 5)
                                .labelsHidden()
                            }
                        }

                        Divider()
                            .frame(height: 28)

                        SettingsRow(
                            title: "Min Free Critical",
                            subtitle: "Critical space floor"
                        ) {
                            HStack(spacing: 6) {
                                Text("\(Int(configMgr.config.minFreeSpaceCriticalGB)) GB")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .frame(width: 62, alignment: .center)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.14)))

                                Stepper("", value: Binding(
                                    get: { Int(configMgr.config.minFreeSpaceCriticalGB) },
                                    set: { val in
                                        configMgr.updateConfig {
                                            $0.minFreeSpaceCriticalGB = Double(val)
                                            if Double(val) >= $0.minFreeSpaceWarningGB {
                                                $0.minFreeSpaceWarningGB = min(250.0, Double(val) + 5.0)
                                            }
                                        }
                                    }
                                ), in: 1...100, step: 1)
                                .labelsHidden()
                            }
                        }
                    }
                }

                SettingsCard(title: "Hardware Bus & Factory Defaults", icon: "cable.connector.horizontal", iconColor: .teal) {
                    SettingsRow(
                        title: "Minimum Expected USB / Bus Speed",
                        subtitle: "Warn if a cable or hub negotiates below this link rate"
                    ) {
                        Picker("", selection: Binding(
                            get: { configMgr.config.minExpectedUsbSpeedBps },
                            set: { val in configMgr.updateConfig { $0.minExpectedUsbSpeedBps = val } }
                        )) {
                            Text("Disabled (No Speed Check)").tag(UInt64(0))
                            Text("480 Mbps (USB 2.0)").tag(UInt64(480_000_000))
                            Text("5 Gbps (USB 3.0 SuperSpeed)").tag(UInt64(5_000_000_000))
                            Text("10 Gbps (USB 3.2 SuperSpeed+)").tag(UInt64(10_000_000_000))
                            Text("20 Gbps (USB 3.2 2x2 / USB4)").tag(UInt64(20_000_000_000))
                            Text("40 Gbps (Thunderbolt 3/4)").tag(UInt64(40_000_000_000))
                        }
                        .labelsHidden()
                        .frame(width: 235)
                    }

                    Divider()

                    SettingsRow(
                        title: "Factory Default Thresholds",
                        subtitle: "Restore 58°C/68°C thermal limits, 85%/93% capacity limits, and 5 Gbps bus speed"
                    ) {
                        Button("Reset to Defaults") {
                            configMgr.updateConfig {
                                $0.tempWarningCelsius = 58
                                $0.tempCriticalCelsius = 68
                                $0.diskUsedWarningPercent = 85.0
                                $0.diskUsedCriticalPercent = 93.0
                                $0.minFreeSpaceWarningGB = 30.0
                                $0.minFreeSpaceCriticalGB = 15.0
                                $0.minExpectedUsbSpeedBps = 5_000_000_000
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }
}
