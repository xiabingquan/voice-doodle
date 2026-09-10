import SwiftUI

/// Semantic design tokens. System-native only: every value maps to a system
/// semantic — SF Symbols, system materials, system fonts, no custom palette.
enum UITokens {

    /// Spacing scale.
    enum Space {
        /// Inside a badge, between an icon and its label.
        static let xs: CGFloat = 4
        /// Between controls, within a row.
        static let sm: CGFloat = 8
        /// Between related rows.
        static let md: CGFloat = 12
        /// Between groups, form breathing room.
        static let lg: CGFloat = 16
        /// Horizontal inset for onboarding step copy.
        static let onboardingInset: CGFloat = 16
    }

    /// Type scale. All system text styles, named by role.
    /// (Not named `Type` — that collides with Swift's `foo.Type` metatype syntax.)
    enum Typography {
        static let sectionHeader = Font.caption.weight(.semibold)
        /// Font for grouped-Form row titles. Shared by both sides of a row
        /// so one row never carries two type sizes.
        static let rowTitle = Font.body
        static let secondary = Font.caption
        static let stepTitle = Font.title3.weight(.semibold)
        static let display = Font.title2.weight(.semibold)
    }

    /// Semantic colours. All system semantic colours.
    enum Palette {
        static let primary = Color.primary
        static let secondary = Color.secondary
        static let accent = Color.accentColor
        static let ok = Color.green
        /// Warning colour. macOS expresses warnings in orange — the menu-bar
        /// disabled icon is likewise `systemOrange`. System `.yellow` is
        /// nearly unreadable on light backgrounds and unfit for banner text.
        static let warning = Color.orange
        static let error = Color.red
        /// Hairline separators and control borders.
        static let separator = Color.secondary.opacity(0.25)
    }

    /// Fixed dimensions kept consistent across surfaces.
    enum Metric {
        static let dashboardWidth: CGFloat = 360
        /// Wizard window: 400×360 fits one-item-per-page content.
        static let onboardingWidth: CGFloat = 400
        static let onboardingHeight: CGFloat = 360
        static let welcomeIcon: CGFloat = 48
    }
}
