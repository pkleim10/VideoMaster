# VideoMaster — Feature Analysis & Improvement Suggestions

**User documentation:** [docs/USER_GUIDE.md](docs/USER_GUIDE.md) — getting started, everyday tasks, settings, shortcuts, and glossary (conversational tone; screenshot placeholders in [docs/images/](docs/images/)).

## Current Feature Set (Summary)

**Library & Browsing:** Grid/List views, sortable columns, search (filename only), sidebar filters (All, Recently Added, Recently Played, Top Rated, Corrupt), collections with rule-based membership, tag filtering (multi-select, AND/ANY).

**Metadata & Organization:** Star ratings, tags, play count, last played, inline file renaming.

**Playback:** Inline AVPlayer in detail pane, filmstrip click-to-seek, external player, Surprise Me.

**Data:** SQLite + GRDB, FTS5 table, data sources (folders), layout/preference persistence.

---

## Suggested Improvements

### Polish & UX

1. **Video notes** — Add an optional notes field per video for personal annotations.

2. **Filter section visibility** — Allow Library, Collections, Rating, and Tags filter sections to be individually shown or hidden quickly. **Control via context menus** (e.g. on each section header: show/hide with checkmarks), so users can reduce clutter or focus on one filter type without opening Settings.

### Future / Larger Scope

3. **Custom metadata** — User-defined key-value metadata (e.g. "Director", "Location").

5. **Full documentation (web-based)** — Comprehensive user and developer documentation hosted on the web.

---

### Completed

- **Keyboard shortcuts** — Done.

- **Appearance (Light / Dark / System)** — Done. Settings → Application. Menu commands include Cmd+Delete (delete), Cmd+Shift+R (remove from library), Cmd+Return (play in external player), Cmd+Shift+O (add folder), Cmd+Shift+S (Surprise Me), Cmd+Option+T (clear tag filters), and others; discoverable in the menu bar when a library is open.

