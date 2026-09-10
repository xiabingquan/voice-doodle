import SwiftUI

/// Single source of truth for what a permission status *means*: SF Symbol,
/// colour, and default Chinese caption. Both dashboard and onboarding render
/// from this.
enum PermissionState {
    case granted
    case denied

    var symbolName: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .granted: return UITokens.Palette.ok
        case .denied: return UITokens.Palette.error
        }
    }

    var caption: String {
        switch self {
        case .granted: return "已授权"
        case .denied: return "未授权"
        }
    }
}
