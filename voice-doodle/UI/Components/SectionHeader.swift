import SwiftUI

/// Group heading with an optional SF Symbol. Used as a Form `Section`
/// header in settings and dashboard.
struct SectionHeader: View {
    let title: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: UITokens.Space.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(UITokens.Palette.secondary)
            }
            Text(title)
        }
        .font(UITokens.Typography.sectionHeader)
        .foregroundStyle(UITokens.Palette.secondary)
    }
}
