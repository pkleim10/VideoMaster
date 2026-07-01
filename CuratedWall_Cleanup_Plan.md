# Curated Wall — Cleanup Plan

**Branch:** `feature/curated-wall` (build ~504)
**Status:** In progress.

## Progress
- ✅ **1. Grid scrollbar** — native scroller shown for all "Show scroll bars" settings (dropped the GeometryReader → flexible columns). `02015b0`
- ✅ **2. Import** — Import New restored as a left-cluster header icon + live scan progress in the header status. `3f0af5c`
- ✅ **3. Surprise Me** — restored as a header icon (✨, ⌘⇧S); re-wired auto-play. `3f0af5c`
- ⬜ 4. Fonts & sizing (design polish)
- ⬜ 5. Top video details (design polish)
- ⬜ 6. First-play/select delay (investigate — see the 720px per-card preview note; measure first)
- ✅ **7. Full-screen "last used size"** — persisted `playerLastWasFullScreen`; "Last used size" reopens full-screen. `8403837`
- ⬜ 8. Delete a tag (context menu on chips)
- ⬜ **NEW follow-up:** `CuratedWallGrid` has **no scroll-to-selection infrastructure** (only the list view does) — surfaced via Surprise Me (a picked card off-screen in Wall mode isn't scrolled into view). Broader than Surprise Me; add `ScrollViewReader` + scroll-to for the Wall grid.

---


The Curated Wall redesign deleted the legacy nav bar / bottom filter strip, which dropped several **affordances** whose underlying functions still exist in `LibraryViewModel`. Most "was present in main" items are re-surfacing UI, not rebuilding logic. Grouped below by type.

---

## A. Restore missing affordances (logic exists; UI was removed)

### 1. No scrollbar on the grid
- **Cause:** Main used `LibraryGridView` (AppKit `NSScrollView`, persistent scroller). The Wall uses `CuratedWallGrid` with a SwiftUI `ScrollView(.vertical)`, which uses macOS **overlay scrollers** that auto-hide. `LibraryGridView` is now unused.
- **Fix (small):** Add `.scrollIndicators(.visible)` to `CuratedWallGrid`'s `ScrollView` (respects the system "show scroll bars" setting but keeps it visible while scrolling). If a *persistent* bar is wanted regardless of system setting, wrap the grid in an `NSScrollView`-backed representable instead (larger).
- **Decision needed:** overlay-visible (simple) vs always-on AppKit scroller (matches main exactly).

### 2. No Import
- **Cause:** Main's nav bar had **two** buttons: "Add Folder" (`showFolderPicker()`) and "Import New" (`importNew()` — scan data sources for new files). Current state: the menu has **Add Folder…** (⌘⇧O) but **`importNew()` has no UI at all** (neither header nor menu).
- **Fix (small):** Add an Import affordance to the Curated Wall header (`curatedHeaderBar`) — likely a small icon button or an overflow/"…" menu holding Add Folder + Import New + Surprise Me. Also add "Import New" to the app menu for parity.
- **Decision needed:** individual header buttons vs a single "＋/⋯" library-actions menu in the header.

### 3. No Surprise Me
- **Cause:** Menu command still exists (⌘⇧S → `surpriseMePickRandom()`); the **visible** nav-bar button was removed.
- **Fix (small):** Add a Surprise Me button to the header (same overflow menu or a dedicated icon). Pure UI.

### 8. No way to delete a tag
- **Cause:** `deleteTag(_:)` and `renameTag(_:to:)` exist on the VM but are only wired into `BottomFilterColumnsView` (the old bottom strip, not mounted in the Wall). The Wall's tag surfaces (`CuratedWallFiltersDrawer` Tags card, inspector Tags) are **toggle/apply only**.
- **Fix (small–med):** Add delete (and ideally rename) to the drawer's Tags card — e.g. a right-click context menu per tag chip ("Rename…", "Delete Tag") reusing the existing VM methods, with a confirm for delete. Optionally a small "Manage tags" affordance.
- **Decision needed:** context menu on chips vs a dedicated tag-management sheet.

---

## B. Bugs

### 7. "Last used size" doesn't remember full-screen
- **Cause:** The size state persists `playerFloatingSize` and `playerSizeIsCompact`, but **`isPlayerFullScreen` is a runtime-only flag** (not persisted, no key). So if your last session ended in full-screen, "Last used size" reopens at the last *windowed* size.
- **Fix (small):** Persist a "last playback was full-screen" flag (or persist `isPlayerFullScreen`), and on start with `preference == .lastSize`, if it was full-screen, set `isPlayerFullScreen = true` (which now correctly waits for the async player — see the recent full-screen fix). Precedence: full-screen > compact > free size.

---

## C. Investigate

### 6. Delay on first-time play and select
- **Likely causes (needs measurement):**
  - **First play:** `InlinePlaybackController.start()` runs `await AVURLAsset.load(.isPlayable)` *before* creating the `AVPlayer` — a cold-asset load adds latency on first play; the panel shows nothing until the player exists. Subsequent plays are warmer.
  - **First select:** the inspector's `loadHero()` calls `thumbnailService.detailPreviewImage(...)` / `generateFilmstrip(...)`, which can generate on-demand the first time (disk/AV work), delaying the hero.
- **Approach:** instrument with `os_signpost` + `.notice` timings (per the project's perf-instrumentation approach), measure play-start and select-to-hero on cold vs warm, then optimize (e.g. create the `AVPlayer` immediately and validate in parallel; prewarm/cache the detail preview; move work off-main). **Measure before changing.**

---

## D. Design polish (match the mockups)

Reference mockups: `docs/images/workspace-audit-2026-06/curated-wall-full-window-mock.png`, `curated-wall-inspector-detail-mock.png`, `curated-wall-cards-refined-mock.png`.

### 4. Fonts & sizing closer to the mockups
- **Scope:** A typographic/spacing pass across the Wall header, `CuratedWallCard`, and `CuratedWallInspector`. Current code uses ad-hoc `.font(.system(size:))` / `.caption2` values; the mocks have a tighter, more deliberate scale. Best done as one focused pass with the mockups open, ideally leaning on the design tokens (`AppSpacing`, type styles) rather than magic numbers.

### 5. Top video details closer to the mockups
- **Current:** `titleAndActions` (title + Play/Reveal icons) and `factsRow` (only 3 facts: resolution · duration · file size).
- **Mockup target:** larger editable **title** with an edit pencil + a dimmed path/"in folder" line; a **labeled quick-actions row** (Play · Reveal · Quick Tag · Quick Rate); and a **richer, compact facts grid** — Resolution+fps · Duration · File Size · Codec · Date Added · Last Played+Plays · Subtitles (Yes/No / filename) — with small uppercase labels.
- **Fix (med):** Rebuild `titleAndActions` + `factsRow` to that structure. Most data already exists on `Video`; a couple of fields (last played, plays, codec, fps, subtitles) may need surfacing.

---

## Suggested order (low-risk → higher-touch)

1. **Grid scrollbar** (1) — one line, immediate.
2. **Full-screen last-size** (7) — small, self-contained bug.
3. **Import / Surprise Me** (2, 3) — header affordances (bundle together).
4. **Delete tag** (8) — drawer context menu.
5. **Investigate the delay** (6) — measure, then decide.
6. **Design polish: top details** (5), then **fonts/sizing** (4) — the larger visual passes, done against the mockups.

## Decisions (settled)

1. **Scrollbar:** native overlay scroller that respects the macOS "Show scroll bars" system setting — `.scrollIndicators(.visible)` on the SwiftUI `ScrollView`. This is the world-class/native choice (matches Finder/Photos); a forced always-on AppKit scroller would be *less* native, so we avoid it unless later chosen deliberately as a product decision.
2. **Import / Surprise Me:** individual header **icon buttons** in `curatedHeaderBar` (not an overflow menu). Add Folder, Import New, Surprise Me as distinct icons.
3. **Delete tag:** **right-click context menu** on the tag chips (Rename… / Delete Tag), reusing the existing VM methods, with a confirm on delete.
