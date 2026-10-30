// ============================================================================
// File: SettingsView.swift
// Module: Layer 4 (Presentation / Settings UI)
// Purpose: Multi-tab macOS settings container hosting the 6 modular configuration
//          and inspection views with custom native toolbar navigation.
// Concurrency: Main thread (@MainActor / SwiftUI view graph).
// ============================================================================

import SwiftUI
import AppKit

// MARK: - Native macOS Settings Window Container (Cmd+,)

/// Primary Settings window container hosting 6 modular preference tabs.
struct SettingsView: View {
    @ObservedObject var configMgr = ConfigManager.shared
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var monitor = DiskHealthMonitor.shared

    private let tabs: [(tag: Int, title: String, icon: String)] = [
        (0, "General", "gearshape.fill"),
        (1, "Thresholds", "slider.horizontal.3"),
        (2, "Notifications", "bell.badge.fill"),
        (6, "Automation", "bolt.shield.fill"),
        (3, "S.M.A.R.T.", "cpu.fill"),
        (4, "Statistics", "chart.bar.xaxis"),
        (5, "Diagnostics", "wrench.and.screwdriver.fill")
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
                case 6:
                    AutomationRulesTab(configMgr: configMgr, viewModel: viewModel, monitor: monitor)
                case 3:
                    SmartInspectorTab(monitor: monitor)
                case 4:
                    StatisticsAndInsightsTab(monitor: monitor, configMgr: configMgr, viewModel: viewModel)
                default:
                    DiagnosticsAndExportTab(configMgr: configMgr, viewModel: viewModel, monitor: monitor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 820, height: 700)
    }
}
