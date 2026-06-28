import SwiftUI

// MARK: - Pure Token Definitions
//
// These are the raw values. Prefer using the semantic types and modifiers
// in DesignSystem.swift for most UI work.

enum DesignTokens {
    // Spacing scale (in points)
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
        static let xxxl: CGFloat = 24
    }

    // Corner radius scale
    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
        static let xxl: CGFloat = 16
    }

    // Elevation definitions (used by AppShadow in DesignSystem)
    struct Elevation {
        let radius: CGFloat
        let y: CGFloat
        let opacity: Double
    }

    static let subtleElevation = Elevation(radius: 8, y: 1, opacity: 0.08)
    static let cardElevation   = Elevation(radius: 12, y: 2, opacity: 0.10)
    static let floatingElevation = Elevation(radius: 20, y: 4, opacity: 0.18)
}