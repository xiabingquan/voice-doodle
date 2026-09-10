import SwiftUI

/// Press feedback for dashboard rows: dims while held, restores on release.
/// Every row is a control — clickability comes from press response plus the
/// trailing indicator.
struct PressFeedbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// A whole-row control: title left, value/indicator right, entire width is
/// the hit target. `font` applies to the leading title; defaults to
/// `rowTitle` so both sides share one size.
struct PressableRow<Trailing: View>: View {
    let title: String
    var font: Font = UITokens.Typography.rowTitle
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: UITokens.Space.sm) {
                Text(title).font(font)
                Spacer()
                trailing()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedbackStyle())
    }
}
