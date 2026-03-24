# VideoMaster — Feature Analysis & Improvement Suggestions

**User documentation:** [docs/USER_GUIDE.md](docs/USER_GUIDE.md) — getting started, everyday tasks, settings, shortcuts, and glossary (conversational tone; screenshot placeholders in [docs/images/](docs/images/)).

## Current Feature Set (Summary)

**Library & Browsing:** Grid/List views, sortable columns, search (filename only), sidebar filters (All, Recently Added, Recently Played, Top Rated, Corrupt), collections with rule-based membership, tag filtering (multi-select, AND/ANY).

**Metadata & Organization:** Star ratings, tags, play count, last played, inline file renaming.

**Playback:** Inline AVPlayer in detail pane, filmstrip click-to-seek, external player, Surprise Me.

**Data:** SQLite + GRDB, FTS5 table, data sources (folders), layout/preference persistence.

---

## Suggested Improvements

### Future / Larger Scope

1. **Custom metadata** — User-defined key-value metadata (e.g. "Director", "Location"). **Video notes** are a special case of this (e.g. a long-text field or a built-in "Notes" key), not a separate feature.

2. **Full documentation (web-based)** — Comprehensive user and developer documentation hosted on the web.

---

### Completed

- **Keyboard shortcuts** — Done. Menu commands include Cmd+Delete (delete), Cmd+Shift+R (remove from library), Cmd+Return (play in external player), Cmd+Shift+O (add folder), Cmd+Shift+S (Surprise Me), Cmd+Option+T (clear tag filters), and others; discoverable in the menu bar when a library is open.

- **Appearance (Light / Dark / System)** — Done. Settings → Application.

