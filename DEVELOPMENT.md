---
title: MacAMP — Developer Guide
description: Architecture, build, test, and contribution reference for the MacAMP music player.
---

# MacAMP — Developer Guide

MacAMP is a native, offline, on-device music player for **macOS 14+** and **iOS/iPadOS 17+**, built entirely in **Swift 6** with strict concurrency. The shared Swift package, `PlayerCore`, contains the audio engine, persistence, reusable services, view models, and design components. Two app shells (`macampMac`, `macampiOS`) compose it with platform views and integrations; the macOS shell also owns downloads, provider bridging, and local MCP hosting.

This is the engineering reference. For an overview of the project, see the [README](README.md); for the user guide, see [MacAMP User Guide](docs-site/content/docs/index.mdx).

## Documentation map

| Guide | What it covers |
|---|---|
| **[`PlayerCore/README.md`](PlayerCore/README.md)** | **Portable core-logic spec** — audio, DSP, persistence, playback coordination, metadata/artwork/lyrics/MIDI, and the shared `@Observable` view models. Written so the player can be reimplemented on another OS. |
| **[`macOS/README.md`](macOS/README.md)** | **Interface & visual spec** — design tokens, components, every screen, and the visual language of the (reference-quality) macOS shell. |
| **[`iOS/README.md`](iOS/README.md)** | 🚧 **Work in progress** — the iOS / iPadOS shell (functional, not release-hardened); includes the maintained feature-parity matrix vs macOS. |
| [`docs-site/`](docs-site/) | End-user guide and distribution documentation (Fumadocs static site). |

> **Surface status:** **macOS** and **PlayerCore** are the mature, documented surfaces. **iOS** is **work in progress** — it builds and runs, but has not had the macOS shell's QA / release-hardening pass.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        PlayerCore (Swift package)               │
│                                                                 │
│  Models  ──▶  Persistence  ──▶  Services  ──▶  ViewModels      │
│     │              │                │               │           │
│     └──▶  Metadata ──▶  Artwork     │               │           │
│     └──▶  Lyrics                    │               │           │
│     └──▶  MIDI                      │               │           │
│                                     │               │           │
│  Decoding ──▶  AudioEngine ──▶  DSP ┘               │           │
│                    │                                │           │
│               Visualizer ───────────────────────────┘           │
│                                                                 │
│  DesignSystem  (SwiftUI + CoreGraphics, no AppKit/UIKit)        │
└──────────────────────────┬──────────────────────────────────────┘
                           │
          ┌────────────────┴────────────────┐
          ▼                                 ▼
    macampMac                          macampiOS
  (macOS 14+)                         (iOS 17+)
  SwiftUI shell                       SwiftUI shell
  + AppKit glue                       + AVAudioSession
  + Sparkle auto-update               + background audio
  + projectM*                         + document-picker import
```

`*` projectM and AI subscription connectors are always compiled into `macampMac`.
The **`macampiOS`** shell is **🚧 work in progress** — see [`iOS/README.md`](iOS/README.md).

---

## Module Map

`PlayerCore` exposes 13 library products from `Package.swift`:

| Module | Responsibility |
|---|---|
| `Models` | Value types: `Track`, `Playlist`, `Album`, `Artist`, availability state machine (`present` / `missing` / `externalOffline`), `InstrumentalCacheLocation` (single source of truth for the karaoke cache directory), `CacheDirectoryOverlapPolicy` |
| `Separation` | Offline vocal-separation pipeline for karaoke mode: `StemSeparating` / `InstrumentalCaching` / `KaraokeRendering` protocols, `CoreMLSeparator` actor (Mel-Band Roformer via Core ML), `SeparationPipeline` (decode → resample 44.1 kHz → STFT → Core ML → iSTFT → ALAC/AAC → cache), `InstrumentalCache` actor (content-addressed LRU, 2 GB cap, user-relocatable directory), `InstrumentalCache+Removal` (per-entry removal, pin-guarded, emits change-seam once per batch), `STFTProcessor` (vDSP Hann FFT/iSTFT), `InstrumentalWriter` (atomic `.m4a` — 24-bit ALAC or 256 kbps AAC per the `InstrumentalRenderQuality` setting), `CanonicalSourcePath` (shared path canonicalization helper), `SeparationAvailability` / `SeparationError` typed contracts. **Never imports AppKit/UIKit.** |
| `Persistence` | GRDB 7.11.1 schema, append-only migrations (**v1–v20**), keyset-paginated repositories, `ValueObservation` queries, FTS5 full-text search, JSON/JSPF playlist IO. **Profiles (v12–v15):** per-profile library scoping (`LibraryVisibility`), profile / track-state / library-root repositories, `playlist.profileId`, optional custom avatar image path (`profile.avatarImagePath`, v13), one opaque playback snapshot per profile (`profilePlaybackState`, v14). **Listening stats (v15):** `playEvent` (denormalized, survivable, `utcOffsetSeconds`), `playEventRollup` (monthly compaction), `playSegmentHeat` (100-bucket replay heatmap), `folderTrackOrder` (per-profile, per-root drag order). **AI substrate (v16):** `trackAudioFeature` (cached tempo/energy/brightness with `analysisVersion` + `fileSize`/`mtime` fingerprint, cascading FK), `generatedPlaylist` (provenance for AI-generated playlists, `UNIQUE(playlistId)`, cascading), `smartPlaylist.rulesVersion`/`lastEvaluatedAt` (rule-schema versioning + evaluation timestamps, backfilled `DEFAULT 1`). Smart-playlist rules are stored in `smartPlaylist`; the shared `SmartPlaylistCompiler` and `SmartPlaylistEvaluator` implement query compilation and evaluation. **Downloads history (v17):** `downloadHistory` (append-only completed-download log: `id`, `canonicalVideoID`, `title`, `uploader`, `durationSeconds`, `filePath`, `audioFormat`, `audioQuality`, `sourceURL`, `downloadedAt`, `utcOffsetSeconds`; `DownloadHistoryRepository` exposes keyset-paged reads + advisory lookup for the paste-report hint). |
| `Metadata` | Tag reading + **atomic** writing via SFBAudioEngine/TagLib (`SFBMetadataReader` / `SFBMetadataWriter`: temp-copy → `replaceItemAt` → rollback, FSEvents self-write suppression), `GenreNormalizer` (ID3 codes) |
| `Artwork` | Async artwork cache, placeholder generation |
| `Lyrics` | Lyrics fetch, sync, and GRDB-backed storage |
| `MIDI` | MIDI device enumeration and event routing; `AVAudioUnitSampler` + GeneralUser GS SoundFont |
| `Decoding` | `DecoderProviding` protocol + SFBAudioEngine 0.12.1 codec bridge (FLAC, MP3, Ogg, Opus, WavPack, APE, …) |
| `AudioEngine` | `SFBAudioPlayer` wrapper, `AVAudioUnitEQ` insertion, `@Sendable` tap, gapless `enqueue` |
| `DSP` | vDSP FFT (4096 / Hann / hop 1024), ReplayGain, 10-band EQ, peak metering — all audio-thread-safe |
| `Visualizer` | `VisualizerBackend` protocol, `SpectrumProvider` SPSC ring buffer, Metal cross-platform renderer |
| `Services` | Library scanner/import pipeline, playback coordinator + queue, `NowPlayingService` + remote commands, `ReplayGainService`, `ProfileService` (per-profile session / PIN state machine + switch orchestration), `PlayEventRecorder` (off-main play-event capture with capture-time UTC offset and profile attribution), `PlaySegmentTracker` (1 Hz playhead sampler → 100-bucket replay heatmap upserts), `PlayEventCompactor` (24-month rolling compaction to `playEventRollup`), `ListeningDigestBuilder` (versioned deterministic JSON digest — top tracks/artists/genres, local-hour facets, replay heatmap clusters), `LyricsSweepService` (offline embedded + `.lrc` sweep into `lyricsCache`, zero network), `KaraokeRenderService` (on-demand serial render driver with pause/resume and queue management), **`DownloadQueueService`** (`Downloads/` — **concurrent** audio-download driver via bundled `yt-dlp` + `ffmpeg`, up to `downloadMaxConcurrent` simultaneous transfers (user-settable, default 3); `DownloadQueueing` protocol; `YouTubeURLNormalizer` (canonical video/playlist id extraction), `YtDlpCommandBuilder` / `YtDlpProgressParser` (argument tables + per-line progress parser including `ffprogress [<videoID>].txt` conversion-progress polling), `DownloadStagingSweeper` (stale-partial cleanup on launch), `ToolUpdateInstaller` / `ToolUpdatePlanner` (SHA-256-verified self-update with automatic rollback); `DownloadToolProviding` / `ToolProcessRunning` / `ToolReleaseFetching` seams with `Fake*` conformers in `PlayerCoreTestSupport`; download storage vocabulary `DownloadAudioFormat` / `DownloadAudioQuality` (frozen `String` raw values); **`YouTubeOEmbedClient`** (`OEmbedFetching` — paste-time title/thumbnail decoration via YouTube's oEmbed endpoint, ≤4-request concurrency gate); **`DownloadHistoryRecorder`** (append-only write of completed rows to GRDB `downloadHistory`, v17)), **`LibraryToolbox`** (ten library tools — `search_tracks`, `list_genres`, `get_tracks`, `get_track_features`, `get_listening_stats`, `list_playlists`, `get_playlist`, `sample_tracks`, `propose_playlist`, `match_tracks` — published at three tiers via `ToolProfile`: `.onDevice` 5 library / 600-char results, `.cloud` all 10 / 8 KB, `.external` all 10 / 16 KB; `ToolboxRendering` is the only place a track record becomes text and never reads `filePath`; `propose_playlist` carries its own 500-identifier ceiling (`ToolResultBudget.proposalIdentifierLimit`) and takes either an explicit `track_ids` membership **or** genre + `target_count` criteria the app materialises server-side — title-ordered, present-only, deterministic — while every other identifier argument keeps its separate, unchanged 100-id cap; four playback-control tools — `get_playback_state`, `play_tracks`, `queue_tracks`, `transport` — are registered separately via `LibraryToolboxContext.playback` when the grant is on: `.onDevice` adds 3 of 4 for a total of 8, `.cloud`/`.external` add all 4 for a total of 14; settings mutation is permanently off-limits at every tier. The `.cloud` chat tier additionally merges any tools the listener's own MCP servers publish — appended AFTER the library's own, `mcp__`-namespaced, so a frozen name can never be shadowed), **`LibraryChatSession`** (on-device `LanguageModelSession` actor: `AssistantChatEvent` vocabulary, 4096-token proactive + reactive condensation, five hand-written `Tool` wrappers with schema-parity drift guard), **`LibraryChatInstructions`** / **`LibraryChatTools`** / **`LibraryChatBudget`** |
| `ViewModels` | `@Observable` view models shared verbatim between macOS and iOS shells (player, library, search, queue, EQ, visualizer, lyrics, playlist + import/export, enrichment, folder & genre browsers) + the `SidebarDestination` navigation enum + shared `TagEditModel` (`TagEditing/` — patch/collapse logic for the tag editor) + `LyricsBrowserViewModel` (keyset-paged lyrics library) + `ScrubberHeatViewModel` (replay heatmap normalization for the scrubber overlay) + `KaraokeReadyStore` / `KaraokeReadyListViewModel` + `KaraokeQueueStore` / `KaraokeQueueViewModel` + `DownloadQueueStore` / `DownloadsViewModel` (in-memory download queue projection + download intents; `DownloadPasteInput` paste parser — URL normalization, dedup, playlist cap enforcement; `DownloadsViewModel+History` — advisory previously-downloaded count shown in the paste report, via `DownloadHistoryRepository`, never blocks or alters an enqueue) + `ListeningStatsViewModel` (four listening-window digest loader — 7 days / 30 days / 12 months / all time — for the Stats sidebar destination) + **`LibraryChatViewModel`** (`@MainActor @Observable`, two-closure `LibraryChatEngine` value type, tier-agnostic multi-turn transcript) |
| `DesignSystem` | Shared SwiftUI components, album-art theming (SwiftUI + CoreGraphics/ImageIO/CryptoKit only); includes `GenreFilterBarView` (shared genre chip bar), `ActiveTick`/`TickPolicy` (playback-gated UI timer), and `SpectrumColors` neon tokens |

`PlayerCoreTestSupport` (also a library product) ships `OfflineRenderHarness`, signal generators, and `Fake*` protocol implementations for hermetic unit tests.

### AIConnectorKit (separate Swift package — `AIConnectorKit/Package.swift`)

A three-product package that adds opt-in AI provider connectors to the assistant surface. It depends on `PlayerCore` (for `Services`, `ViewModels`) but **PlayerCore never imports AIConnectorKit** — the dependency is one-directional.

| Product | Linked into | Responsibility |
|---|---|---|
| `AIConnectorKit` | `macampMac` | Core contracts: `AIProviderConnector`, `SecretStore` / `KeychainSecretStore`, `HTTPTransport` / `URLSessionTransport`, `JSONSchemaObject`, `ConnectorFailure`, `withDeadline`; **tool-calling loop** (`AITool`, `ToolLoopEngine` — up to 20 rounds, 60 s/round deadline, 16 KB result cap — `ToolLoopRequest`/`ToolLoopOutcome`/`ChatEvent`); all five `ToolCallingConnector` conformers (`AnthropicConnector`, `OpenAIConnector`, `OllamaConnector`, `ChatGPTConnector`, `ClaudeSubscriptionConnector`); **`WebSearchTool`** — the one built-in tool this kit publishes (bare wire name `web_search`, never `mcp__`-namespaced), a bounded Tavily lookup that is **keyless by default** and merely upgraded when a key is stored, with a per-status error taxonomy plus a load-bearing catch-all, flattened untrusted result text, and zero logging of queries, titles or keys; **`YouTubeLinkResolver`** — turns "title + artist" into a *verified* `watch?v=` link through one exported strict URL validator (`validatedWatchURL(_:)`) and an oEmbed JSON confirmation, never `youtube.com/watch` HTML. Two ways in, ONE gate: `resolve(_:)` finds its own candidate through the search provider, and `verify(_:proposedIDs:)` takes candidate ids a caller already has — the shell asks the answering model for them (see `ModelVideoLinkProposer`), which costs nothing against the search provider's daily cap. Both paths then pass the identical shape → oEmbed-existence → title-overlap gate, so a wrong id resolves to `nil` and the caller falls back rather than rendering it |
| `AIConnectorBridge` | `macampMac` | Seam conformers that connect `AIConnectorKit` to `PlayerCore`: `AIConnectorSettingsProviding`, `PlaylistQuerySchema` (canonical JSON schema), `ConnectorPromptBuilder` / `ConnectorPayloadBudget` (payload-budget enforcement); **chat bridge** (`LibraryToolAdapter` turns `LibraryToolbox` into `[AITool]`, `ConnectorChatEngine` composes the loop for multi-turn conversations, `ConnectorChatTurn` maps events onto the shared `AssistantChatEvent` vocabulary) |
| `AIConnectorKitOAuth` | `macampMac` | OAuth 2.0 engines and subscription connectors (Claude subscription, ChatGPT subscription). Excluded from `macampiOS` at link time — never via a compile flag. **Wire-level backend contracts are documented in the source:** `ChatGPTBackendContract.swift` records four requirements measured against the live backend — three on 2026-09-06 and one on 2026-09-09. (1) `GET /models` requires a pinned `client_version` query parameter (`"1.0.0"`; an old-but-valid value returns HTTP 200 with an empty catalog, which is the silent failure trap). (2) `POST /responses` requires `stream: true` (the endpoint no longer accepts non-streaming requests). (3) `POST /responses` **rejects `max_output_tokens`** outright — HTTP 400 `{"detail":"Unsupported parameter: max_output_tokens"}` on every model, so the field is absent from all three request bodies and the backend's own ceiling applies; the terminal-`response.incomplete` truncation *detection* is independent and stays. (4) The terminal `response.completed` now arrives with `"output": []` and the finished items are delivered only as `response.output_item.done` events, so `completedResponse(in:)` assembles the output from those events when the terminal object is empty — a populated terminal still wins, so a flip back costs nothing. A plain-JSON body is returned untouched for the same backend-flip tolerance. Two Anthropic contracts sit in `AIConnectorKit`: `AnthropicSystemPrompt` records that the Claude OAuth edge needs the identity line as a **discrete first system block** (a concatenated plain string is refused with a disguised HTTP 429 `rate_limit_error` that omits the `anthropic-ratelimit-unified-*` headers a real rate-limit carries), and `ToolWireEncoding.anthropicSchema(_:)` strips `maxItems`/`minItems` from every `array`-typed node because `/v1/messages` refuses them — `tools.N.custom: For 'array' type, property 'maxItems' is not supported` (measured 2026-09-09; the library tools carry those bounds, so every chat turn 400'd until it was stripped). All of these constants are **UNOFFICIAL** and injected rather than hardcoded so a future measurement can replace them. |

`AIConnectorBridge` is the **only** product allowed to import `PlayerCore` symbols; `AIConnectorKit` and `AIConnectorKitOAuth` are Foundation/Security/CryptoKit-only. All three products are linked into `macampMac`. The iOS exclusion is verified by `scripts/check-ios-oauth-linkage.sh` (run in the `portability-guard` CI job). See [`Spikes/ADR-ai-provider-connectors.md`](Spikes/ADR-ai-provider-connectors.md) for the full rationale, payload budget, and consent-model spec.

### MCP Swift SDK (`modelcontextprotocol/swift-sdk 0.12.1`)

The macOS shell links the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) (exact pin `0.12.1`) to power the in-process MCP server (`macOS/Sources/MCP/`). This is the **only** new third-party dependency added by the library-chat epic, and it was taken deliberately rather than out of convenience.

MCP is a **wire format with a versioned specification** — JSON-RPC framing, capability negotiation, protocol-version negotiation across four dated revisions. Hand-rolling it would create a permanent obligation to re-implement a moving spec correctly against every client never tested against, where "wrong" is silent. The official Swift SDK is written by the protocol's own authors and is the artifact the spec is validated against.

**Cost measured, not assumed.** The `MCP` library target links only `swift-system`, `swift-log`, and `eventsource`. `swift-nio`, `swift-atomics`, and `swift-collections` appear in `Tuist/Package.resolved` because SwiftPM resolves the whole manifest, but they belong to the SDK's conformance executables and are never linked here — `otool -L` on the built app finds zero NIO images. The SDK is wired to `macampMac` only; `iOS/Project.swift` is untouched.

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Xcode | 16+ (Xcode 26 used in CI) | Mac App Store / [developer.apple.com](https://developer.apple.com/xcode/) |
| Tuist | latest stable | `brew install tuist` |
| Mint | latest stable | `brew install mint` |
| SwiftLint | 0.64.0 (pinned) | via Mint (`mint bootstrap`) |
| SwiftFormat | 0.61.1 (pinned) | via Mint (`mint bootstrap`) |

**`DEVELOPER_DIR` is required for tests.** `swift test` needs Xcode's platform frameworks (`Testing.framework` ships only in Xcode, not Command Line Tools):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Set `DEVELOPER_DIR` for **all** `swift build` / `swift test` invocations: the `@Observable` view models, `#Preview` macros, and Swift Testing (`Testing.framework`) require Xcode's toolchain — bare Command Line Tools cannot expand those macros or link the test framework. Switching `DEVELOPER_DIR` forces a full `.build` rebuild.

---

## Build and Run

### 1. Generate the Xcode workspace

```sh
tuist install --force-resolved-versions   # resolve + fetch dependencies
tuist generate --no-open                  # write MacAMP.xcworkspace
```

This produces `MacAMP.xcworkspace` at the repo root. Open it in Xcode or drive it with `xcodebuild`.

### 2. Schemes

| Scheme | Target | Notes |
|---|---|---|
| `macampMac` | macOS app + projectM library + AI subscription connectors | Includes `libprojectM-4.4.dylib` (LGPL, dynamically linked) and all OAuth connectors |
| `macampiOS` | iOS/iPadOS app | 🚧 WIP — requires a simulator or device |

### 3. Build (macOS, headless / CI)

```sh
xcodebuild build \
  -workspace MacAMP.xcworkspace \
  -scheme macampMac \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
```

### 4. Build (iOS Simulator)

```sh
xcodebuild build \
  -workspace MacAMP.xcworkspace \
  -scheme macampiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO
```

### 5. Build PlayerCore package only (no workspace needed)

```sh
swift build -c release
```

---

## Test

### PlayerCore package tests (SwiftPM)

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --no-parallel
```

The package suites include `ArtworkTests`, `AudioEngineTests`, `AvailabilityTests`, `CoordinatorTests`, `DecodingTests`, `DesignSystemTests`, `DSPTests`, `EnrichmentTests`, `EQPresetTests`, `HarnessTests`, `LibraryTests`, `LibraryWatchTests`, `LyricsTests`, `MetadataTests`, `MIDITests`, `NowPlayingTests`, `PersistenceTests`, `PlaylistIOTests`, `ReplayGainTests`, `ScannerTests`, `SeparationTests`, `StatsTests`, `ViewModelTests`, and `VisualizerTests`.

> **Test isolation:** Allocation tests use process-global counters, and several async tests depend on scheduling. Both CI pipelines run the complete core suite with `--no-parallel`. Parallel runs remain useful for diagnosing isolation problems, but their failures must be investigated; they are not waived or retried automatically.

Audio engine suites use `@Suite(.serialized)` to avoid port/device collisions.

### macOS app tests (Tuist workspace)

```sh
xcodebuild test \
  -workspace MacAMP.xcworkspace \
  -scheme macampMac \
  -destination 'platform=macOS,arch=arm64'
```

### List tests without running

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --list-tests
```

---

## Lint and Format

Tools are pinned in `Mintfile` (SwiftLint 0.64.0, SwiftFormat 0.61.1). Bootstrap once:

```sh
mint bootstrap
```

Then:

```sh
# Check formatting (lint mode — no writes)
mint run swiftformat . --lint

# Check style (strict — warnings are errors)
mint run swiftlint lint --strict

# Auto-format (only your own files — never run on the whole tree if other agents are active)
mint run swiftformat path/to/your/file.swift
```

---

## CI

`.github/workflows/ci.yml` runs twelve jobs on every push and pull request:

| Job | What it does |
|---|---|
| `lint` | SwiftFormat (lint mode) + SwiftLint (strict) via Mint |
| `test-package` | `swift build -c release` + `swift test --no-parallel` on the PlayerCore package |
| `test-app` | `tuist install` + `tuist generate --no-open` + `xcodebuild test -scheme macampMac -skip-testing:macampMacUITests` |
| `uitest-smoke` | XCUITest smoke run for `macampMacUITests` — **non-required** (does not block merges or releases) |
| `build-ios` | Generates the workspace, runs `xcodebuild test -scheme macampiOS` on an available iPhone simulator, and validates the compiled iOS strings |
| `portability-guard` | `scripts/check-playercore-portability.sh` + `scripts/check-ios-oauth-linkage.sh` — hard failures if `PlayerCore` imports `AppKit`/`UIKit` or if iOS links an OAuth product |
| `ios-portability` | Builds `PlayerCore-Package` scheme for `generic/platform=iOS Simulator` to catch macOS-only API drift |
| `fm-compile-check` | Asserts `FoundationModels` is present in the CI SDK — prevents the assistant layer from being silently preprocessed away |
| `frozen-column-guard` | `scripts/check-frozen-track-columns.sh` — hard failure if code reads or writes the four frozen `track` columns (v12 freeze) |
| `no-hardcoded-text` | `scripts/check-hardcoded-strings.sh` — hard failure if user-visible copy bypasses String Catalogs |
| `ai-network-boundary` | `scripts/check-ai-network-boundary.sh` — hard failure if the AI surface touches `URLSession` outside `AIConnectorKit`; also scans `Toolbox/` and `MCP/`, and separately forbids outbound `NWConnection` construction in `MCP/` (the MCP server may use `NWListener`-accepted connections but must never initiate one) |
| `docs` | `npm ci` + `npm run build` for the Fumadocs static site (`docs-site/`) — **non-blocking**: not in the `release` job's `needs:` list, so a docs build failure never blocks a release |

On a `v*` tag (after the ten release-gating base jobs pass — `uitest-smoke` and `docs` are excluded by design), a thirteenth **`release`** job first fetches and converts the karaoke separation model (this step must precede `tuist generate` — the resource glob is evaluated at generate time), then builds `macampMac` in Release (`ARCHS=arm64 ONLY_ACTIVE_ARCH=NO` is required because the vendored `libprojectM-4.4.dylib` is arm64-only), **ad-hoc signs** it, packages a `.dmg`, asserts the bundle contains both `MelBandRoformer.mlmodelc` and `libprojectM-4.4.dylib`, and publishes a GitHub Release carrying the `.dmg` + the `Package.resolved` dependency snapshot. [`.gitlab-ci.yml`](.gitlab-ci.yml) mirrors these jobs as a first-class equal pipeline (macOS runners, the same tag-gated `release` with `artifacts:` + `release:`).

Concurrent runs on the same ref are cancelled automatically. A commented-out `notarize` job at the bottom of `ci.yml` shows the Developer-ID signing pipeline; it's gated to tag pushes and requires repository secrets (`APPLE_ID`, `NOTARIZATION_TEAM_ID`, `NOTARIZATION_APP_PASSWORD`, `DEVELOPER_ID_APPLICATION`).

---

## Audio Architecture

**Decision: Option A** (see [`Spikes/ADR-audio-engine.md`](Spikes/ADR-audio-engine.md)).

`SFBAudioPlayer` owns the `AVAudioEngine`. The pipeline:

```
SFBAudioPlayer (owns AVAudioEngine)
  decoder (FLAC/MP3/… via SFBAudioEngine 0.12.1)
    ──▶ sourceNode (AVAudioSourceNode)
    ──▶ AVAudioUnitEQ (10 bands, globalGain = ReplayGain)
          │  installTap(bus 0, 1024 frames)  ← PRE-pan, post-EQ
          ▼
          @Sendable tap: memcpy ch0 → SPSC ring buffer
          (zero alloc / lock / ARC / log on the audio thread)
          │  pull — no per-frame main.async
          ▼
          vDSP real FFT 4096 / Hann / hop 1024 → log bands
          │
          ▼
          Metal spectrum renderer (~60 fps, instant-attack / 0.85 release)
    ──▶ panNode (AVAudioMixerNode, pan = balance)
    ──▶ mainMixerNode
    ──▶ outputNode ──▶ 🔊
```

Key points:

- **Gapless** playback is free via `SFBAudioPlayer.enqueue(_:)`.
- **EQ** is inserted once via `modifyProcessingGraph`; the `audioPlayer(_:reconfigureProcessingGraph:with:)` delegate re-establishes `EQ → panNode → mainMixer` and re-installs the tap on any sample-rate or channel change.
- **Balance** is applied through a dedicated `panNode` (`AVAudioMixerNode`) inserted between the EQ and `mainMixerNode`. Setting `pan` on `mainMixerNode` itself is silently inert (it feeds the output node, not a mixer). The tap lives on the EQ output, pre-pan, so balance never affects the visualizer.
- **Tap buffer size** is 1024 frames (`SFBPlaybackEngine.tapBufferSize`). The FFT still reads 4096 samples from the 16384-sample ring — tap size and FFT size are independent and must stay that way.
- **Visualizer ballistics** — `SpectrumBallistics` applies instant-attack / exponential-release (factor 0.85 per 1/60 s) in the consumer layer. Each on-screen consumer owns a private instance.
- **ReplayGain** is applied through `eq.globalGain` (clamped to −96…+24 dB). Anti-clip mode uses `REPLAYGAIN_TRACK_PEAK`.
- **Native crossfade is deferred.** `SFBAudioPlayer` is a single-stream player. A future Option-C spike (own `AVAudioEngine` + two `AVAudioSourceNode`s) would be required.
- **Option B was infeasible** on the pinned SFBAudioEngine 0.12.1 (`SFBAudioPlayerNode` does not exist in that version).
- **Karaoke mode uses offline pre-render, not real-time inference.** Mel-Band Roformer is non-causal and requires an 8-second look-ahead window; Core ML inference also allocates and takes tens to hundreds of milliseconds per chunk — both are incompatible with the render-thread invariants above. The `SeparationPipeline` runs entirely off the audio thread at `Task.detached(priority: .utility)`, producing a cached instrumental (24-bit ALAC or 256 kbps AAC, per the Karaoke quality setting). Rendering is **on demand** — a track is separated only when the user asks for it (the player-bar mic button or a track-list "Create Karaoke Version" action), not auto-prewarmed. The coordinator resolves the decoder URL to the cached file at playback time, below the `Track` model — artwork, ReplayGain, Now Playing, and gapless all keep the original track identity. See [`Spikes/ADR-karaoke-separation.md`](Spikes/ADR-karaoke-separation.md) for the full rationale and channel policy.

---

## Visualizer

The visualizer backend is protocol-driven (`VisualizerBackend`), so multiple renderers can coexist:

| Backend | Platforms | Notes |
|---|---|---|
| Metal spectrum | macOS + iOS (default) | Cross-platform; always available |
| projectM (MilkDrop) | macOS only | Always compiled into `macampMac` (`MACAMP_PROJECTM` is always defined); never in `PlayerCore` |

The `SpectrumProvider` ring buffer is the only data path from the audio thread to the visualizer. Consumers pull on a `CADisplayLink` cadence. The audio producer never calls `DispatchQueue.main.async` from the render callback.

---

## Performance Contract

| Metric | Target |
|---|---|
| Library scale | 100k tracks / 50k-entry playlist |
| FTS5 full-text search | < 50 ms (cold, 100k tracks) |
| Scroll frame rate | 60 fps, hitch-ratio below Instruments threshold |
| Idle CPU (audio paused, no visualizer) | ≈ 0% |
| Visualizer-hidden GPU | ≈ 0% (Metal layer paused) |
| Audio-thread allocations | Zero |
| 100k batch import peak memory | Bounded (windowed inserts, no full-array load) |

See `.opencode/skills/macamp/references/performance-budget.md` for measurement methodology and Instruments workflows.

---

## Audio-Thread Invariants

**Zero allocation. Zero locks. Zero ARC. Zero `os_log`. Zero ObjC/Swift collections** on the render callback or tap closure.

The render callback runs on a real-time thread. Any of the following causes glitches or priority inversion:

- `malloc` / `free` (including `Array`, `Dictionary`, `String` construction)
- `os_log` / `print` / `NSLog`
- `DispatchSemaphore.wait` / `NSLock.lock` (blocking)
- ObjC message sends that may allocate
- Swift `class` retain/release cycles

Pre-allocate all buffers before the engine starts. Use `UnsafeMutablePointer` or `AVAudioPCMBuffer` pools. The tap closure must be `@Sendable` (non-isolated) and touch only `Sendable`, pre-allocated state. Swift 6's runtime enforces this: a tap created inside a `@MainActor` type that is invoked on the render thread will `SIGTRAP`.

Full invariants, lock-free primitive recipes, and pre-allocation patterns: [`.opencode/skills/macamp/SKILL.md`](.opencode/skills/macamp/SKILL.md).

---

## Distribution

**One command produces a shippable release:**

```sh
./scripts/release.sh --version 1.2.3            # ad-hoc, no Apple account needed
./scripts/release.sh --version 1.2.3 --identity "Developer ID Application: …"
./scripts/release.sh --version 0.0.0-test --dry-run   # plan only; no secrets, no network
```

`scripts/release.sh` is a pure orchestrator over eight stages — `PREFLIGHT → MODEL → BUILD → SIGN → DMG → NOTARIZE → APPCAST → VERIFY` — each delegating to a standalone script (`tools/separation/fetch-and-convert-model.sh`, `build-macamp.sh`, `codesign-app.sh`, `package-dmg.sh`, `notarize.sh`, `setup-sparkle-key.sh`, `make-appcast.sh`). Full runbook: [`docs-site/content/docs/distribution.mdx`](docs-site/content/docs/distribution.mdx).

**Direct (macOS, `.dmg` + Sparkle):** the shipped macOS app carries a wired `SPUStandardUpdaterController` — a live **Check for Updates…** button and a stable/beta channel picker in **Preferences ▸ Updates**, with automatic background checks opted in via `SUEnableAutomaticChecks`. Updates are EdDSA-signed; the private key is created once by `scripts/setup-sparkle-key.sh` and never leaves the login Keychain. `dist/releases/` retains every shipped `.dmg`, which is what lets Sparkle's `generate_appcast` emit **binary delta** updates.

MacAMP distributes its macOS app directly. The `.dmg` ships the full `macampMac` binary, the projectM library (LGPL, dynamically linked), all AI subscription connectors, and the karaoke separation model.

**CI release:** the GitHub and GitLab tag jobs validate the bundle identifier and Sparkle feed in the built app before signing. Set the production values in `macOS/Project.swift` to enable release packaging. The CI path uses ad-hoc signing. Use the local Developer ID and notarization workflow for public distribution.

---

## Acknowledgments and Licensing

MacAMP is built on open-source software including SFBAudioEngine (MIT), GRDB.swift (MIT), Sparkle (MIT), and a set of LGPL audio codecs (mpg123, libsndfile, LAME, True Audio) shipped as dynamically-linked XCFrameworks to satisfy the LGPL relink requirement.

The projectM / MilkDrop visualizer (LGPL 2.1) ships in the `macampMac` build (dynamically linked, never in `PlayerCore`).

The crossfeed kernel test fixtures (`tools/fixtures/bs2b/`) vendor **libbs2b 3.1.0** C source (MIT, © 2005 Boris Mikhaylov) to generate ground-truth impulse responses. The vendored C source is used at build/test time only and is not shipped in the app.

Full attribution, license texts, and redistribution notes: [`docs-site/content/docs/acknowledgments.mdx`](docs-site/content/docs/acknowledgments.mdx).

---

## Key Files at a Glance

```
Package.swift                        PlayerCore modules + test targets
macOS/Project.swift                  macampMac Tuist target (single macOS target; includes projectM + AI connectors)
iOS/Project.swift                    macampiOS Tuist target
Workspace.swift                      Tuist workspace root
Spikes/ADR-audio-engine.md           Audio engine decision record (Option A)
.opencode/skills/macamp/SKILL.md     Engineering contract + invariants (read this)
.github/workflows/ci.yml             CI pipeline
scripts/release.sh                        One-command release orchestrator
scripts/build-macamp.sh                   Model + generate + build; installed-app cleanup is opt-in
scripts/setup-sparkle-key.sh              One-time Sparkle EdDSA key setup
scripts/check-playercore-portability.sh   AppKit/UIKit import guard
scripts/check-hardcoded-strings.sh        Localization guard
tools/separation/fetch-and-convert-model.sh  Karaoke model fetch + Core ML convert
docs-site/content/docs/distribution.mdx     Release / notarization runbook
docs-site/content/docs/acknowledgments.mdx  Open-source acknowledgments
```

---

## Related

- **Engineering contract and invariants:** [`.opencode/skills/macamp/SKILL.md`](.opencode/skills/macamp/SKILL.md)
- **Audio ADR:** [`Spikes/ADR-audio-engine.md`](Spikes/ADR-audio-engine.md)
- **End-user guide:** [`docs-site/`](docs-site/)
