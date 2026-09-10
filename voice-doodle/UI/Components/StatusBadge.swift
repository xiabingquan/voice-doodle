import SwiftUI

/// Compact permission status: symbol + caption at a caller-chosen text style.
/// Semantics come from `PermissionState`; the dashboard and onboarding render
/// the same semantics at their own scales rather than inventing symbol pairs.
struct StatusBadge: View {
    let state: PermissionState
    /// Overrides `state.caption` when a surface needs different wording.
    var label: String? = nil
    var font: Font = UITokens.Typography.secondary

    var body: some View {
        HStack(spacing: UITokens.Space.xs) {
            Image(systemName: state.symbolName)
                .foregroundStyle(state.tint)
            Text(label ?? state.caption)
        }
        .font(font)
    }
}
