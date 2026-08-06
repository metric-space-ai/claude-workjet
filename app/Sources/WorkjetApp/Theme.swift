import SwiftUI

/// Dark, linear, cardless popover theme. System typography, blue system
/// accent, thin dividers, no decorative role icons.
enum WJTheme {
    static let popoverWidth: CGFloat = 470
    static let popoverHeight: CGFloat = 790

    static let background = Color(red: 0.094, green: 0.094, blue: 0.102)
    static let surface = Color.white.opacity(0.055)
    static let surfaceHover = Color.white.opacity(0.09)
    static let divider = Color.white.opacity(0.10)
    static let accent = Color(nsColor: .systemBlue)
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.35)

    static let quotaOK = Color(nsColor: .systemGreen)
    static let quotaWarning = Color(nsColor: .systemYellow)
    static let quotaCritical = Color(nsColor: .systemRed)
}

struct WJDivider: View {
    var body: some View {
        Rectangle()
            .fill(WJTheme.divider)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// Small square button for functional icons only (plus, gear, pencil,
/// close, stop). Always pair with an accessibility label at the call site.
struct WJIconButtonStyle: ButtonStyle {
    var tint: Color = .primary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? WJTheme.surfaceHover : WJTheme.surface)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Independent pill-style choice button (computers in the header, harness
/// and transport choices in editors). Never composed into an enclosing
/// segmented-control shell.
struct WJChoiceButton: View {
    let title: String
    let isSelected: Bool
    var accessibilityLabel: String? = nil
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : WJTheme.secondaryText)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? WJTheme.accent.opacity(0.85) : WJTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isSelected ? WJTheme.accent : WJTheme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(help ?? "")
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

struct WJSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(WJTheme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}
