import SwiftUI

/// Severity of a banner. One pattern replaces the five different warning and
/// error styles that had accumulated (red caption+triangle, yellow
/// caption+triangle, orange text, emoji prefixes, HUD orange triangle).
enum BannerSeverity {
    case info
    case warning
    case error
    case success

    var symbolName: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: return UITokens.Palette.secondary
        case .warning: return UITokens.Palette.warning
        case .error: return UITokens.Palette.error
        case .success: return UITokens.Palette.ok
        }
    }
}

/// Inline status line: SF Symbol plus text, both tinted by severity.
struct SeverityBanner: View {
    let severity: BannerSeverity
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UITokens.Space.xs) {
            Image(systemName: severity.symbolName)
                .foregroundStyle(severity.tint)
            Text(message)
                .foregroundStyle(severity.tint)
                .multilineTextAlignment(.leading)
        }
        .font(UITokens.Typography.secondary)
    }
}
