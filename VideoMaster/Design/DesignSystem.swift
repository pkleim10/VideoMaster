import SwiftUI

// MARK: - VideoMaster Design System
//
// Single source of truth for the **Cinematic Blue** visual language.
// Opinionated dark-first theme with blue accents, blue gradients,
// and selective Liquid Glass materials (on chrome/panels, not everywhere).
//
// Performance is non-negotiable for large libraries. Grid cells stay relatively cheap.
//
// Usage:
//   .appCard()
//   .appCell(isSelected: isSelected, isHovering: isHovering)
//   Color.appSurface
//   AppSpacing.md
//   AppRadius.cell

// MARK: - Spacing

enum AppSpacing {
    /// 2pt — hairline adjustments
    static let xxs: CGFloat = 2
    /// 4pt — tightest regular spacing
    static let xs: CGFloat = 4
    /// 6pt — small gaps inside cells
    static let sm: CGFloat = 6
    /// 8pt — standard small padding
    static let md: CGFloat = 8
    /// 12pt — comfortable internal spacing
    static let lg: CGFloat = 12
    /// 16pt — standard outer padding
    static let xl: CGFloat = 16
    /// 20pt — generous breathing room
    static let xxl: CGFloat = 20
    /// 24pt — section-level spacing
    static let xxxl: CGFloat = 24
}

// MARK: - Corner Radii

enum AppRadius {
    /// 4pt — small elements (badges, tiny cards)
    static let xs: CGFloat = 4
    /// 6pt — compact grid cells (small thumbnail size)
    static let sm: CGFloat = 6
    /// 8pt — standard grid cells
    static let md: CGFloat = 8
    /// 10pt — larger cards, panels
    static let lg: CGFloat = 10
    /// 12pt — prominent surfaces (detail chrome, overlay panels)
    static let xl: CGFloat = 12
    /// 16pt — very prominent or modal-like surfaces
    static let xxl: CGFloat = 16
}

// MARK: - Elevation / Shadows

struct AppShadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
    let opacity: Double
}

extension AppShadow {
    /// Very subtle lift — good for grid cells on hover or selected state.
    static let subtle = AppShadow(
        color: .black,
        radius: 8,
        x: 0,
        y: 1,
        opacity: 0.08
    )

    /// Soft card elevation — use on surfaces that should feel slightly raised.
    static let card = AppShadow(
        color: .black,
        radius: 12,
        x: 0,
        y: 2,
        opacity: 0.10
    )

    /// Stronger elevation for floating panels (e.g. overlay player).
    static let floating = AppShadow(
        color: .black,
        radius: 20,
        x: 0,
        y: 4,
        opacity: 0.18
    )
}

// MARK: - Semantic Colors (Cinematic Blue Dark theme)

extension Color {
    // === Dark cinematic base (opinionated, blue-tinted) ===
    static let appBackground = Color(hex: "#0a0f1a")          // Deep navy/charcoal
    static let appSurface    = Color(hex: "#121826")          // Slightly lifted surface
    static let appCard       = Color(hex: "#1a2233")          // Card/panel base

    // Content (high contrast on dark)
    static let appTextPrimary   = Color.white
    static let appTextSecondary = Color(hex: "#a1b0c9")
    static let appTextTertiary  = Color(hex: "#6b7a94")

    // Interactive states — stronger than stock for scannability
    static let appHover     = Color.white.opacity(0.07)
    static let appSelection = Color(hex: "#3b82f6").opacity(0.22)   // Blue-tinted selection

    // Accent — primary blue family
    static let appAccent = Color(hex: "#3b82f6")   // Core vibrant blue
    static let appAccentLight = Color(hex: "#60a5fa")

    static let appDivider = Color.white.opacity(0.08)

    // Special
    static let appBadgeBackground = Color.black.opacity(0.65)

    // Gradient helpers (blue cinematic)
    static let appBlueGradient = LinearGradient(
        colors: [Color(hex: "#3b82f6"), Color(hex: "#2563eb")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let appCyanBlueGradient = LinearGradient(
        colors: [Color(hex: "#3b82f6"), Color(hex: "#22d3ee")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// Small hex convenience (local to design system for now)
private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Materials (Liquid Glass on dark + blue tinting)

extension Material {
    /// Primary "glass" surface for panels, sidebars, and chrome.
    /// On dark + blue theme this gives the translucent, reflective Liquid Glass look.
    static var appCardMaterial: Material { .regularMaterial }

    /// Lighter glass for floating elements (overlay player, popovers).
    static var appFloatingMaterial: Material { .thinMaterial }

    /// Very subtle glass for overlays that need to sit gently on content.
    static var appSubtleGlass: Material { .ultraThinMaterial }
}

// MARK: - View Modifiers (the practical API)

extension View {
    /// Applies a tasteful card-like surface with subtle depth.
    /// Use on larger surfaces (detail sections, overlay panels, etc.).
    func appCard() -> some View {
        self
            .background(Color.appCard)
            .background(Material.appCardMaterial, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .shadow(
                color: AppShadow.card.color,
                radius: AppShadow.card.radius,
                x: AppShadow.card.x,
                y: AppShadow.card.y
            )
            .opacity(0.98) // slight polish
    }

    /// Primary styling for grid cells (Cinematic Blue).
    /// Intentionally lightweight for LazyVGrid.
    ///
    /// Selection uses a blue-tinted glass surface.
    /// Hover is a gentle lift.
    func appCell(isSelected: Bool, isHovering: Bool) -> some View {
        self.appCellWithRadius(isSelected: isSelected, isHovering: isHovering, cornerRadius: AppRadius.md)
    }

    /// Grid cell styling with explicit corner radius (for size variants).
    func appCellWithRadius(isSelected: Bool, isHovering: Bool, cornerRadius: CGFloat) -> some View {
        let backgroundFill: Color = isSelected
            ? Color.appAccent.opacity(0.30)
            : (isHovering ? Color.appHover : Color.clear)

        let borderColor: Color = isSelected
            ? Color.appAccent
            : (isHovering ? Color.appAccent.opacity(0.35) : Color.clear)

        return self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Lightweight hover treatment for interactive elements.
    func appHover(isHovering: Bool) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .fill(isHovering ? Color.appHover : Color.clear)
            )
    }

    /// Standard padding used inside most content cards and cells.
    func appPadding(_ level: AppPaddingLevel = .standard) -> some View {
        let value: CGFloat = switch level {
        case .tight: AppSpacing.sm
        case .standard: AppSpacing.md
        case .comfortable: AppSpacing.lg
        }
        return self.padding(value)
    }

    /// Applies a soft drop shadow using the design system's elevation tokens.
    func appElevation(_ level: AppElevationLevel = .subtle) -> some View {
        let shadow = switch level {
        case .subtle: AppShadow.subtle
        case .card: AppShadow.card
        case .floating: AppShadow.floating
        }
        return self.shadow(
            color: shadow.color,
            radius: shadow.radius,
            x: shadow.x,
            y: shadow.y
        )
    }
}

enum AppPaddingLevel {
    case tight
    case standard
    case comfortable
}

enum AppElevationLevel {
    case subtle
    case card
    case floating
}

// MARK: - Typography Helpers (lightweight)

extension Font {
    /// Used for primary titles in detail pane and prominent labels.
    static var appTitle: Font { .headline }

    /// Standard body text in metadata areas.
    static var appBody: Font { .callout }

    /// Small labels, duration badges, metadata pills.
    static var appCaption: Font { .caption }

    /// Very small supporting text.
    static var appCaption2: Font { .caption2 }
}

// MARK: - Theme

/// Cinematic Blue Dark — our primary opinionated theme.
/// Dark-first, blue-accented, with selective Liquid Glass materials.
/// Light mode is de-emphasized for now (decisions are reversible).
struct AppTheme {
    let name: String = "Cinematic Blue"

    /// Primary aesthetic direction: dark + blue + selective Liquid Glass
    let mode: ThemeMode = .cinematicDarkBlue

    var usesVibrancy: Bool { true }
    var prefersBlueGradients: Bool { true }
}

enum ThemeMode {
    case cinematicDarkBlue
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme()
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension View {
    /// Injects the design system theme. Call this once near the root (ContentView or similar).
    func appDesignSystem() -> some View {
        self.environment(\.appTheme, AppTheme())
    }
}

// MARK: - Usage Notes for Performance (Cinematic Blue)
//
// When applying inside VideoGridCell or other high-frequency views:
// - Prefer `.appCell(isSelected:isHovering:)` (still lightweight).
// - Blue gradients and heavy materials are intentionally **not** applied inside the scrolling grid by default.
// - Reserve `.appBlueGradientOverlay`, extra materials, or strong shadows for detail panes, toolbars, and overlays.
// - Keep hover/selection cheap (simple Color fills + stroke).
//
// This keeps the redesign distinctive while still scrolling smoothly on big libraries.

/// Convenience for applying the most common cell treatment in one line.
extension View {
    func appGridCellStyle(isSelected: Bool, isHovering: Bool, gridSize: GridSize? = nil) -> some View {
        // In Cinematic Blue we keep grid cells deliberately restrained.
        // Strong blue gradients / heavy glass are applied elsewhere.
        self.appCell(isSelected: isSelected, isHovering: isHovering)
    }
}