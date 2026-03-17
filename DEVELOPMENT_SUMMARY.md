# VideoMaster — Development Summary

*Last updated: March 2025*

## Project Overview

Native macOS video library management app. Targets macOS 26 (Tahoe). SwiftUI, GRDB (SQLite), AVFoundation. MVVM + Repository pattern.

**Build:** `xcodegen generate` then `DEVELOPER_DIR="/Volumes/Crucial X10/Apps/Xcode.app/Contents/Developer" xcodebuild -project VideoMaster.xcodeproj -scheme VideoMaster -configuration Release build`

**Deploy:** Copy built app from DerivedData to `/Applications/VideoMaster.app`

**Version:** v0.3.0 (tagged and pushed to main)

---

## Recent Release (v0.3.0)

- **Surprise Me** — Toolbar button (exclamationmark.circle.fill) picks a random video from the current list and auto-plays it in the inline player. Uses `pendingAutoPlay` flag for timing-safe playback in both grid and list modes.
- **Filmstrip click-to-play** — Click any cell on the filmstrip to start inline playback from that point in the video. Grid dimensions inferred from image size (400×225 per cell). Pointing-hand cursor on hover.
- **Grid scrollbar** — `ScrollbarEnabler` NSViewRepresentable inside the scroll content finds the HostingScrollView, sets `scrollerStyle = .overlay`, and uses a 1s timer to re-apply (SwiftUI resets it). Without this, grid view had no scrollbar.
- **Inline file rename** — Enter to edit name in list/grid, Enter to confirm, Esc to cancel. Only when exactly one video selected.
- **IMPROVEMENTS.md** — Feature analysis and prioritized suggestions for future work.

---

## Key Architecture Notes

- **Child views receive `LibraryViewModel` and `ThumbnailService` as parameters** — NOT via `@Environment` — because macOS SwiftUI `Table`, `Menu`, and `NavigationSplitView` break the environment chain in isolated window contexts.
- **Performance:** `filteredVideos` is cached; `.id(viewModel.filteredVideosVersion)` on Table/Grid forces view recreation (not diff) when data changes. `applyFilteredVideos` only bumps version on item additions, not renames/deletes, to avoid scroll reset.
- **Scroll position:** `scrollToVideoId` + `ScrollViewReader` for grid; `TableScrollHelper` (NSViewRepresentable) for list — finds NSTableView, calls `scrollRowToVisible`, centers row.
- **Spacebar/Enter/Escape:** Handled via `NSEvent.addLocalMonitorForEvents` in ContentView (keyCodes 49, 36, 53). `viewModel.isEditingText` blocks spacebar when typing in text fields.

---

## Known Issues / Incomplete

1. **Filmstrip timing accuracy** — Some videos seek spot-on, others off by unknown amount. Causes: (a) `AVAssetImageGenerator` uses 2s tolerance, so thumbnails can be from different moments; (b) `AVPlayer.seek(to:)` without tolerance seeks to nearest keyframe. Fix: use `seek(to:toleranceBefore:toleranceAfter:)` with zero tolerance; optionally tighten filmstrip generator tolerance.
2. **FTS5 search unused** — `video_fts` table and `VideoRepository.search()` exist, but `LibraryViewModel.recomputeFilteredVideos()` uses `fileName.contains(query)` instead.
3. **Auto-import from data sources** — Data sources are stored but not wired up.
4. **Sandboxing disabled** — App has file access entitlements.

---

## Important Files

| File | Purpose |
|------|---------|
| `LibraryViewModel.swift` | Central state, filtering, persistence, Surprise Me, pendingAutoPlay |
| `VideoDetailView.swift` | Detail pane, inline player, filmstrip click handler, `startInlinePlayback(at:)`, `handleFilmstripClick` |
| `LibraryGridView.swift` | Grid view, `ScrollbarEnabler` background on LazyVGrid, multi-select, inline rename |
| `LibraryListView.swift` | Table view, `TableScrollHelper`, inline rename |
| `ContentView.swift` | Root layout, NSEvent key monitors, Surprise Me button |
| `ThumbnailService.swift` | Filmstrip generation (2×4 default), `buildFilmstrip` uses `fraction = frameIndex/(totalFrames+1)` |
| `IMPROVEMENTS.md` | Prioritized feature suggestions |

---

## UserDefaults Keys

`VideoMaster.viewMode`, `gridSize`, `sortColumn`, `sortAscending`, `excludeCorrupt`, `confirmDeletions`, `detailHeight`, `sidebarExpanded`, `columnCustomization` (JSON)

---

## Next Steps (from IMPROVEMENTS.md)

Quick wins: FTS5 search, batch tag apply, Quick Look preview. See `IMPROVEMENTS.md` for full list.
