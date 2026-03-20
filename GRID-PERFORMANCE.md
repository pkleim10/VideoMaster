# Grid view performance — analysis

This document is an **exhaustive** pass over what makes **library grid** mode expensive (especially vs list mode), why **Surprise Me!** can still feel slow after scroll fixes, and what to change next. It maps **symptoms → mechanisms → code locations → mitigations**.

---

## 1. Executive summary

| Area | Severity | Notes |
|------|----------|--------|
| **`ThumbnailService` (was a single `actor`)** | **Was critical** | **Fixed:** `ThumbnailService` is now a **class** with thread-safe `NSCache`; fast `load*` no longer queues behind `generate*`. Detail pane loads are no longer stuck behind hundreds of grid thumbnail jobs. |
| **Full-tree teardown on `filteredVideosVersion`** | **High** | `.id(filteredVideosVersion)` on the grid **and** `contentID` including the same version → **entire** grid (and often entire content `NSHostingView`) replaced; **all** `@State` in cells (e.g. decoded `NSImage`) discarded → **re-hit** thumbnail pipeline. |
| **`ForEach(Array(filteredVideos.enumerated()))`** | **Medium–High** | **O(n) allocation** on **every** `body` refresh of the parent; amplifies any frequent invalidation. |
| **`@Bindable` / full `LibraryViewModel` in every cell** | **Medium** | Each `VideoGridCell` is wired to the whole observable model (`renamingVideoId`, `renameText`, `videoRepo`, …). Broad invalidations can fan out to **many** cells. |
| **`ScrollView` + `scrollPosition(id:)` + lazy grid** | **Medium** | Programmatic scroll/sync can still force **layout / identity** work on the lazy container (see §6). |
| **`ScrollbarEnabler` 1s repeating timer** | **Low–Medium** | `flashScrollers()` every second → unnecessary layout / scroller work while the grid is visible. |
| **Native list virtualization** | **Architectural** | `Table` / `NSTableView` **virtualizes** rows; `LazyVGrid` still creates **many** more SwiftUI subtrees and image views per “screenful”. |

---

## 2. Data flow: what invalidates the grid?

### 2.1 `LibraryViewModel` (`@Observable`)

- **`filteredVideos` / `filteredVideosVersion`** — `applyFilteredVideos` bumps **version** when **structure** changes (count or `databaseId` order). Renames that keep order **do not** bump (good for scroll).
- **Anything that calls `recomputeFilteredVideos()`** — sidebar filter, tags, search debounce, sort, many DB observers — eventually replaces `filteredVideos` and may bump version.

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

**Interaction with `contentID`:** For the same version bump, you can get **both** a new hosting `rootView` **and** an `.id` tear-down — redundant churn.

File: `VideoMaster/Views/Library/LibraryGridView.swift` (outer `VStack`).

---

## 3. Thumbnail pipeline (largest practical bottleneck)

### 3.1 `ThumbnailService` (class, not actor)

Loads use `NSCache` + disk reads that **do not** wait on generation. `generateThumbnail` / `buildFilmstrip` remain `async` and can run concurrently for different files.

File: `VideoMaster/Services/ThumbnailService.swift`.

### 3.2 `VideoGridCell` loading strategy

```swift
.task(id: video.filePath) {
    await loadThumbnail()
}
```

- On **appear** / **identity change**, each cell runs `loadThumbnail()`.
- Path: memory miss → disk miss → **`generateThumbnail`** (heavy).
- **No global concurrency limit** at the **task** layer: tasks **pile up**; the **actor** drains them **one at a time** → wall-clock delay grows with library size and scroll distance.
- **Cancellation:** scrolling away cancels `.task`, but anything already running on the actor still **blocks** the queue.

File: `VideoMaster/Views/Library/LibraryGridView.swift` (`VideoGridCell`).

### 3.3 List mode contrast

`AsyncThumbnailView` uses the **same** service with `.task(id: filePath)` — same actor bottleneck **in principle**, but:

- Fewer visible thumbnails at once.
- `Table` **reuses** row views more aggressively than a grid of large cells.

File: `VideoMaster/Views/Library/ThumbnailView.swift`.

---

## 4. Grid view construction costs

### 4.1 `ForEach(Array(viewModel.filteredVideos.enumerated()), ...)`

- Builds a **new** `Array` of `(offset, element)` pairs **whenever** the parent `body` runs.
- Cost **Θ(n)** in **number of filtered videos**, even when `LazyVGrid` only **lays out** a subset.
- **Mitigation:** `ForEach(viewModel.filteredVideos)` and derive range selection without storing index in `ForEach` (e.g. anchor id in `@State`, or `firstIndex` only on shift-click path).

File: `LibraryGridView.swift`.

### 4.2 Per-cell work

Each cell includes:

- **Heavy layout:** thumbnail area, duration badge, filename, optional metadata row, stars (`ForEach(0..<rating)`).
- **`@Bindable var viewModel`** — entire `LibraryViewModel` in **every** cell.
- **`TextField` bound to `$viewModel.renameText`** only when renaming, but type still carries full observable wiring.
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

- After 0.2s, finds `NSScrollView`, then starts **`Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true)`** calling `configureScroller` and **`flashScrollers()`**.
- **Effect:** perpetual UI churn while the grid is open.

File: `LibraryGridView.swift` (`ScrollbarEnabler`).

---

## 7. Frozen split view during inline playback

When `freezeContent == true`, **content** `rootView` is **not** updated (`ResizableSplitView`). That avoids grid churn during playback but is unrelated to **browsing** slowness unless users compare behaviors.

File: `ResizableSplitView.swift`.

---

## 8. Recommended direction (prioritized)

### P0 — Thumbnail throughput (biggest win)

1. **Stop serializing all work on one `actor`.** Typical pattern:
   - **Memory + disk “read” path** on `MainActor` with `NSCache` + quick disk read (or a small dedicated queue for disk reads only).
   - **Generation** on a **background** task with a **bounded** semaphore (e.g. 3–4 concurrent `AVAssetImageGenerator` jobs), then publish result on main actor.
2. **Coalesce** `generateThumbnail` per `filePath` (single in-flight future shared by multiple awaiters).
3. Ensure `.task` **cancellation** propagates into generation (check `Task.isCancelled` / `async let` groups).

### P1 — Reduce full-grid teardown

1. **Reconcile `contentID` vs `.id(filteredVideosVersion)`** — avoid applying **both** full hosting replacement and `.id` for the same semantic change; consider moving toolbar state refresh to a **narrower** subtree (e.g. small observable `ToolbarState` or `InvalidateToolbarToken`) so `contentID` need not include `filteredVideosVersion`.
2. Prefer **ForEach identity** on stable `video.id` without nuking the whole `VStack` when possible.

### P2 — Cell granularity

1. Replace **`@Bindable var viewModel`** in cells with **narrow** inputs: `isSelected`, `isRenamingThisRow`, callbacks, optional `Binding` only for the one row being renamed.
2. Replace `Array(enumerated())` with plain `ForEach(videos)`.

### P3 — Scroll / scroller hygiene

1. If `scrollTo` is hot on huge libraries: try **coarse `NSScrollView` offset first**, then **one** delayed `scrollTo`, or gate `scrollTo` by library size.
2. **Remove or drastically reduce** `ScrollbarEnabler` timer; configure scroller once or on bounds changes.

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

*Last updated: performance deep-dive (grid vs list, Surprise Me, thumbnail actor, identity churn).*
