# VideoMaster Design System

This directory contains the design language and tokens that should drive all visual decisions going forward.

## Philosophy (Cinematic Blue Dark)

We are taking a **fully opinionated** direction:

- **Dark-primary "Cinematic Blue" aesthetic** — rich dark surfaces with a strong blue accent family and blue gradients.
- **Selective Liquid Glass** — we use Apple's translucent, depth-oriented materials (regular/thin/ultraThin) on the dark theme for chrome, panels, and floating elements. We are cautious with it in the main grid for performance reasons.
- **Blue-forward with gradients** — blues (#3b82f6 core, with cyan/blue gradients) are the emotional through-line.
- **Performance first**: Grid cells remain relatively lightweight. Materials and complex effects are reserved for non-scrolling or low-density surfaces.
- **Distinctive, not generic**: We are deliberately moving away from stock Apple toolkit look toward something that feels like a premium media app.

Light mode is de-prioritized for now (decisions are reversible). We can re-introduce a high-quality Light variant later if needed.

## Core Tokens (Cinematic Blue)

- **Spacing & Radius**: Same as before (performance-friendly scale)
- **Elevation**: Subtle shadows for cards and floating panels
- **Semantic Colors**: Deep navy/charcoal backgrounds, blue-tinted surfaces, strong blue accent (`#3b82f6`), blue gradients
- **Materials**: Liquid Glass style (regular / thin / ultraThin) with blue harmony on dark
- **Gradients**: `appBlueGradient`, `appCyanBlueGradient` for headers, selections, and accents
- **Typography**: Still using system fonts for now (we can add custom later)

## Recommended Modifiers

```swift
// Grid cells (keep cheap)
.appCell(isSelected: isSelected, isHovering: isHovering)

// Larger surfaces + Liquid Glass
.appCard()
.appElevation(.floating)
.appOverlayPanel()

// Accents
Color.appAccent
Color.appBlueGradient   // or .appCyanBlueGradient

// General
.appPadding(.comfortable)
.appHover(isHovering: isHovering)
```

## Applying During Redesign

1. Start with the grid (`VideoGridCell`).
2. Move on to the filter strip, detail pane, and overlay player.
3. Use materials more deliberately (they are currently underused).
4. Make hover and selection states noticeably stronger without adding heavy animation in scrolling views.
5. Keep cell modifiers as simple as possible — prefer these system modifiers over custom view hierarchies inside `LazyVGrid`.

## Performance Guidelines

- Avoid per-cell complex view trees.
- Prefer simple `Color` + `RoundedRectangle` fills for cells over multiple layered materials.
- Use the provided elevation shadows sparingly in the grid.
- Test scrolling performance after any visual change to cells.

## Future Evolution

Next areas we can push while staying opinionated and performant:
- Subtle blue gradient treatments on selected filmstrip frames or detail headers
- Stronger but cheap hover "glow" using the blue accent on grid cells (validate perf first)
- Toolbar / sidebar using richer Liquid Glass + vibrancy
- Cinematic thumbnail overlays (very subtle blue gradient at bottom of thumbnails)
- Typography refinements or a custom display font for titles

Always keep grid performance as the gating factor.

Update this README and the source when new patterns are added.