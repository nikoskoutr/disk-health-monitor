import SwiftUI
import AppKit

// MARK: - Reusable Settings UI Components

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
