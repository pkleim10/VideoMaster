# VideoMaster User Guide

Welcome! This guide is for **people**, not engineers. It mixes a gentle **getting-started** path with a **reference** section you can skim later.  
Figures use a shared [placeholder](images/placeholder.svg) until you add real screenshots — see [images/README.md](images/README.md) for filenames and capture tips.

---

## Welcome to VideoMaster

**What it is**  
VideoMaster helps you **browse and organize video files** that live in folders on your Mac. It doesn’t move your originals into a mystery box: it **indexes** what you point it at, then gives you a fast grid or list, search, a **filter strip** (library slices, collections, per-star filter, tags), **tags** and **star ratings**, optional **custom metadata**, and a detail pane for each file.

**What a library is**  
A **library** is a single database file that remembers your folders, tags, ratings, collections, custom field definitions (and values), and what it learned about each video. Your actual videos stay where they are on disk. You can have more than one library (for example, work vs. home) and switch between them from the **File** menu.

**Who it’s for**  
Anyone with lots of clips — editors, archivists, or “I have three hard drives of family videos” folks — who wants one place to **find** and **open** things without hunting in Finder.

![Main window overview (placeholder)](images/placeholder.svg)  
*Later: replace with `main-window.png` — full window with browsing pane, bottom filter strip, and detail.*

---

## First launch: create or open a library

When you don’t have a library open yet, you’ll see a simple screen with a few big buttons.

![Landing screen (placeholder)](images/placeholder.svg)  
*Later: `landing.png`.*

**Typical paths:**

1. **Create library in default location** — quickest start if you’re fine with the app’s default spot.
2. **Create library…** — you choose **where** the library file should live (and what it’s called).
3. **Open library…** — open an existing `.videomaster` (or library) file you already have.
4. **Open recent** — shortcuts to libraries you used before.

You can do the same things from the menu bar: **File** → **New Library…**, **Open Library…**, **Open Recent**, etc.

> **Tip:** **Settings → Application** (appearance) is always available. Other tabs need an **open library**.

---

## Tour of the main window

The window splits **vertically** into two main areas (drag the **vertical** divider to change how wide the browser is vs. the detail pane). Inside the **left** area, a **horizontal** splitter separates the **list or grid** from the **filter strip** below it.

| Area | What it does |
|------|----------------|
| **Left — Browser** | **Top:** **Grid** or **list** of videos; **search** is in the toolbar here. **Bottom:** **Filter strip** — four columns (**Library**, **Collections**, **Rating**, **Tags**) to choose which videos appear. You can **collapse** this strip to reclaim space (**View** menu **⌥⌘F**, or context menu on the list/grid). When collapsed, the strip has no height but the **splitter** stays so you can drag it back. |
| **Right — Detail** | **Preview** on top (thumbnail or **filmstrip**), **metadata and actions** below (name, path, tags, ratings, **custom metadata**, play buttons, and more). |

The **toolbar** above the browsing pane has things you’ll use often: **Add Folder**, **Import New**, **List / Grid**, **Surprise Me!**, sorting, and (in list mode) **Columns**. The **status bar** at the very bottom shows counts and import progress.

![Toolbar and browsing area (placeholder)](images/placeholder.svg)  
*Later: `toolbar.png` or crop of main window.*

---

## Everyday tasks

### Add folders (data sources)

VideoMaster only knows about videos inside **folders you add**.

1. Click **Add Folder** in the toolbar (or **File** → **Add Folder…**, shortcut **⇧⌘O**).
2. Choose one or more folders. The app will **scan** them for video files (see **File extensions** in Settings if something’s missing).

**Import New** rescans those folders for **new** files since the last time — handy after you’ve dropped more clips onto a drive.

*Why it matters:* Without a data source, your library stays empty even if you have terabytes of video elsewhere.

---

### Grid vs. list

Use the **segmented control** in the toolbar:

- **Grid** — visual thumbnails; great for skimming.
- **List** — sortable columns; great for names, dates, and batch selection. Changing sort (toolbar or column headers) clears multi-selection; with exactly one video selected, the grid or list scrolls to that item.
- **List columns** — In **Settings → Library**, choose which standard metadata columns (duration, resolution, size, rating, date added, plays, created, last played) and which custom metadata fields appear. Name is always shown. **Multiline Text** custom fields are not available as list columns. In list mode, the toolbar **Columns** button opens the same options. Up to **16** custom fields can appear as columns at once (alphabetical order). You can still reorder and resize columns from the table header.

Your choice is remembered.

![Grid view (placeholder)](images/placeholder.svg)  
*Later: `grid-view.png`.*

![List view (placeholder)](images/placeholder.svg)  
*Later: `list-view.png`.*

---

### Search

Type in the **search field** above the browsing pane. Search matches **file names** (and uses the app’s full-text index when you’re searching). Combine search with **filter strip** choices (library slice, collections, rating, tags) to narrow things down.

---

### Library filter

In the **Library** column of the **bottom filter strip**, you’ll see entries like:

- **All Videos** — no extra filter.
- **Recently Added** / **Recently Played** / **Top Rated** — smart slices (you can tune windows and visibility in **Settings → Library**).
- **Duplicates** — files that look like duplicates by size and duration (a handy cleanup aid).
- **Corrupt** — files that never got useful duration/resolution metadata (often damaged or wrong type).
- **Missing** — files the library thinks should exist but aren’t on disk anymore.

Choosing **Missing** starts a scan for files that are no longer on disk. You can run **Scan for missing files** again from the toolbar while that filter is active.

Which rows appear here is controlled in **Settings → Library** under **Sidebar Filters**.

---

### Collections

**Collections** are saved groups built from **rules** (for example, “tag contains Vacation” AND rating ≥ 4). They appear under **COLLECTIONS** in the filter strip.

- Click **New Collection** to build one.
- Right-click a collection to **edit** or **delete** it.

![Collection editor (placeholder)](images/placeholder.svg)  
*Later: `collection-editor.png`.*

---

### Ratings

Under **RATING** in the filter strip, pick **1–5 stars** to filter to that rating (this is separate from **Top Rated** in the Library column). When a star filter is active, **Remove Filter** appears in the column header; **View → Clear Filters** (**⌥⌘C**) clears tag filters and this rating filter together when applicable. In the **detail** pane you can change the rating for the current selection (or multiple selected videos).

---

### Tags

Under **TAGS** in the filter strip, click a **tag** to filter by it. Next to the header, the small **ALL** / **ANY** pill toggles whether videos must have **every** selected tag or **at least one**. The **×** button clears tag filters only. **View → Clear Filters** (**⌥⌘C**) clears **both** selected tags and an active per-star **rating** filter (when those filters are on).

In the **detail** pane, tags show as **chips**: click to add or remove tags for the selected video(s). Active tags are easy to spot.

---

### Play videos

- **Play Video** / inline player in the detail pane — watch inside the app; **Space** toggles play/pause when you’re not typing in a field.
- **Play in External Player** — **File** menu or context menu; shortcut **⌘Return** opens the default app for that file.
- **Filmstrip** — switch the preview to a strip of frames; **click a frame** to start inline playback from that point.
- **Surprise Me!** — picks a random video from the **current filtered list**, scrolls to it, and can auto-play (see **Settings → Video**).

---

### Rename

- **Click the file name** in the detail pane to edit, or press **Return** (Enter) with **exactly one** video selected in grid or list (when you’re not already in a text field).
- **Escape** cancels rename.

---

### Delete vs. remove from library

- **Delete** — moves the **actual file** to the **Trash** (subject to **Confirm deletions** in Settings).
- **Remove from Library** — removes the entry from the library **without** trashing the file on disk.

Both are in context menus and the **File** menu. **⌘Delete** triggers delete (with confirmation if enabled). **⇧⌘R** removes from library.

---

### Drag and drop

You can **drop folders or files** onto the browsing pane to import — useful when you already have Finder open.

---

### Settings

Open **VideoMaster → Settings…** (standard macOS Settings window).

| Tab | What you’ll find |
|-----|-------------------|
| **Application** | **Appearance:** **System** (follow macOS light/dark), **Light**, or **Dark** (locks the app to that style). |
| **Library** | Exclude corrupt files from most filters, confirm before delete, which **Library** filter-strip rows show (Recently Added, Duplicates, Missing, …) and their options. **List view columns** — which standard and custom metadata columns appear in list view (same choices as the toolbar **Columns** button). The bottom **filter strip** can be **expanded** or **collapsed** from the **View** menu (**⌥⌘F**), or via the context menu on the list/grid (when the strip has height, you can also use its context menu). Your **saved splitter height** for the strip is unchanged when you collapse. When collapsed, the strip has **no height**; the **horizontal splitter** remains so you can drag it to reveal filters again. *(Requires an open library.)* |
| **Video** | Default **filmstrip** grid (rows × columns), regenerate filmstrips, **Surprise Me!** auto-play, **maximum large preview thumbnail (long-edge)**, **auto adjust video pane** toggle (splitter fits preview to media). *(Requires an open library.)* |
| **Data Sources** | List of watched folders, add/remove, **Show in Finder**. *(Requires an open library.)* |
| **File Ext** | Which extensions count as video when scanning; add custom extensions or reset to defaults. *(Requires an open library.)* |
| **Custom Metadata** | Define field **names** and **types** (String, Text, Number, Date, Date & Time); add or remove definitions with **+** / **−**. Enter and edit values in the **detail** pane for selected video(s). Which fields appear as **list** columns is configured under **Library** (not here). *(Requires an open library.)* |

![Settings Library tab (placeholder)](images/placeholder.svg)  
*Later: `settings-library.png`.*

---

## If something goes wrong

- **Empty library** — Add a **data source** folder and use **Import New**; check **Settings → File Ext** if your files use an unusual extension.
- **Videos “missing”** — You moved or deleted files outside the app; choose the **Missing** filter (it scans automatically), or use **Scan for missing files** in the toolbar to refresh, then fix paths or remove stale entries.
- **Corrupt bucket** — Those files lack normal metadata; they might not be real videos or need re-encoding. They’re still visible under **Corrupt** even if hidden elsewhere.
- **Weird window columns after a crash** — Recent builds **sanitize saved layout**; if it ever happens again, drag dividers back once — values are clamped on save now.
- **List view crashed while deleting** — Update to the latest version; list scrolling was hardened against that crash.

When in doubt, **File** → **Open Library…** and pick your library file again — you won’t lose videos, only the app’s window state might reset.

---

## Reference for experienced users

### Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| **⇧⌘S** | Surprise Me! |
| **⌥⌘C** | **Clear Filters** — clears selected tag filters and an active per-star rating filter (**View** menu; disabled when neither applies) |
| **⌥⌘T** | Toggle **Thumbnail** / **Filmstrip** in the detail preview (same as the segmented control) |
| **⌥⌘F** | Expand / collapse the bottom **filter strip** |
| **⌘Delete** | Delete selected video(s) (confirmation if enabled) |
| **⇧⌘R** | Remove selected from library |
| **⇧⌘O** | Add Folder… |
| **⌘Return** | Play in external player |
| **Return** | Start rename (single selection, grid/list, not in a text field) |
| **Escape** | Cancel rename, stop inline playback, or cancel tag rename |
| **Space** | Play/pause inline player (when not typing in a text field) |

**No shortcut today:** **Open Library…** and **Show in Finder** are menu-only. On many Mac apps **⌘O** means “Open…” — VideoMaster does **not** assign **⌘O** to **Open Library…** yet; use the menu or landing buttons. **⇧⌘O** is **Add Folder**.

---

### Menu map (File-focused)

Under **File** (exact labels may vary slightly by OS language):

- **Add Folder…** — add watched folder(s).  
- **Delete…** / **Remove from Library** — selection actions.  
- **Play in External Player** / **Show in Finder** / **Open With** — work with the current selection.  
- **Create library in default location** / **New Library…** / **Open Library…** / **Open Recent** — library lifecycle.  
- **Save Copy…** — backup library file.  
- **Close Library…** / **Delete This Library…** — close or delete the **database** (not your video files).

Other commands live under **VideoMaster** (About, Settings, etc.) and the **View** / **Window** menus as macOS provides. **View** includes **Surprise Me!**, **Clear Filters** (⌥⌘C, when tag or per-star rating filters are active), **Toggle Thumbnail / Filmstrip** (⌥⌘T), and **Expand/Collapse Filter Strip** (⌥⌘F).

---

### Glossary

| Term | Meaning |
|------|---------|
| **Library** | The app’s database for one workspace: folders, metadata, tags, collections. |
| **Data source** | A folder on disk that VideoMaster scans for videos. |
| **Import New** | Rescan data sources for files that aren’t in the library yet. |
| **Filtered list** | Whatever appears in the grid/list **after** filter strip + search rules — Surprise Me only picks from here. |
| **Filter strip** | Bottom of the browser column: **Library**, **Collections**, **Rating**, **Tags**; can be collapsed (**⌥⌘F**). |
| **Custom metadata** | User-defined fields (Settings); values edited in the **detail** pane; optional **list** columns. |
| **Collection** | A saved smart group defined by rules. |
| **Corrupt** (filter) | Videos missing both duration and resolution in metadata — often unusable clips. |
| **Duplicates** (filter) | Same size and duration as another file — likely copies (verify before deleting). |
| **Missing** (filter) | Library path no longer exists on disk. |
| **Filmstrip** | Preview mode showing a grid of frames from the video. |
| **Inline playback** | Playing inside the detail pane with the built-in player. |

---

### Where this doc lives

- Guide: `docs/USER_GUIDE.md` (this file).  
- Screenshot checklist: `docs/images/README.md`.

---

*Happy browsing — may your duplicates be few and your filmstrips load fast.*
