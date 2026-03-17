# VideoMaster — Feature Analysis & Improvement Suggestions

## Current Feature Set (Summary)

**Library & Browsing:** Grid/List views, sortable columns, search (filename only), sidebar filters (All, Recently Added, Recently Played, Top Rated, Corrupt), collections with rule-based membership, tag filtering (multi-select, AND/ANY).

**Metadata & Organization:** Star ratings, tags, play count, last played, inline file renaming.

**Playback:** Inline AVPlayer in detail pane, filmstrip click-to-seek, external player, Surprise Me.

**Data:** SQLite + GRDB, FTS5 table, data sources (folders), layout/preference persistence.

---

## Suggested Improvements

### High Impact, Low Effort

1. **Use FTS5 for search** — The `video_fts` table and `VideoRepository.search()` exist, but `LibraryViewModel` uses `fileName.contains(query)`. Switching to FTS5 would give token-based search and better performance on large libraries.

2. **Batch tag apply** — When multiple videos are selected, allow applying or removing tags in one action instead of per-video.

3. **Configurable "Recently Added"** — Currently hardcoded to 7 days. Add a setting (e.g. 7/14/30 days) or a "Recently Added" submenu.

4. **Quick Look preview** — Use `NSWorkspace.shared.open(url, configuration: .init())` or `QLPreviewPanel` so users can preview videos without opening the full player.

### Medium Impact

5. **Auto-import from data sources** — Data sources are stored but not wired up. Add a background scan or "Scan data sources" that imports new files from configured folders.

6. **Duplicate detection** — Detect duplicates by file size + duration, or by content hash, and surface them (e.g. "Possible duplicates" collection or filter).

7. **Share sheet** — Add a Share button that uses `NSSharingServicePicker` for selected videos.

8. **Playlist export** — Export selected videos as M3U/M3U8 or a simple text list of paths for use in other players.

### Polish & UX

9. **Keyboard shortcuts** — Document and add shortcuts for common actions (e.g. Cmd+Delete for delete, Cmd+O for open in Finder, Cmd+E for external play).

10. **Video notes** — Add an optional notes field per video for personal annotations.

11. **Collection rule OR logic** — Collections use AND/ANY for tags, but rules within a collection are always AND. Add an option for OR between rules (e.g. "Name contains X OR Tag = Y").

12. **Filmstrip timing accuracy** — As discussed: tighten `AVAssetImageGenerator` tolerance and use `seek(to:toleranceBefore:toleranceAfter:)` with zero tolerance for more accurate seeks.

### Future / Larger Scope

13. **Custom metadata** — User-defined key-value metadata (e.g. "Director", "Location").

14. **Database backup/restore** — Export/import the SQLite DB for backup or migration.

15. **Smart collections** — Predefined collections like "Unwatched" (play count = 0), "Long videos" (duration > X), "Large files" (size > X).

---

## Quick Wins

- **FTS5 search** — Small change, big search improvement.
- **Batch tag apply** — UI change in the detail pane when multiple videos are selected.
- **Quick Look** — One or two API calls for preview support.
