# Playback Redesign — Single Resizable Player

**Date:** 2026-06-30
**Supersedes:** the three-mode playback model (detail pane / overlay / full screen) analyzed in `Playback_Audit_2026-06-29.md`.
**Status:** Approved direction. Implementation plan.

## Concept (decided)

One player surface, with **size** as a continuous property instead of three discrete modes:

```
compact (inspector-hero footprint) → any in-window size → TRUE full-screen
            \________ one AVPlayer carried across, never restarted ________/
```

- A **resizable floating player** anchored to the window's **top-right**, resized by a **lower-left drag handle**; minimum size = the inspector-hero footprint, maximum = window content area. Size is persisted.
- **Compact** sits over the hero spot, leaving the inspector tools visible (rate/tag/note while watching).
- **Larger** sizes occlude the wall/tools — fine, you're watching.
- **True full-screen** (borderless, edge-to-edge, menu bar/Dock hidden) is the immersive maximal state — *not* "fill the window." Backed by the **same** `InlinePlaybackController` player, re-hosted in the borderless window (no re-buffer, position + subtitles preserved). Reuses `FullscreenInlinePlayerWindowController`, fed the existing player.
- **Starting-size preference**: `compact | fullScreen | specific(W×H)`, plus remember-last.

## Architecture

- **`InlinePlaybackController`** (exists) stays the single engine: owns the `AVPlayer` + `SubtitleTrack`, resume load/save, errors, recordPlay, play-pause/restart. The player **instance** is shared by whichever host is showing it.
- **`FloatingPlayerPanel`** (new) — the in-window resizable host. Renders `controller.player` (via `FloatingPlayerView`/`KeyAwarePlayerView`) + subtitle overlay + resume banner + error overlay + a compact header (filename, size presets, full-screen button, close). Owns the lower-left resize handle.
- **Full-screen** — `FullscreenInlinePlayerWindowController` re-hosts the *same* player; on exit, control returns to `FloatingPlayerPanel` at the prior size.
- **Inspector hero** — always shows the still/filmstrip (preview + click-to-seek to start). The floating player overlays it while playing; stopping reveals the still again.
- **Keyboard** lives on the focused player view (`KeyAwarePlayerView.keyDown`): Space (play/pause), restart, full-screen toggle, Esc (exit/stop), plus the **⌘⌥R** menu command as a reliable alternate. This retires the global-monitor key dance.

## State model

Add (alongside the old fields at first, so each step builds):

- `isPlayingInline: Bool` — keep (playback active).
- `playerFloatingSize: CGSize` — current in-window size (persisted as last size).
- `isPlayerFullScreen: Bool` — true OS full-screen active.
- `playerStartPreference: PlayerStartPreference` (`.compact | .fullScreen | .specific(w,h)`), persisted.

On play: size = preference (compact → min/hero; specific → that; fullScreen → enter full-screen).

## To be deleted (by the end)

- `InlinePlaybackMode`, `setInlinePlaybackMode`, `playInlineStartsFullscreen`, `playInlineInOverlay`, `inlineOverlayActive`, `inlinePlaybackMode`, `overlayPlayerWidth`.
- `OverlayInlinePlayerView` / `OverlayPlayerPanel` (folded into `FloatingPlayerPanel`).
- The inspector hero's *player* branch (it goes back to still/filmstrip only).
- The `inlinePlayPauseToggle` / `inlineRestartFromBeginning` counters.
- The dead `VideoDetailView` + legacy `libraryContent`/`contentBody`/`libraryNavBar`/`detailContent` chain.
- The ⌥⌘1/2/3 mode menu commands → replaced by a full-screen toggle + size presets.

## Checkpoints (each builds + installs)

1. **State model** — add `playerFloatingSize`, `isPlayerFullScreen`, `PlayerStartPreference` + persistence. No behavior change yet. (Old mode fields remain temporarily.)
2. **`FloatingPlayerPanel` at compact size** — single in-window player host (subtitles, resume, error, header, close), wired to the controller for start/stop. Replace the inspector-hero player branch and the overlay panel with this. **Restores working playback** (fixes the current build-483 breakage) at compact size.
3. **Resize** — lower-left drag handle, min (hero) / max (window) clamps, size persistence, size presets in the header.
4. **True full-screen carry-across** — full-screen button moves the controller's player into `FullscreenInlinePlayerWindowController`; Esc/close returns to the in-window panel at the prior size.
5. **Preferences** — starting-size preference UI (Settings) + apply on play.
6. **Delete the old mode machinery** + dead `VideoDetailView`/legacy layout; clean up menus; finalize keyboard.

## How this satisfies the locked requirements

- **Filmstrip click → seek-and-play, any size:** one path; the click time opens the player at the preferred size, seeked precisely.
- **Respect the starting-size preference:** the preference *is* the size; no discrete modes to drift.
- **Subtitles in every size:** one subtitle overlay scales with the one player.
- **Save-on-stop / resume:** one controller persists position regardless of size or full-screen.
- **Keyboard:** handled on the single focused player surface; ⌘⌥R as the reliable restart alternate.
