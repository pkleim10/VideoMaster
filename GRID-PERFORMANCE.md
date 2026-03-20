# Grid view performance — analysis

This document is an **exhaustive** pass over what makes **library grid** mode expensive (especially vs list mode), why **Surprise Me!** can still feel slow after scroll fixes, and what to change next. It maps **symptoms → mechanisms → code locations → mitigations**.

---

## 1. Executive summary

| Area | Severity | Notes |
|------|----------|--------|
| **`ThumbnailService` (was a single `actor`)** | **Was critical** | **Fixed:** `ThumbnailService` is now a **class** with thread-safe `NSCache`; fast `load*` no longer queues behind `generate*`. Detail pane loads are no longer stuck behind hundreds of grid thumbnail jobs. |
| **Full-tree teardown on `filteredVideosVersion`** | **Improved** | Version bumps only when filtered **membership** changes (add/remove/rename id), **not** pure sort/reorder — same video set reorders in place without nuking every cell. `.id` + `contentID` still replace the tree when rows enter/leave the list. |
| **`ForEach(Array(filteredVideos.enumerated()))`** | **Fixed** | **Was** Θ(n) per parent refresh; **now** `ForEach(filteredVideos)`. |
| **`@Bindable` / full `LibraryViewModel` in every cell** | **Improved (P2)** | **`VideoGridCell`** no longer `@Bindable`; narrow inputs + rename binding only for active row. Parent grid still observes full VM. |
| **`ScrollView` + `scrollPosition(id:)` + lazy grid** | **Medium** | Programmatic scroll/sync can still force **layout / identity** work on the lazy container (see §6). |
| **`ScrollbarEnabler` 1s repeating timer** | **Fixed** | No repeating `flashScrollers()`. |
| **Native list virtualization** | **Architectural** | `Table` / `NSTableView` **virtualizes** rows; `LazyVGrid` still creates **many** more SwiftUI subtrees and image views per “screenful”. |

---

## 2. Data flow: what invalidates the grid?

### 2.1 `LibraryViewModel` (`@Observable`)

- **`filteredVideos` / `filteredVideosVersion`** — `applyFilteredVideos` bumps **version** only when the **set** of `video.id` (file paths) in the filtered list **changes** (add/remove/rename path). **Pure sort/reorder** of the same rows does **not** bump. (Older docs incorrectly tied bumps to `databaseId` **order**.)
- **Anything that calls `recomputeFilteredVideos()`** — sidebar filter, tags, search debounce, sort, many DB observers — eventually assigns `filteredVideos`; the **version** increments only when membership of ids changes, not when only order changes.

Relevant: `LibraryViewModel.applyFilteredVideos`, `recomputeFilteredVideos`.

### 2.2 `ResizableSplitView` + `contentID`

- `LibraryContentView` sets  
  `contentID: "\(viewMode)-\(videos.isEmpty)-\(filteredVideosVersion)"`.
- When **`contentID` changes**, the content pane’s `NSHostingView.rootView` is **replaced** (when not frozen). That is a **full** new SwiftUI tree for **toolbar + grid/list + overlays**.
- This was added to fix **stale toolbar** state; it **corrects UI** but **amplifies** the cost of any `filteredVideosVersion` bump.

File: `VideoMaster/Views/ContentView.swift`, `VideoMaster/Views/Components/ResizableSplitView.swift` (`updateNSView`, `lastContentID`).

### 2.3 `.id(filteredVideosVersion)` on the grid (and list)

```text
LibraryGridView:  .id(viewModel.filteredVideosVersion)
LibraryListView:  .id(viewModel.filteredVideosVersion)
```

When the version increments, SwiftUI treats the subtree as a **new** identity: **destroys** child state, **recreates** `LazyVGrid` children, **re-runs** `.task` for thumbnails, etc.

**Sort / reorder:** `applyFilteredVideos` bumps the version only when `Set(video.id)` changes — **not** when the same videos are only reordered (e.g. table sort).

**Interaction with `contentID`:** For the same version bump, you can get **both** a new hosting `rootView` **and** an `.id` tear-down — redundant churn.

File: `VideoMaster/Views/Library/LibraryGridView.swift` (outer `VStack`).

---

## 3. Thumbnail pipeline (largest practical bottleneck)

### 3.1 `ThumbnailService` (class, not actor)

Loads use `NSCache` + disk reads that **do not** wait on generation.

**P0:** `generateThumbnail` and filmstrip builds are **coalesced per path** (one in-flight `Task`, many awaiters) and limited to **4 concurrent** AV jobs via `ThumbnailGenerationGate`.

File: `VideoMaster/Services/ThumbnailService.swift`.

### 3.2 `VideoGridCell` loading strategy

```swift
.task(id: video.filePath) {
    await loadThumbnail()
}
```

- On **appear** / **identity change**, each cell runs `loadThumbnail()`.
- Path: memory miss → disk miss → **`generateThumbnail`** (heavy).
- **Concurrency:** grid `.task`s still **schedule** freely, but **AV generation** is **capped** and **deduped** per path inside `ThumbnailService`.
- **Cancellation:** scrolling away cancels `.task`; shared in-flight work for a path may still **finish** if another consumer is waiting (by design).

File: `VideoMaster/Views/Library/LibraryGridView.swift` (`VideoGridCell`).

### 3.3 List mode contrast

`AsyncThumbnailView` uses the **same** service with `.task(id: filePath)` — generation still goes through the **same capped / coalesced** pipeline when something calls `generateThumbnail`, but:

- Fewer visible thumbnails at once.
- `Table` **reuses** row views more aggressively than a grid of large cells.

File: `VideoMaster/Views/Library/ThumbnailView.swift`.

---

## 4. Grid view construction costs

### 4.1 `ForEach(viewModel.filteredVideos)` (fixed)

- **Was:** `ForEach(Array(enumerated()))` → **Θ(n)** allocation on **every** parent `body` run (selection changes, etc.) — catastrophic at 12k items.
- **Now:** plain `ForEach` on `filteredVideos`; shift‑range uses `lastClickedVideoId` + `firstIndex` on click only.

File: `LibraryGridView.swift`.

### 4.2 Per-cell work

Each cell includes:

- **Heavy layout:** thumbnail area, duration badge, filename, optional metadata row, stars (`ForEach(0..<rating)`).
- **P2 (partial):** `VideoGridCell` no longer uses **`@Bindable var viewModel`**. It takes **`isRenaming`**, **`renameText`** (`.constant("")` when not the rename row), **`videoRepo`**, and small callbacks — so cells are not wired to **every** `LibraryViewModel` change (scan strings, sidebar, etc.). The **parent** `LibraryGridView` still observes the full model.
- **`onHover`** → state updates on mouse moves (many cells).
- **Two `onTapGesture` layers** + **`contextMenu`** building `Menu("Open With")` with **`urlsForApplications`** (filesystem hit) **per menu open**, not per frame — OK, but context menu closure captures `video`.

Files: `LibraryGridView.swift` (`VideoGridCell`).

### 4.3 `GeometryReader` + dynamic `LazyVGrid(columns:)`

- Column array is recomputed from width; **fine**, but ties grid layout to parent geometry passes.
- Resizes cause **relayout**; combined with many images, cost adds up.

---

## 5. Scroll / “Surprise Me!” path (grid)

Current flow:

1. `scrollToVideoId` → short defer, then **`ScrollViewReader.scrollTo(id:, anchor: .center)`** so scroll matches real `LazyVGrid` layout (AppKit geometry estimates were often wrong).

**Risk:** `scrollTo` on a large lazy grid can still be **expensive** (layout work). If profiling shows stalls, consider a hybrid (coarse `NSScrollView` nudge + delayed `scrollTo`) or limiting `scrollTo` to smaller result sets.

Files: `LibraryGridView.swift` (`ScrollViewReader`, `onChange(scrollToVideoId)`).

---

## 6. Auxiliary: `ScrollbarEnabler`

- After 0.2s, finds `NSScrollView` and applies scroller policy **once** (no repeating timer).
- **`flashScrollers()` removed:** it was firing every timer tick **and** on SwiftUI `updateNSView`, forcing full layout on huge lazy grids → multi‑second track clicks and hitchy scrolling.

File: `LibraryGridView.swift` (`ScrollbarEnabler`).

---

## 7. Frozen split view during inline playback

When `freezeContent == true`, **content** `rootView` is **not** updated (`ResizableSplitView`). That avoids grid churn during playback but is unrelated to **browsing** slowness unless users compare behaviors.

File: `ResizableSplitView.swift`.

---

## 8. Recommended direction (prioritized)

### P0 — Thumbnail throughput (biggest win)

**Largely done in tree:** `ThumbnailService` is a **class** (fast `load*` vs `generate*`); **coalescing** per path; **`ThumbnailGenerationGate`** (4 concurrent AV jobs).

**Still optional / next:**
1. **Progressive thumbnails** (small/fast frame → sharp swap).
2. Stronger **cancellation** inside long AV work (`Task.checkCancellation`).
3. **Priority** / visibility hints so on-screen rows win the queue.

### P1 — Reduce full-grid teardown

1. **Reconcile `contentID` vs `.id(filteredVideosVersion)`** — avoid applying **both** full hosting replacement and `.id` for the same semantic change; consider moving toolbar state refresh to a **narrower** subtree (e.g. small observable `ToolbarState` or `InvalidateToolbarToken`) so `contentID` need not include `filteredVideosVersion`.
2. Prefer **ForEach identity** on stable `video.id` without nuking the whole `VStack` when possible.

### P2 — Cell granularity

1. **`VideoGridCell`:** narrow inputs (no `@Bindable` VM) — **done**.
2. **Grid `ForEach`:** no `Array(enumerated())` — **done**. Optional: same **narrow observation** for **list** rows if profiling warrants it.

### P3 — Scroll / scroller hygiene

1. If `scrollTo` is hot on huge libraries: try **coarse `NSScrollView` offset first**, then **one** delayed `scrollTo`, or gate `scrollTo` by library size.
2. ~~**Remove** `ScrollbarEnabler` timer~~ **Done** — no `flashScrollers` churn.

### P4 — Structural (larger projects)

- **`NSCollectionView`** / compositional layout in `NSViewRepresentable` for **true** cell reuse matching Finder-scale libraries.
- **Prefetch** indices near visible rect (UIKit/macOS patterns) wired to thumbnail queue.

---

## 9. How to verify (profiling)

1. **Instruments:** Time Profiler + SwiftUI (if available on your OS) + **System Trace** for main-thread saturation.
2. **os_signpost** around: `applyFilteredVideos`, grid `scrollTo` / `scrollToVideoId`, `ThumbnailService.generateThumbnail` entry/exit, `contentHost.rootView =`.
3. **A/B:** Temporarily short-circuit `generateThumbnail` (return placeholder) — if Surprise Me / scroll becomes instant, the queue/AV path is confirmed dominant.

---

## 10. File index

| Concern | Primary files |
|--------|----------------|
| Grid layout, scroll, cells | `VideoMaster/Views/Library/LibraryGridView.swift` |
| Thumbnails, AV gen, cache | `VideoMaster/Services/ThumbnailService.swift` |
| Filtered list + version | `VideoMaster/ViewModels/LibraryViewModel.swift` |
| Content host replacement | `VideoMaster/Views/ContentView.swift`, `ResizableSplitView.swift` |
| List / table path | `VideoMaster/Views/Library/LibraryListView.swift`, `ThumbnailView.swift` |

---

*Last updated: aligns with v0.6.x work — ScrollViewReader scroll, ScrollbarEnabler fix, `ForEach` without `enumerated()`, thumbnail gate + coalesce, `VideoGridCell` narrow inputs, `filteredVideosVersion` = membership-only, `contentID` + `.id` still duplicated (future reconcile).*
