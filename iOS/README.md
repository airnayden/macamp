---
title: MacAMP — iOS / iPadOS Shell
description: The iOS/iPadOS app shell over PlayerCore. Work in progress.
---

# MacAMP — iOS / iPadOS Shell

> ## 🚧 Work in progress
>
> **macOS is the reference, release-quality surface.** The iOS/iPadOS shell is
> **substantially implemented but not release-hardened**: it builds and runs, every
> top-level screen exists, and the audio-session and import layers are wired — but
> it has **not** been through the same visual-fidelity, QA, and App-Store hardening
> pass as macOS. Layouts, APIs, and file organization here are **subject to
> change**. Known gaps are tracked in [Status & known gaps](#status--known-gaps).

The `macampiOS` target is a thin SwiftUI shell over the shared
[`PlayerCore`](../PlayerCore/README.md) package. It reuses audio, persistence, metadata, DSP, and shared presentation state
(`@Observable` view models) from `PlayerCore`. The shell contributes
(1) the iOS/iPadOS view layer and (2) the platform glue that PlayerCore
deliberately does not own — the `AVAudioSession` and document-picker import.

> For the portable core logic, see [`PlayerCore/README.md`](../PlayerCore/README.md).
> For the fully-realized UI reference, see [`macOS/README.md`](../macOS/README.md).

---

## Composition root

[`AppEnvironment`](Sources/AppEnvironment.swift) is the single app-wide object
graph, built once and injected through the SwiftUI environment
(`@Environment(AppEnvironment.self)`). It mirrors the macOS composition root — only
the leaf dependencies differ — and exposes two factories:

| Factory | Wiring |
|---|---|
| `live()` | On-disk `AppDatabase.shared`, real `SFBPlaybackEngine` (ADR Option A, verified on iOS), SFB/TagLib metadata reader, GRDB repositories + preset store. Activates the audio session. |
| `preview()` | In-memory database + the modules' shipped `Fake*` implementations — no disk, audio, or network. Keeps `#Preview` hermetic. |

The graph it assembles: the nine shared view models (`library`, `search`,
`player`, `queue`, `equalizer`, `visualizer`, `lyrics`, `playlists`,
`playlistImportExport`), the shared services (`coordinator`, `scanner`,
`nowPlaying`, `replayGain`, `remoteCommands`, `enrichment`, `infoService`), and the
iOS-only `audioSession` controller. Every stored property is `@ObservationIgnored`
— change tracking lives inside the nested `@MainActor @Observable` view models.

---

## Imported media access

`AppEnvironment.live()` restores saved library-root grants before constructing
the playback graph. The importer and playback graph share one
`SecurityScopedAccessOwner`, retaining successful grants beyond the scan. Unit
tests cover ownership and balanced release; reopening iCloud and third-party
provider media on physical devices still needs verification.

## Adaptive shell

[`RootTabView`](Sources/RootTabView.swift) adapts to size class:

- **iPhone (compact)** → a `TabView` tab bar.
- **iPad (regular)** → a `NavigationSplitView` (sidebar + detail).

Both present the same five destinations over the shared environment:

| Tab (`AppTab`) | SF Symbol | Screen |
|---|---|---|
| Library | `music.note.house` | [`LibraryScreen`](Sources/Library/LibraryScreen.swift) |
| Playlists | `music.note.list` | [`PlaylistsScreen`](Sources/Playlists/PlaylistsScreen.swift) |
| Now Playing | `play.circle` | [`NowPlayingScreen`](Sources/Player/NowPlayingScreen.swift) |
| Search | `magnifyingglass` | [`SearchScreen`](Sources/Search/SearchScreen.swift) |
| Settings | `gearshape` | [`SettingsScreen`](Sources/Settings/SettingsScreen.swift) |

---

## Screens

| Area | Files | Notes |
|---|---|---|
| **Library** | [`Library/`](Sources/Library) — `LibraryScreen`, `AlbumDetailView`(+VM), `ArtistDetailView`(+VM), `LibraryScopePicker`, `GenreFilterChipBar`, `PlayableTrackList`, `DetailPlayBar` | Keyset-paginated tracks/albums/artists with album & artist detail, genre filtering, and a scope picker. |
| **Now Playing** | [`Player/`](Sources/Player) — `NowPlayingScreen`, `EQSheet`, `LyricsView`, `VisualizerSheet`, `MetalVisualizerView`, `AlbumArtSupport`, `VisualizerSupport` | Transport + artwork, with EQ, synced lyrics, and the Metal spectrum visualizer presented as sheets. |
| **Playlists** | [`Playlists/`](Sources/Playlists) — `PlaylistsScreen`, `PlaylistDetailView`, `AddToPlaylistSheet`, `PlaylistNameSheet`, `PlaylistTransfer` | Browse/edit playlists; add-to-playlist and rename sheets; import/export transfer. |
| **Search** | [`Search/`](Sources/Search) — `SearchScreen` | Debounced FTS5 search over the shared `SearchViewModel`. |
| **Settings** | [`Settings/`](Sources/Settings) — `SettingsScreen`, `AppSettings` | Preferences backed by the App-Group `UserDefaults` suite; playback, EQ and visualizer defaults, optional online metadata auto-fill, and enrichment progress. |
| **Tag editor** | [`Tags/`](Sources/Tags) — `TagEditorSheet`(+VM +Model), `TagEditContextMenu`, `WritableSource` | Atomic tag writing via PlayerCore's `MetadataWriting`, with online auto-fill. |

---

## iOS-only platform layers

These exist **only** in the shell because `PlayerCore` is platform-agnostic (it has
no `AVAudioSession` or `UIDocumentPicker`).

### Audio session
[`AudioSessionController`](Sources/AudioSessionController.swift) owns the
`AVAudioSession` lifecycle and routes every system audio event through the pure
[`AudioSessionPolicy`](Sources/Audio/AudioSessionPolicy.swift) state machine
(exhaustively self-checked in DEBUG). It configures the `.playback` category
(background audio), pauses on interruptions (calls/Siri) and resumes only when the
system grants `.shouldResume`, pauses on `oldDeviceUnavailable` route changes
(headphones unplugged) per the HIG, and restarts the graph on
`AVAudioEngineConfigurationChange` — guarded so a config change mid-interruption
never blasts the speaker. It drives PlayerCore through the `PlaybackCoordinating`
seam.

### Document import
[`Import/`](Sources/Import) — `DocumentImporter`, `SecurityScopedBookmarks`,
`BookmarkLifecycle` — brings folders/files in through the document picker and
persists security-scoped bookmarks so access survives relaunch.

---

## Now-playing surfaces

The shell keeps two now-playing presentations in sync from one playback state:

1. **In-app** Now Playing screen (`PlayerViewModel`).
2. **Control Center / lock screen** — `MPNowPlayingInfoCenter` + media-key/remote
   commands via PlayerCore's `NowPlayingService` and `RemoteCommandHandler`
   (constructed and `activate()`-d in `AppEnvironment`).

> **App Group:** `group.si.macamp.MacAMP` is **retained** and load-bearing — the
> shell's [`AppSettings`](Sources/Settings/AppSettings.swift) is backed by
> `UserDefaults(suiteName: AppGroup.identifier)`. PlayerCore's `NowPlayingSnapshot`
> publish seam still exists but is **dormant**: `AppEnvironment` constructs
> `NowPlayingService` with `snapshotWriter: nil`, so nothing is written to the
> container today. See [`PlayerCore/README.md`](../PlayerCore/README.md#app-group-boundary-types).

---

## Status & known gaps

- **Implemented:** all five tabs, album/artist detail, playlists, search, tag
  editor, EQ / lyrics / visualizer sheets, audio-session policy, background
  enrichment, security-scoped import, and the full lock-screen / Control Center
  now-playing feed — the shell calls `updateTrack` on every playback-state change,
  so `MPNowPlayingInfoCenter` carries a real title, and transport commands route
  back through the shared coordinator via `RemoteCommandHandler`.
- **No home-screen widget or Live Activity.** The `macampWidget` extension and the
  iOS `LiveActivityController` were **removed** — those surfaces do not exist on
  any platform today. The App-Group snapshot seam that fed them is retained but
  dormant (see [Now-playing surfaces](#now-playing-surfaces)).
- **Release hardening is pending.** The iOS shell has not had the macOS shell's QA / release-hardening pass; visual fidelity, layout, and distribution details are subject to change.
- **No dedicated UI-fidelity pass.** Unlike macOS, these screens have not been
  through snapshot/visual QA; spacing and layout may still shift.

---

## Feature parity vs macOS

> **This section is a MAINTAINED contract.** Any change that adds, removes, or
> materially alters a user-facing feature in either shell must update this table in
> the same change — stating what tier the feature moved to. A stale parity table is
> a failing gate, not a known gap. See also the parity maintenance rule in
> [`.opencode/skills/macamp/SKILL.md`](../.opencode/skills/macamp/SKILL.md).

### On par (shared PlayerCore core)

Both shells consume the same `@Observable` view models, repositories, and services
from PlayerCore with no duplication of business logic. The following work
identically on iOS and macOS today:

- **Playback** — SFBAudioPlayer Option A graph, 10-band EQ, ReplayGain
  (`eq.globalGain`, clamped −96…+24 dB), gapless enqueue, volume + balance.
- **Codecs** — the full SFBAudioEngine 0.12.1 codec set (FLAC, MP3, Ogg Vorbis,
  Opus, WavPack, APE, and more) via the shared `DecoderProviding` seam.
- **Library** — GRDB schema v1–v16, keyset-paginated track/album/artist browsing,
  FTS5 full-text search (<50 ms cold on 100k tracks), three-state availability
  machine (`present` / `missing` / `externalOffline`).
- **Metadata** — tag reading + atomic writing (`SFBMetadataWriter`: temp-copy →
  `replaceItemAt` → rollback, FSEvents self-write suppression), online auto-fill.
- **Artwork & theming** — `ThemeExtractor` album-art color derivation, design
  tokens, and the single shipped **MacAMP** skin (`ThemePreset.macAMP` →
  `ColorPalette.macAMP`). Both shells collapsed from a multi-skin picker to one
  skin; each declares its own `ThemePreset` enum with the identical single case and
  the identical stored-preference migration (any legacy id — `viceCity`, `purple`,
  `midnight`, … — resolves to `macAMP` and is rewritten in place on first launch).
- **Lyrics** — playing-track synced lyrics (embedded + `.lrc` + LRCLIB opt-in),
  GRDB cache.
- **Metal visualizer** — spectrum renderer (`VisualizerBackend` protocol, SPSC
  pull-don't-push, `SpectrumBallistics` instant-attack / 0.85 release).
- **Playlists** — CRUD, drag-reorder, JSON/JSPF import/export.
- **Genre filter, album detail, artist detail** — shared `GenreFilterBarView`,
  `AlbumDetailViewModel`, `ArtistDetailViewModel`.
- **Background enrichment** — online metadata/info fetch pipeline.
- **Control Center / lock screen** — `NowPlayingService` + `RemoteCommandHandler`
  (constructed and `activate()`-d in `AppEnvironment`; media keys + transport
  commands fully wired).
- **Listening stats capture** — `PlayEventRecorder` and `PlaySegmentTracker` are
  constructed and wired in
  [`AppEnvironment+Composition.swift`](Sources/AppEnvironment+Composition.swift)
  (lines 60, 65) and surfaced via `playHooks`
  ([`AppEnvironment.swift`](Sources/AppEnvironment.swift) lines 76–86); play events
  and segment heatmaps are written to GRDB on iOS exactly as on macOS.

**iOS-only strengths** (no macOS equivalent):

- `AVAudioSession` policy state machine — `.playback` category, interruption
  resume, `oldDeviceUnavailable` route-change pause, engine restart on config
  change; exhaustively self-checked in DEBUG.
- Security-scoped document-picker import — `DocumentImporter` +
  `SecurityScopedBookmarks` + `BookmarkLifecycle`; access survives relaunch.

---

### Partial on iOS

| Feature | macOS | iOS |
|---|---|---|
| **AI / Intelligence** | Full assistant: multi-turn `LibraryChatSession`, in-transcript library track lists (real `TrackListRow`s with the library's own context menu, plus a "Not in your library" table on that same grid — numbered rows, a checkbox on every row, a live per-row download-status column, and Open/Download buttons beside the batch "Download selected"), `LibraryToolbox` (ten library tools + up to four playback-control tools = up to 14 at cloud/external tiers, across three tier profiles), chat message copy + text selection on every bubble, per-turn failure banners with distinct copy for rate limits, auth expiry, and unreachable providers, Web & Music Suggestions (verified YouTube links and search-fallback rows in the transcript, with the answering provider asked for the video ids before the rate-capped web search is spent), answer-first transcript layout on proposal turns (lookup machinery collapsed behind one disclosure), all six `AIFeatureBundle` surfaces (NL Creation, Auto Mixes, Organization, Rediscovery, Insights, Hygiene), five `AIConnectorKit` provider connectors, MCP external-access server, and outbound MCP client servers (Preferences ▸ Intelligence ▸ MCP Servers — add/edit/remove, per-server enable behind a trust disclosure, connection test). | Read-only Auto Mixes slice only: `GeneratedPlaylistService` + `AutoMixListViewModel`. FoundationModels is not referenced; the macOS seams that are absent are documented as **absences of a trigger** in [`AppEnvironment+AI.swift`](Sources/AppEnvironment+AI.swift) lines 15–27 — the day iOS grows a profile switcher or app-launch refresh, no new infrastructure is needed. |
| **Profiles** | Full UI: create/edit/delete/switch, PIN gate, per-profile library roots with legacy import, avatar images, export/import `.macampprofile` archive. | Guest-fixed: `ProfileService` is constructed so shared view models scope correctly, but no surface calls `switchTo` and `onActiveProfileChanged` never fires. See [`AppEnvironment.swift`](Sources/AppEnvironment.swift) lines 71–73. One closure addition is the documented migration path. |
| **Listening stats UI** | Full dashboard: Stats sidebar destination, four-window digest (`ListeningStatsViewModel`), Listening Clock, Top Tracks/Artists/Genres, Most Replayed with `ReplayHeatCurve`, Recent Plays, right-panel Stats tab, and the scrubber heat overlay on **every** macOS scrubber (player bar, full player, expanded Now Playing overlay, menu-bar mini) — each naming the curve as "Most Replayed" (a visible caption on the two roomy surfaces, a `.help` tooltip on the player bar and the mini popover). | Capture runs (events and heatmaps are written — see "On par" above), but **no UI exists**. `ListeningStatsViewModel` and `ScrubberHeatViewModel` are in PlayerCore and ready; the shell has no Stats screen or scrubber overlay yet. The overlay is additionally hover-driven, and iOS has no hover — an iOS port would need its own reveal trigger, not a straight lift. |
| **Queue** | Full sidebar destination, editing (reorder/remove), drag-to-reorder. | `QueueViewModel` is wired in `AppEnvironment` as one of the nine shared VMs, but no dedicated queue screen exists in the iOS shell. |
| **Visualizer backends** | Metal spectrum (default) + projectM / MilkDrop (always compiled in via `MACAMP_PROJECTM`, LGPL dynamically linked). | Metal spectrum only. projectM is structurally impossible on iOS: the `MACAMP_PROJECTM` flag is never defined for `macampiOS`, and the LGPL dynamic-link strategy cannot be replicated under iOS sandbox rules. |

---

### Missing entirely on iOS

These features have no partial implementation in the iOS shell today:

- **Karaoke / stem separation** — the Mel-Band Roformer Core ML model is 467 MB;
  bundling it in an iOS target would make the app undownloadable over cellular and
  is the honest blocker. The `Separation` PlayerCore module is platform-agnostic
  (no AppKit/UIKit), so the infrastructure is ready if a model-delivery strategy
  (on-demand resource, user download) is ever accepted.
- **Lyrics browser + sweep** — `LyricsBrowserViewModel` and `LyricsSweepService`
  exist in PlayerCore; no iOS screen presents them.
- **Favourites surface** — no dedicated Favourites screen or drag-reorderable
  favourites list. The `isFavourite` per-profile state is stored and the toggle
  widget exists in shared components; the screen is missing.
- **Folder browsing / watching** — `FolderBrowserViewModel` and `FolderSidebar`
  exist in PlayerCore, but persistent folder watching via FSEvents is macOS-only.
  iOS imports files through the document picker (security-scoped bookmarks) rather
  than watching a directory, so the model doesn't translate directly. The
  bottom-pinned **sidebar import progress strip** is macOS-only for the same
  reason — iOS has no sidebar — though its `ImportProgressModel` source lives in
  PlayerCore and would drive an iOS surface unchanged. The **folder Sort control**
  (Name / Date Added, ascending or descending, remembered across launches) is
  macOS-only for the same "no sidebar" reason and does not move the tier; its whole
  mechanism is portable — `FolderSort` (Models), `FolderSidebarViewModel.sort` and
  the `newestDateAdded` the folder summaries derive all live in PlayerCore, and only
  the menu and the `AppSettings.folderSort` persistence are shell-side.
- **All six AI feature-bundle UIs / connectors / consent / MCP** — NL playlist
  creation, Organization, Rediscovery, Insights, Hygiene, the assistant chat
  surface, all five provider connectors (`AnthropicConnector`, `OpenAIConnector`,
  `OllamaConnector`, and the two OAuth subscription connectors), library-browsing
  consent sheet, the **Web & Music Suggestions** section (consent-gated public-web
  lookups behind their own disclosure, plus two optional Keychain-stored provider
  keys), the MCP external-access server, and the outbound **MCP Servers**
  management section (add/edit/remove, per-server enable behind its own trust
  disclosure, connection test). `iOS/Project.swift` references no AIConnectorKit
  product at all, and `scripts/check-ios-oauth-linkage.sh` hard-fails if
  `AIConnectorKitOAuth` or `AIConnectorMCP` ever appears there.
- **Signal-path panel** — the player-bar format capsule opens a popover reporting
  the whole chain (source codec / rate / depth / bitrate, DSD badge, ReplayGain and
  total gain, graphic + parametric EQ and crossfeed state, balance, engine
  connection format, device clock, a sample-rate-conversion indicator, and a
  **"Direct path"** verdict that is never labelled "bit-perfect"). macOS-only. The
  decision logic is fully portable — `SignalPathModel` / `SignalPathInputs` live in
  PlayerCore `ViewModels` and depend on nothing platform-specific — but two of its
  inputs do not exist on iOS: there is no player bar to host the capsule, and the
  device clock is read through the macOS-only CoreAudio HAL
  (`CoreAudioNominalRate`). An iOS port would supply `deviceNominalRate: nil` (which
  the mapper already treats as "cannot claim a direct path") or an
  `AVAudioSession.sampleRate` reading, and place the panel on the Now Playing screen.
- **Sparkle auto-update** — not applicable on iOS. MacAMP is direct-distribution
  only (no App Store channel); iOS distribution today is sideload / dev-build.
  There is no equivalent update channel on iOS.
- **macOS chrome** — menu bar mini player, system media-key monitor
  (`MediaKeyMonitor`), right panel (Lyrics/Tags/Info/Stats tabs), splash screen,
  window toolbar with sidebar/right-panel toggles, Preferences window (twelve
  panes).
- **Bare-arrow keyboard shortcuts** — ↑/↓ adjusts volume ±5% and ←/→ seeks ±5 s
  using bare (no-modifier) arrow keys. The handler walks the key window's
  first-responder chain and yields when a text field, table, or outline is focused,
  so the shortcuts activate only when no input or list navigation is focused. iOS
  has no system keyboard; the shortcuts do not apply.
- **Menu-bar mini player improvements (batch 10)** — live volume slider binding,
  popover self-dismissal via `NSWindow` accessor when "Show MacAMP" is tapped, and
  layout corrections to the title/artist/control cluster. The menu bar surface is
  already macOS-only (see "macOS chrome" above); this entry tracks the specific
  improvements shipped in this batch.
- **Marquee/sliding track titles** — long titles animate as a seamless sliding loop
  on four macOS surfaces: the menu-bar popover, the expanded Now Playing overlay,
  the right-panel title row, and the **player-bar identity** (added after the first
  three; the player bar was scoped out of the original rollout and brought in
  later). Powered by `MarqueeText` (DesignSystem), which short-circuits all
  animation while the player is paused, keeping idle CPU ≈ 0%. The player bar's
  artist line stays a plain `ArtistLink` — it is an interactive navigation control
  and `MarqueeText` carries no action. No iOS equivalent today.
- **Provider and model label in the assistant** — the intelligence caption below
  the chat field reflects the active route: "Powered by Apple Intelligence" for the
  on-device Foundation Models path, or "Powered by \<Provider\> — \<Model\>" for a
  cloud connector route. The assistant chat surface is macOS-only on this shell (see
  the AI / Intelligence row in Partial above).
- **Chat bubble hover-copy button** — a third copy affordance appears on every
  chat bubble on hover: a top-trailing overlay button that copies the full message
  and shows a "Copied" toast. The button is opacity-hidden when not hovered
  (`.allowsHitTesting(false)` while invisible, so it cannot intercept text
  selection). iOS has no hover state; the existing `.textSelection(.enabled)` and
  context-menu Copy remain the applicable paths when the chat surface ships on iOS.
- **YouTube downloader** — the Downloads sidebar destination (paste-links sheet,
  Queue tab with concurrent per-item progress, drag-reorder and pause/resume,
  **History tab** with reveal/re-download/delete-row/clear-all actions) and the
  **Downloads preferences pane** (destination folder picker, simultaneous-downloads
  stepper, container/quality pickers, engine version + self-update) are macOS-only.
  **Parallel downloads** (up to `downloadMaxConcurrent` simultaneous transfers) are
  also macOS-only for the same reason. `DownloadQueueStore`, `DownloadsViewModel`,
  `DownloadPasteInput` and the whole `Services/Downloads` queue live in PlayerCore
  and are portable by construction (no `Process`, no `URLSession` — both are
  confined to two named macOS-shell files by `scripts/check-downloader-boundary.sh`).
  The blocker is the engine, not the UI: the feature drives a bundled `yt-dlp` +
  `ffmpeg` pair through `ToolProcessRunning`, and iOS has no process spawning at
  all, so an iOS port needs a different conformer entirely rather than a view layer.
  The download History tab and parallel-download driver are part of this epic
  (downloads-v2, 2026-09-14) and are macOS-only with no iOS timeline.
- **Release hardening** — no snapshot/visual QA pass, no App Store submission
  review, no notarization pipeline. Visual fidelity and layout remain subject to
  change.

---

### Natural parity order

When macOS reaches sufficient maturity to justify the iOS effort, the natural
sequence is:

1. **Stats UI** — `ListeningStatsViewModel` is already in PlayerCore and fully
   wired; capture has been running since v15. A Stats screen is almost purely view
   work.
2. **Queue screen + Favourites surface** — both VMs (`QueueViewModel`,
   `FavouriteViewModel`) are shared; the gap is the view layer only.
3. **On-device chat (Auto Mixes → full assistant)** — the trigger absences
   documented in `AppEnvironment+AI.swift` are the only blockers; the toolbox,
   session, and VM are in PlayerCore. Requires `FoundationModels` availability on
   the target device.
4. **Profiles switcher** — one chained closure (`onActiveProfileChanged`) and a
   settings screen; `ProfileService` is already constructed.
5. **Karaoke** — blocked on a model-delivery decision (on-demand resource or user
   download); everything else is portable.

---

## Build & run

Requires Xcode's toolchain (for `@Observable`, `#Preview`, and Swift Testing):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
tuist install --force-resolved-versions
tuist generate --no-open
```

Then build for a simulator (substitute any installed iPhone/iPad simulator):

```sh
xcodebuild build \
  -workspace MacAMP.xcworkspace \
  -scheme macampiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO
```

> **Tip (faster sim builds):** target a concrete device by UDID with
> `ONLY_ACTIVE_ARCH=YES` — the generic `iOS Simulator` destination compiles
> `x86_64` + `arm64` (2× the C++ compile time).

---

## Related

- **Portable core logic:** [`PlayerCore/README.md`](../PlayerCore/README.md)
- **macOS UI reference:** [`macOS/README.md`](../macOS/README.md)
- **Project overview / build matrix:** [root `README.md`](../README.md)
- **Engineering contract & invariants:** [`.opencode/skills/macamp/SKILL.md`](../.opencode/skills/macamp/SKILL.md)
