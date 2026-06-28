import SwiftUI

// MARK: - Component Styles
//
// These are higher-level styles built on top of the core tokens.
// They represent common "components" in the app and make the redesign
// more consistent and faster to apply.

extension View {
    /// Recommended treatment for the main video grid cells.
    /// This is the single most important visual surface for most users.
    /// Applies Cinematic Blue selection/hover and size-appropriate rounding.
    func appVideoGridCell(
        isSelected: Bool,
        isHovering: Bool,
        size: GridSize
    ) -> some View {
        let radius: CGFloat = switch size {
        case .small: AppRadius.sm
        case .medium: AppRadius.md
        case .large: AppRadius.lg
        }

        return self
            .appCellWithRadius(isSelected: isSelected, isHovering: isHovering, cornerRadius: radius)
    }

    /// Styling for the floating overlay player container.
/// Uses Liquid Glass + blue accent border for a premium cinematic feel.
    func appOverlayPanel() -> some View {
        self
            .background(Material.appFloatingMaterial)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
            .appElevation(.floating)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.25), lineWidth: 1)
            )
    }

    /// Treatment for sections inside the detail pane.
    /// Uses a glass-like surface with subtle blue accent border.
    func appDetailSection() -> some View {
        self
            .background(Material.appSubtleGlass)
            .background(Color.appSurface.opacity(0.6)) // tint for depth on dark
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .appElevation(.subtle)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.12), lineWidth: 0.5)
            )
    }

    /// Container for the main preview (filmstrip / thumbnail / player) area in the detail pane.
    /// Dark blue background surface matching the style of the Details / Rating / Tags cards.
    /// No prominent blue border — presence comes from the surface, rounding, and elevation.
    func appHeroPreview() -> some View {
        self
            .background(Material.appCardMaterial)
            .background(Color.appSurface.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous))
            .appElevation(.card)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.xl, style: .continuous)
                    .stroke(Color.appDivider, lineWidth: 1)
            )
    }

    /// Stronger, more prominent card for data sections (Details, Rating+Tags, etc.).
    /// More lift and clearer blue accent than the subtle variant.
    func appDetailCard() -> some View {
        self
            .background(Material.appCardMaterial)
            .background(Color.appSurface.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
            .appElevation(.card)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.35), lineWidth: 1)
            )
    }

    /// Standard treatment for the filter strip / bottom chrome.
    /// Liquid Glass treatment with blue harmony.
    func appFilterStrip() -> some View {
        self
            .background(Material.appSubtleGlass)
            .background(Color.appSurface.opacity(0.75))
            .overlay(
                Rectangle()
                    .fill(Color.appDivider)
                    .frame(height: 0.5),
                alignment: .top
            )
    }
}

// MARK: - Thumbnail Framing
//
// These can be used to give thumbnails and filmstrips a more intentional presentation
// without adding heavy per-cell cost.

extension View {
    /// Gives an image view a refined framed look suitable for video content.
    func appThumbnailFrame(cornerRadius: CGFloat = AppRadius.md) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
            )
    }

    /// Clean media frame for content inside the dark preview container.
    /// Subtle definition without blue accent (the container itself provides the visual weight).
    func appMediaFrame(cornerRadius: CGFloat = AppRadius.lg) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.appDivider.opacity(0.6), lineWidth: 1)
            )
    }

    /// Optional blue gradient overlay treatment (use sparingly in grid for perf).
    func appBlueGradientOverlay(opacity: Double = 0.15) -> some View {
        self.overlay(
            LinearGradient(
                colors: [.clear, Color.appAccent.opacity(opacity)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Chrome / Nav Bar Buttons

extension View {
    /// Consistent treatment for small icon/action buttons in the library nav bar and similar chrome.
    /// Glass-tinted surface with subtle blue accent ring.
    func appNavBarButton() -> some View {
        self
            .buttonStyle(.plain)
            .padding(6)
            .background(Color.appSurface.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.25), lineWidth: 1)
            )
    }
}