import SwiftUI
import AppKit

// MARK: - Native macOS Settings Window Container (Cmd+,)

struct SettingsView: View {
    @ObservedObject var configMgr = ConfigManager.shared
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var monitor = DiskHealthMonitor.shared

    private let tabs: [(tag: Int, title: String, icon: String)] = [
        (0, "General", "gearshape.fill"),
        (1, "Thresholds", "slider.horizontal.3"),
        (2, "Notifications", "bell.badge.fill"),
        (3, "S.M.A.R.T.", "cpu.fill"),
        (4, "Diagnostics", "wrench.and.screwdriver.fill")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Custom Native-Style Toolbar Tab Switcher (avoids macOS NSTabView label squishing)
            HStack(spacing: 6) {
                ForEach(tabs, id: \.tag) { tab in
                    let isSelected = (viewModel.selectedTab == tab.tag)
                    Button(action: {
                        viewModel.selectedTab = tab.tag
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12, weight: .semibold))
                            Text(tab.title)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundColor(isSelected ? .white : .primary)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // Active Tab Content
            Group {
                switch viewModel.selectedTab {
                case 0:
                    GeneralSettingsTab(configMgr: configMgr, viewModel: viewModel)
                case 1:
                    ThresholdsSettingsTab(configMgr: configMgr)
                case 2:
                    NotificationsSettingsTab(configMgr: configMgr, viewModel: viewModel)
                case 3:
                    SmartInspectorTab(monitor: monitor)
                default:
                    DiagnosticsAndExportTab(configMgr: configMgr, viewModel: viewModel, monitor: monitor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 700, height: 650)
    }
}
