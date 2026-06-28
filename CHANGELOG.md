# Changelog

**VideoMaster changelogs are maintained live by agents.**

## How maintenance works (for agents)

**Two phases:**

1. **Live updates (development / every commit)**
   - After changes + `bash scripts/build_and_install.sh`, append high-level summaries to the `## Unreleased` section.
   - Do this before or as part of the commit.

2. **Consolidation (on release)**
   - After running the build script for a release, convert the `## Unreleased` content into a new release header:
     ```
     ## X.Y.Z (build NNN) - YYYY-MM-DD
     ```
   - Clear the Unreleased section.
   - The release commit message should align with the consolidated text.

Most recent releases sit directly after the Unreleased section.

See `AGENTS.md` and `.cursor/rules/build-deploy.mdc` for the full agent and release workflow.

### Agent quick checklist
- After `bash scripts/build_and_install.sh` → append high-level bullets to `## Unreleased`.
- Before committing → ensure the Unreleased section accurately reflects the changes in this commit.
- On release (after the final build) → promote Unreleased content into a versioned header and clear it.

---

## 0.15.0 (build 410) - 2026-06-28

- UI (floating overlay player): Made the overlay player panel much more "intentional" as a first-class cinematic object.
  - Replaced raw `windowBackgroundColor` + anonymous splitter with a themed `Color.appSurface` container using `UnevenRoundedRectangle` (xl radius on the leading edge only).
  - Added a subtle `appAccent` outer stroke so the panel reads as a deliberately placed surface rather than leftover window space.
  - Redesigned the width splitter as a visible blue-tinted grip (three stacked capsules) that clearly communicates "this panel is adjustable".
  - Framed the `FloatingPlayerView` with `.appMediaFrame()` + breathing room so the video feels contained instead of bleeding to the edges.
  - Added a compact header bar (filename + close button) using design tokens; this makes the floating player read as a summoned panel, not just "video in a box".
  - The treatment deliberately avoids heavy shadows/materials on the resizable container itself (to preserve smooth live dragging) while still delivering strong visual presence through surface, rounding, accent, and framing.
  - Header close button stops inline overlay playback cleanly.
  - Build 409.

- UI (remaining chrome & editors sweep): Completed the visual pass on the last major stock-looking areas.
  - Detail pane Thumbnail/Filmstrip switcher: replaced stock `.segmented` Picker with `AppSegmentedControl` for full consistency.
  - Overlay player resume banner and error overlay: updated to use `Material.appFloatingMaterial`, `appSurface`, `appAccent` strokes, `appText*` colors.
  - `FilmstripConfigView`: wrapped in glass card, app colors for labels, accent-tinted Generate button, improved steppers.
  - `TagEditorView` & `TagToggleChip`: switched from `accentColor`/`secondary` to `appAccent`/`appTextSecondary`/`appSurface`.
  - `CollectionEditorView`: updated ALL/ANY pill and labels to use `appAccent`/`appTextSecondary`.
  - Settings tabs (Application, Library, Data Sources, List Columns, Custom Metadata, File Ext, etc.): swept `.secondary`/`.tertiary` → `appTextSecondary`/`appTextTertiary`; added `appAccent` tint to key pickers.
  - Various remaining `.bordered` buttons in detail/overlay now consistently tinted where they weren't.
  - Split view surfaces and surrounding chrome already using design tokens; deep NSSplitView divider drawing left as system thin (common limitation).
  - Build 407.

- UI (status bar): Styled the bottom status bar to match the Cinematic Blue design system.
  - Subtle `Color.appSurface.opacity(0.55)` background with a thin `appDivider` top separator.
  - All labels use `Color.appTextSecondary`.
  - Progress indicators tinted with `Color.appAccent`.
  - Consistent `.caption` typography and tight vertical padding.
  - Replaces the previous stock `.bar` material and raw `.secondary` styles.
  - Build 405.

- UI (LandingView): Full Cinematic Blue redesign of the first-impression screen shown when no library is open.
  - Deep `appBackground` full-window treatment.
  - Large, well-weighted title in `appTextPrimary`; subtitle in `appTextSecondary`.
  - Main actions grouped in a prominent glass/surface card (`Material.appSubtleGlass` + `appSurface`) with subtle `appAccent` border and generous `AppRadius.xl`.
  - Primary "Create in default" uses borderedProminent tinted with `appAccent`.
  - Other create/open actions styled consistently with `appAccent` tint.
  - "Open recent" section has a clean divider and hoverable recent items using `appHover` + rounded surfaces.
  - Tighter, more intentional spacing using `AppSpacing` scale.
  - Overall more premium and opinionated dark-first landing experience.
  - Build 404.

- UI (search): Replaced the stock `.searchable` field with a custom styled search pill inside the library nav bar for full Cinematic Blue treatment.
  - Magnifying glass icon + "Search videos" placeholder.
  - Clear (x) button appears when text is present.
  - Focus ring uses `appAccent` (stronger when focused).
  - Uses `appSurface`, `appTextPrimary/Tertiary`, `AppRadius`, `AppSpacing`.
  - Integrated after the sort control; the bar's glass container frames it nicely.
  - Stock searchable behavior removed (no duplicate field); search logic in LibraryViewModel is unchanged.
  - Build 403.

- UI (empty states & placeholders): Styled the "No Videos" empty state and the "Select a video" detail-pane placeholder with the Cinematic Blue design system.
  - Both now use a subtle glass/surface card treatment (Material + appSurface + thin accent border) for a designed, contained look instead of raw floating text.
  - Consistent semantic colors: `appTextPrimary/Secondary/Tertiary`.
  - Proper `AppSpacing` and `AppRadius`.
  - "Add Folder" button tinted with `appAccent`.
  - "Select a video" now includes a short helpful subtitle and stronger visual weight.
  - Build 402.

- UI (top chrome — Priority 1): Finished styling the library nav bar and main toolbar for visual consistency with the Cinematic Blue design system.
  - Replaced the last remaining stock `.segmented` picker (Playback Mode: Detail/Overlay/Full Screen) with `AppSegmentedControl`.
  - Gave the inline library nav bar (directly above grid/list) a matching glass container (Material + appSurface + subtle accent border), same language as the custom segmented controls and bottom filter strip.
  - Restyled the remaining stock buttons in the library nav bar:
    - Columns button
    - Sort menu trigger
    - Scroll navigation cluster (top / page up / page down / bottom)
  - Introduced reusable `.appNavBarButton()` modifier (plain style + surface fill + rounded clip + thin accent ring) to keep the treatment consistent and easy to maintain.
  - Tinted the main window toolbar action buttons (Add Folder, Import New, Surprise Me) with `Color.appAccent`.
  - Removed `.controlSize(.small)` and raw `.bordered` styles from the chrome.
  - Build 401.

- UI (grid): Made selected video cells pop more distinctly.
  - Stronger outer selection: `appAccent.opacity(0.30)` fill + full `appAccent` 2pt border (was subtle 0.22 wash + 0.85 opacity).
  - Thumbnail now gets its own prominent blue accent ring (2pt `appAccent`) when the cell is selected, in addition to the outer card treatment. This makes the actual video content stand out.
  - Filename becomes semibold when its cell is selected.
  - All changes are still lightweight (simple fills/strokes, no per-cell heavy effects).
  - Build 399.

- UI (top nav bar): Replaced the stock segmented pickers with a custom `AppSegmentedControl` for View Mode (List/Grid) and Grid Size (S/M/L).
  - Proper sliding pill selection indicator using `.matchedGeometryEffect` + spring animation.
  - Outer container uses `Material.appSubtleGlass` + `appSurface` with a thin `appAccent` border.
  - Selected segment: `appAccent` tinted fill + stroke; bold semibold primary text.
  - Unselected: secondary text color.
  - Fully integrated with existing side-effects (preferences save + scroll-to-selected on view switch).
  - Removes one of the strongest remaining "generic macOS" visual elements in the main browsing UI.
  - Build 396.

- Bugfix (top nav bar): The custom `AppSegmentedControl` for List/Grid and S/M/L was expanding to a huge height (~4 inches) because it had no explicit height and the selection pill used an unconstrained `RoundedRectangle` inside a `ZStack`. When the vertical split's top pane proposed a large height (from saved layout or measurement), the shapes filled it.
  - Fix: Added `.frame(height: 28)` to keep the control compact like stock segmented controls.
  - Refactored selection indicator to use `.background` on the segment content (the background sizes exactly to the label + padding, no more ZStack + free shape).
  - Reduced internal vertical padding slightly for fit.
  - Build 397.

- Polish: Made the "little bounce" you like when the grid reorders or changes density (via grid size or window width) explicit.
  - Added `.animation(.spring(response: 0.38, dampingFraction: 0.80), value: viewModel.gridSize)` to the `LazyVGrid`.
  - This captures the pleasant springy repositioning of cells (previously purely implicit) so it stays consistent as we continue the visual work.
  - The effect happens on S/M/L changes (now driven by the custom segmented control) and when the number of columns recalculates.
  - Reorders from sorting also continue to get lively movement because we only force-recreate the grid on structural set changes, not pure order changes.
  - Build 398.

- UI (bottom filter strip): Applied full Cinematic Blue treatment to `BottomFilterColumnsView` (the 4-column LIBRARY / COLLECTIONS / RATING / TAGS area under the grid/list).
  - Whole strip: `.appFilterStrip()` (subtle glass + appSurface + top divider line) for cohesive bottom chrome.
  - Column separators: thin `Color.appDivider` lines instead of stock Dividers.
  - Section headers: bold left blue accent bar (matching detail pane) + `Color.appAccent` text.
  - All rows, counts, badges: semantic `appTextPrimary/Secondary/Tertiary`, `appSurface` capsules, `AppSpacing`/`AppRadius`.
  - Selection states: `Color.appAccent.opacity(0.22)` rounded rects (consistent with grid/list).
  - Rating stars: cleaned up (no more colorScheme ternary).
  - Tag rename field and New Tag sheet: surfaced with app tokens.
  - "New Collection"/"New Tag" actions and empty states use `appTextSecondary/Tertiary`.
  - Lists tinted with `appAccent`.
  - Build 395.

- Bugfix (list view): "Go to top" now lands the first row *flush* under the column headers with no remaining gap. After the prior fix you could still wheel the mouse ~3-4 px further to tuck the row a little higher.
  - Root cause of residual gap: the previous overlap calculation converted whole `headerView`/`clip` *frames* into `NSScrollView` coordinates. Small differences in borders, separators, intercell spacing, and SwiftUI Table wrappers produced a 3-4 pt error in the computed intrusion.
  - Precise fix in `ScrollCommandHandler`:
    - `scrollListToAbsoluteTop`: after `scrollRowToVisible(0)`, convert only the *bottom edge point* of `table.headerView` (`NSPoint(x:0, y: bounds.maxY)`) directly into the `NSClipView` using `convert(_:to:)`.
    - Solve for the clip origin that places `rowRect.minY` exactly at that local "under-header" Y in the clip: `targetY = rowRect.minY - headerBottomLocalY_inClip`.
    - `reflectScrolledClipView`, then immediately call a new `correctListFirstRowUnderHeader(...)` helper that re-measures the same mapping and applies a micro-nudge if `|currentY - desiredY| > 0.25`.
    - The existing re-application timers (async + 80 ms) keep calling the full routine so any later layout/selection-visible adjustments are also corrected.
  - Grid mode and non-`.top` commands unchanged.
  - Build 394.

- Bugfix (list view): "Go to top" (⌘↑ or the top button) now positions the first row fully visible directly beneath the column headers (no longer half-hidden).
  - Initial attempt (y=0 for list .top) was insufficient. Even with document y=0 as the top of row 0, the `NSScrollView` clip view frame can intrude a few points under the `NSTableHeaderView` that the scroll view places for a SwiftUI `Table`. Targeting y=0 therefore parked the top sliver of row 0 behind the header.
  - Real fix in `ScrollCommandHandler`:
    - For `.top` + list mode: find the dominant `NSTableView`, call `scrollRowToVisible(0)`, derive `targetY` from `rect(ofRow: 0).minY`.
    - Measure the actual overlap: convert `table.headerView` and the content clip frames into the scroll view's coordinate space; `overlap = max(0, headerRect.maxY - clipRect.minY)`.
    - Compensate: `targetY -= overlap`. This places document row-top slightly "above" the clip top so it lands exactly at the visual bottom edge of the header.
    - Schedule two follow-up reapplications (immediate async + 80 ms) because SwiftUI/AppKit may run additional layout/selection-visibility scrolls that would otherwise re-obscure the first row.
  - Non-top commands and grid mode unchanged.
  - Build 393.

- Bugfix: Sorting the list view by the "Plays" column now correctly sorts by numeric play count.
  - Root cause: `VideoSort` enum (used by both the toolbar Sort menu and the fast custom sorter in `recomputeFilteredVideos`) had no `playCount` case.
  - `VideoSort.from(keyPath:)` fell back to `.dateAdded` whenever `\Video.playCount` (or `sortablePlayCount`) was passed from the Table's `sortOrder`.
  - `sortByTableOrder` therefore sorted by date added (or previous sort) instead of plays.
  - Fix: Added `.playCount` to `VideoSort`, implemented `comparators()` / `from(keyPath:)`, and the corresponding case in `sortByTableOrder`.
  - Added `var sortablePlayCount: Int` on `Video` for consistency.
  - Updated the Plays `TableColumn` (value keypath) to use `\.sortablePlayCount`.
  - "Plays" is now available as a sort in the list column header click and in the toolbar Sort menu.
  - Build 390.

- UI (list view): Applied Cinematic Blue treatment to `LibraryListView` rows for parity with grid.
  - Name column: thumbnails now use `.appMediaFrame` (small radius) + dark surface.
  - Larger popover thumbnails also framed.
  - Rename TextField inside list uses `appSurface` + `appAccent` stroke.
  - Filename text uses `appTextPrimary`.
  - Subtitles indicator pill uses `appAccent` background.
  - All data columns updated to semantic `Color.appTextSecondary` / `appTextTertiary`.
  - Resolution column now shows a small styled pill (dark surface + blue accent) for visual consistency.
  - Table tinted with `Color.appAccent` for blue-leaning selection/hover.
  - Consistent use of `AppSpacing`, `AppRadius`, and caption fonts.
  - Build 389.

- UI (grid cells): Applied Cinematic Blue treatment to `VideoGridCell`.
  - Now uses `.appVideoGridCell(...)` (backed by `.appCell`) for selection (blue-tinted fill + accent border) and hover states.
  - Thumbnail area backed by dark `appSurface` + `.appMediaFrame` (neutral subtle border).
  - Duration badge uses `appBadgeBackground`.
  - All text uses semantic `appTextPrimary/Secondary/Tertiary`.
  - Resolution pill styled as dark surface + blue accent.
  - File size and labels use design tokens.
  - Rename field inside grid uses `appSurface` + `appAccent` stroke.
  - Placeholder uses `appSurface` + tertiary icon.
  - Consistent `AppSpacing` / `AppRadius` and `Font.appCaption*` throughout.
  - Added size-aware rounding support in the grid cell style (`appCellWithRadius`).
  - Build 388.

- UI (detail pane): Removed prominent blue border from the filmstrip/thumbnail/player container. It now uses a dark blue surface background (Color.appSurface) matching the style and treatment of the Details, Custom, Rating, and Tags cards, with only a subtle neutral divider stroke. Inner frames also use neutral strokes.
- UI (detail pane, aggressive): Much stronger cinematic treatment on filmstrip/thumbnail + details data.
  - New `.appHeroPreview()` for the main preview area (dark blue surface matching the data cards, subtle divider stroke only).
  - `.appMediaFrame()` on preview imagery updated to neutral (no blue accent).
  - `.appDetailCard()` (stronger than previous subtle section) used on Details + Rating/Tags blocks with thicker blue strokes and more lift.
  - Section headers now have a bold left blue accent bar + uppercase labels on metadata rows for scannability.
  - Title area given a subtle surface treatment. Resize handle now has a visible blue grip.
  - Metadata rows have more weight (medium weight values, tighter hierarchy).
  - Stronger visual separator between the two data columns.
  - Picker bar integrated into the hero container with blue tint.
  - Left blue accent bars added to all section headers (Details, Custom, Rating, Tags).
  - Metadata rows made more scannable (uppercase labels, medium weight values).
  - Build 385.

## Unreleased

## 0.14.1 (378) - 2026-06-27

- videomaster-playback-test pass: reviewed full checklist against implementation; fixed list view not receiving explicit centered scroll re-anchor after leaving detail-pane playback (now sets scrollToVideoId for both grid and list on exit).

## 0.14.0 (376) - 2026-06-27

- Foundation and agent workflow release:
  - Added `AGENTS.md`, `ROADMAP.md`, `SKILLS.md` as the core foundation documents.
  - Reconciled build/deploy rules; created `.cursor/rules/release-workflow.mdc` for VideoMaster.
  - Created `videomaster-playback-test` skill.
  - Retired `IMPROVEMENTS.md` and `DEVELOPMENT_SUMMARY.md` (key ideas folded into `ROADMAP.md`).
  - Cleared `docs/USER_GUIDE.md` (full guide deferred until closer to production release).
  - Introduced live `CHANGELOG.md` process: agents maintain high-level changes in `## Unreleased` on every commit; content is consolidated into versioned release entries on release.
  - Strengthened rules and agent instructions for commit discipline (always `git add -A` for tracked + untracked files) and requiring releases to commit all completed work.

## 0.13.0 (375) - 2026-06-16

- floating overlay playback + playback-mode control

## 0.12.1 - 2026-06-15

- fix grid scroll position after inline playback

## 0.12.0 - 2026-06-15

- library performance overhaul and stability fixes

## 0.11.0 - 2026-06-14

- navigation controls, consolidated view bar, move + convert fixes

## 0.10.0 - 2026-06-07

- in-app re-encoding, Recently Converted filter, and playback UX

## 0.9.0 - 2026-05-08

- library polish, subtitles, and playback UX

## 0.8.1 (281) - 2026-04-02

- Release VideoMaster 0.8.1 (build 281)

## 0.8.0 - 2026-03-27

- Release VideoMaster 0.8.0

## Earlier releases

Follow the same pattern. See git tags (`v0.7.x` and prior) and their associated commit messages for the exact summaries and (where recorded) build numbers at the time.

---

*This file is the source of truth for "what shipped in which build" and for the running history of changes between releases.*