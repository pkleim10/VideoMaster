# VideoMaster — Feature Analysis & Improvement Suggestions

## Current Feature Set (Summary)

**Library & Browsing:** Grid/List views, sortable columns, FTS5 search (debounced, token-based), sidebar filters (All, Recently Added, Recently Played, Top Rated, Corrupt), collections with rule-based membership, tag filtering (multi-select, AND/ANY).

**Metadata & Organization:** Star ratings, tags, play count, last played, inline file renaming.

**Playback:** Inline AVPlayer in detail pane, filmstrip click-to-seek, external player, Surprise Me.

**Data:** SQLite + GRDB, FTS5 table, data sources (folders), layout/preference persistence.

---

## Suggested Improvements

### High Impact, Low Effort

1. ~~**Use FTS5 for search**~~ — **Done** (build 60). Search now uses FTS5 with 250ms debounce.

2. ~~**Batch tag apply**~~ — **Already implemented**. `addTag(_:toVideos:)` and `removeTag(_:fromVideos:)` handle multi-select tagging.

3. ~~**Configurable "Recently Added"**~~ — **Done** (build 62). Settings for Recently Added days, Recently Played days, and Top Rated minimum rating.

4. ~~**Quick Look preview**~~ — **Will not implement**.

### Medium Impact

5. ~~**Auto-import from data sources**~~ — **Already implemented**. Data sources are scanned and new files are imported automatically.

6. **Duplicate detection** — Detect duplicates by file size + duration, or by content hash, and surface them (e.g. "Possible duplicates" collection or filter).

7. ~~**Share sheet**~~ — **Will not implement**.

8. ~~**Playlist export**~~ — **Will not implement**.

### Polish & UX

9. **Keyboard shortcuts** — Document and add shortcuts for common actions (e.g. Cmd+Delete for delete, Cmd+O for open in Finder, Cmd+E for external play).

10. **Video notes** — Add an optional notes field per video for personal annotations.

11. ~~**Collection rule OR logic**~~ — **Already implemented**. Collections have an ALL/ANY toggle that switches between AND and OR for rules.

12. ~~**Filmstrip timing accuracy**~~ — **Will not implement**.

### Future / Larger Scope

13. **Custom metadata** — User-defined key-value metadata (e.g. "Director", "Location").

14. ~~**Database backup/restore**~~ — **Already implemented**. Save Copy and library import/export via the File menu.

15. ~~**Smart collections**~~ — **Will not implement**.

---

## Left to Implement

- **6. Duplicate detection** — Detect duplicates by file size + duration, or by content hash.
- **9. Keyboard shortcuts** — Document and add shortcuts for common actions.
- **10. Video notes** — Optional notes field per video for personal annotations.
- **13. Custom metadata** — User-defined key-value metadata (e.g. "Director", "Location").
