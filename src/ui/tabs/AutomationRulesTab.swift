// ============================================================================
// File: AutomationRulesTab.swift
// Module: Layer 4 (Presentation / Settings Tabs)
// Purpose: Declarative "When X Happens, Do Y" Automation Rule Builder, Preset
//          Library, Dry-Run Simulator, Process I/O Culprit Monitor, and Audit Log.
// Concurrency: Main thread (@MainActor / SwiftUI view graph); background execution.
// ============================================================================

import SwiftUI
import AppKit

/// Preference tab managing declarative "When [Trigger] on [Scope] -> Do [Action]" rules,
/// live Darwin `<libproc.h>` process I/O sampling, and rule execution audit history.
struct AutomationRulesTab: View {
    @ObservedObject var configMgr: ConfigManager
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var monitor: DiskHealthMonitor

    private let cooldownOptions: [(label: String, seconds: TimeInterval)] = [
        ("1 minute", 60),
        ("5 minutes", 300),
        ("15 minutes", 900),
        ("30 minutes", 1800),
        ("1 hour", 3600),
        ("4 hours", 14400),
        ("24 hours", 86400)
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                // 1. Master Header & Preset Templates
                engineHeaderCard

                // 2. Interactive Rule Editor (when creating or editing a rule)
                if viewModel.isEditingAutomationRule {
                    ruleEditorCard
                }

                // 3. Configured Rules List
                rulesListCard

                // 4. Live Process Disk I/O Culprit Detector
                processIoCulpritCard

                // 5. Execution & Dry-Run Audit Log
                auditLogCard
            }
            .padding(.bottom, 16)
        }
        .onAppear {
            if viewModel.topIoCulprits.isEmpty {
                sampleIoProcessesNow()
            }
        }
    }

    // MARK: - 1. Master Header Card

    @ViewBuilder
    private var engineHeaderCard: some View {
        SettingsCard(title: "Rule-Based Automation Engine (\"When X Happens, Do Y\")", icon: "bolt.shield.fill", iconColor: .purple) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Enable Automated Remediation & Action Rules")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Evaluates triggers, drive scopes, poll hysteresis, and safety guards on every background poll cycle.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { configMgr.config.enableActionRulesEngine },
                        set: { val in configMgr.updateConfig { $0.enableActionRulesEngine = val } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                Divider()

                HStack(spacing: 10) {
                    Button(action: {
                        viewModel.draftAutomationRule = ActionRule(
                            id: UUID().uuidString,
                            name: "Custom Rule #\(configMgr.config.actionRules.count + 1)",
                            isEnabled: true,
                            scope: .externalOnly,
                            triggerMetric: .temperatureCelsius,
                            conditionOperator: .greaterThanOrEqual,
                            thresholdValue: 65.0,
                            targetIssueCode: "TEMP_CRITICAL",
                            requiredConsecutivePolls: 2,
                            cooldownSeconds: 1800.0,
                            actionType: .sendNotification
                        )
                        viewModel.editingAutomationRuleId = nil
                        viewModel.isEditingAutomationRule = true
                    }) {
                        Label("New Rule...", systemImage: "plus.circle.fill")
                    }

                    Menu {
                        ForEach(ActionRule.defaultStarterRules) { preset in
                            Button(action: {
                                addPresetRule(preset)
                            }) {
                                Text("\(preset.name) (\(preset.actionType.shortBadgeTitle))")
                            }
                        }
                        Divider()
                        Button("Restore Default Starter Rules") {
                            configMgr.updateConfig {
                                $0.actionRules = ActionRule.defaultStarterRules
                            }
                        }
                    } label: {
                        Label("Add Preset Template", systemImage: "sparkles")
                    }

                    Spacer()

                    let enabledCount = configMgr.config.actionRules.filter(\.isEnabled).count
                    Text("\(enabledCount) of \(configMgr.config.actionRules.count) rules active")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }

                if let banner = viewModel.simulationBannerText {
                    HStack(spacing: 8) {
                        Image(systemName: statusIcon(for: viewModel.simulationBannerStatus))
                            .foregroundColor(statusColor(for: viewModel.simulationBannerStatus))
                        Text(banner)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(2)
                        Spacer()
                        Button(action: { viewModel.simulationBannerText = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(statusColor(for: viewModel.simulationBannerStatus).opacity(0.12))
                    )
                }
            }
        }
    }

    // MARK: - 2. Rule Builder / Editor Card

    @ViewBuilder
    private var ruleEditorCard: some View {
        SettingsCard(
            title: viewModel.editingAutomationRuleId == nil ? "Create New Automation Rule" : "Edit Automation Rule",
            icon: "slider.horizontal.below.square.and.square.filled",
            iconColor: .blue
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // Name & Dry-Run Toggle
                HStack(spacing: 12) {
                    Text("Rule Name:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 110, alignment: .leading)
                    TextField("e.g. External SSD Thermal Cutoff", text: $viewModel.draftAutomationRule.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Toggle("Dry-Run Only", isOn: $viewModel.draftAutomationRule.dryRunOnly)
                        .font(.system(size: 11.5))
                        .help("Logs when the rule would fire without executing the live action.")
                }

                // Drive Scope (IF)
                HStack(spacing: 12) {
                    Text("Drive Scope:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 110, alignment: .leading)
                    Picker("", selection: $viewModel.draftAutomationRule.scope) {
                        ForEach(ActionDriveScope.allCases, id: \.self) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)

                    if viewModel.draftAutomationRule.scope == .specificTarget {
                        TextField("BSD (disk4), Mount (/Volumes/SSD), or Serial", text: $viewModel.draftAutomationRule.specificTargetFilter)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                    } else {
                        Spacer()
                    }
                }

                // Trigger Metric (WHEN)
                HStack(spacing: 12) {
                    Text("When Trigger:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 110, alignment: .leading)
                    Picker("", selection: $viewModel.draftAutomationRule.triggerMetric) {
                        ForEach(ActionTriggerMetric.allCases, id: \.self) { metric in
                            Text(metric.displayName).tag(metric)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)

                    if viewModel.draftAutomationRule.triggerMetric == .issueCode {
                        Picker("", selection: $viewModel.draftAutomationRule.targetIssueCode) {
                            ForEach(ActionRuleEngine.knownIssueCodes, id: \.code) { item in
                                Text("\(item.code) — \(item.description)").tag(item.code)
                            }
                        }
                        .labelsHidden()
                    } else if viewModel.draftAutomationRule.triggerMetric == .severityTransition {
                        Picker("", selection: $viewModel.draftAutomationRule.targetIssueCode) {
                            Text("Transitions to CRITICAL").tag("CRITICAL")
                            Text("Transitions to WARNING").tag("WARNING")
                            Text("Recovers to HEALTHY").tag("RECOVERED")
                        }
                        .labelsHidden()
                    } else {
                        Picker("", selection: $viewModel.draftAutomationRule.conditionOperator) {
                            ForEach(ActionConditionOperator.allCases, id: \.self) { op in
                                Text(op.rawValue).tag(op)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 70)

                        TextField("Value", value: $viewModel.draftAutomationRule.thresholdValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 85)
                            .font(.system(size: 12, design: .monospaced))

                        Text(viewModel.draftAutomationRule.triggerMetric.unitSuffix)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                // Hysteresis & Cooldown
                HStack(spacing: 12) {
                    Text("Confirmation:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 110, alignment: .leading)

                    Stepper(
                        "Sustained for \(viewModel.draftAutomationRule.requiredConsecutivePolls) poll\(viewModel.draftAutomationRule.requiredConsecutivePolls == 1 ? "" : "s")",
                        value: $viewModel.draftAutomationRule.requiredConsecutivePolls,
                        in: 1...10
                    )
                    .font(.system(size: 12))
                    .frame(width: 195, alignment: .leading)

                    Text("Cooldown:")
                        .font(.system(size: 12, weight: .semibold))

                    Picker("", selection: $viewModel.draftAutomationRule.cooldownSeconds) {
                        ForEach(cooldownOptions, id: \.seconds) { opt in
                            Text(opt.label).tag(opt.seconds)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)

                    Spacer()
                }

                // Action Type (DO)
                HStack(spacing: 12) {
                    Text("Do Action:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 110, alignment: .leading)
                    Picker("", selection: $viewModel.draftAutomationRule.actionType) {
                        ForEach(ActionExecutionType.allCases, id: \.self) { act in
                            Text(act.displayName).tag(act)
                        }
                    }
                    .labelsHidden()
                }

                if viewModel.draftAutomationRule.actionType.requiresParameter {
                    HStack(spacing: 12) {
                        Text(viewModel.draftAutomationRule.actionType == .runMacShortcut ? "Shortcut Name:" : "Script Path:")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 110, alignment: .leading)
                        TextField(
                            viewModel.draftAutomationRule.actionType == .runMacShortcut ? "e.g. Emergency Drive Alert" : "/Users/you/scripts/on_disk_fault.sh",
                            text: $viewModel.draftAutomationRule.actionParameter
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                        if viewModel.draftAutomationRule.actionType == .runCustomScript {
                            Button("Browse...") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = true
                                panel.canChooseDirectories = false
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    viewModel.draftAutomationRule.actionParameter = url.path
                                }
                            }
                        }
                    }
                }

                if viewModel.draftAutomationRule.actionType.isMutatingMountAction {
                    HStack(spacing: 6) {
                        Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                            .foregroundColor(.orange)
                        Text("Safety Guard Active: Root '/' and internal macOS system drives are automatically protected from unmount/eject/read-only actions.")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                HStack {
                    Button("Cancel") {
                        viewModel.isEditingAutomationRule = false
                        viewModel.editingAutomationRuleId = nil
                    }
                    Spacer()
                    Button("Test / Dry-Run Draft") {
                        let rec = monitor.simulateActionRule(viewModel.draftAutomationRule, executeLive: false)
                        viewModel.simulationBannerStatus = rec.status
                        viewModel.simulationBannerText = rec.outputDetail
                    }
                    Button(action: saveDraftRule) {
                        Text(viewModel.editingAutomationRuleId == nil ? "Add Rule" : "Save Changes")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.draftAutomationRule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - 3. Configured Rules List Card

    @ViewBuilder
    private var rulesListCard: some View {
        SettingsCard(title: "Configured Automation Rules", icon: "list.bullet.indent", iconColor: .indigo) {
            if configMgr.config.actionRules.isEmpty {
                Text("No automation rules configured. Click 'New Rule...' or 'Add Preset Template' above.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 10) {
                    ForEach(configMgr.config.actionRules) { rule in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center, spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { rule.isEnabled },
                                    set: { val in
                                        configMgr.updateConfig { cfg in
                                            if let idx = cfg.actionRules.firstIndex(where: { $0.id == rule.id }) {
                                                cfg.actionRules[idx].isEnabled = val
                                            }
                                        }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(rule.name)
                                            .font(.system(size: 12.5, weight: .bold))
                                            .foregroundColor(rule.isEnabled ? .primary : .secondary)
                                        if rule.dryRunOnly {
                                            Text("DRY-RUN")
                                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.orange.opacity(0.2))
                                                .foregroundColor(.orange)
                                                .cornerRadius(4)
                                        }
                                    }

                                    // Declarative sentence badges: WHEN [...] ON [...] -> DO [...]
                                    HStack(spacing: 5) {
                                        ruleTokenBadge(prefix: "WHEN", text: rule.conditionSummary, color: .orange)
                                        ruleTokenBadge(prefix: "ON", text: rule.scope.displayName, color: .blue)
                                        if rule.requiredConsecutivePolls > 1 {
                                            ruleTokenBadge(prefix: "FOR", text: "\(rule.requiredConsecutivePolls) polls", color: .secondary)
                                        }
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.secondary)
                                        ruleTokenBadge(prefix: "DO", text: rule.actionType.shortBadgeTitle, color: .purple)
                                    }
                                }

                                Spacer()

                                HStack(spacing: 6) {
                                    Button(action: {
                                        let rec = monitor.simulateActionRule(rule, executeLive: false)
                                        viewModel.simulationBannerStatus = rec.status
                                        viewModel.simulationBannerText = rec.outputDetail
                                    }) {
                                        Text("Simulate")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .controlSize(.small)
                                    .help("Simulate a matching telemetry snapshot in Dry-Run mode.")

                                    Button(action: {
                                        viewModel.draftAutomationRule = rule
                                        viewModel.editingAutomationRuleId = rule.id
                                        viewModel.isEditingAutomationRule = true
                                    }) {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 11))
                                    }
                                    .controlSize(.small)
                                    .help("Edit rule")

                                    Button(action: {
                                        configMgr.updateConfig { cfg in
                                            cfg.actionRules.removeAll { $0.id == rule.id }
                                        }
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 11))
                                            .foregroundColor(.red)
                                    }
                                    .controlSize(.small)
                                    .help("Delete rule")
                                }
                            }

                            if rule.id != configMgr.config.actionRules.last?.id {
                                Divider().padding(.top, 2)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 4. Live Process Disk I/O Culprit Detector Card

    @ViewBuilder
    private var processIoCulpritCard: some View {
        SettingsCard(title: "Active Process Disk I/O Culprit Detector (Darwin libproc)", icon: "waveform.path.ecg.rectangle.fill", iconColor: .teal) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top Processes Reading & Writing to Storage")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Samples per-process kernel rusage_info_v4 disk I/O counters to pinpoint runaway background writers.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: sampleIoProcessesNow) {
                        HStack(spacing: 5) {
                            if viewModel.isSamplingIoProcesses {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("Sample Active I/O")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                    }
                    .disabled(viewModel.isSamplingIoProcesses)
                }

                if viewModel.topIoCulprits.isEmpty {
                    Text("Click 'Sample Active I/O' to inspect process disk activity.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                } else {
                    Divider()
                    VStack(spacing: 4) {
                        HStack {
                            Text("PID")
                                .frame(width: 55, alignment: .leading)
                            Text("PROCESS")
                                .frame(width: 190, alignment: .leading)
                            Text("LIVE READ / WRITE")
                                .frame(width: 170, alignment: .leading)
                            Spacer()
                            Text("CUMULATIVE DISK I/O")
                        }
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)

                        ForEach(viewModel.topIoCulprits) { proc in
                            HStack {
                                Text("\(proc.pid)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 55, alignment: .leading)
                                Text(proc.processName)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1)
                                    .frame(width: 190, alignment: .leading)
                                Text(String(format: "R %.2f / W %.2f MB/s", proc.readMBps, proc.writeMBps))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(proc.combinedMBps >= 1.0 ? .orange : .primary)
                                    .frame(width: 170, alignment: .leading)
                                Spacer()
                                Text("R \(formatBytes(proc.totalBytesRead)) • W \(formatBytes(proc.totalBytesWritten))")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 5. Execution & Dry-Run Audit Log Card

    @ViewBuilder
    private var auditLogCard: some View {
        SettingsCard(title: "Automation Rule Execution Audit Log", icon: "clock.arrow.circlepath", iconColor: .orange) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent Rule Triggers & Dry-Run Simulations")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if !monitor.publishedActionLog.isEmpty {
                        Button("Clear History") {
                            monitor.clearActionAuditLog()
                        }
                        .controlSize(.small)
                    }
                }

                if monitor.publishedActionLog.isEmpty {
                    Text("No automation actions have fired yet. Click 'Simulate' on any rule above to test its trigger and action.")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    Divider()
                    VStack(spacing: 6) {
                        ForEach(monitor.publishedActionLog.prefix(12)) { rec in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(rec.status.rawValue)
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(statusColor(for: rec.status).opacity(0.18))
                                        .foregroundColor(statusColor(for: rec.status))
                                        .cornerRadius(4)

                                    Text(rec.ruleName)
                                        .font(.system(size: 11.5, weight: .bold))

                                    Text("• \(rec.driveDisplayName)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)

                                    Spacer()

                                    Text(rec.formattedTime)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Text("\(rec.triggerReason) — \(rec.outputDetail)")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func saveDraftRule() {
        var cleaned = viewModel.draftAutomationRule
        cleaned.name = cleaned.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.name.isEmpty else { return }

        configMgr.updateConfig { cfg in
            if let existingId = viewModel.editingAutomationRuleId,
               let idx = cfg.actionRules.firstIndex(where: { $0.id == existingId }) {
                cfg.actionRules[idx] = cleaned
            } else {
                cfg.actionRules.append(cleaned)
            }
        }
        viewModel.isEditingAutomationRule = false
        viewModel.editingAutomationRuleId = nil
    }

    private func addPresetRule(_ preset: ActionRule) {
        var copy = preset
        copy.id = "\(preset.id)-\(Int(Date().timeIntervalSince1970))"
        copy.isEnabled = true
        configMgr.updateConfig { cfg in
            cfg.actionRules.append(copy)
        }
    }

    private func sampleIoProcessesNow() {
        guard !viewModel.isSamplingIoProcesses else { return }
        viewModel.isSamplingIoProcesses = true
        let vm = viewModel
        DispatchQueue.global(qos: .userInitiated).async {
            let sampled = ProcessIoInspector.shared.sampleActiveCulpritsWindow(durationSec: 0.25, topN: 5)
            DispatchQueue.main.async {
                vm.topIoCulprits = sampled
                vm.isSamplingIoProcesses = false
            }
        }
    }

    private func ruleTokenBadge(prefix: String, text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(prefix)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
    }

    private func statusColor(for status: ActionExecutionStatus) -> Color {
        switch status {
        case .succeeded: return .green
        case .dryRun: return .blue
        case .blockedBySafetyGuard: return .orange
        case .failed: return .red
        }
    }

    private func statusIcon(for status: ActionExecutionStatus) -> String {
        switch status {
        case .succeeded: return "checkmark.circle.fill"
        case .dryRun: return "play.circle.fill"
        case .blockedBySafetyGuard: return "shield.lefthalf.filled.badge.checkmark"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}
