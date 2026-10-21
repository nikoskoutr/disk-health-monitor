import SwiftUI
import AppKit

struct NotificationsSettingsTab: View {
    @ObservedObject var configMgr: ConfigManager
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: "macOS Notification Center", icon: "bell.badge.fill", iconColor: .red) {
                    SettingsRow(
                        title: "Enable Desktop Alert Banners",
                        subtitle: "Deliver native macOS alerts when drive health transitions to Warning, Critical, or Recovered."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { configMgr.config.enableNativeNotifications },
                            set: { val in configMgr.updateConfig { $0.enableNativeNotifications = val } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsRow(
                        title: "Audible System Beep on Critical Faults",
                        subtitle: "Play a native macOS alert sound immediately when a Critical hardware or thermal fault occurs."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { configMgr.config.enableCriticalSoundAlert },
                            set: { val in configMgr.updateConfig { $0.enableCriticalSoundAlert = val } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }

                SettingsCard(title: "Telegram Bot Integration", icon: "paperplane.fill", iconColor: .blue) {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Telegram Bot Token")
                                .font(.system(size: 13, weight: .medium))
                            Text("Encrypted in macOS Keychain")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 175, alignment: .leading)

                        HStack(spacing: 6) {
                            if viewModel.showToken {
                                TextField("123456789:ABCDEF...", text: Binding(
                                    get: { viewModel.botToken },
                                    set: { val in viewModel.updateBotToken(val) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            } else {
                                SecureField("Enter Bot Token from @BotFather", text: Binding(
                                    get: { viewModel.botToken },
                                    set: { val in viewModel.updateBotToken(val) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            }

                            Button(action: { viewModel.showToken.toggle() }) {
                                Image(systemName: viewModel.showToken ? "eye.slash.fill" : "eye.fill")
                                    .foregroundColor(.secondary)
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.borderless)
                            .help(viewModel.showToken ? "Hide Bot Token" : "Reveal Bot Token")
                        }
                    }

                    Divider()

                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Telegram Chat ID")
                                .font(.system(size: 13, weight: .medium))
                            Text("Target user or channel ID")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 175, alignment: .leading)

                        TextField("e.g. 123456789 or -100...", text: Binding(
                            get: { configMgr.config.telegramChatId.isEmpty ? configMgr.resolvedTelegramChatId : configMgr.config.telegramChatId },
                            set: { val in configMgr.updateConfig { $0.telegramChatId = val } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    }

                    Divider()

                    SettingsRow(
                        title: "Daily Morning Health Digest (09:00)",
                        subtitle: "Automatically send a silent daily status summary every morning at 09:00 local time."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { DiskHealthMonitor.shared.dailySummaryEnabled },
                            set: { val in DiskHealthMonitor.shared.dailySummaryEnabled = val }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsRow(
                        title: "Verify Telegram Delivery",
                        subtitle: "Send an immediate test notification to confirm your Bot Token and Chat ID."
                    ) {
                        Button(action: { viewModel.runTelegramTest() }) {
                            HStack(spacing: 6) {
                                if viewModel.isTestingTelegram {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "paperplane.fill")
                                }
                                Text("Send Test Message")
                            }
                            .padding(.horizontal, 4)
                        }
                        .disabled(viewModel.isTestingTelegram || viewModel.botToken.isEmpty || configMgr.resolvedTelegramChatId.isEmpty)
                    }

                    if let result = viewModel.testResult {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: viewModel.testSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(viewModel.testSuccess ? .green : .red)
                            Text(result)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(viewModel.testSuccess ? .primary : .red)
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill((viewModel.testSuccess ? Color.green : Color.red).opacity(0.12))
                        )
                    }
                }

                SettingsCard(title: "Webhook & Custom Script Automation", icon: "network", iconColor: .purple) {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Webhook Endpoint URL")
                                .font(.system(size: 13, weight: .medium))
                            Text("Discord, Slack, ntfy, or JSON")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 175, alignment: .leading)

                        HStack(spacing: 6) {
                            if viewModel.showWebhookUrl {
                                TextField("https://discord.com/api/webhooks/...", text: Binding(
                                    get: { viewModel.webhookUrl },
                                    set: { val in viewModel.updateWebhookUrl(val) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            } else {
                                SecureField("https://...", text: Binding(
                                    get: { viewModel.webhookUrl },
                                    set: { val in viewModel.updateWebhookUrl(val) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            }

                            Button(action: { viewModel.showWebhookUrl.toggle() }) {
                                Image(systemName: viewModel.showWebhookUrl ? "eye.slash.fill" : "eye.fill")
                                    .foregroundColor(.secondary)
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.borderless)

                            Button(action: { viewModel.runWebhookTest() }) {
                                if viewModel.isTestingWebhook {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Test")
                                }
                            }
                            .disabled(viewModel.isTestingWebhook || viewModel.webhookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if let hookRes = viewModel.webhookTestResult {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: viewModel.webhookTestSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(viewModel.webhookTestSuccess ? .green : .red)
                            Text(hookRes)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(viewModel.webhookTestSuccess ? .primary : .red)
                                .lineLimit(2)
                            Spacer()
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill((viewModel.webhookTestSuccess ? Color.green : Color.red).opacity(0.12))
                        )
                    }

                    Divider()

                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Alert Hook Script Path")
                                .font(.system(size: 13, weight: .medium))
                            Text("Executed on alert / recovery")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 175, alignment: .leading)

                        HStack(spacing: 6) {
                            TextField("/usr/local/bin/on-disk-alert.sh", text: Binding(
                                get: { configMgr.config.alertScriptPath },
                                set: { val in configMgr.updateConfig { $0.alertScriptPath = val } }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                            Button("Browse...") {
                                viewModel.browseAlertScriptAction()
                            }

                            Button(action: { viewModel.runAlertScriptTest() }) {
                                if viewModel.isTestingAlertScript {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Test")
                                }
                            }
                            .disabled(viewModel.isTestingAlertScript || configMgr.config.alertScriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if let scriptRes = viewModel.alertScriptTestResult {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: viewModel.alertScriptTestSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(viewModel.alertScriptTestSuccess ? .green : .red)
                            Text(scriptRes)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(viewModel.alertScriptTestSuccess ? .primary : .red)
                                .lineLimit(3)
                            Spacer()
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill((viewModel.alertScriptTestSuccess ? Color.green : Color.red).opacity(0.12))
                        )
                    }
                }
            }
            .padding(8)
        }
        .onAppear {
            viewModel.botToken = configMgr.resolvedTelegramBotToken
            viewModel.webhookUrl = configMgr.resolvedWebhookUrl
        }
        .onDisappear {
            viewModel.commitBotTokenNow(viewModel.botToken)
            viewModel.commitWebhookUrlNow(viewModel.webhookUrl)
        }
    }
}
