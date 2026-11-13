---
title: MacAMP — macOS Interface & Visual Specification
description: A recreation-grade spec of MacAMP's macOS shell — design tokens, components, every screen, and the visual language.
---

# MacAMP — macOS Interface & Visual Specification

macOS is MacAMP's **reference, release-quality surface**. This document is a
*recreation spec*: it captures the design tokens, reusable components, screen
layouts, and visual language precisely enough for a designer or engineer to
rebuild the same interface — on macOS or another platform.

The shell (`macampMac`) is a pure **SwiftUI** view layer over the shared
[`PlayerCore`](../PlayerCore/README.md) package. All state comes from PlayerCore's
`@Observable` view models; this target contributes only views, window/menu
plumbing, and macOS-specific glue (AppKit-backed media keys, folder watching,
Sparkle updates, the optional projectM visualizer).

> **Token values are authoritative** — read from
> [`PlayerCore/Sources/DesignSystem`](../PlayerCore/Sources/DesignSystem). Every
> screen composes from these; there are **no magic numbers** in the components.
> The *portable theme-extraction algorithm* lives in the
> [PlayerCore spec](../PlayerCore/README.md#11-design-system-logic-designsystem).

---

## Table of contents

1. [Design tokens](#1-design-tokens)
2. [Album theming](#2-album-theming)
3. [Reusable components](#3-reusable-components)
4. [App & window structure](#4-app--window-structure)
5. [Main window layout](#5-main-window-layout)
6. [Screen by screen](#6-screen-by-screen)
7. [Player bar](#7-player-bar)
8. [Menu bar & visualizer](#8-menu-bar--visualizer)
9. [Visual language summary](#9-visual-language-summary)
10. [Responsive behavior & interaction](#10-responsive-behavior--interaction)

---

## 1. Design tokens

The single source of truth for the look. Injected via the SwiftUI environment
(`\.designTokens`) and switched wholesale by the user's theme preset.

### Color ([`Tokens/ColorTokens.swift`](../PlayerCore/Sources/DesignSystem/Tokens/ColorTokens.swift))

Colors are stored as raw sRGB components (`ColorValue`) so they are `Sendable` and
can cross actor boundaries (e.g. out of the theme extractor). Each semantic role is
an `AdaptiveColor` with **light + dark** variants resolved against `\.colorScheme`.
`ColorValue.luminance` (WCAG) drives contrasting-foreground choices.

**Semantic roles:** `canvas`, `surface`, `surfaceRaised`, `textPrimary`,
`textSecondary`, `textTertiary`, `textDisabled`, `separator`, `accent`,
`accentMuted`, `onAccent`, `success`, `warning`, `danger`.

**`.standard` palette (exact hex):**

| Role | Light | Dark |
|---|---|---|
| canvas | `#F2F2F6` | `#08080C` |
| surface | `#FBFBFD` | `#131319` |
| surfaceRaised | `#FFFFFF` | `#1E1E28` |
| textPrimary | `#0E0E14` | `#F5F5F7` |
| textSecondary | `#55555F` | `#A8A8B3` |
| textTertiary | `#6A6A74` | `#8A8A96` |
| textDisabled | `#A0A0A8` | `#5A5A63` |
| separator | `#14141A` @10% | `#FFFFFF` @10% |
| accent | `#5B3FE0` | `#7C5CFF` |
| accentMuted | accent @14% | accent @22% |
| onAccent | `#FFFFFF` | `#FFFFFF` |
| success | `#248A3D` | `#30D158` |
| warning | `#9A6700` | `#FFD60A` |
| danger | `#D70015` | `#FF453A` |

**Built-in palettes (2):** `standard` — the neutral base `withAccent` and
`DesignTokens.standard` derive from — and **`macAMP`**, the one shipped skin: a
synthwave theme (dark canvas `#0D0221`, accent `#FF2975`, cyan secondary text
`#4DE2F0`). The `midnight` / `red` / `orange` / `cyan` / `pink` palettes were
removed when MacAMP collapsed to a single skin; the four accent values that also
backed **profile avatar gradients** are frozen as literals in
[`ProfileAvatar.swift`](../PlayerCore/Sources/DesignSystem/Components/ProfileAvatar.swift)
so saved avatars render unchanged, and are pinned by `ProfileAvatarTests`.

### Spacing — 4-pt grid ([`Tokens/SpacingScale.swift`](../PlayerCore/Sources/DesignSystem/Tokens/SpacingScale.swift))

| Token | pt |
|---|---|
| hairline | 1 |
| xxSmall | 4 |
| xSmall | 8 |
| small | 12 |
| medium | 16 |
| large | 24 |
| xLarge | 32 |
| xxLarge | 48 |
| xxxLarge | 64 |

### Typography ([`Tokens/TypographyScale.swift`](../PlayerCore/Sources/DesignSystem/Tokens/TypographyScale.swift))

SF Pro throughout, **Dynamic Type** aware (built on `Font.system(_:design:)`), zero
bundled font files. Roles pick a text style + weight; time labels use monospaced
digits.

| Role | Style · Weight |
|---|---|
| displayLarge | largeTitle · bold |
| displayMedium | title · bold |
| titleLarge | title2 · semibold |
| titleMedium | title3 · semibold |
| headline | headline · semibold |
| body | body · regular |
| callout | callout · regular |
| caption | caption · medium |
| timecode | footnote · medium · **monospaced digits** |

### Corner radii ([`Tokens/CornerRadii.swift`](../PlayerCore/Sources/DesignSystem/Tokens/CornerRadii.swift))

`small 8 · medium 12 · large 16 · xLarge 24 · pill 999` — always paired with
`.continuous` rounded rectangles for soft optical curvature.

### Elevation & motion ([`Tokens/Elevation.swift`](../PlayerCore/Sources/DesignSystem/Tokens/Elevation.swift))

Shadows are black at a token opacity (never inlined):

| Level | opacity · radius · yOffset |
|---|---|
| none | 0 · 0 · 0 |
| low | 0.18 · 8 · 2 |
| medium | 0.24 · 20 · 8 |
| high | 0.34 · 40 · 16 |

Motion timings (seconds): `quick 0.18 · standard 0.30 · expressive 0.5`. All
animation collapses to `nil` under reduce-motion (`\.themePresentation`).

### Materials ([`Tokens/MaterialTokens.swift`](../PlayerCore/Sources/DesignSystem/Tokens/MaterialTokens.swift))

`chrome .ultraThin` (bars) · `popover .regular` · `hud .thick` · modal scrim @0.45.
Collapse to opaque surfaces under reduce-transparency.

---

## 2. Album theming

The now-playing artwork tints the chrome. A `ThemeExtractor` actor derives an
`accent` + gradient `background` off-main (histogram over a 48-px thumbnail, cached
by SHA-256 — full algorithm in the
[PlayerCore spec](../PlayerCore/README.md#11-design-system-logic-designsystem)).

- **`ThemedBackground`** ([`Components/ThemedBackground.swift`](../PlayerCore/Sources/DesignSystem/Components/ThemedBackground.swift)) paints the theme's solid/gradient plus a radial accent bloom (`.plusLighter`, suppressed under reduce-transparency); falls back to `canvas`.
- The [player bar](#7-player-bar) applies the theme as a ~14% wash and recolors transport buttons, the slider, and the repeat badge, animated with `motion.expressive`.

---

## 3. Reusable components

### Shared (PlayerCore `DesignSystem`, cross-platform)

| Component | Shape & key values |
|---|---|
| [`ArtworkView`](../PlayerCore/Sources/DesignSystem/Components/ArtworkView.swift) | 1:1 image, `radii.large`, `separator` hairline border, `elevation.medium`. Placeholder: surfaceRaised→accentMuted gradient + `music.note`. |
| [`PlayerSlider`](../PlayerCore/Sources/DesignSystem/Components/PlayerSlider.swift) | Seek/volume. Track 6 pt capsule (separator), optional buffered fill, accent fill, 18 pt accent thumb w/ onAccent border. Adjustable a11y, ±5%. |
| [`TransportButton`](../PlayerCore/Sources/DesignSystem/Components/TransportButton.swift) | Kinds: play/pause/stop/next/previous/shuffle/repeat. Prominence: standard (glyph + hover fill) / prominent (filled accent disc). Sizes: small 36 / medium 52 / large 68 pt. Press scales to 0.9 (no reduce-motion). |
| [`StateView`](../PlayerCore/Sources/DesignSystem/Components/StateView.swift) | Empty/loading/offline. 96 pt accentMuted emblem, titleLarge + callout, optional prominent CTA, max width 420. |
| [`TrackRow`](../PlayerCore/Sources/DesignSystem/Components/TrackRow.swift) | 48×48 art, headline title (accent if playing), caption subtitle, timecode duration, playing = accent rail + waveform symbol effect. |

### macOS-specific

| Component | Notes |
|---|---|
| [`MacAMPToolbarButton`](Sources/MacAMPToolbarButton.swift) | SF Symbol, accent tint, accentMuted hover fill (0.15 s), help tooltip. |
| [`FavouriteButton`](Sources/FavouriteButton.swift) | Heart filled(accent)/hollow(textTertiary), plain style. |
| [`MediaGridTile`](Sources/Library/MediaGridTile.swift) | Square art on surfaceRaised, `radii.medium`, 2 pt accent hover border, callout title + caption subtitle (centered, 1 line). |
| [`PlayShuffleBar`](Sources/PlayShuffleBar.swift) | Capsule Play + Shuffle (accent bg, onAccent text) + inline filter field (capsule, surfaceRaised, max 180). |
| [`GenreFilterChipBar`](Sources/GenreFilterChipBar.swift) | Thin macOS adapter over the shared `GenreFilterBarView` (PlayerCore `DesignSystem`). Supplies the per-shell environment; the chip layout, selection logic, and "hidden when ≤1 genre" rule live in the shared component. |
| [`InlineSpectrumView`](Sources/InlineSpectrumView.swift) | 90×36 compact visualizer, 24 bars, 4 modes, neon colors. |
| [`ToastView`](Sources/ToastView.swift) | Capsule bubble, accent bg / onAccent, top slide+fade, 2.5 s auto-dismiss. |
| [`SynthwaveEmptyBackground`](Sources/SynthwaveEmptyBackground.swift) | Empty-state backdrop: surface + purple→pink vertical gradient + top-trailing cyan radial (glow 0.26 dark / 0.14 light). Purple follows `tokens.colors.accent`; the pink/cyan neon ends are fixed `AdaptiveColor` stops. |

---

## 4. App & window structure

[`MacAMPApp.swift`](Sources/MacAMPApp.swift) declares three scenes:

- **`Window("MacAMP", id: "main")`** — the primary window.
- **`Settings`** — the Preferences window.
- **`MenuBarExtra`** (`.window` style) — the [menu-bar mini player](#8-menu-bar--visualizer).

**Launch:** a **splash** ([`SplashView.swift`](Sources/SplashView.swift), 620×414)
shows key art + a neon loading bar through phases `loadingLibrary` (0.75 s) →
`startingEngine` (0.75 s) → fade (0.5 s, easeInEaseOut) before the main window
expands. Tooltip delay 500 ms; media-key monitoring installed at launch.

**Keyboard / media keys** ([`MainWindowActions.swift`](Sources/MainWindowActions.swift),
[`MediaKeyMonitor.swift`](Sources/MediaKeyMonitor.swift)): Space = play/pause,
⌘→/⌘← = next/previous, ⌘↑/⌘↓ = volume ±5%, **↑/↓ = volume ±5%** (bare, yields to
focused text fields / tables / outlines via responder-chain walk), **←/→ = seek
±5 s** (bare, same yield rule), hardware play/next/previous keys map to transport,
Esc closes overlays.

---

## 5. Main window layout

[`MainWindowView.swift`](Sources/MainWindowView.swift) — `minWidth 880`,
`minHeight 560`, tinted with `accent`. A vertical stack (spacing 0):

```
┌───────────────────────────────────────────────────────────┐
│ hairline separator                                        │
├──────────┬────────────────────────────────────┬───────────┤
│ Sidebar  │ detail column                       │  Right    │
│ (240)    │  ├ content toolbar + divider        │  panel    │
│          │  └ content pane                      │ (optional)│
├──────────┴────────────────────────────────────┴───────────┤
│ Player bar (height 100)                                    │
└───────────────────────────────────────────────────────────┘
  overlays: enrichment progress · toast · now-playing expanded · drop hint
```

- **Sidebar** 240 pt, toggle animated 0.15 s easeOut; visibility `.all`/`.detailOnly`.
- **Content toolbar** ([`MainWindowToolbar.swift`](Sources/MainWindowToolbar.swift)): sidebar toggle · centered destination title (headline) · context actions (Library `+`; Playlists `↓`/`+`; Playlist detail `↑`) · right-panel toggle.
- **Navigation state** ([`NavigationModel.swift`](Sources/NavigationModel.swift)): persisted `sidebar: SidebarDestination`; transient `artistDetail`, `showRightPanel` (default true), `showNowPlayingOverlay`, `sidebarVisibility`.
- **Drag-and-drop import:** URL drop shows an accent-bordered overlay + "drop to import" hint (0.15 s easeInOut).

---

## 6. Screen by screen

### Sidebar ([`SidebarView.swift`](Sources/SidebarView.swift))

`.sidebar` List on `surface @25%`. A **search field**
([`LibrarySearchField.swift`](Sources/LibrarySearchField.swift), capsule w/
magnifier + clear) sits at the top, then these sections in this order:

1. **Library** — All Tracks (`music.note`), Albums (`square.stack`), Artists (`music.mic`), Favourites (`heart`), **Lyrics** (`text.quote`), **Stats** (`chart.bar`), **Queue** (`list.bullet`), **Downloads** (`arrow.down.circle`). Row order is explicit (`LibrarySection.libraryRowList`), not `allCases`, so an enum declaration change can never silently reorder the sidebar. **Downloads is the last Library row and has no section of its own** (`SidebarDestination.fixed(.downloads)`): selecting it opens the queue pane, the toolbar `+` button opens the paste sheet, and it is the only Library row carrying a badge — the pending download count, absent until the composition root has built the queue.
2. **Karaoke** (conditional — only when karaoke mode is available) — **Karaoke** (`music.mic`) and **Karaoke Queue** (`list.bullet.clipboard`).
3. **Assistant** (conditional — only when the Intelligence master toggle is on) — **Assistant** (`sparkles`).
4. **Playlists** — expandable `DisclosureGroup`, drag-reorderable, `music.note.list`, context menu Rename / Delete. Playlists sits **below** Karaoke and Assistant: the two conditional sections are short and fixed in height, while the playlist list grows without bound and would otherwise push them off screen.
5. **Folders** (library roots) — `folder`, or `externaldrive.badge.xmark` + "missing" badge when offline; context menu Remove / Export JSON. Folders renders **last**, after Karaoke, Assistant, and Playlists.

Collapsible-section state is keyed by `SidebarSectionID` (`library`, `playlists`, `karaoke`, `intelligence`, `folders`) — five ids for five sections. Downloads has no id because it is a row, not a section; `SidebarSelectionStore.loadSectionExpansion()` drops any persisted key that names no live id, so a retired section cannot linger in the stored dictionary.

`LibrarySection.allCases.count` is **12**: `allTracks`, `albums`, `artists`, `favourites`, `lyrics`, `stats`, `queue`, `karaoke`, `karaokeQueue`, `playlists`, `assistant`, `downloads`. Folder rows in the sidebar are rendered from library-root records, not from this enum.

**Accessibility identifiers** (used by `macampMacUITests` XCUITest smoke suite):
`sidebar.list` (the List), `sidebar.row.<section>` (each fixed section row),
`player.bar` (`PlayerBarView`), `albums.view` (`AlbumsGridView`),
`library.searchField` (`LibrarySearchField`).

### Library browser ([`LibraryBrowserView.swift`](Sources/LibraryBrowserView.swift))

Vertical stack: **GenreFilterChipBar** (if >1 genre) → **PlayShuffleBar** → virtualized,
keyset-paginated, multi-select **track table**. Columns: number/speaker (44) · title
(accent if playing) · artist ([clickable](Sources/LibraryTrackRow.swift)) · album ·
duration (80, monospaced). Empty/loading → `StateView` over
`SynthwaveEmptyBackground`. Context menu: Play · Play Next · Add to Queue · Add to
Playlist ▸ · Edit Tags · Delete. Rows are [`TrackListRow`](Sources/TrackListRow.swift)
(leading number/`speaker.wave.2.fill`, title+artist, availability badge, duration,
favourite toggle; 0.55 opacity when not `present`).

### Albums / Artists grids ([`Library/`](Sources/Library))

`LazyVGrid` with `.adaptive(minimum: 150)` of `MediaGridTile`s, above a sort bar
(search + name/year toggle). **Artist detail** drills in with a back bar, a 120×120
circular hero, `displayMedium` name, an info button, an optional bio, and the
artist's album grid.

### Playlists ([`Playlists/`](Sources/Playlists))

List of playlists (icon + name + track count; context menu Rename/**Organize…**/Export/Delete;
toolbar Create/Import). **Detail** ([`PlaylistDetailView.swift`](Sources/Playlists/PlaylistDetailView.swift),
228 LOC, decomposed into region files): back bar → `GenreFilterChipBar` →
`PlayShuffleBar` → local filter → drag-reorderable track list, with an Edit-Order
toggle, Export, and an **Organize…** toolbar button. Supporting files: `PlaylistDetailRows.swift` (row rendering),
`PlaylistDetailActions.swift` (toolbar/context actions), `PlaylistDetailLoading.swift`
(empty/loading states), `PlaylistDetailContextMenu.swift` (context menu),
`PlaylistFilePanels.swift` (import/export file panels), `PlaylistOrganizeActions.swift` (Organize actions — see below).

**Organize actions** (`PlaylistOrganizeActions.swift`, [`Playlists/`](Sources/Playlists)) — four AI-powered actions on a whole playlist: Suggest a Name, Reorder by Energy, Remove Duplicates, Split by Theme. Accessed from **two** surfaces: the sidebar playlist row context menu (between Rename... and Delete, gated by `AIFeatureBundle.organization`) and the playlist detail toolbar (beside Export). Track source is a `PlaylistOrganizeTrackSource` enum: `.loadedDetail` drains the shared `PlaylistViewModel` when called from the detail view; `.repositoryPages` reads directly from `PlaylistRepository` off-main when called from the sidebar row, so the action works without the playlist being open. Every Organize action produces a proposal reviewed through `ProposalPreviewSheet` before any write. These actions are **NOT** on the per-track context menu — they operate on the whole playlist.

**Reorder by Energy — the gate and the reasons.** The item is the only one that can be present-but-disabled, because its precondition (an analyzed library) is something the listener can fix. The gate reads `AudioAnalysisViewModel.analyzedFraction` against `MixRanking.energyArcCoverage` (0.8), but **treats unmeasured coverage as permissive**: `analyzedFraction` is filled by an asynchronous read and is `0` until it lands, and a `.contextMenu` body evaluated in that window is not rebuilt by the later Observation change — so reading the placeholder as a measurement greys the item out permanently on a fully analyzed library. `hasMeasuredCoverage` is the discriminator, and the menu additionally refreshes coverage on appearance (`.task`, off-main, two `COUNT(*)`s — never synchronous DB I/O on the main thread). The 0.8 threshold itself is unchanged.

When a proposal cannot be produced, the reason is reported rather than collapsed: every contextual proposer sets `AssistantViewModel.lastUnavailability` (`AIProposalUnavailability`), which is orthogonal to `lastError` exactly as `lastTierDiagnostic` is. `PlaylistOrganizeMenu.message(for:fallback:)` maps each case to its own toast — "A playlist needs at least 3 tracks…", "This playlist is too long to reorder by energy (limit 100 tracks)", "Not enough of this playlist has been analyzed yet…", "This playlist is already in energy order" — because the library-wide menu gate and the mix pipeline's **per-selection** coverage check (measured after metadata resolution drops unavailable or invisible rows) answer different questions, so a passing gate does not imply a proposal.

### Downloads ([`Downloads/`](Sources/Downloads))

`DownloadsView` is the body of the `SidebarDestination.fixed(.downloads)` destination. It has two surfaces:

**Paste sheet** (`DownloadsPasteSheet`, `downloads.pasteSheet`) — opened by the toolbar `+` button or **File > Add Download**. A multi-line `TextEditor` accepts one URL per line. On **Add**, `DownloadPasteInput.parse(_:)` normalizes each URL via `YouTubeURLNormalizer`, deduplicates by video ID, and produces a `DownloadPasteReport` (links recognized, skipped, duplicates). A single playlist URL first fetches the real track count and shows a confirmation sheet with the exact count — capped at 500, with an "Add first 500" option on longer playlists. `DownloadPasteResult` is rendered in the sheet header as "N links, M duplicate(s) skipped".

**Queue tab** (`DownloadsQueueView`) — the first of two tabs in `DownloadsView`. Shows all active and pending downloads: multiple rows can be in-progress simultaneously (up to the **Simultaneous downloads** limit; see Preferences below). Each active row shows its title, a progress bar, speed, and estimated size. When a conversion step follows the download, the bar is **determinate** while ffmpeg samples are available (real percentage from `ffprogress [<videoID>].txt` in the staging directory) and indeterminate when samples are absent; the caption within the `.postProcessing` phase is stamped to the format-specific string ("Converting to M4A…" / "Converting to MP3…" / "Converting to Opus…" / "Converting to FLAC…") once the format is known, falling back to the generic "Converting audio…" until then — the caption text does NOT change again within the phase regardless of the fraction. Pending rows below the active ones are drag-reorderable. Right-click any pending row for Remove. Each active row has an **inline cancel button** (`xmark.circle`) — there is no right-click cancel on active rows. A **Pause / Resume** button in the section header halts the entire queue (new downloads do not start; active ones finish). The queue is in-memory and resets on quit; quit teardown calls `cancelAll()` synchronously so no spawned child is reparented to launchd.

Accessibility identifiers: `downloads.queue.activeRow.<n>` (active row title `Text`), `downloads.queue.activeRow.<n>.cancelButton` (inline cancel button), `downloads.queue.activeRow.<n>.progress` (active row progress bar), `downloads.queue.row.<n>` (pending row title `Text`; position 0 = the first pending row), `downloads.queue.pausedNotice` (paused-state notice), `downloads.queue.pauseButton` (pause/resume header button).

**History tab** (`DownloadsHistoryView`) — the second tab. Lists every completed download in reverse-chronological order, read from the GRDB `downloadHistory` table (v17, append-only). Each row shows the title, uploader, a format badge (e.g. "M4A · Best"), and a relative timestamp; the exact capture-local time is available as a `.help()` tooltip on the timestamp. Right-click gives: **Reveal in Finder** (opens the file's containing folder), **Re-download** (re-enqueues the original URL — the file is not deleted first; if the destination already exists yt-dlp will attempt to overwrite it), **Delete row** (removes only the history record — the file on disk is NEVER touched). A **Clear All** button in the tab header wipes all history records; again, no files are deleted.

Accessibility identifiers: `downloads.history.row.<n>` (row title `Text`), `downloads.history.clearButton` (clear-all header button).

**Queue-row decoration:** after `enqueue()` adds rows to the pending queue, `DownloadQueueService.decoratePendingRows` fires `YouTubeOEmbedClient` for each recognized video ID (≤4 requests at a time). Titles, uploaders, and thumbnails fill in asynchronously on the **queue rows** — not inside the paste sheet. The paste sheet itself contains no oEmbed rendering; its one `ProgressView()` is the yt-dlp busy indicator while a spawn is in flight. A lookup that fails or times out leaves the row showing the raw URL. Decoration is cosmetic — it never gates or delays the enqueue.

**Advisory hint:** after **Add** returns, the sheet queries `DownloadHistoryRepository` for how many of the pasted URLs were previously downloaded and, if any, shows a one-line notice ("You already downloaded N of these"). This hint never blocks or delays an enqueue — it runs as a follow-up read after the result is already on screen.

Downloaded files land in the configured destination folder (default `~/Music/MacAMP Downloads`). That folder is **never** a library root and is never watched. Whether a finished file also enters the library is one switch — **Add finished downloads to my library** in **Preferences ▸ Downloads** (`DownloadPreferences.autoImportEnabled`), which ships **OFF**. With it on, `DownloadLibraryImporter` runs a single `LibraryScanner.scan(.files([url]))` per finished item and ownerless-path visibility (`LibraryVisibility`) makes the result visible to every profile, since the destination belongs to no profile's roots. With it off **no scan runs at all** and the file stays a plain file in that folder until the listener adds the folder as a library root themselves.

**Player-surface integration:** with auto-import on, a completed download appears in All Tracks (and any other view covering ownerless paths) as soon as its scan lands; with auto-import off it appears in no view until the folder is added to the library. Either way, once a downloaded file *is* in the library the track row, tag editor, artwork display, EQ, and all other player surfaces treat it identically to any other library file. The "Added to your library" toast is gated on the same decision: `DownloadImportAnnouncement.announces(_:)` reads the importer's `nil` (auto-import off, no scan) as "say nothing", so MacAMP never announces an import that did not happen.

Accessibility identifiers (sheet + toolbar): `downloads.pasteSheet` (sheet title `Text`), `downloads.addButton` (toolbar `+` button).

### Favourites ([`FavouritesView.swift`](Sources/FavouritesView.swift))

Genre filter + PlayShuffleBar + drag-reorderable favourites list.

### Search results ([`SearchResultsView.swift`](Sources/SearchResultsView.swift))

Table: title · artist · album · duration, ranked by the FTS5 query.

### Now Playing (expanded) ([`NowPlayingExpandedView.swift`](Sources/NowPlayingExpandedView.swift))

Bottom-slide overlay on `canvas @97%`: close chevron → **280×280** artwork
(`radii.large`, shadow 0.3/20/8) → centered title (titleLarge) + artist → optional
200×48 visualizer → scrubber → transport (previous · **large prominent** play/pause
· next) → volume row (max 280).

The overlay's scrubber (`OverlayScrubber`) carries the same **replay heat overlay**
(`ScrubberHeatOverlay`) as the player bar and the full player, revealed on hover or
drag, with a leading-aligned **"Most Replayed"** caption
(`ScrubberHeatCaption`) above the 320 pt slider. The caption is always in the view
tree and revealed by a plain opacity toggle, so there is no hover-time layout jump
and nothing to suppress under reduce-motion; it appears only when a curve is
actually being drawn (`ScrubberHeatLabel.isVisible`). Hover reveal is independent
of the overlay's `paused` flag, which gates only the 0.5 s progress ticker.

### Stats dashboard ([`StatsView.swift`](Sources/StatsView.swift))

Full-width scrollable page, `canvas @25%` background. A segmented **period filter** (Last 7 Days / Last 30 Days / Last 12 Months / All Time) sits at the top of the page alongside a refresh button. Switching the filter costs no I/O — the view model loads all windows in one pass.

The page is split into two groups:

**Group 1 — the selected period:**

- **Raw-horizon caption** (All Time only) — a `caption`-weight note explaining that per-track and time-of-day detail covers the most recent 24 months of raw events while artist/genre totals are permanent.
- **Overview cards** (`StatsOverviewCards`) — four cards: Plays, Listening Time, Completion rate, Skip Rate.
- **Listening Clock** (`StatsListeningClockView`) — hour-of-day and day-of-week bar charts (Swift Charts), with a "Most active: X" daypart caption.
- **Top section** (`StatsTopListsView`) — Tracks / Artists / Genres sub-picker (segmented). Top Tracks rows are playable via double-click when the track is still in your library; Artists and Genres are display-only.

**Group 2 — All Time & History:**

- **Most Replayed** (`StatsMostReplayedView`) — replay-affinity ranked rows, each with title, artist, full-listen count, affinity percentage, and a `ReplayHeatCurve` mini curve. Requires three full listen passes **or** one 1% slice heard three times (`ReplayHeatAnalysis.hasTrustworthyShape`) — so a single sitting spent rewinding to the same passage still ranks. Rows are playable via double-click when the track is still in your library.
- **Recent Plays** (`StatsRecentPlaysView`) — last 50 plays, newest first, with relative timestamp, listened duration, and a skip badge (`forward.end` glyph) for skipped plays. Rows are playable via double-click when the track is still in your library; deleted-track rows appear in `textTertiary` with no hand cursor.
- **Lifetime Most Played** — pre-existing per-profile play-count ranking (unchanged from before the dashboard).

Playback from any row uses `StatsRowActions` (shared modifier): double-click queues the single track; a context menu adds Play and Add to Queue. The modifier adds nothing for rows whose track is no longer in the library.

Accessibility identifiers: `stats.windowFilter` (period picker), `stats.topCategory` (sub-picker), `stats.hourChart`, `stats.weekdayChart`, `stats.recentPlays`.

### Right panel ([`RightPanelView.swift`](Sources/Player/RightPanelView.swift))

The optional right panel (toggled via the toolbar, default visible) shows four tabs for the currently playing track: **Lyrics**, **Tags**, **Info**, **Stats**.

The **Stats tab** (`StatsPanelView`) has three independently gated blocks:

- **Now Playing** — lifetime play count and full-listen count from `profileTrackState`. Always shown when a track is playing.
- **History** — shown only when `playEvent` rows exist for this track (requires at least one play since the v15 stats log). Rows: Last played (relative date), First played (calendar date), Time listened (abbreviated duration), Skips (inflected count).
- **Replay Map** — a `ReplayHeatCurve` at 24 pt height, shown once the track clears `ReplayHeatAnalysis.hasTrustworthyShape`: three full listen passes **or** one 1% slice heard three times. Same curve shape as the scrubber overlay.

### Assistant pane ([`Assistant/`](Sources/Assistant))

The `AssistantView` (`SidebarDestination.fixed(.assistant)`) is the primary AI surface. It holds the request field, the multi-turn chat transcript, the feed of past proposals and Library Health findings, and the inline error / fall-through notice layer. It is backed by `AssistantViewModel` (PlayerCore `ViewModels`), `LibraryChatViewModel` (PlayerCore `ViewModels`), and `AssistantFeedModel`.

**Chat surface** — `AssistantView` routes submissions through `submitRouted()`. When a conversation is available (Apple Intelligence ready, OR a cloud connector with library-browsing consent accepted), the message starts or continues a chat turn via `LibraryChatViewModel.send(_:)`. When chat isn't available (consent declined, provider not configured), the same button runs the single-shot ladder via `AssistantViewModel.submit(text:profileId:)` as before. One field, one button, two paths — the notice layer explains which ran and why.

`LibraryChatViewModel` (`@MainActor @Observable`) owns the multi-turn conversation:
- `messages: [LibraryChatMessage]` — the visible transcript. Each message carries `role` (`.listener` / `.assistant`), `text`, `events: [AssistantChatEvent]`, `proposalIds: [UUID]`, and a `failure` field.
- `isResponding: Bool` — set while a turn is in flight; the field is disabled.
- `send(_:)` never throws; every outcome (reply, tool activity, truncation, failure) becomes a row.
- `reset()` discards both the message list AND the engine — the tier owns the history (FM transcript / cloud actor), so clearing only the list would leave the model answering against a conversation the listener can no longer read.
- `cancelInFlight()` is called by `rebuildAI` / `rescopeAI` on provider or profile change.

The engine itself is a `LibraryChatEngine` — a struct of two `@Sendable` closures (`prewarm` / `send`) so it crosses the `@available(macOS 26)` and module-boundary constraints without a protocol. The shell builds it from `AppEnvironment.makeChatEngine(settings:toolbox:connectors:)` and wraps it in a `Result<LibraryChatEngine, LibraryChatFailure>`.

**Tool-activity rows** — `AssistantChatEvent.toolCall(name:)` and `.toolResult(name:summary:resultCount:)` appear as rows in the transcript. The shell keys a **localized caption** off the stable snake_case tool name (e.g. `"search_tracks"` → "Searched your library"); the `summary` field is model-facing text and is never rendered verbatim to the user. When `resultCount` is non-nil the row appends a count suffix using the inflected grammar key `app.assistant.chat.tool.resultCount` (`LibraryChatStrings.toolResultCount(_:)`) — "— ^[N result](inflect: true)" — so "1 result" vs "4 results" is automatic across all locales without a plural table. `everyToolHasItsOwnCaption` drives a test so a tenth tool without copy fails immediately.

**Answer first on a proposal turn.** `LibraryChatMessageRow.collapsesActivity(_:)` decides the layout: a turn that FILED A PROPOSAL renders **bubble → proposal card → suggestion links → a collapsed `DisclosureGroup`** holding every lookup caption and intermediate track list ("^[N lookup](inflect: true) behind this answer", `app.assistant.chat.lookups.summary`, identifier `assistant.chat.lookups.<index>`). A 43-track ask runs a dozen lookups, and those are provenance rather than content once a card states the result. A turn with NO proposal keeps the flat activity-first layout deliberately — there the track lists ARE the answer the three-sentence prose rule tells the model not to repeat. The decision is keyed on `proposalIds`, never on the resolver, so applying a proposal cannot spring the machinery back open. The disclosure's summary line is itself the toggle (a plain `Button` inside the label, with a pointing-hand cursor) — SwiftUI's disclosure label is inert, so the chevron used to be the only target.

**A discarded proposal keeps its card.** `AssistantView.chatProposal(_:)` resolves a turn's proposal against `ProposalStore` first and then against `DiscardedProposalStore` ([`Assistant/DiscardedProposalStore.swift`](Sources/Assistant/DiscardedProposalStore.swift)), which `ProposalPreviewSheet` records into immediately before it discards. So pressing **Discard** closes the sheet without leaving the proposal in "Waiting for you" — and the card on the turn that proposed it stays, so the review sheet can be opened again. Re-opening re-files the proposal (`AppEnvironment.restoreDiscardedProposal(_:)`) because `AssistantViewModel.apply` refuses a handle the pending store does not hold. An **applied** proposal is never recorded, so its card still disappears: that playlist now exists. The shadow store is never persisted and is emptied by `LibraryChatViewModel.reset()` along with the download registry and status projection.

**Suggestion links** (`LibraryChatSuggestionList`, [`Assistant/LibraryChatSuggestionList.swift`](Sources/Assistant/LibraryChatSuggestionList.swift)) — `match_tracks` answers a batch with the tracks it found AND the songs it could not (`AssistantChatSuggestion`). A miss is not a playable row, so it renders as a link beneath the activity. Two kinds, drawn/spoken/identified apart because they make different promises: a **video** row (`play.rectangle.fill`) opens a `watch?v=` link that `YouTubeLinkResolver.validatedWatchURL` — AIConnectorKit's single sanctioned validator — accepted, and a **search** row (`arrow.up.right.square` plus a visible "search" tag) opens the fallback query this app composes from the miss's own two strings. `destination(for:)` re-runs the validator on every received link even though the enricher already did, so the rendering gate is structural rather than inherited; anything it turns down falls back to the search form. Ten rows show before an expander.

**Where a video link comes from — the model first, the search provider second.** `AppEnvironment.enriched(_:using:proposer:)` asks `ModelVideoLinkProposer` for the ids before it spends a web search: the provider that just named the misses is asked, through the `structuredCompletion` every connector implements, for each song's 11-character id (songs addressed **by index**, never by echoed title, so a re-spelled title cannot pair an id to the wrong row). Those ids go through `YouTubeLinkResolver.verify(_:proposedIDs:)` — the same shape → oEmbed → title-overlap gate a searched candidate passes — and only the songs that did NOT verify fall through to `resolve(_:)`, the rate-capped search path. This exists because the keyless search tier has a **daily cap**: once it answers HTTP 429 `daily_cap_reached` the resolver reads that as "no candidate" and every remaining song silently degrades to a search row, which is what a listener sees as "some links open the video, some open a search page". A model-supplied id costs nothing against that cap, and a hallucinated one fails the gate and degrades to exactly the search row it would have had anyway. Identifiers: `assistant.chat.suggestions.<msgIndex>.<toolIndex>` (the list), `….link.video.<rowIndex>` / `….link.search.<rowIndex>` (the rows), `….expander`. Context menu: **Copy Link**, which copies the row's destination character for character.

**On-device web pointer** (`LibraryChatWebPointer`, [`Assistant/LibraryChatWebPointer.swift`](Sources/Assistant/LibraryChatWebPointer.swift)) — a dismissible banner shown when the Web & Music Suggestions grant is on but the tier answering is the on-device one, which is never given the lookups. It states that plainly rather than letting the setting look broken. Identifiers: `assistant.chat.webPointer` (on the message `Text`, not the container) and `assistant.chat.webPointer.dismiss`.

**Chat message copy and text selection** ([`Assistant/LibraryChatMessageCopy.swift`](Sources/Assistant/LibraryChatMessageCopy.swift)) — every bubble in the transcript carries three copy affordances applied by the `chatMessageCopyAffordances(for:index:)` View extension:

- **`.textSelection(.enabled)`** — the platform-native path: drag to select part of a message, then ⌘C.
- **Context-menu "Copy"** — the discoverable path: right-click any bubble, choose Copy, and the whole message lands on the clipboard.
- **Hover-reveal copy button** — a top-trailing overlay button, opacity-hidden when not hovered (`.allowsHitTesting(false)` while invisible so it cannot intercept text selection), that copies the full message and posts a "Copied" toast via `ToastManager`. The button is attached above `.accessibilityElement(children: .combine)` so it remains its own AX element rather than folding into the bubble's label.

All three apply to `.listener` and `.assistant` bubbles. Neither requires a special runtime guard: an assistant bubble is built only inside `if !message.text.isEmpty`, and a listener row is minted from a trimmed non-empty send, so neither bubble can offer Copy on an empty string. `canCopy(_:)` names that structural gate so it is assertable in tests without a pasteboard.

`copyText(for:)` returns `message.text` verbatim — no trimming, normalizing, or truncating. The spoken accessibility label ("`<role>: <message>`") intentionally differs so VoiceOver role prefix never reaches the clipboard. `copy(_:)` is the only function that touches `NSPasteboard`; `copyText(for:)` is pure so tests drive it without clobbering the developer's clipboard.

Identifiers: `bubbleIdentifier(role:index:)` = `"assistant.chat.\(role.rawValue).\(index)"` where `role.rawValue` is `"listener"` or `"assistant"`, giving `assistant.chat.listener.<n>` and `assistant.chat.assistant.<n>` for the two bubble kinds. The Copy item identifier is derived: `"\(bubbleIdentifier(role:index:)).copy"` — never spelled independently, so renaming a bubble cannot leave the menu item pointing at nothing. Context-menu buttons take neither `.help` nor `.pointingHandCursor()` — the same exemption as "Copy Link": `NSMenu` rows do not receive `.onHover`, and the visible label already names the action.

**Per-turn failure banners** — when a turn produced no answer, the `assistantContent` builder adds a `failureBanner` row below any activity rows. The text is resolved by `LibraryChatFailureCopy.message(for:)` ([`Assistant/LibraryChatFailureCopy.swift`](Sources/Assistant/LibraryChatFailureCopy.swift)), which switches over `LibraryChatFailure` and calls `providerMessage(_:)` for the `.providerFailed` case. Accessibility identifier: `assistant.chat.failure.<index>`.

The failure-copy mapping table — what a listener reads for each case:

| `LibraryChatFailure` case | Listener action | Copy shown |
|---|---|---|
| `.unavailable(reason)` | none | `reason.message` (the tier availability table's own copy) |
| `.consentRequired` | accept consent | "This provider needs your permission to browse your library…" |
| `.providerFailed(.rateLimited)` — no wait stated | retry | "This provider is limiting requests right now. Try again shortly." |
| `.providerFailed(.rateLimited)` — with `retryAfter` | retry after | "…Try again in about `<Foundation units format>`." |
| `.providerFailed(.authExpired)` | sign in again | "…rejected its saved sign-in. Sign in to it again in Preferences ▸ Intelligence…" |
| `.providerFailed(.unreachable)` | check connection | "…could not be reached. Check your connection, then ask again." |
| `.providerFailed(.timeout)` | retry or shorten | "…did not answer in time. Ask again, or try a shorter request." |
| `.providerFailed(.httpStatus)` — with code | none | "…answered with an error (`<code>`)." |
| `.providerFailed(<unknown token>)` | none | generic (`failureAnswerFailed`) |
| `.answerFailed` | retry or rephrase | "The assistant couldn't answer that. Try again, or ask in a different way." |

Any `.providerFailed` row above additionally gets the provider's **own** explanation on a second line when one arrived — see the sanitized-detail contract below.

Three `ConnectorFailure` cases deliberately map to `nil` (falling back to `.answerFailed` copy) because no listener action exists behind them: `.unconfigured` cannot happen on a turn the routing matrix already cleared; `.malformedResponse` and `.cancelled` have no fix a listener can apply. The `retryAfter` duration is formatted by Foundation's `.units(allowed:width:maximumUnitCount:1)` — one unit only ("2 hours", not "1 hour 52 minutes"), locale-automatic.

**The sanitized-detail contract.** Two fields from an HTTP error cross the module boundary: the status **code**, and a **sanitized provider message**. `ConnectorFailure.httpStatus(_:body:providerMessage:)` carries the latter — the provider's own `error.message`, falling back to a top-level `detail` string, and *nothing else from the response*, trimmed and capped at `ConnectorFailure.maxProviderMessageCharacters` (200) by the single shared helper `ConnectorFailure.sanitizedProviderMessage(in:)`, which all four connectors (Anthropic, OpenAI, ChatGPT, Ollama) call at their `httpStatus` throw site. The `detail` spelling is the ChatGPT subscription backend's dialect and is **not** decoration: without it, `{"detail":"Unsupported parameter: max_output_tokens"}` reached a listener as a bare "(400)", which is how a total outage shipped undiagnosed (measured 2026-09-09). `ConnectorChatFailureMapping` copies it into `LibraryChatProviderFailure.detail`, and `LibraryChatFailureCopy.message(for:)` composes ONE `LocalizedStringResource` — the typed sentence, then `\n`, then the detail (`LibraryChatStrings.failureWithDetail(_:detail:)`, catalog key `app.assistant.chat.failure.detail`). The detail is a *second line* rather than part of the sentence because it is the provider's English and no catalog can translate it. A blank or absent detail renders exactly today's sentence; an unrecognised reason token still degrades to the generic copy **and** still shows the detail.

The response **body** remains deliberately unrepresentable in `LibraryChatProviderFailure` — there is no field that could carry one — so a raw payload, a URL, a header or a credential can never reach the screen. `ConnectorFailure.body` keeps its old "machine diagnostics only, never rendered" contract; `providerMessage` is the single named exception to that type's "nothing here is user-facing" rule. Scope: this path explains HTTP-error failures (the measured Claude 400). It does not apply to a truncated HTTP 200, which carries no error body at all.

**Library-browsing consent (v2)** — `AppSettings.libraryBrowsingConsentedConnectorIDs: Set<String>` records per-connector acceptance. The routing matrix reaches the consent branch only through `.connector`, so the on-device branch never reads the record. Declining writes nothing — `chatDeclinedProviderID` is `@State` on `AssistantView`, so:
- The sheet is not re-offered on every send (hostile).
- Leaving the pane and returning offers it again (not "never").
`LibraryChatConsentTests` pins all three values through identical inputs and demands one answer.

**Waiting for you section** (`AssistantView+PendingProposals.swift`) — reads `ProposalStore.proposals` directly and shows a card at the top of the feed for each pending proposal. Closes the gap that previously left proposals unreachable when their producer (a reset chat, a dismissed sheet, or an MCP client) was gone from screen. Additive and write-free: the card opens the existing `ProposalPreviewSheet` through the existing `AssistantSheet.proposal` case.

**Request submission (single-shot, unchanged)** — `AssistantViewModel.submit(text:profileId:)` runs the four-tier ladder off-main. The UI disables the field while a request is in flight.

**Error banner and fall-through notice** — `AssistantStatusView` reads `AssistantViewModel.lastError` (typed failure: `noMatchingTracks`, `generationFailed`, `featureDisabled`) and `lastTierDiagnostic` (tier-level: `connectorUnavailable`, `connectorTimedOut`, `connectorFailed`, `modelFailed`). These are **orthogonal**: both can be set simultaneously. The notice copy is provider-agnostic because `AssistantTierDiagnostic` lives in PlayerCore. A connector predicate returning `false` records `.connectorUnavailable`; an absent or default connector does not.

**Proposal preview sheet** (`ProposalPreviewSheet`, [`Assistant/ProposalPreviewSheet.swift`](Sources/Assistant/ProposalPreviewSheet.swift)) — the review surface shown for every AI proposal before any write. `ProposalPreviewSections` renders the track list with one `Toggle` per row; the toggle writes to an **exclusion set** (everything starts ticked; unticking adds to the excluded set). `PlaylistOrganizeDiff.excluding(trackIds:)` pin-and-reflows the excluded ids out of the proposed order. A running "N of M selected" count drives the Apply button's enabled state (Apply is disabled when the exclusion set equals the full member set). Proposals beyond the preview cap stay included by construction — an id the preview never listed can never enter the exclusion set, so the "tracks past the cap are always included" caption is structurally guaranteed. Accessibility identifier: `assistant.proposalPreview`.

**More Like This** — right-click a track and choose **More Like This (track title — artist)**. The menu item interpolates the seed track's title and artist so multi-selection or a sorted list doesn't leave it ambiguous which song it uses. Routes to `AssistantViewModel.moreLikeSeed(_:profileId:)`.

**Library Health / Hygiene detail** (`HygieneDetailView`, [`Assistant/HygieneDetailView.swift`](Sources/Assistant/HygieneDetailView.swift)) — opened by tapping the "Things worth reviewing" card in `AssistantView`. `HygieneDetailModel` runs three analyzers at open time and maps each finding to pre-built proposals (never in `body`). The sheet has three sections (Duplicates, Genre spellings, Missing tags). Each finding row: display copy + **Review** button (shows the proposal in `ProposalPreviewSheet`). Each section: a **Review All** button which calls `hygieneProposals(for:)` over the whole category in one batch — three hundred untagged tracks produce ONE `.tagChangeSet`, not three hundred. `deconflicted(_:)` keeps only the first `.organize` per playlist in a batch (two competing membership rewrites on the same playlist conflict); the second group surfaces on the next reload. A duplicate finding that survives its own fix (`.playlistCleanups` becomes empty after apply) keeps its row but loses its Review button — the copy says "nothing left for MacAMP to change" — because the two copies are still on disk and this layer cannot propose deleting a file. Accessibility identifiers: `assistant.hygiene.reviewAll.duplicates`, `assistant.hygiene.reviewAll.genreSpellings`, `assistant.hygiene.reviewAll.missingTags`.

---

### Preferences ([`PreferencesView.swift`](Sources/PreferencesView.swift))

`Settings` scene, **860×580 default, user-resizable, minimum content 800×520**. Resizability uses `.windowResizability(.contentMinSize)` plus `SettingsWindowResizable`, which enables the native window's resize controls. Selecting a section preserves the user's window size and updates the window title to the visible pane.

**Thirteen sections** — General, Library, Downloads, Playback, Output, Equalizer, Visualizer, Karaoke, Intelligence, Online, Profiles, Updates, Acknowledgments. A native `NavigationSplitView` sidebar uses their existing localized titles and SF Symbols. Rows wrap for longer translations and support keyboard selection. Stable identifiers are `preferences.section.<rawValue>`; the selected detail preserves every existing pane and control.

Layout: native sidebar + detail. The sidebar `List` owns navigation scrolling (`preferences.sidebar`); each detail `Form` independently owns settings-content scrolling (`preferences.form`, or the existing `preferences.tab.intelligence` identifier for Intelligence). The shared pane header remains above its Form. There is no outer scroll view or nested same-direction scroller. The detail fills the space beside the sidebar, including after resize.

`PreferenceMetrics`: window minimum **800×520**, sidebar minimum/ideal/maximum **180/200/260 pt**, pane minimum height **380 pt**. Pane styling continues to use the design tokens for typography, spacing, accent, canvas and surfaces. All sections remain reachable at the minimum width without a widening toolbar.

#### Intelligence pane (Preferences ▸ Intelligence)

`IntelligencePreferencesPane` ([`Preferences/IntelligencePreferencesPane.swift`](Sources/Preferences/IntelligencePreferencesPane.swift)) is the macOS-only surface for the on-device AI assistant feature. Tab icon: `sparkles`. Accessibility identifier: `preferences.tab.intelligence`.

The pane contains eight sections, rendered in this order by `IntelligencePreferencesPane.body`: Enable, Provider, Playback Control, External Access, **Web & Music Suggestions**, MCP Servers, Feature Bundles, Audio Analysis.

**Enable section** (`IntelligenceEnableSection`) — the master Intelligence toggle (`intelligence.masterToggle`) with two caption rows explaining what the feature does and what happens when it is off. A live `IntelligenceStatusRow` appears below, reporting the active tier — either Apple Intelligence readiness (`AssistantAvailabilityProbe`) or the selected connector's own state once one is chosen (`intelligence.availabilityStatus`). The status is read from `AssistantAvailabilityProbe.current(intelligenceEnabled:)` on appear and on every toggle flip — not in `body` — because the reading crosses into the system's language-model service. A fallback caption ("The heuristic tier still answers requests") appears for unavailable reasons other than the user switching the feature off manually.

**Provider section** (`IntelligenceProviderSection`, [`Preferences/IntelligenceProviderSection.swift`](Sources/Preferences/IntelligenceProviderSection.swift)) — the connector picker (`intelligence.connectorPicker`) bound to `AppSettings.selectedConnectorID`. All six entries are always present in `macampMac`: Apple Intelligence (default — picker tag `nil`), Ollama, Anthropic Claude, OpenAI, Claude Subscription, ChatGPT. Selecting a connector triggers `.task(id:)` which calls `provider.reload` to probe the live `ConnectorRegistry` and populate the status row (`intelligence.connectorStatus.<id>`) and the model picker (`intelligence.modelPicker`). The status row contains a **Set Up…** button (`intelligence.connectorSetup`) for credential connectors (opens `IntelligenceConnectorConfigSheet`) and a **Sign In…** button (`intelligence.connectorSignIn`) for OAuth subscription connectors (presents `ClaudeSignInSheet` or `ChatGPTSignInSheet` via `#if MACAMP_EXTERNAL_OAUTH`). A **Refresh** button (`intelligence.connectorRefresh`) re-probes status on demand. The connect-time consent sheet (`IntelligenceConsentSheet`) is presented modally from this section before any non-local connector's first request; it discloses the exact payload budget (`ConnectorPayloadBudget`: 600 characters, 64 genres, 50 artists). The section is `.disabled(!settings.intelligenceEnabled)` — the picker is inert while the master switch is off. Claude Subscription carries a `ClaudeCLICredentialStore` path: if the Claude CLI is signed in on this Mac, `OAuthCredentialEngine` detects and reuses it (displaying "Signed in via Claude CLI"), with a **Stop Using CLI Session** button that suppresses reuse for the life of the process without deleting the CLI's own credential.

**Feature bundles section** (`IntelligenceBundlesSection`) — one toggle per `AIFeatureBundle`: NL Creation, Auto Mixes, Organization, Rediscovery, Insights, Hygiene. Each toggle has its own caption row. The whole section is `.disabled(!settings.intelligenceEnabled)` — individual bundle switches are inert while the master switch is off. Accessibility identifiers follow the pattern `intelligence.bundleToggle.<rawValue>`.

**Playback control section** (`IntelligencePlaybackControlSection`, [`Preferences/IntelligencePlaybackControlSection.swift`](Sources/Preferences/IntelligencePlaybackControlSection.swift)) — a single toggle (`intelligence.playbackControl.toggle`) bound to `AppSettings.assistantPlaybackControlEnabled`. **Default ON.** When on, the four control tools (`get_playback_state`, `play_tracks`, `queue_tracks`, `transport`) are registered with the `LibraryToolbox` and the conditional instruction line is added to `LibraryChatInstructions`. When off, those tools are absent from every tier's published list and the instruction line is absent — a model is never told to call a tool it was not given. The caption states the default explicitly rather than hiding it (the rationale: typing "play it" into your own player's chat box is the instruction; the off-switch exists for a read-only assistant). `PlaybackControlWitness` (`macOS/Sources/Assistant/PlaybackControlWitness.swift`) is the `ToolboxPlaybackControlling` conformer that bridges the seam to `PlaybackCoordinator` and is injected at composition root. Accessibility identifier: `intelligence.playbackControl.toggle`.

**Audio analysis section** (`AudioAnalysisSettingsSection`) — opt-in background audio-feature extraction (tempo, energy, brightness) that feeds the smart-playlist engine and mix generator. The section shows library coverage ("34% analyzed — 340 of 1,000 tracks"), current pass progress, and pause / resume / stop controls while a pass runs. Idle, it offers **two** start actions: **Analyze Library** (`intelligence.analysisStart`) fills only the gaps — it is fingerprint-driven and correctly a no-op at full coverage — and **Re-analyze Library** (`intelligence.analysisRescan`) discards every cached `trackAudioFeature` row and measures the whole library again, behind a destructive `confirmationDialog` (`intelligence.analysisRescanConfirm` / `intelligence.analysisRescanCancel`) whose copy states plainly that it decodes every audio file again and can take a long time. The rows are pure derived data, so deletion is the whole of the "force" mode — there is no second staleness rule to keep in step with `AudioFeatureCoverageReader`. Progress, pause, resume and stop behave identically for both passes.

**Web & Music Suggestions section** (`IntelligenceWebSuggestionsSection`, [`Preferences/IntelligenceWebSuggestionsSection.swift`](Sources/Preferences/IntelligenceWebSuggestionsSection.swift)) — "Suggest music beyond my library" (`intelligence.webSuggestions.toggle`), bound to the `AppSettings` pair `webSuggestionsEnabled` + `webSuggestionsConsented`. **Default OFF, and consent is never derived from enablement:** flipping the switch on presents `IntelligenceWebSuggestionsConsentSheet` first (`intelligence.webSuggestions.consent.{sheet,payload,acceptButton,cancelButton}`), which names both recipients, states that only song titles and artists leave (never files, paths, playlists or listening history), and says plainly that the lookups happen **only while a cloud provider is answering — the on-device assistant is never given them**. Declining leaves both flags off. Below the toggle sit two **optional** Keychain-backed key fields (`intelligence.webSuggestions.keyField.<slot>`, with `…saveKey.<slot>` / `…removeKey.<slot>`) for the search provider and the video Data API: both services run keyless by default, and a key only raises the provider's own rate limit — it changes nothing about what is sent. Keys live in `KeychainSecretStore`, never in `UserDefaults`. The section is `.disabled(!settings.intelligenceEnabled)`.

`IntelligencePreferencesPane` reads `AppEnvironment` for the coordinator and `AppSettings` for all toggle bindings. It does NOT add a `.onChange` for `intelligenceEnabled` to fire a graph rebuild — `AppEnvironment` owns that via `withObservationTracking`; a change handler would rebuild the graph twice per flip.

#### External Access section (Preferences ▸ Intelligence ▸ External Access)

`ExternalAccessSettingsSection` appears after the Audio Analysis section. It surfaces `MCPExternalAccessModel` (`@MainActor @Observable`) to the user.

The section has four controls and one status row:

- **Allow external access** toggle (`intelligence.externalAccess.toggle`) — bound to `AppSettings.externalAccessEnabled`. Off by default. The first time this is turned on, `ExternalAccessDisclosure` is presented modally before the server starts: it explains that MacAMP cannot identify which program connects, and forwards the per-result caps from `ToolProfile.external` (100 rows, 16 KB). The toggle is `.disabled(!settings.intelligenceEnabled)` — external access requires the master switch.
- **Allow control access** toggle (`intelligence.externalAccess.controlToggle`) — bound to `AppSettings.externalAccessControlEnabled`. **Default OFF.** When off, the four control tools are absent from the MCP tool list entirely — a client that names one receives an unknown-tool error that enumerates only the ten metadata tools, so the control surface cannot be discovered. When on, those four tools are appended to the list and a disclosure caption states plainly that a connected program can start and stop playback. The toggle is only visible when external access is enabled. Accessibility identifiers for the control disclosure: `intelligence.externalAccess.consent.control`.
- **Port** field (`intelligence.externalAccess.port`) — bound to `AppSettings.externalAccessPort`. Default 46114. An out-of-range stored value degrades to the default without crashing.
- **Address** row (`intelligence.externalAccess.address`) — `http://127.0.0.1:<port>`, shown in monospaced text when the server is running.
- **Status** row (`intelligence.externalAccess.status`) — reflects `MCPServerStatus`: `.stopped`, `.running(port:)`, `.portUnavailable(port:)`, `.failed(reason:)`. A failure reason appears as a secondary caption (`intelligence.externalAccess.failureReason`).

**`MCPExternalAccessModel`** is the composition root's `externalAccess` property — a `lazy var` that **outlives** the `AIStack`. The AI graph is rebuilt on provider change, model change, profile switch, and master-toggle flip; an MCP server rebuilt alongside it would drop every connected external client for reasons unrelated to external access. `AppEnvironment.connectExternalAccess(settings:)` wires the model to `AppSettings` changes; `apply(settings:)` is the single place all four switches (`intelligenceEnabled`, `externalAccessEnabled`, `externalAccessConsented`, `externalAccessControlEnabled`) are read.

**Tool count by grant state:** ten metadata tools when `externalAccessControlEnabled` is false (the default); all fourteen when true (`tools/list` returns `[…the first nine…, get_playback_state, play_tracks, queue_tracks, transport, match_tracks]` — `match_tracks` is registered after the control block, so the grant appends rather than renumbering). `MCPControlGrantTests` pins this matrix and the unknown-tool enumeration so a grant-state mismatch fails a test rather than going to wire.

**`MCPLibraryServer`** (actor) binds to `127.0.0.1:<port>` via `NWListener` with `requiredLocalEndpoint`. No silent fallback port — a busy port becomes `.portUnavailable` in the status row, because the address shown in the pane must be accurate. `allowLocalEndpointReuse` is `false`.

**The transport is stateless.** `MCPHTTPConnectionLoop` gives every accepted TCP connection its own (`MCP.Server`, `StatelessHTTPServerTransport`) pair, built by `MCPServerFactory.make(source:)` / `MCPServerFactory.transport(port:)` and torn down when the socket closes. There are no sessions: **no `Mcp-Session-Id` is minted or required**, **GET and DELETE answer 405** (`Allow: POST`), responses are **plain `Content-Length`-framed JSON** rather than SSE, and every POST is self-contained — `tools/call` is served on a brand-new connection with no prior `initialize`. The pair is connection-scoped rather than shared for two verified SDK reasons: `Server`'s built-in `initialize` handler refuses a second initialize (`-32600 Server is already initialized`, *not* gated on `Configuration.strict`), and `StatelessHTTPServerTransport` keys its response waiters by the client's own JSON-RPC id, so two clients that both number a request `1` would collide. The validation pipeline is the SDK's stateless default with origin validation pinned to the bound port (`OriginValidator.localhost(port:)`); `AcceptHeaderValidator(mode: .jsonOnly)` requires `application/json` to be *named*, so the `application/json, text/event-stream` pair every real client sends is served. Accessibility identifiers for the disclosure: `intelligence.externalAccess.consent.{sheet,payload,acceptButton,cancelButton}`.

**`AIStack`** gained one member: `let externalToolbox: LibraryToolbox`. The toolbox is read at call time through a closure (`MCPToolboxSource.currentToolbox`), never captured — so a profile switch replaces the `AIStack` and the next `tools/call` finds the incoming profile's scope automatically.

#### Updates pane (Preferences ▸ Updates)

`UpdatesPreferencesPane` ([`Preferences/GeneralPanes.swift`](Sources/Preferences/GeneralPanes.swift)) is the macOS-only Sparkle surface:

- **Update channel** picker — Stable / Beta, bound to `AppSettings.updateChannel`. The value feeds `SparkleUpdaterDelegate.allowedChannels(for:)`: Stable → `[]` (untagged appcast items only), Beta → `["beta"]`. A caption warns that beta builds may be less stable.
- **Check for Updates…** button — calls `UpdaterModel.checkForUpdates()`, which runs a *verbose* user-initiated check (reports "up to date" and network failures, unlike the silent scheduled one). `.disabled(!updater.canCheckForUpdates)`, mirrored from `SPUUpdater` via KVO. Accessibility identifier: `preferences.updates.checkButton`.
- **Automatic checks have no toggle.** `SUEnableAutomaticChecks` in `Info.plist` opts in up front; the pane only carries a caption stating that background checks happen.

`MacAMPApp` builds exactly one `SPUStandardUpdaterController` in its `init()` and injects the `UpdaterModel` façade into the environment. `UpdaterModel.preview` is inert (no updater attached), so previews and tests never touch the network.

#### Karaoke pane (Preferences ▸ Karaoke)

A dedicated `KaraokePreferencesPane` (replacing the old `KaraokeSettingsSection` inside Playback) contains:

- **Toggle** — "Karaoke mode" (`settings.karaoke.toggle`), bound to `AppSettings.karaokeEnabled`.
- **Quality picker** — Standard (256 kbps AAC) / High (24-bit ALAC), bound to `AppSettings.karaokeQuality`. Applies to new renders only.
- **Cache location** — `NSOpenPanel`-backed path picker (plain path, never a security-scoped bookmark). **Choose...** / **Reset to Default**. A folder that overlaps any profile's library roots (bidirectionally) is rejected.
- **Limit cache size** toggle + 1/2/5/10 GiB cap picker, bound to `AppSettings.karaokePruneEnabled` / `AppSettings.karaokeCacheCapBytes`.
- **Cache size readout** — `LabeledContent` showing current size via `ByteCountFormatStyle`.
- **Clear button** — "Clear Karaoke Cache", disabled while clearing.

The pane is macOS-only. iOS builds compile the `AppSettings` keys for compatibility but the UI is not present.

#### Downloads pane (Preferences ▸ Downloads)

`DownloadsPreferencesPane` ([`Preferences/DownloadsPreferencesPane.swift`](Sources/Preferences/DownloadsPreferencesPane.swift)) configures the YouTube downloader. Tab icon: `arrow.down.circle`. The pane is macOS-only; iOS builds compile the `AppSettings` keys for compatibility but the UI is not present.

- **Destination folder** — `NSOpenPanel`-backed path picker. Default `~/Music/MacAMP Downloads`. A folder that overlaps the karaoke instrumental cache (bidirectionally) or any of MacAMP's own Application Support / Caches locations is rejected. The rejection is enforced by `DownloadsDestinationRejection.reject(_:karaokeCacheDirectory:)`, which runs the three gates in order (app-internal → karaoke-overlap → writability probe) because the writability probe creates the directory and must not create it inside a refused location. The destination is NOT a library root and is never watched.
- **Add finished downloads to my library** toggle (`preferences.downloads.autoImportToggle`) — bound to `AppSettings.downloads.autoImportEnabled`, **default OFF**. On: each finished item is imported individually via `LibraryScanner.scan(.files([url]))` on its `after_move` path, and a caption says so. Off: nothing is scanned, so a downloaded track lands on disk and appears nowhere in the app — the one failure this switch can cause, and one a listener cannot diagnose, so the off-state notice (`preferences.downloads.autoImportOffCaption`) names both exits: this toggle, or adding that folder in Preferences ▸ Library.
- **Simultaneous downloads** Picker (`preferences.downloads.concurrencyPicker`) — bound to `AppSettings.downloads.maxConcurrent`, range 1–4, **default 3**. Controls how many yt-dlp processes run in parallel. The tooltip (`downloadsConcurrencyHelp`) reads "How many downloads transfer at the same time." A caption below (`downloadsConcurrencyCaption`) explains the honest tradeoff: more transfers share your connection and can prompt YouTube to slow down or temporarily refuse requests from your IP; if downloads start failing, set it back to 1; a change applies to downloads that start from now on. Absent ≠ 0: the key is stored as an Optional integer and a missing entry resolves to the default (3) rather than to 0, so an install that predates this key gets the correct default without a migration.
- **Container** picker — M4A *(default)* / MP3 / Opus / FLAC, bound to `AppSettings.downloads.audioFormat`. Controls the yt-dlp `--audio-format` argument.
- **Quality** picker — Best *(default)* / High / Medium, bound to `AppSettings.downloads.audioQuality`. Disabled for FLAC (lossless has no quality setting). Note: for YouTube opus sources yt-dlp remuxes (stream-copies) rather than re-encoding, so this setting is inert for those items.
- **Engine version** row — displays the installed yt-dlp version (`YYYY.MM.DD` tag) and a staleness indicator (stale after 90 days). **Check for Updates** (`preferences.downloads.engineCheckButton`) probes the GitHub Releases API for a newer version. **Update Engine** (`preferences.downloads.engineUpdateButton`) downloads, SHA-256-verifies, swaps, and validates the new binary; it rolls back automatically if the swapped binary fails its own `--version` check. Both buttons are disabled while any download is active (`DownloadToolManager.isUpdateDeferred()`).

#### Profiles pane (Preferences ▸ Profiles)

Lists profiles with create/edit/delete/switch actions, PIN management, and export/import archive actions. Export writes a `.macampprofile` file via `NSSavePanel`; import reads one via `NSOpenPanel`. Both panels use `#if DEBUG` launch-environment seams (`UITEST_ARCHIVE_EXPORT_DIR`) so XCUITest can drive them without a modal `runModal()` block.

---

## 7. Player bar

[`PlayerBarView.swift`](Sources/PlayerBarView.swift) — height **100**, padding
`xLarge`/`medium`, `.ultraThinMaterial @80%` + album-theme wash @14% (or `canvas
@80%` under reduce-transparency), hairline top separator. Three zones plus optional
inline spectrum ([`Player/`](Sources/Player)):

| Zone | Contents |
|---|---|
| **Identity** ([`PlayerBarIdentity.swift`](Sources/Player/PlayerBarIdentity.swift)) | 48×48 artwork + title (headline, `MarqueeText` — slides while playing, static when paused) / artist (caption, an interactive `ArtistLink`, deliberately NOT a marquee: `MarqueeText` carries no action and would destroy artist navigation); tap → expanded overlay; pointing-hand cursor. |
| **Transport** ([`PlayerBarTransport.swift`](Sources/Player/PlayerBarTransport.swift)) | shuffle · previous · **play/pause (medium prominent)** · next · repeat (with "1" badge when repeat-one) · **karaoke button** (when karaoke setting is enabled). Cycle off→all→one. |
| **Scrubber** ([`PlayerBarScrubber.swift`](Sources/Player/PlayerBarScrubber.swift)) | optional bitrate/rate capsule (≥280 pt) · elapsed timecode · `PlayerSlider` · remaining `-M:SS`. 0.5 s ticker while playing. **Replay heat overlay** (`ScrubberHeatOverlay`) revealed on hover or drag — a `ReplayHeatCurve` drawn behind the slider track, showing which sections of the track you replay most. Appears once `totalPasses >= 3` **or** some 1% slice has been heard 3+ times. This 18 pt row has no vertical room for the visible "Most Replayed" caption the full player and expanded overlay use, so the bar names the curve with a **`.help` tooltip** instead — selected as a `Text` value (empty when there is no curve) rather than behind an `if`, which would change the subtree's identity and discard the overlay's loaded model. |
| **Spectrum** ([`InlineSpectrumView.swift`](Sources/InlineSpectrumView.swift)) | 90×36, 24 bars, when enabled. |
| **Volume** ([`PlayerVolumeControl.swift`](Sources/Player/PlayerVolumeControl.swift)) | volume slider between speaker icons + balance row (L / slider / R / reset). |

#### Karaoke button ([`Player/KaraokeButton.swift`](Sources/Player/KaraokeButton.swift))

`KaraokeButton` appears in the transport cluster after the repeat button, but only
when the karaoke setting is enabled. It reads `PlayerViewModel.karaokeButtonState`
and renders one of five states:

| State | Appearance | Behavior |
|---|---|---|
| `hidden` | `EmptyView` — absent from view tree and AX hierarchy | Setting is OFF; button does not exist |
| `disabled(reason)` | `microphone` glyph, greyed (`textDisabled` token), inert | Model unavailable (App Store build, fresh clone, load failure); `.help(reason.message)` tooltip |
| `renderable` | `microphone` glyph + `+` badge (`mic.badge.plus`) | No instrumental yet; click to schedule a render on demand |
| `preparing(Double)` | `microphone` glyph + `KaraokeProgressRing` arc overlay (accent, 2 pt, 0→1) | Render in progress for the current track; arc value from `karaokePreparationProgress` |
| `ready` | `microphone` glyph, standard prominence | Instrumental cached; press toggles karaoke ON |
| `active` | `microphone.slash` glyph, accent styling | Instrumental is playing; press toggles karaoke OFF |

The button uses `KaraokeButtonStyle` (private), which mirrors `TransportButton`'s
circular styling at `TransportButton.Size.small` (36 pt diameter, 0.40 glyph
scale). The action is `environment.player.toggleKaraoke()` — fire-and-forget.
Accessibility identifier: `player.karaokeButton` (present in all visible states;
absent when `hidden`).

`KaraokeProgressRing` is a private leaf view that reads only
`environment.player.karaokePreparationProgress` (the Rule-3 scoped property from
`PlayerViewModel`), so the ring re-renders on progress updates alone without
triggering a full transport cluster re-render. The arc uses `.allowsHitTesting(false)`
so it never blocks the button tap target. Reduce-motion is honored by construction
(value-driven `Circle().trim`, no animation).

#### Karaoke ready list — Remove Karaoke Version

The **Karaoke** sidebar section (`KaraokeReadyListView`) supports per-entry removal. Right-click a row (or a multi-row selection) and choose **Remove Karaoke Version** to delete the cached instrumental(s). The action is multi-select-aware: all selected rows are processed in one batch. A karaoke version currently in use (pinned by the coordinator or render service) is kept; the toast message reports the outcome explicitly:

- All removed: "Removed N karaoke versions"
- Some kept: "Removed N karaoke versions; the one in use was kept"
- All kept: "Kept — this karaoke version is in use"

Removal emits the cache change-seam exactly once per batch, so the ready list and sidebar badge update in a single pass. The inline mic icon on track rows (`trackRow.karaokeRender`, a11y id) schedules a render without playback; it is enabled only when karaoke is available, the track has no ready instrumental, and it is not already rendering.

---

## 8. Menu bar & visualizer

### Menu-bar mini player ([`MenuBarView.swift`](Sources/MenuBarView.swift))

300 pt wide, padding `large`, on `surface`: now-playing card (56×56 art + title/artist)
→ scrubber → transport (previous · play/pause · next) → volume → divider → footer
(Show MacAMP `macwindow` · Quit `power`).

The scrubber carries the **replay heat overlay** (`ScrubberHeatOverlay`) like every
other MacAMP scrubber, revealed on hover or drag. It names the curve with the
**`.help` tooltip** form (`scrubberHeatTooltip`), not the visible
`ScrubberHeatCaption` — this popover carries no text labels at all, so the only
prose above the scrubber would read as a heading for the popover rather than a
name for a decoration, and the caption is permanently in the layout by design, so
its row would grow a summon-and-dismiss utility for text visible only on hover.

`.menuBarExtraStyle(.window)` rebuilds the content on each open, so the overlay's
`.task(id:)` re-reads exactly one `playSegmentHeat` row per presentation — the
intended coarse refresh, since the row can only change when a listen flushes.

### Visualizer

The main window uses [`InlineSpectrumHost`](Sources/InlineSpectrumView.swift)
in the player bar and expanded player. Each instance draws through
`InlineSpectrumNSView` and shares the selected mode through the visualizer model.

[`VisualizerHostView`](Sources/VisualizerHostView.swift) is implemented separately
and currently has only a preview entry point.

Full-bleed Metal (or projectM) stage with an **auto-hiding HUD** deck (thick-glass
capsule, `elevation.high`, hides after 2.5 s): a **mode rail**
(bars/oscilloscope/particles/aurora), optional renderer menu, a windowed↔fill
presentation toggle, and a full-screen toggle. **Windowed** mode rounds
(`radii.xLarge`), borders, shadows, and pads the renderer, and adds a bottom accent
bloom; **fill** mode drops all chrome. An idle overlay (waveform glyph + title +
message) shows when nothing is playing.

---

## 9. Visual language summary

- **Neon / synthwave accents** power the spectrum, splash bar, and empty states — pink `rgb(1.0, 0.22, 0.56)`, cyan `rgb(0.39, 0.82, 1.0)`, purple `rgb(0.68, 0.35, 1.0)` (and the `macAMP` palette). Chrome otherwise stays neutral (`standard` palette) and lets album art supply the color via [theming](#2-album-theming).
- **Gradients:** splash neon loading bar (pink→purple→cyan, dual glow); synthwave empty backdrop; visualizer accent bloom (radial `.plusLighter`).
- **Animation:** hover fills & toggles `quick (0.18)`; transitions `standard (0.30)`; theme changes `expressive (0.5)`; springs for toasts/overlays; spectrum bars use interpolating springs. All respect reduce-motion.
- **SF Symbols** (never bundled art): transport `play.fill`/`pause.fill`/`shuffle`/`repeat`(`.1`)/`backward.fill`/`forward.fill`/`speaker.wave.2.fill`; nav `sidebar.leading`/`sidebar.trailing`/`chevron.*`; media `music.note`(`.list`)/`heart`(`.fill`)/`square.stack`/`person.2`; state `exclamationmark.triangle.fill`/`externaldrive.badge.xmark`; actions `plus`/`trash`/`pencil`/`square.and.arrow.up`/`.down`/`magnifyingglass`/`xmark.circle.fill`/`slider.vertical.3`/`waveform`/`gearshape`/`globe`/`macwindow`/`power`.

---

## 10. Responsive behavior & interaction

- **Constraints:** window `minWidth 880` / `minHeight 560`; sidebar fixed 240; grids adapt at 150 pt min tile.
- **Adaptive hiding:** the scrubber drops its bitrate capsule below ~280 pt; the genre bar hides with ≤1 genre; the player bar sheds optional elements when compact.
- **Dynamic Type:** all fonts scale; spacing tokens scale with them; fixed artwork sizes (48/56/120/280) hold.
- **Interaction:** multi-select (⌘-click), right-click context menus with a double-click primary action, destructive actions in `danger`; drag-and-drop reordering (playlists/favourites) and file import; hover states (toolbar fills, tile borders, pointing-hand cursors); overlays transition from their originating edge.

---

## Related

- **Portable core logic:** [`PlayerCore/README.md`](../PlayerCore/README.md)
- **Design tokens & components (source):** [`PlayerCore/Sources/DesignSystem`](../PlayerCore/Sources/DesignSystem)
- **iOS shell (WIP) + feature-parity matrix:** [`iOS/README.md`](../iOS/README.md)
- **Project overview / build & test:** [root `README.md`](../README.md)
- **End-user feature guide:** [`docs-site/content/docs/`](../docs-site/content/docs/)
- **Engineering contract:** [`.opencode/skills/macamp/SKILL.md`](../.opencode/skills/macamp/SKILL.md)
