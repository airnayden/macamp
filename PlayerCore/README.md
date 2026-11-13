---
title: PlayerCore — Portable Core-Logic Specification
description: An OS-agnostic specification of MacAMP's shared engine, data model, and coordination logic — enough to reimplement the player on another platform.
---

# PlayerCore — Portable Core-Logic Specification

`PlayerCore` contains MacAMP’s shared audio, decoding, DSP, persistence,
metadata, artwork, lyrics, MIDI, playback coordination, and the `@Observable`
presentation layer. The macOS and iOS shells add platform views, composition,
permissions, and integrations. Downloads, provider bridging, and MCP hosting
currently live in the macOS shell; they require their own portability work.

This document is written as a **reimplementation reference**: it captures the
*contracts, algorithms, data structures, constants, and control flow* precisely
enough to rebuild the same player on another OS (Android/Kotlin, Windows/C++, a
web stack). Every section links to the Swift source it describes; read the source
for the last mile.

> **Portability contract (CI-enforced):** `PlayerCore` **never** imports `AppKit`
> or `UIKit` ([`scripts/check-playercore-portability.sh`](../scripts/check-playercore-portability.sh)).
> It uses only `Foundation`, `Accelerate` (vDSP), `AVFAudio`/`AudioToolbox`,
> `Darwin`, `MediaPlayer`, `CryptoKit`, `CoreML` (the `Separation` module),
> `ImageIO`/`CoreGraphics`, and
> `Metal`/`MetalKit` (the latter guarded by `#if canImport(MetalKit)`). Anything
> platform-specific lives in the shells. When porting, these are the seams you
> re-implement against your platform's equivalents.

- **Language / mode:** Swift 6, complete strict concurrency ([`Package.swift`](../Package.swift)).
- **Platforms:** macOS 14+, iOS 17+.
- **External deps (pinned exact):** GRDB.swift `7.11.1` (SQLite), SFBAudioEngine `0.12.1` (decoders + TagLib).

---

## Table of contents

1. [Design principles & invariants](#1-design-principles--invariants)
2. [Module map](#2-module-map)
3. [Domain model (`Models`)](#3-domain-model-models)
4. [Audio pipeline (`AudioEngine` + `Decoding`)](#4-audio-pipeline-audioengine--decoding)
5. [DSP & spectrum (`DSP`)](#5-dsp--spectrum-dsp)
6. [Visualizer (`Visualizer`)](#6-visualizer-visualizer)
7. [Vocal separation (`Separation`)](#7-vocal-separation-separation)
8. [Persistence & data model (`Persistence`)](#8-persistence--data-model-persistence)
9. [Playback coordination (`Services`)](#9-playback-coordination-services)
10. [Metadata, Artwork, Lyrics, MIDI](#10-metadata-artwork-lyrics-midi)
11. [Presentation layer (`ViewModels`)](#11-presentation-layer-viewmodels)
12. [Design system logic (`DesignSystem`)](#12-design-system-logic-designsystem)
13. [Testing & DI (`PlayerCoreTestSupport`)](#13-testing--di-playercoretestsupport)
14. [Reimplementation checklist](#14-reimplementation-checklist)

---

## 1. Design principles & invariants

These are the load-bearing rules. Break them and you get glitches, memory
blow-ups, or data loss. Preserve them in any port.

| Invariant | What it means |
|---|---|
| **Protocol-driven DI** | Every service/repository is a `protocol` with a shipped `Fake*` in [`PlayerCoreTestSupport`](TestSupport/PlayerCoreTestSupport). No concrete type is injected directly. Hermetic tests, swappable backends. Exception: `TrackRepository`'s ProfileState reads (favourites, counters, per-profile resolution) are concrete-extension APIs by long-standing precedent — view models may hold the concrete `TrackRepository` for those reads; every other service/repository seam stays protocol-routed with a Fake. |
| **Audio-thread safety** | The render/tap callback runs on a real-time thread: **zero allocation, zero locks, zero ARC, zero logging, zero ObjC/Swift collections**. Pre-allocate everything. The tap closure is `@Sendable` (non-isolated) and touches only pre-allocated, `Sendable` state. |
| **Pull-don't-push** | The audio thread never calls `DispatchQueue.main.async` or posts to a queue. Visualizer consumers **pull** the latest spectrum from a bounded metering ring on their own display cadence. |
| **Bounded memory** | Never load the whole library or a full playlist. All list reads are **keyset-paginated**; all `ValueObservation`s are `LIMIT`-capped. A 100k-track library stays within a bounded footprint. |
| **Append-only migrations** | Schema migrations are string-literal-named (`"v1"`…`"v20"`) and **never edited** once shipped. |
| **Three-state availability** | Tracks are `present` / `missing` / `externalOffline`. When media vanishes, the row **stays** with a new state — **never deleted**. The user decides removal. |
| **ReplayGain via EQ global gain** | Loudness normalization is applied through the EQ unit's `globalGain` (clamped `−96…+24 dB`), computed on track change, never on the render thread. |
| **Stats survivability** | Play events and segment heatmaps denormalize artist/title/album/genre at capture. The digest **never** joins live `track`/`playlist` rows. No `filePath` or instrumental path appears in events, rollups, heatmaps, or archive payloads. |
| **Segment capture on main actor** | Playhead sampling is main-actor 1 Hz, playback-gated. It never touches the audio render thread. |

Deep-dive annexes live in
[`.opencode/skills/macamp/references/`](../.opencode/skills/macamp/references):
`audio-thread-safety.md`, `spectrum-architecture.md`, `grdb-patterns.md`,
`performance-budget.md`.

---

## 2. Module map

14 library products, layered by dependency ([`Package.swift`](../Package.swift)):

```
Models  ─ the value-type foundation (no deps)
  ├─ Decoding      (+ SFBAudioEngine)      decode any codec → PCM
  ├─ DSP                                    FFT, SPSC ring, spectrum
  ├─ Metadata      (+ SFBAudioEngine)       tag read / atomic write, sort keys
  │    └─ Artwork                            content-addressed art cache
  ├─ AudioEngine   (Models+Decoding+DSP)    playback engine, EQ, tap
  │    └─ MIDI                               sampler + sequencer + bounce
  ├─ Visualizer    (Models+DSP)             backends + power control
  ├─ Separation    (Models+Decoding)        offline vocal separation (karaoke)
  ├─ Persistence   (+ GRDB)                 SQLite schema, repos, playlist IO
  │    └─ Lyrics   (+ Metadata+GRDB)        lyric sources + cache
  ├─ Services      (Persistence+Metadata+AudioEngine+Lyrics+Separation)
  │                                          coordinator, queue, scanner,
  │                                          now-playing, replay-gain, enrichment,
  │                                          profiles, stats, lyrics sweep,
  │                                          KaraokeRenderService,
  │                                          LibraryToolbox (ten library tools, three tiers),
  │                                          LibraryChatSession (on-device FM chat)
  ├─ DesignSystem                            tokens + album theming (SwiftUI),
  │                                          GenreFilterBarView, ActiveTick/TickPolicy,
  │                                          SpectrumColors
  └─ ViewModels    (Services+Persistence+AudioEngine+Visualizer+Lyrics+Artwork+DesignSystem+Separation)
                                             13 @Observable view models + TagEditModel
                                             + KaraokeButtonState + KaraokeReadyStore
                                             + KaraokeReadyListViewModel
                                             + LibraryChatViewModel (multi-turn chat)
```

Plus [`PlayerCoreTestSupport`](TestSupport/PlayerCoreTestSupport) (fakes + render
harness, including `FakeStemSeparator`, `FakeInstrumentalCache`,
`FakeKaraokeRenderer`, `FakeLibraryToolbox`) and a `macamp-cli` executable
([`Sources/macamp-cli`](../Sources/macamp-cli)) for headless decode/metadata/DB
smoke tests.

---

## 3. Domain model (`Models`)

Pure value types — `Codable`, `Sendable`, `Equatable`, `Hashable`. These persist
as GRDB records (see [§7](#7-persistence--data-model-persistence)); their fields
are the canonical shape.

### Track ([`Records/TrackRecord.swift`](Sources/Persistence/Records/TrackRecord.swift))

Identity + file: `id: Int64?`, `filePath: String` (UNIQUE), `mtime`, `fileSize`,
`dateAdded`, `availability`.
Tags: `title`, `sortTitle`, `artistName`, `albumTitle`, `albumArtist`, `composer`,
`genre`, `year`, `trackNumber`, `discNumber`.
Graph FKs: `artistId`, `albumId`.
Stream: `duration`, `bitrate`, `sampleRate`, `bitDepth`, `channelCount`.
Loudness: `replaygainTrackGain/Peak`, `replaygainAlbumGain/Peak`.
User state: `playCount`, `listenedCount`, `isFavourite`, `customPosition`.

`artistName`/`albumTitle` are **denormalised** copies of the `artist`/`album`
tables so the FTS5 search index can be backed by `track` alone.

### Album / Artist / Playlist

- **Album** ([`AlbumRecord.swift`](Sources/Persistence/Records/AlbumRecord.swift)): `id`, `title`, `sortTitle`, `artistId`, `year`, `mbid`.
- **Artist** ([`ArtistRecord.swift`](Sources/Persistence/Records/ArtistRecord.swift)): `id`, `name`, `sortName` (required), `mbid`.
- **Playlist** ([`PlaylistRecord.swift`](Sources/Persistence/Records/PlaylistRecord.swift)): `id`, `name`, `isSmartPlaylist`.

### Availability state machine ([`Records/Availability.swift`](Sources/Persistence/Records/Availability.swift))

```
enum Availability { case present, missing, externalOffline }
```

| From | Trigger | To |
|---|---|---|
| `present` | file gone from disk | `missing` |
| `present` | external volume unmounts | `externalOffline` |
| `missing` / `externalOffline` | file reachable again | `present` |
| `externalOffline` | volume deleted/reformatted | `missing` |

Transitions are computed by the [`AvailabilityReconciler`](Sources/Persistence/Availability/AvailabilityReconciler.swift)
(§7). **Rows are never deleted** — only the `availability` column is rewritten.

### App-Group boundary types

- **`AppGroup`** ([`Models/NowPlayingSnapshot.swift`](Sources/Models/NowPlayingSnapshot.swift)) — the shared App-Group identifier. **Load-bearing:** the iOS shell's `AppSettings` is backed by `UserDefaults(suiteName: AppGroup.identifier)`, so this enum is on the live path even though nothing publishes a snapshot today.
- **`NowPlayingSnapshot`** (same file) — tiny, Codable: `title`, `artist?`, `album?`, `artworkRef?`, `duration`, `elapsed`, `isPlaying`. Published through the injectable `SnapshotWriting` seam (`UserDefaultsSnapshotWriter` / `FileSnapshotWriter`). A snapshot carries display text and small references only — never a `DatabasePool`, a `TrackRecord`, or file bytes — so any App-Group reader stays entirely off the live database.

> **Status: the publish seam is DORMANT.** Both app shells construct
> `NowPlayingService` with `snapshotWriter: nil`, so nothing is written at runtime.
> The types stay as a ready-made publish path (and remain covered by
> `NowPlayingTests`) for a future App-Group reader. `AppGroup.identifier` itself is
> **not** dormant — see above.

---

## 4. Audio pipeline (`AudioEngine` + `Decoding`)

**Architecture — ADR Option A** ([`Spikes/ADR-audio-engine.md`](../Spikes/ADR-audio-engine.md)):
`SFBAudioPlayer` owns the `AVAudioEngine`. A 10-band EQ sits between the source
node and the main mixer; a **post-EQ** tap feeds the spectrum ring.

```
decoder ─▶ sourceNode ─▶ AVAudioUnitEQ (10 bands, globalGain = ReplayGain)
                               │
                        installTap(bus 0, 1024 frames)  ← PRE-pan, post-EQ
                               │  @Sendable: memcpy ch0 → SPSC ring
                               ▼
                        SpectrumProvider (pulled by visualizer)
                               │
                        ─▶ panNode (AVAudioMixerNode, pan = balance)
                        ─▶ mainMixerNode ─▶ outputNode ─▶ 🔊
```

### PlaybackEngine protocol ([`AudioEngine/PlaybackEngine.swift`](Sources/AudioEngine/PlaybackEngine.swift))

The whole transport contract (`@MainActor`, class-bound):

- **State:** `state: PlaybackState` (`idle`/`stopped`/`playing`/`paused`), `currentTime`, `duration`, `stateDidChange: ((PlaybackState)->Void)?`.
- **Transport:** `load(_ url:) throws`, `enqueue(_ url:) throws`, `play()`, `pause()`, `stop()`, `seek(to:)`.
- **EQ/gain:** `setBandGain(_ index:, dB:)`, `setGlobalGain(_ dB:)`.
- **Volume/balance:** `volume: Float` + `setVolume(_:)`, `balance: Float` + `setBalance(_:)`.
- **Gapless callbacks:** `onEndOfAudio: (()->Void)?` (stream finished → auto-advance), `onRenderingComplete: (()->Void)?` (successor rendering completes → pre-schedule the next).

### Graph construction order ([`AudioEngine/SFBPlaybackEngine.swift`](Sources/AudioEngine/SFBPlaybackEngine.swift))

`insertEQAndTap()` runs inside `player.modifyProcessingGraph`:

1. `engine.attach(eq)` — once, idempotent.
2. `engine.attach(panNode)` — once, idempotent.
3. Query `sourceNode.outputFormat(forBus: 0)` (fallback 44.1 kHz stereo).
4. `disconnectNodeOutput(sourceNode)`.
5. `connect(sourceNode → eq)` then `connect(eq → panNode)` then `connect(panNode → mainMixerNode)` with that format.
6. `installTap(on: eq, bus: 0, bufferSize: 1024)` — **pre-pan, post-EQ**. Tap size is `SFBPlaybackEngine.tapBufferSize = 1024`; the FFT still reads 4096 samples from the 16384-sample ring — these are independent and must stay that way.

On any sample-rate/channel change, SFB calls the delegate's
`reconfigureProcessingGraph(with: format)`, which re-attaches the EQ and panNode, re-connects
`eq → panNode → mainMixer` **using the passed format** (the node's own format is stale mid-
reconfig), re-applies pan/balance, re-installs the tap on the EQ output, and returns the EQ as the
node to feed. Never call `engine.start()`/`stop()` — the player owns lifecycle.

### Gapless & callbacks

- `enqueue(url, immediate:false)` pre-buffers the successor; SFB switches with **no gap** (no crossfade — single-stream, deferred).
- SFB delegate `renderingWillComplete` → engine `onRenderingComplete` → coordinator pre-schedules next.
- SFB delegate `renderingComplete` → engine `onEndOfAudio` → coordinator auto-advances.
- Callbacks hop to the main actor (`Task { @MainActor in … }`).

### ReplayGain

Applied through `eq.globalGain`, clamped to `−96…+24 dB`
([`AudioEngine/EQBand.swift`](Sources/AudioEngine/EQBand.swift): `clampGlobalGain`).
The value is stored in a lock-guarded box and pushed in the delegate's
`renderingWillStart` (per-decoder). Anti-clip mode uses `TRACK_PEAK`. This
placement is invariant across any future architecture change.

### The `@Sendable` tap

```swift
// Tap lives on the EQ output (pre-pan), bufferSize = SFBPlaybackEngine.tapBufferSize (1024)
eq.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
    ingest(buffer, into: provider)      // memcpy channel-0 → SPSC ring, nothing else
}
```

`@Sendable` (non-isolated) is mandatory: a tap closure created inside a
`@MainActor` type and invoked on the render thread will `SIGTRAP` under Swift 6's
isolation runtime. Capture only pre-allocated, `Sendable` state.

### EQ band layout ([`AudioEngine/EQBand.swift`](Sources/AudioEngine/EQBand.swift))

10 ISO bands: 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz. Band 0 = low shelf,
band 9 = high shelf, bands 1–8 = parametric peaking (bandwidth 0.5). All start at
0 dB.

### Decoding ([`Decoding/`](Sources/Decoding))

- **`DecoderProviding`** — factory: `makeDecoder(for url:) throws -> any PCMDecoding`, plus `supportedPathExtensions` / `supportedMIMETypes`.
- **`PCMDecoding`** — `processingFormat`, `sourceFormat?`, `frameLength`, `framePosition`, `supportsSeeking`, `decode(into:frameLength:)`, `seek(toFrame:)`. Thread-confined, **not** `Sendable`.
- **`SFBDecoderProvider`** bridges SFBAudioEngine 0.12.1: FLAC, MP3, Ogg Vorbis, Opus, WavPack, APE, WAV, AIFF, CAF, and DSD (DSF/DSDIFF, decimated to PCM).
- **`DecodingError`** — typed triage ladder: `ioError` → `unsupportedFormat` → `corruptedFile` → `truncated`.

### Test doubles

`FakePlaybackEngine` (in-memory state machine, records gains) and
`FakeDecoderProvider`/`FakePCMDecoder` (stateless sine synthesis:
`amplitude·sin(2π·f·n/sr)`) enable hermetic engine/coordinator tests.

---

## 5. DSP & spectrum (`DSP`)

Pure Accelerate/vDSP math — the most portable module. All values below are exact.

### FFT ([`DSP/SpectrumAnalyzer.swift`](Sources/DSP/SpectrumAnalyzer.swift))

| Parameter | Value |
|---|---|
| Transform size | **4096** samples |
| `log2n` | 12 |
| Magnitude bins | 2048 (`n/2`) |
| Window | **Hann**, normalized (`vDSP_hann_window`, `vDSP_HANN_NORM`) |
| Output bands | **128** |
| dB floor / ceiling | **−80** / 0 dB |
| Reference power | `(n/2)²` = 4,194,304 |

Pipeline: `vDSP_vmul` (window) → `vDSP_ctoz` (interleave→split) → `vDSP_fft_zrip`
(forward real FFT) → `vDSP_zvmags` (magnitude) → `vDSP_vdbcon` (→ dB) →
`vDSP_vclip` (floor).

**Bin → band:** 128 bands with **logarithmic** edges:
`edge[i] = round(pow(2048, i/128))`. Each band's value is the **peak dB** across
its bins, normalized `(peak − (−80)) / 80` → `[0,1]`. No temporal smoothing in the
DSP layer (visualizers add their own attack/decay).

### Bounded metering ring ([`DSP/SPSCRingBuffer.swift`](Sources/DSP/SPSCRingBuffer.swift), [`DSP/AtomicCounter.swift`](Sources/DSP/AtomicCounter.swift))

- Capacity **16384** floats (power of two → index via bitmask).
- Two 64-bit atomic counters (`OSAtomicAdd64Barrier`, full-barrier) for write/read totals; single-producer, single-consumer.
- **Producer** (`write`): one `AtomicAccessGate.tryAcquire` attempt, then up to two wrapping `memcpy`s and one atomic add. It never waits; a block is dropped while a reader owns the payload. Only accepted samples advance the write total.
- **Consumer** (`readLatest`): waits for exclusive payload ownership on a non-audio thread, then peeks at the most recent `count` samples ending at the write head; zero-fills the front if underfull. Concurrent snapshots cannot copy an overwritten generation.

### SpectrumProvider ([`DSP/SpectrumProvider.swift`](Sources/DSP/SpectrumProvider.swift))

The seam between audio thread and UI: `ingest(ptr, count)` (producer) →
`latestSpectrum() -> [Float]` (consumer peeks 4096 samples → 128 bands, reusing
scratch buffers). This is the **only** data path out of the render callback.

---

## 6. Visualizer (`Visualizer`)

### Contracts ([`Visualizer/VisualizerBackend.swift`](Sources/Visualizer/VisualizerBackend.swift))

- **`SpectrumSource`** (`Sendable`): `bandCount` (default 128), `latestSpectrum() -> [Float]` (0…1), `latestWaveform() -> [Float]` (−1…1). `SpectrumProvider` conforms.
- **`VisualizerMode`**: `bars`, `oscilloscope`, `particles`, `aurora`.
- **`VisualizerBackend`**: `mode`, `seed`, `isRendering`, `stats`, `start()`, `stop()`, `setSize(_:)`, `tick() -> VisualizerRenderStats`. `tick()` pulls one frame from the source and builds CPU-side render state.

### Backends ([`Visualizer/MetalVisualizerBackend.swift`](Sources/Visualizer/MetalVisualizerBackend.swift))

- **`HeadlessVisualizerBackend`** — CPU-only; exposes `lastFrame` for golden tests.
- **`MetalVisualizerBackend`** — `MTKViewDelegate`; pulls spectrum each `draw(in:)` and renders (pixel format `rgba8Unorm`). Both share a `VisualizerCore` value type that owns mode/seed/time and builds `VisualizerFrameState` (bars via band-averaging, particles, waveform).

### Determinism & power

- **`SeededGenerator`** ([`Visualizer/SeededGenerator.swift`](Sources/Visualizer/SeededGenerator.swift)) — SplitMix64 PRNG; `(seed, mode, spectrum)` renders reproducibly → golden-image tests.
- **`VisualizerPowerController`** ([`Visualizer/VisualizerPowerController.swift`](Sources/Visualizer/VisualizerPowerController.swift)) — `shouldRender = isVisible && appActive && !menuBarOnly`. When false, the delegate stops the render loop → **~0% GPU**. Target frame rate **60 fps** (30 under reduce-motion). Consumers pull on a `CADisplayLink` cadence.

**Porting:** swap Metal for Vulkan/OpenGL/WebGPU behind `VisualizerBackend`; the
spectrum math and power gating are platform-neutral. On macOS an optional
projectM/MilkDrop backend is compiled in only under `#if MACAMP_PROJECTM` and is
never part of `PlayerCore`.

---

## 7. Vocal separation (`Separation`)

The `Separation` module implements karaoke mode as an **offline pre-render
pipeline**. Real-time inference is architecturally impossible: Mel-Band Roformer
is non-causal (requires an 8-second look-ahead window), and Core ML inference
allocates memory and takes tens to hundreds of milliseconds per chunk — both
violate the render-thread invariants in [§1](#1-design-principles--invariants).
Instead, the pipeline runs entirely off the audio thread at
`Task.detached(priority: .utility)`, producing a cached ALAC instrumental that
the coordinator substitutes at playback time. See
[`Spikes/ADR-karaoke-separation.md`](../Spikes/ADR-karaoke-separation.md) for
the full rationale and channel policy.

> **Portability:** `Separation` never imports `AppKit` or `UIKit`. Its only
> system dependencies are `Foundation`, `Accelerate`, `CoreML`, and `AVFAudio`.

### Pipeline stages

```
source file
  → SeparationPCMStream (bounded decoder pulls + persistent AVAudioConverter)
  → model-sized windows (44.1 kHz / stereo / float32; one-window lookahead)
  → STFTProcessor.forward (vDSP Hann FFT, per-segment)
  → CoreMLSeparator.separate (Mel-Band Roformer → vocal estimate → complex subtraction)
  → STFTProcessor.inverse (iSTFT + overlap-add, exact-length trim)
  → InstrumentalWriteStream (incremental .m4a; ALAC or AAC; publish only after EOF)
  → InstrumentalCache.store (content-addressed LRU, 2 GB cap)
  → cached URL returned to coordinator
```

Rendering is **on demand**: a track is separated only when the user explicitly
requests it (`KaraokeRenderService.requestRender(_:)`, driven by the player-bar
mic button or a track-list "Create Karaoke Version" action), never auto-prewarmed
by enabling karaoke or advancing the queue. The coordinator itself **never**
renders — it only reads the cache, and auto-deactivates karaoke when the current
track has no ready instrumental.

The coordinator resolves the decoder URL to the cached instrumental **below** the
`Track` model — artwork, ReplayGain, Now Playing, and gapless all keep the
original track identity. Only the URL handed to the engine changes.

### Protocols ([`Separation/`](Sources/Separation))

| Protocol | Production conformer | Responsibility |
|---|---|---|
| `StemSeparating` | `SeparationPipeline` | `separate(url:progress:) async throws -> URL`; `availability` |
| `InstrumentalCaching` | `InstrumentalCache` (actor) | `cachedInstrumental(for:)`, `store(_:for:identity:)`, `pin`/`unpin`, `totalBytes`, `clearAll()`, `readySnapshot()` + `setOnEntriesChanged(_:)` (ready change-seam), `setMaxByteSize(_:)`, `relocate(to:)` |
| `KaraokeRendering` | `KaraokeRenderService` (in `Services`) | On-demand serial render driver: `setEnabled(_:)`, `requestRender(_:)`, `cancelAll()`, `onProgress`, `onFinished` |
| `SpectrogramPredicting` | `CoreMLSeparator` (actor) | Per-segment Core ML inference seam; swappable for `FakeSpectrogramPredictor` in tests |

### Availability — the unified `.unavailable` path

`SeparationAvailability` has two cases: `.available` and
`.unavailable(reason: SeparationUnavailableReason)`. The three reasons cover
every "not here" scenario with a single code path:

| Reason | When |
|---|---|
| `.modelNotBundled` | iOS builds, CI, fresh clones — model absent |
| `.modelLoadFailed` | Model present but corrupt or Core ML load failed |
| `.incompatibleModel` | Manifest version mismatch or invalid STFT parameters |

`CoreMLSeparator` resolves availability once at startup (cached). Any consumer
that receives `.unavailable` shows the reason's `LocalizedStringResource` message
and takes no further action — no special-case code for App Store vs CI vs iOS.

### Cache design ([`Separation/InstrumentalCache.swift`](Sources/Separation/InstrumentalCache.swift))

`InstrumentalCache` is a `public actor` that mirrors `ArtworkCache`:

- **Content-addressed:** files are named `<SeparationCacheKey.hexValue>.m4a`.
  `SeparationCacheKey` is `SHA256(path ⑟ size ⑟ mtime) XOR SHA256(modelSHA)` —
  any change to the source file or model produces a different key.
- **LRU eviction:** a monotonic clock stamps each store/lookup; eviction drops
  older, unpinned entries while protecting the just-stored result. If the new
  output cannot fit beside pinned entries, store fails with a capacity error
  rather than returning an already-deleted URL.
- **Default cap:** `InstrumentalCache.defaultByteCap = 2 GB` (2 × 1024³).
- **Pins:** active and pre-scheduled instrumentals are pinned by the coordinator
  and render service so eviction never drops a file currently in use.
- **Index:** an `index.json` sidecar tracks entries — including each entry's
  source-file identity (`sourcePath` + `(size, mtime)`), which backs the ready
  change-seam (`readySnapshot()` / `setOnEntriesChanged`) that drives the in-memory
  `KaraokeReadyStore`. A corrupted index is silently discarded and rebuilt empty on
  the next store.
- **No GRDB:** the cache is filesystem + JSON only — no Persistence import.

The **default** cache directory is `~/Library/Application Support/MacAMP/Instrumentals/`,
defined by `Models.InstrumentalCacheLocation` (the single source of truth for the
default location). The user can relocate the cache to any folder
(`AppSettings.karaokeCacheDirectoryPath` → `relocate(to:)`); the composition root
feeds the *current* configured directory to both the scanner exclusion guard and
the library-root overlap check, so whichever directory is active is never scanned
or accepted as a library root. The byte cap is likewise user-configurable
(prune toggle + 1/2/5/10 GiB cap, `setMaxByteSize(_:)`; `0` = unlimited).

### v1 limitations (accepted, not bugs)

These are recorded in [`Spikes/ADR-karaoke-separation.md`](../Spikes/ADR-karaoke-separation.md):

1. **Hi-res audio decimated to 44.1 kHz** — the model was trained at 44.1 kHz;
   any higher sample rate is resampled before separation. Original playback is
   unaffected.
2. **Advancing to an un-rendered track auto-deactivates karaoke** — rendering is
   on demand, so a track with no ready instrumental cannot play as karaoke. When
   playback reaches such a track (auto-advance, next/previous, `play(at:)`, or a
   queue edit), the coordinator silently turns karaoke off and plays the original,
   surfacing a one-shot toast. The user re-renders that track (mic button or
   "Create Karaoke Version") to sing along to it.
3. **Mid-song toggle has a ~100–300 ms gap** — `SFBAudioPlayer` is single-stream
   (Option A); switching between original and instrumental requires
   `engine.reload(url:at:resumePlaying:)`, which stops, loads, seeks, and
   resumes. Inherent to the single-stream architecture.
4. **Original ReplayGain applied to instrumental** — the source track's gain
   values are used; the instrumental's true loudness differs slightly (typically
   < 1 dB under-correction).

### Test doubles (in `PlayerCoreTestSupport`)

- **`FakeStemSeparator`** — configurable availability, return URL, error, and
  latency; records `requestedURLs`, `separateCallCount`, `maxObservedConcurrency`.
- **`FakeInstrumentalCache`** (actor) — pre-seeded lookups; `storeCallCount`,
  `clearCallCount`, `isPinned`, `contains`.
- **`FakeKaraokeRenderer`** (`@MainActor`) — records `isEnabled`,
  `requestedURLs`, and per-method call counts; `emit(_:)` fires `onProgress` and
  `finish(_:success:)` fires `onFinished`.
- **`FakeSpectrogramPredictor`** — pure Swift, no Core ML, no disk; keeps only a
  configurable frequency band so the subtraction result is exactly assertable.

---

## 8. Persistence & data model (`Persistence`)

> **Note:** this section was previously §7. The `Separation` module was inserted as §7.

SQLite via GRDB. WAL journaling; one writer, concurrent readers; all access
through `writer.read {}` / `writer.write {}` closures. DB lives at
`~/Library/Application Support/MacAMP/library.sqlite`
([`Persistence/AppDatabase.swift`](Sources/Persistence/AppDatabase.swift)).

### Migrations — head **`v20`** ([`Persistence/AppDatabase+Migrations.swift`](Sources/Persistence/AppDatabase+Migrations.swift))

Append-only, string-literal names, never erasing in production:

| Migration | Adds |
|---|---|
| `v1` | Base schema: `artist`, `album`, `track`, `playlist`, `playlistTrack`, `smartPlaylist`, `artworkRef`, `bookmark` |
| `v2` | `trackSearch` FTS5 external-content index |
| `v3` | `eqPreset` (custom presets) |
| `v4` | `lyricsCache` |
| `v5` | `track.genre` (nullable, **filter-only**, NOT in FTS5) |
| `v6` | `track.albumArtist/composer/year/channelCount` + backfills the normalized artist/album graph & FKs (set-based SQL, index-first idempotent upsert) |
| `v7` | `track.customPosition` |
| `v8` | `track.isFavourite` (INTEGER 0/1, `NOT NULL DEFAULT 0`) |
| `v9` | `infoCache` (MusicBrainz + Wikipedia narratives, `UNIQUE(entityType, entityKey)`) |
| `v10` | Covering indexes: `(isFavourite, customPosition)`, `genre COLLATE NOCASE`, `(filePath COLLATE NOCASE, customPosition)` |
| `v11` | `track.listenedCount` (INTEGER, `NOT NULL DEFAULT 0`) |
| `v12` | `profile` table (+ built-in Guest row id=1), `profileTrackState` composite-PK junction table (per-profile favourites/playCount/listenedCount/customPosition, sparse-backfilled from frozen `track.*` columns), `libraryRoot` (per-profile watch roots), `playlist.profileId` FK (backfilled to Guest). Freezes `track.isFavourite/playCount/listenedCount/customPosition` — those columns are now dead, read/written by nothing except the v12 backfill. |
| `v13` | `profile.avatarImagePath` (nullable TEXT) — optional path to a downsampled PNG in Application Support |
| `v14` | `profilePlaybackState` — one opaque playback snapshot row per profile (`ON DELETE CASCADE`), composite PK on `profileId` |
| `v15` | `playEvent` (denormalized survivable play log, nullable `trackId` bare FK, `utcOffsetSeconds INTEGER NOT NULL`), `playEventRollup` (monthly compaction, `UNIQUE(profileId, yearMonth, artistKey, genreKey)`), `playSegmentHeat` (100-bucket replay heatmap, 400-byte LE blob, `UNIQUE(profileId, trackId)`), `folderTrackOrder` (per-profile per-root drag order, composite PK) |
| `v16` | AI substrate: `trackAudioFeature` (cached tempo/energy/brightness, `analysisVersion` + `fileSize`/`mtime` fingerprint, cascading FK — nullable `bpm`, `energy` and `bpm` range indexes); `generatedPlaylist` (provenance for AI-generated playlists, `UNIQUE(playlistId)`, cascading FK, `generatorKind` index); `smartPlaylist.rulesVersion` (`NOT NULL DEFAULT 1` — backfills every existing row as schema v1) + `smartPlaylist.lastEvaluatedAt` (nullable, NULL = "never evaluated"). Split into [`Persistence/AppDatabase+Migrations+AI.swift`](Sources/Persistence/AppDatabase+Migrations+AI.swift). |
| `v17` | `downloadHistory` — append-only completed-download log: `id`, `canonicalVideoID`, `title`, `uploader`, `durationSeconds`, `filePath`, `audioFormat`, `audioQuality`, `sourceURL`, `downloadedAt`, `utcOffsetSeconds`. |
| `v18` | `trackLoudness` — BS.1770-4 loudness cache keyed by `trackId` (`ON DELETE CASCADE`). `integratedLUFS REAL` (NULLABLE — nil is the silence sentinel), `truePeak REAL NOT NULL`, `albumLUFS`/`albumPeak`, `blockPowersHistogram BLOB` (3004 bytes, 751 × LE `UInt32`), `analysisVersion`, `fileSize`/`mtime` fingerprint, `cueStartFrame INTEGER NOT NULL DEFAULT -1`, nullable `cueEndFrame`, `computedAt`. |
| `v19` | `parametricEQPreset` — user-saved parametric EQ presets: `id` (rowid alias PK), `name TEXT NOT NULL UNIQUE`, `filtersJson TEXT NOT NULL` (opaque JSON array of `ParametricFilter`), nullable `preamp REAL`. |
| `v20` | CUE sheet columns on `track`: `cueStartFrame INTEGER NOT NULL DEFAULT -1` (−1 = whole-file, not a CUE segment), nullable `cueEndFrame INTEGER` (NULL = play to EOF), nullable `cueSheetPath TEXT`. Also turns the two literal cue-sentinel terms in `TrackLoudnessRepository`'s staleness query into the real `track` columns. |

Head assertions live in **ten** test files — all must be updated together when a new migration lands:
`AppDatabaseTests.swift` (full list), `LyricsCacheTests.swift` (full list),
`MigrationTests.swift` (`.last == "v20"`), `AIMigrationTests.swift` (`.last == "v20"`),
`StatsSchemaTests.swift` (`.last == "v20"`), `ProfilePlaybackStateRepositoryTests.swift` (`.last == "v20"`),
`DownloadHistorySchemaTests.swift` (`.last == "v20"`), `TrackLoudnessSchemaTests.swift` (`.last == "v20"`),
`ParametricEQPresetTests.swift` (`.last == "v20"`), `CueTrackSchemaTests.swift` (`.last == "v20"`).
`grep -rn '"v20"' PlayerCore/Tests` must report exactly 11 lines (the ten above plus one from `AppDatabaseTests`'s full ledger list).

### Core schema (through v20)

`track` (unique by `filePath` plus `cueStartFrame`; −1 identifies a whole-file track) carries every field in [§3](#3-domain-model-models),
with `availability` `CHECK`-constrained to the three states. `playlistTrack`
enforces `UNIQUE(playlistId, position)` (doubles as the ordering index).
`smartPlaylist` holds `playlistId UNIQUE` + `rulesJson`. `trackSearch` is an FTS5
external-content index over `title`/`artistName`/`albumTitle` with
`unicode61 remove_diacritics=1` (so "Bohème" matches "boheme").

**v15 stats tables:**

- `playEvent` — one row per play. `profileId` FK cascades; `trackId` is a bare nullable integer (no FK) so deleting a track never removes its events. Denormalized `artistName`, `title`, `albumTitle`, `genre`, `durationSeconds` are captured at write time. `utcOffsetSeconds` stores the listener's UTC offset at `startedAt` for local-hour facets. Indexes on `(profileId, startedAt)` and `(profileId, trackId)`.
- `playEventRollup` — monthly compaction output. `UNIQUE(profileId, yearMonth, artistKey, genreKey)` is the upsert key. NULL artist/genre collapse to `""` sentinel so `GROUP BY` buckets them correctly.
- `playSegmentHeat` — per-profile per-track replay heatmap. `bucketCounts` is a 400-byte little-endian blob (100 × `UInt32`). `UNIQUE(profileId, trackId)`. `trackId` is bare (no FK) for the same survivability reason as `playEvent`.
- `folderTrackOrder` — per-profile per-root drag order. Composite `PRIMARY KEY(profileId, rootPath, trackId)` with `ON DELETE CASCADE` on both FKs. Un-positioned tracks sort last via a `COALESCE(position, INT64_MAX)` sentinel.

**v16 AI substrate tables** ([`Persistence/AppDatabase+Migrations+AI.swift`](Sources/Persistence/AppDatabase+Migrations+AI.swift)):

- `trackAudioFeature` — cached audio analysis for one track. Primary key is the caller-supplied `trackId` (cascading FK, so deleting a track discards its analysis). `fileSize`/`mtime` fingerprint detects re-encodes and defuses SQLite rowid reuse. `bpm` is nullable (tempo estimation can legitimately find no reliable beat in ambient material); `energy` and `brightness` are always computable and not null. `analysisVersion` versions the feature extractor. Range indexes on `energy` and `bpm` back the smart-playlist compiler and mix generator's predicate queries.
- `generatedPlaylist` — provenance row for a playlist a generator produced: which `generatorKind`, from which `specJson` at `specVersion`, and when it `lastRefreshedAt`. `UNIQUE(playlistId)` with `ON DELETE CASCADE`; `generatorKind` index backs "show me every daypart mix" reads.
- `smartPlaylist.rulesVersion` — `NOT NULL DEFAULT 1`, applied to every existing row by the migration. Rules predating versioning are treated as schema v1. `smartPlaylist.lastEvaluatedAt` — nullable; `NULL` means "never evaluated", which is what every pre-v16 row carries after migration.

### Keyset pagination ([`Persistence/Repositories/Pagination.swift`](Sources/Persistence/Repositories/Pagination.swift))

The universal list-read pattern — **never `OFFSET`**:

```sql
WHERE (sortKey, id) > (?, ?)  ORDER BY sortKey, id  LIMIT n+1
```

Fetch `n+1`, return `n` + a `PageCursor{key,id}` when the extra row exists. Stable
under concurrent inserts; O(1) per page regardless of depth.

### Repositories ([`Persistence/Repositories/`](Sources/Persistence/Repositories))

`TrackRepository` exposes paged reads: all tracks (by `sortTitle,id`), `tracksByRoot`
(folder prefix, honoring `folderTrackOrder` position via `COALESCE(position, INT64_MAX)` sentinel), `tracksByGenre` (`nil`=all, `""`=untagged,
else `= ? COLLATE NOCASE`), `tracksByAlbum` (`disc*100000+track` order), `tracksByArtist`,
`distinctGenres`, `rootSummary` (availability counts), and `searchTracks` (FTS5
`MATCH` with prefix patterns, ranked by BM25, `< 50 ms` at 100k). `ValueObservation`s
(e.g. recently-added) are always `LIMIT`-capped.

`PlayEventRepository` exposes keyset-paginated event reads (`playEvents(profileId:before:limit:)`), rollup reads, bounded deletion (`deleteEventsOlderThan(_:profileId:)`, batch-looped), `upsertRollup` (read-modify-save for idempotent compaction), `trackPlayStats(profileId:trackId:)` (aggregate last/first played, total seconds, skip count for the right-panel Stats tab), and `topTrackIds(profileId:since:limit:)` (bounded ranked track ids for the stats dashboard top-tracks list).

`PlaySegmentHeatRepository` exposes `segmentHeat(profileId:trackId:)`, `mergeSegmentHeat(profileId:trackId:identity:deltas:updatedAt:)` (read-modify-write in one transaction, saturating at `UInt32.max`, all-zero merge writes nothing), and keyset `allSegmentHeat(profileId:after:limit:)` for digest and archive reads.

`TrackRepository` also exposes `resolvedTracks(profileId:trackIds:)` (concrete extension — batch-resolves at most 500 track ids to `ProfileScopedTrack` rows, applying no `LibraryVisibility` filter so deleted/moved tracks still resolve for stats history). The bound is a ceiling, not a chunk size: callers that page (e.g. `MixCandidateResolver`) still chunk to `InsightPaging.resolveChunkSize` so the ids they hand over arrive in their own ranked order.

`LyricsBrowseRepository` (in the `Lyrics` module) exposes `tracksWithLyrics(profileId:after:limit:)` — a keyset-paginated join of `track` and `lyricsCache` (on `cacheKey = filePath`) that excludes sentinel rows (`source == "none"`) and applies `LibraryVisibility` scoping.

### Availability reconciler ([`Persistence/Availability/AvailabilityReconciler.swift`](Sources/Persistence/Availability/AvailabilityReconciler.swift))

`reconcile()` runs in three phases, deliberately separating filesystem I/O from the write lock:

**Phase A — `readSnapshot` (`dbWriter.read`, no write lock held).** Streams only the three columns the state machine needs (`id`, `filePath`, `availability`) via `Row.fetchCursor` into lightweight `AvailabilitySnapshotRow` structs. A full `TrackRecord` carries 31 columns for a decision that reads exactly one; materialising the whole row is unnecessary at 100k scale.

**Phase B — `probe` (no transaction held).** Walks the snapshot off the database, resolving each row's availability via the injected `FileSystemProbing` seam (`present` → else external+unmounted → `externalOffline` → else `missing`). The probe is wrapped in a `PassProbeCache` decorator that memoizes **both** `fileExists(atPath:)` (per path) and `volume(forPath:)` (per mount root, `/Volumes/<name>`) within one reconcile() pass only. Neither cache ever persists across pass boundaries — `PassProbeCache` is constructed fresh per `reconcile()` call and never escapes, so a drive unmounted between two passes is re-probed by the second. `fileExists` memoization is what collapses N `stat(2)` calls to one for every CUE-sheet disc image (all segments share one audio file). `volume()` is consulted only after `fileExists` fails, so an all-present library never pays for it. This phase can block for seconds on a stalled network mount or a spinning-up drive; holding that inside a write transaction would pin SQLite's single writer for the entire pass.

**Phase C — `applyChanges` (`dbWriter.write`, one short transaction).** Applies only the rows whose availability changed, each via a targeted `UPDATE … WHERE id = ?`. Early-returns immediately when nothing changed, so a steady-state pass opens **no** write transaction at all. A row deleted between phases A and C makes its update match nothing — no explicit handling required. Only the `availability` column is rewritten. **Never deletes rows.**

### Playlist IO ([`Persistence/Playlists/`](Sources/Persistence/Playlists))

Import/export **M3U, M3U8, PLS, JSPF (JSON)**. Import resolves each entry against the
unique `filePath` (one indexed lookup each) and reports **unresolved** entries with
line numbers — never silently dropped. Export supports absolute/relative paths.

### Smart playlists — storage only (WIP)

The `smartPlaylist` table and [`SmartPlaylistRecord`](Sources/Persistence/Records/SmartPlaylistRecord.swift)
(`rulesJson`) exist, but **no rule compiler/engine is implemented yet** — rules are
stored, not evaluated. This is a deliberate WIP seam; a port can defer it. (A
compiler would parse `rulesJson` into a predicate tree and emit a SQL `WHERE`
clause.)

---

## 9. Playback coordination (`Services`)

### PlaybackCoordinator ([`Services/PlaybackCoordinating.swift`](Sources/Services/PlaybackCoordinating.swift), [`Services/PlaybackCoordinator.swift`](Sources/Services/PlaybackCoordinator.swift))

The `@MainActor` source of truth bridging the queue to the engine. It publishes an
observable `CoordinatorState` { `current`, `queue`, `history`, `shuffle`,
`repeatMode`, `playback`, `manualQueue` } and wires the engine on init:

```
engine.stateDidChange    → publish()
engine.onEndOfAudio      → handleTrackDidFinish()      // auto-advance
engine.onRenderingComplete → prescheduleNextIfNeeded() // gapless
```

It exposes transport (`play/pause/toggle/stop/next/previous/seek/play(at:)`), queue
editing (`setQueue/append/insert/remove/move/removeAll/reorder`), a **manual queue**
(`enqueueManual`, `playNextManual`, …), volume/balance, and
`snapshot()`/`restore()` for state persistence. It also fires
`onTrackStarted/onTrackPlayed/onTrackListened` hooks (a 60-second listen timer
drives `listenedCount`).

### PlaybackQueue — pure value type ([`Services/PlaybackQueue.swift`](Sources/Services/PlaybackQueue.swift))

Engine-independent model of order and position: `entries: [TrackRef]`,
`order: [UUID]` (identity or shuffled), `currentID`, derived `history`.

- **Shuffle** ([`Services/ShuffleOrder.swift`](Sources/Services/ShuffleOrder.swift)): Fisher–Yates over an injected RNG, computed **once** when engaged (current track pinned first), never re-randomized mid-cycle. Deterministic under a seeded RNG.
- **Repeat** ([`Services/RepeatMode.swift`](Sources/Services/RepeatMode.swift)): `off` / `one` / `all`.
- **Navigation** skips non-`present` refs; wraps only under `repeat all`. Reconciliation preserves stable shuffle for untouched ids.

### Manual-queue precedence & orchestration ([`Services/PlaybackCoordinator+Orchestration.swift`](Sources/Services/PlaybackCoordinator+Orchestration.swift))

Forward advance: `repeat one` replays current → else the manual queue (consumed
front-first) → else the context queue → else stop. This lets "Play Next" interleave
without polluting the browsing context. Gapless pre-scheduling guards against
double-enqueue with `lastScheduledNextID`.

### TrackRef ([`Services/TrackRef.swift`](Sources/Services/TrackRef.swift))

Lightweight queue element (`id: UUID`, `trackID`, `filePath`, `title?`, `artist?`,
`duration?`, `availability`, …) so the hot path never touches the database. `url`
and `isPlayable` (`availability == .present`) are derived.

### LibraryScanner ([`Services/Scanner/LibraryScanner.swift`](Sources/Services/Scanner/LibraryScanner.swift))

Chunked, bounded-memory import: per chunk → one read-tx (existing rows by path,
bounded `IN`) → bounded-concurrency metadata reads → one batched write-tx.
**Fingerprint skip** (`filePath` + `mtime` + `fileSize`) avoids re-reading
unchanged files. Cancellable at chunk boundaries; emits `ScanEvent.progress/finished`.
Default chunk 5000, concurrency `min(cores, 8)`.

### Now-playing & remote ([`Services/NowPlaying/`](Sources/Services/NowPlaying))

`NowPlayingService` mirrors state into `MPNowPlayingInfoCenter` and writes the App-
Group `NowPlayingSnapshot`. `RemoteCommandHandler` maps `MPRemoteCommandCenter`
(play/pause/toggle/next/previous/changePlaybackPosition) **through the coordinator**
— so lock-screen, media keys, and in-app UI share one source of truth. It must be
constructed and `activate()`-d by each shell.

The App-Group snapshot publish path is an **optional, currently dormant** seam:
`NowPlayingService(snapshotWriter:)` defaults to `nil`, and both shells pass `nil`
by design, so no snapshot is written at runtime. Passing a
`UserDefaultsSnapshotWriter` / `FileSnapshotWriter` (or any `SnapshotWriting`
conformer) turns publishing on with no other change; `NowPlayingService` guards
every write behind `guard let snapshotWriter else { return }`. See
[§3 — App-Group boundary types](#app-group-boundary-types).

### ReplayGain, Enrichment, Info

`ReplayGainService` ([`Services/ReplayGain/`](Sources/Services/ReplayGain)) computes
gain on track/settings change and pushes it to `engine.setGlobalGain` (anti-clip
limited). `EnrichmentService` + `InfoService` run background, pausable
metadata/lyrics/narrative enrichment (MusicBrainz + Wikipedia + LRCLIB) behind a
shared rate limiter, caching into `infoCache`/`lyricsCache`.

### Listening stats pipeline ([`Services/Stats/`](Sources/Services/Stats))

`PlayEventRecorder` (`PlayEventRecording` protocol + `FakePlayEventRecorder`) — consumes `PlayEventSignal` from the coordinator's `onPlayEvent` hook. Reads `genre`/`albumTitle` off-main from `TrackRepository`, stamps `utcOffsetSeconds` from an injected `TimeZone`, and writes a `playEvent` row off-main. Holds an `attributionProfileId` set at track-start time (not at signal time) so profile switches are attributed correctly. Exposes `flushAndWait() async` for the quit-flush path.

`PlaySegmentTracker` (`PlaySegmentTracking` protocol + `FakePlaySegmentTracker`) — samples the playhead at 1 Hz on the main actor while playing. Accumulates contiguous listened ranges, converts them to 100-bucket delta arrays via `PlaySegmentBuckets.deltas(for:duration:)`, and merges them into `playSegmentHeat` off-main at each track transition. Handles seek (`noteSeek(from:to:)`), pause, karaoke swap, restore, and repeat-one semantics. Lazy-begin covers restore and `activateManual` paths that never fire `onTrackStarted`.

`PlayEventCompactor` (`PlayEventCompacting` protocol + `FakePlayEventCompactor`) — idempotent 24-month rolling compaction. Aggregates raw events by `(profileId, yearMonth, artistKey, genreKey)` into `playEventRollup` and deletes the source rows in one atomic transaction. Uses `CivilMonth` (pure integer Hinnant algorithm, no `Calendar`/`TimeZone`) for UTC civil month arithmetic. Triggered once per launch via `PlayEventCompactionTrigger`.

`ListeningDigestBuilder` (`ListeningDigestBuilding` protocol) — builds a versioned `ListeningDigest` JSON from keyset scans of `playEvent`, `playEventRollup`, and `playSegmentHeat`. Deterministic: `JSONEncoder([.sortedKeys])`, fixed 4-dp rounding, total ordering on every array, integer-microsecond quantization for seconds sums. Local-hour facets use the stored `utcOffsetSeconds` (no `Calendar`). `mostReplayed` clusters come from `playSegmentHeat` alone (lifetime, never windowed, gated by `ReplayHeatAnalysis.hasTrustworthyShape` — `totalPasses >= 3` **or** a bucket heard `>= 3` times, so one sitting that replayed a passage still qualifies).

`LyricsSweepService` (`LyricsSweeping` protocol) — offline sweep of embedded tags and `.lrc` sidecars into `lyricsCache`. Runs at `Task.detached(priority: .utility)`, zero network. **One pass at a time, not one per launch**: `start()` is a no-op only while a pass is in flight, so a roots refresh that follows a finished pass still sweeps newly scanned tracks (a launch on which the user first adds a library folder would otherwise leave every one of those tracks unprobed until the next relaunch). Uses an anti-join against `lyricsCache` keyed by `track.filePath` to skip already-resolved tracks, which makes re-running cheap. Writes negative-result sentinels (`source == "none"`) for tracks with no local lyrics so they are not re-probed. Announces each cached document through `onDidCacheLyrics` — never for a sentinel — which the shell routes to `LyricsBrowserViewModel.cacheDidChange()` so the lyrics library reflects rows the sweep commits after the list has loaded.

---

## 10. Library tools and chat (`Services`)

### LibraryToolbox ([`Services/Toolbox/`](Sources/Services/Toolbox))

The single registry of library-reading tools the AI assistant can call. One
`LibraryToolbox` instance is shared by all three access paths (on-device, cloud
connector, external MCP), with the access tier controlling **which** tools are
published and **how much** text a result may occupy.

#### The ten library tools (names are a wire format — never rename)

| # | `name` | Required args | Optional args |
|---|---|---|---|
| 1 | `search_tracks` | `query` | `limit` (1–200) |
| 2 | `list_genres` | — | — |
| 3 | `get_tracks` | `track_ids` (≤100) | — |
| 4 | `get_track_features` | `track_ids` (≤100) | — |
| 5 | `get_listening_stats` | — | `window` (`7d`/`30d`/`12m`/`all`, default `30d`) |
| 6 | `list_playlists` | — | — |
| 7 | `get_playlist` | `playlist_id` | `limit` (1–200) |
| 8 | `sample_tracks` | — | `genre`, `year_min/max`, `tempo_min/max`, `energy_min/max`, `limit` (1–50), `seed` |
| 9 | `propose_playlist` | `name` | `track_ids` (≤500), `genre`, `target_count` (1–500), `description` |
| 10 | `match_tracks` | `pairs` (`title` + optional `artist`) | `limit_per_pair` |

`match_tracks` is registered AFTER the conditional control block, so it is tool 10
when no playback grant is present and tool 14 when one is — every addition is
appended rather than interleaved, because the order is a wire format an external
MCP client reads.

`.onDevice` publishes exactly five — `search_tracks`, `list_genres`,
`sample_tracks`, `get_listening_stats`, `propose_playlist` — the smallest set that
completes the "make me a playlist" loop without exceeding the 4096-token context.
The constant `LibraryToolbox.onDeviceToolNames` is the authoritative list.

#### Tiers (`ToolProfile`)

| Tier | Use | Character limit | Row limit | Row char limit |
|---|---|---|---|---|
| `.onDevice` | FM `LanguageModelSession` | 600 | 10 | 60 |
| `.cloud` | `ConnectorChatEngine` / single-shot | 8192 | 50 | 200 |
| `.external` | MCP server | 16384 | 100 | 300 |

All limits are constants on `ToolResultBudget`. The character limit is **hard** (rows are dropped from the tail until the whole rendered text fits). The row limit is soft (the hard character limit can cut it further). `renderedText(profile:).count <= profile.characterLimit` holds unconditionally.

#### Privacy invariant

`ToolboxRendering` is the only place a `TrackRecord` becomes text or JSON. It
never reads `TrackRecord.filePath`. `LibraryToolboxPrivacyTests` drives every
tool × every tier over rendered text AND payload JSON looking for path strings, and
its call table is kept exhaustive by an assertion against the live registry.

#### `propose_playlist` files, never writes

The `ToolboxProposalFiling` seam is the only non-read surface. It cannot reach a
repository directly — the composition root conforms it over the `ProposalStore`.
The existing `ProposalPreviewSheet` reviews proposals from any source. Nothing is
written until the user clicks Apply.

#### `propose_playlist` — named membership *or* criteria

`propose_playlist` is the one tool with its own identifier ceiling:
`ToolResultBudget.proposalIdentifierLimit` is **500**, and it lands exactly on
`SmartPlaylistRules.maximumLimit`. Every other identifier argument
(`get_tracks`, `get_track_features`, `play_tracks`, `queue_tracks`,
`match_tracks`, `LibraryChatTrackList.resolveLimit`) keeps its own separate,
unchanged 100-id cap — a proposal is *reviewed*, not read back to the model, so
the render bound that governs those does not apply here.

Only `name` is required. The membership can be **named** or **described**:

- **Named** — pass `track_ids` in playing order.
- **Criteria** — omit `track_ids` and pass a `genre` (plus an optional
  `target_count`); the app materialises the membership server-side through the
  same `SmartPlaylistCompiler` read `sample_tracks` uses. Criteria proposals are
  therefore **title-ordered** (`(sortTitle, id)`), **present-only** (`missing` /
  `externalOffline` tracks are excluded by the materialiser), and deterministic —
  the same call twice files the same ids.

**Genre and count are the only criteria.** Keyword/query criteria were measured
against the on-device prefix budget and did not fit, and a schema shared by three
adapters cannot carry a field only two of them can afford. A criteria call that
matches nothing files **no** proposal — an empty playlist is not an offer — and
answers with a sentence naming `list_genres` so the model can retry with the
library's own spelling.

`target_count` is a stated total, not a filter: when it disagrees with the filed
membership the summary echoes both figures and asks for a second attempt rather
than throwing.

---

### LibraryChatSession ([`Services/Assistant/`](Sources/Services/Assistant))

An `actor` that wraps a `LanguageModelSession` (Foundation Models) for multi-turn
on-device chat. `@available(macOS 26, iOS 26, *)`.

#### Creating a session

```swift
let result = LibraryChatSession.make(
    toolbox: toolbox,
    locale: .current,
    intelligenceEnabled: true   // from AssistantAvailabilityProbe
)
// result is .success(session) or .failure(AssistantChatUnavailable)
```

`make` checks capability; `init` skips the check (used only when the caller has
already gated). `prewarm()` should be called once the user starts typing — not at
init time.

#### Sending a turn

```swift
let turn: AssistantChatTurn = try await session.send(text)
// turn.text   — the model's reply
// turn.events — [AssistantChatEvent]: .assistantText / .toolCall / .toolResult
```

`send` throws `AssistantFailure` or lets `CancellationError` through. The busy
latch rejects a concurrent call rather than queuing it.

#### `AssistantChatEvent` vocabulary

```swift
enum AssistantChatEvent: Sendable, Equatable, Hashable {
    case assistantText(String)
    case toolCall(name: String)                    // snake_case LibraryTool.name
    case toolResult(name: String, summary: String, resultCount: Int?) // summary: model-facing, NOT localized copy; resultCount: pre-truncation total, nil = not list-shaped
}
```

**The summary is model-facing, not user copy.** A shell keys a localized caption
off the tool NAME. Rendering the summary verbatim to a user is a shell bug.
`resultCount` is the pre-truncation total number of results the lookup found, or
`nil` when the answer is not list-shaped (stats digest, proposal, refusal). A shell
may display this beside the localized caption — "Searched your library — 4 results"
— using the inflected grammar key `app.assistant.chat.tool.resultCount`
(`"— ^[N result](inflect: true)"`), so "1 result" vs "4 results" is automatic.
`resultCount` never reaches the wire: it travels in the event vocabulary only.

Both the on-device and cloud connector paths produce `AssistantChatEvent` values
using the same vocabulary. `ConnectorChatEventMapping` maps `ChatEvent` (kit) →
`AssistantChatEvent` exactly.

#### `LibraryChatProviderFailure` — the provider-failure token vocabulary

When a provider turn fails for a reason the listener can act on, `LibraryChatFailure.providerFailed(_:)` carries a `LibraryChatProviderFailure`. The reason field is a **`String` token, not an enum**. The module boundary is the reason: `ConnectorFailure` lives in `AIConnectorKit`, which PlayerCore must never import. Mirroring as a Swift enum would duplicate the type across a boundary that exists to prevent exactly that. A string token crosses whole and the shell owns the closed vocabulary that renders it, with a safe generic default for any token a later build introduces.

The closed vocabulary is `LibraryChatProviderFailure.Reason` (static string constants):

| Token | When | Which optional fields carry meaning |
|---|---|---|
| `"rate-limited"` | Provider is throttling requests | `retryAfter: TimeInterval?` — wait until retry, when the provider stated one |
| `"auth-expired"` | Saved credential was rejected | — |
| `"unreachable"` | Provider refused / DNS failure / offline / TLS error | — |
| `"timeout"` | Deadline elapsed before reply | — |
| `"http-status"` | Unusable HTTP status code | `statusCode: Int?` — the code only; response body is never carried |

A shell switches over these with a `default:` fallback to the generic failure copy, so an unrecognised token (introduced by a future build) degrades gracefully. The outer `LibraryChatFailure` switch has no `default:` — that enum is repo-internal, so a new case must be given copy before the shell compiles.

`LibraryChatProviderFailure` carries **only two numeric payloads** (`retryAfter`, `statusCode`). No diagnostic token, no `underlying` error, and no HTTP response body cross this boundary — the body in particular is a truncated response payload that must never reach the screen.

#### Context policy (condensation)

The session tracks the token budget from the SDK's `contextSize` (back-deployed to
4096 on macOS 26.0). When usage crosses half the window, MacAMP condenses the
transcript to `[first, last]` — the first entry carries the tool definitions and
must be preserved; dropping it would silently strip all tool capability. If the
SDK throws `exceededContextWindowSize`, MacAMP condenses and retries exactly once.

#### Five hand-written wrappers and the drift guard

`LibraryTool.parametersSchema` is a runtime `ToolboxJSON`; `Tool.parameters`
(Foundation Models) is a `GenerationSchema` synthesised at compile time by
`@Generable`. The five on-device tool wrappers restate their arguments by hand.
`ChatToolManifest` closes the gap: `published(_:)` reads W1's schema,
`reflected(name:arguments:)` reflects the wrapper's actual Swift stored properties.
`LibraryChatSchemaParityTests` asserts equality on every build, with a negative
control that fails four ways (rename/retype/add/required-flip).

---

## 11. Metadata, Artwork, Lyrics, MIDI

### Metadata ([`Metadata/`](Sources/Metadata))

- **Read** (`MetadataReading.readMetadata(from:) -> TrackMetadata`): every textual field is **NFC-normalized**; artwork sorted by picture type; ReplayGain bundled. `SFBMetadataReader` wraps SFB/TagLib.
- **Write** (`MetadataWriting.writeMetadata(_ patch:, to:)`): patch semantics (`nil` = leave unchanged; artwork tri-state `nil`/`[]`/replace). **Atomic sequence**: preflight → copy to hidden sibling in the *same directory* → patch temp → `FileManager.replaceItemAt` (atomic rename) → rollback on any failure. Original is byte-for-byte safe.
- **`MetadataSelfWriteRegistry`**: records self-writes for a grace window (default 5 s) so the folder watcher ignores its own change (no FSEvents self-write loop).
- **`GenreNormalizer`**: resolves ID3 numeric/parenthesised codes (`"(17)"`, `"RX"`) to names; passes free text through.
- **`SortKey`**: NFC → transliterate non-Latin to Latin (`CFStringTransform`) → fold diacritics/case/width against fixed `en_US_POSIX` → strip leading article. Byte-stable keys for keyset pagination across devices.

### Artwork ([`Artwork/`](Sources/Artwork))

`ArtworkProviding.artwork(for:) async throws -> ArtworkResult`. Resolution order:
**embedded** (via Metadata) → **Cover Art Archive** (by MBID) → **iTunes Search**
(upgrades `100x100` → `600x600`); network is opt-in. `ArtworkCache` is a
content-addressed **LRU disk cache**: blobs keyed by **SHA-256** of bytes (dedupe),
an `index.json` sidecar tracks recency/size/provenance, eviction drops
least-recently-used once over the byte cap. Downsampling and hashing via ImageIO +
CryptoKit ([`Artwork/ArtworkImageProcessing.swift`](Sources/Artwork/ArtworkImageProcessing.swift)).

### Lyrics ([`Lyrics/`](Sources/Lyrics))

Sources by precedence: **embedded synced** (3) → **`.lrc` sidecar** (2) → **LRCLIB**
online, opt-in (1) → **embedded unsynced** (0). The `.lrc` parser
([`Lyrics/LRCParser.swift`](Sources/Lyrics/LRCParser.swift)) handles `[mm:ss.xx]`
line timestamps, `<mm:ss.xx>` enhanced word timings, `[ar]/[ti]/[al]` tags, and
`[offset:±ms]` (positive = earlier). Results cache in GRDB (`lyricsCache`, v4).
`LyricsViewModel` highlights the active line/word via binary search.

`GRDBLyricsCache.store` is **precedence-monotonic**: a higher-precedence source overwrites a lower one; a sentinel (`source == "none"`) never overwrites a real result. `markNoLyrics(forKey:)` writes a sentinel via `INSERT … ON CONFLICT DO NOTHING` — sentinels are invisible to resolve, excluded from the lyrics library browse, and overwritable by any online resolve. `LyricsCacheSentinel.source == "none"` is the canonical constant.

`LyricsBrowseRepository` (in the `Lyrics` module) provides `tracksWithLyrics(profileId:after:limit:)` — a keyset-paginated join of `track` and `lyricsCache` on `cacheKey = filePath`, excluding sentinel rows and applying `LibraryVisibility` scoping. `LyricsBrowserViewModel` (`@MainActor @Observable`) drives the macOS lyrics library sidebar: keyset-paged list, preview resolve via a separate `LyricsViewModel` instance, and `clearPreview()` for when the previewed track becomes the playing track.

### MIDI ([`MIDI/`](Sources/MIDI))

`MIDIPlaying` protocol with an `AVAudioUnitSampler` + `AVAudioSequencer`
implementation ([`MIDI/MIDIPlayer.swift`](Sources/MIDI/MIDIPlayer.swift)): SoundFont
injection (GeneralUser GS) and offline bounce (render a MIDI sequence to PCM).
`FakeMIDIPlayer` for tests.

---

## 11. Presentation layer (`ViewModels`)

**13** `@MainActor @Observable` view models, shared verbatim by macOS and iOS. They
talk to Services/Persistence through **windowed** reads and run DB/IO **off-main**
(`Task.detached`). ([`ViewModels/`](Sources/ViewModels))

| View model | Responsibility |
|---|---|
| `PlayerViewModel` | Transport bridge: current track, isPlaying, elapsed/duration, shuffle/repeat, artwork (owns the coordinator's `stateDidChange`) |
| `LibraryViewModel` | Keyset-paged tracks/albums/artists + bounded recently-added observation |
| `SearchViewModel` | Debounced (250 ms) FTS5 search with growing window |
| `QueueViewModel` | Context + manual queue editor (refreshes from coordinator snapshot) |
| `EQViewModel` | 10-band gains, presets, preamp, ReplayGain mode |
| `VisualizerViewModel` | Pull-based spectrum/waveform + mode; visibility gates power |
| `LyricsViewModel` | Resolve + active line/word highlight |
| `PlaylistViewModel` | Keyset-paged playlists + membership editing |
| `PlaylistImportExportViewModel` | m3u/m3u8/pls/JSPF IO, surfaces unresolved entries |
| `EnrichmentViewModel` | Observable projection of the enrichment service |
| `FolderBrowserViewModel` | Keyset window for one library-root folder |
| `FolderSidebarViewModel` | Per-folder sidebar nodes from library roots (stable FNV-1a ids, "missing" badge), counts read off-main |
| `GenreBrowserViewModel` | Keyset window for one genre selection |

Plus the `SidebarDestination` navigation enum (`.fixed(section)` / `.folder(rootId)` /
`.playlist(id)`, Codable & versioned), a `GenreFilter` model, and `TagEditModel`
([`ViewModels/TagEditing/`](Sources/ViewModels/TagEditing)) — the shared patch/collapse
logic for the tag editor (field-level dirty tracking, multi-track collapse, online
auto-fill coordination). Per-shell `TagEditorViewModel` wrappers live in the shells.

Additional view models added in the stats-expansion pass:

| View model | Responsibility |
|---|---|
| `LyricsBrowserViewModel` | Keyset-paged lyrics library (tracks with cached lyrics), preview resolve via a separate `LyricsViewModel`, `clearPreview()` on now-playing match |
| `ScrubberHeatViewModel` | Loads and normalizes `playSegmentHeat` for the scrubber overlay; gated by the shared `ReplayHeatAnalysis.hasTrustworthyShape` (3 committed passes **or** a bucket heard 3+ times); `heat: [Float]?` is nil until the gate passes |
| `KaraokeReadyStore` | In-memory projection of the cache change-seam (`readySnapshot()` / `setOnEntriesChanged`); rebuilt each launch, never persisted; `lastAppliedSequence` starts at `-1` |
| `KaraokeReadyListViewModel` | Profile-scoped ready list with client-side `searchQuery` filter |
| `KaraokeQueueStore` | In-memory projection of `KaraokeRendering.onQueueChanged`; membership + current-item progress, never persisted |
| `KaraokeQueueViewModel` | Resolves display rows in queue order via bounded `tracksByPaths` |
| `ListeningStatsViewModel` | Loads all listening windows in one pass (`load(profileId:)` / `refresh(profileId:)`); exposes `selectedWindow` (zero-I/O switch), `selectedWindowDigest`, `recentPlays` (≤50), `replayedRows` (≤25 replay-affinity ranked), `resolvedTopTrack(_:in:)` for per-row playability; constructed with the concrete `TrackRepository` for ProfileState reads (see DI note below) |

### AI assistant (`AssistantViewModel`)

`AssistantViewModel` ([`ViewModels/AssistantViewModel.swift`](Sources/ViewModels/AssistantViewModel.swift) + sibling files) is the one door every AI mutation goes through. It has exactly two public methods: `submit` (reads only) and `apply` (the only code that writes). There is no method that does both — "the AI changed my library without asking" is not a bug that can be introduced by a careless call site.

#### The four-tier ladder (`AssistantViewModel+Ladder.swift`)

`submit(text:profileId:)` runs `resolvedSpec(for:locale:reading:)` off-main, which tries four tiers in order:

1. **Connector tier** — if a `connectorParser` is injected AND its own `connectorAvailability` predicate returns `true`, the request is forwarded through `AIConnectorKit` with a `withDeadline` bound (default 20 s). The connector tier deliberately does NOT gate on `AssistantAvailability` (Apple Intelligence readiness) — a third-party connector is precisely the path that still works when Apple Intelligence is unavailable.
2. **Foundation Models tier** — if a `modelParser` is injected AND `reading` is `.available`, the on-device FoundationModels tier runs. On any throw it falls through.
3. **Heuristic tier** — `HeuristicQueryParser` (its contract: parsing never throws). Always present.
4. **Deterministic default** — a fixed genre-and-tempo fallback; mirrors the heuristic tier's shape.

A fall-through is **recorded, not vetoed**: `do`/`catch` blocks set `lastTierDiagnostic` and then fall through exactly as before — the lower tiers still answer, and the proposal is a proposal from whichever tier ultimately succeeded. Four diagnostic cases: `connectorUnavailable`, `connectorTimedOut`, `connectorFailed`, `modelFailed`. A connector predicate returning `false` records `.connectorUnavailable`; an ABSENT connector or an unavailable Apple Intelligence reading does not — otherwise every default install would show a fall-through notice.

`.intelligenceDisabled` is the one reading that stops everything: with the master switch off the assistant produces nothing at all. Every other unavailability reason means only "no FM tier"; the lower tiers still answer.

#### `AssistantProposalError`

`lastError: AssistantProposalError?` holds the typed failure the UI can explain. Three cases:

- **`noMatchingTracks`** — `generatedDraft` returned an empty set.
- **`generationFailed(reason:)`** — the draft query itself threw (DB error, etc.).
- **`featureDisabled`** — the relevant `AIFeatureBundle` is off.

`lastError` and `lastTierDiagnostic` are **orthogonal**: both can be set at the same time. The shell reads both independently — a failure banner for `lastError` and a "provider went quiet" notice for `lastTierDiagnostic` can appear simultaneously.

#### Proposal / apply model

`submit` puts an `AIProposal` into `proposals: AIProposalStore` and returns it. Nothing is written. `apply(_:confirmedBatch:)` is the only write path:

- `confirmedBatch` is the set of `Track.ID`s to include after the user's checkbox selections. The shell passes `proposal.memberIDs.subtracting(excludedIDs)` — the exclusion set, not an inclusion set, so tracks beyond the preview cap are included by construction (they can't be in the exclusion set if the preview never listed them).
- `apply` dispatches to the correct writer by `AIProposal.Kind`: `createPlaylist`, `organize` (membership rewrite via `PlaylistOrganizeDiff`), `tagChangeSet` (atomic metadata patch via `MetadataWriting`), `renamePlaylist`.
- **Nothing writes until `apply` is called.** `submit` never calls `apply`. The shell must always show a review surface and pass explicit user confirmation.

#### Hygiene analysis (`AssistantViewModel+Hygiene.swift`)

`hygieneAnalysis(profileId:)` runs three analyzers off-main and maps each `HygieneFinding` to proposals at load time (never in `body`). `hygieneProposals(for:)` over a batch merges every metadata-gap patch into ONE `.tagChangeSet` — section-wide "Review All" raises one file-write confirmation, not one per track. `deconflicted(_:)` keeps only the first `.organize` per playlist in a batch to prevent two competing membership rewrites from undoing each other; the dropped fix resurfaces on the next reload after apply.

---

## 12. Design system logic (`DesignSystem`)

`DesignSystem` is SwiftUI-facing but AppKit/UIKit-free (SwiftUI +
CoreGraphics/ImageIO/CryptoKit). The **token values, component catalog, and visual
language** are documented in the visual spec — see
[`macOS/README.md`](../macOS/README.md#design-system--theming). The **portable
logic** worth calling out here:

**Shared components added in the optimization pass:**

- **`GenreFilterBarView`** — the cross-platform genre chip bar (horizontal scroll of
  capsule chips; selected = accent bg/onAccent; options All / `<genre>` / untagged;
  hidden when ≤1 genre). Each shell wraps it in a thin `GenreFilterChipBar` adapter
  that supplies the per-shell environment.
- **`ActiveTick` / `TickPolicy`** — a playback-gated UI timer. `TickPolicy` decides
  whether a given view needs per-second updates (scrubber, lyrics sync, etc.);
  `ActiveTick` fires only while playback is active, eliminating idle CPU from
  timers that previously ran unconditionally. Seven UI timers across both shells are
  gated through this seam.
- **`SpectrumColors`** — neon color tokens (`pink`, `cyan`, `purple`) used by the
  inline spectrum view and the synthwave empty-state backdrop. Centralizes the
  literal RGB values that were previously duplicated across views.
- **`ReplayHeatCurve`** / **`ReplayHeatShape`** / **`ReplayHeatGeometry`** — the scrubber heat overlay component. `ReplayHeatGeometry` is a caseless enum (not a `View`) so its path-generation helpers are testable from nonisolated Swift Testing cases without a `SIGTRAP`. `ReplayHeatCurve` renders the normalized intensity curve behind a `PlayerSlider`, revealed on hover or drag. Accent comes from `\.designTokens.colors.accent`; opacity bumps under increase-contrast.

**Album theme extraction** ([`DesignSystem/Theming/ThemeExtractor.swift`](Sources/DesignSystem/Theming/ThemeExtractor.swift),
[`ThemeExtractor+Pixels.swift`](Sources/DesignSystem/Theming/ThemeExtractor+Pixels.swift))
— an `actor` that derives an accent + gradient from album art, **off-main**, cached
by SHA-256:

1. Decode + downsample to ≤ 48 px (ImageIO thumbnail).
2. Quantize to 4-bit-per-channel buckets (4096 buckets); skip near-transparent pixels.
3. Score buckets: accent = `count · (0.12 + saturation) · (1 − |brightness − 0.6|·0.55)` (favors saturated, mid-bright); vibrant fallback = `count · (0.05 + saturation²)`.
4. Assemble foreground (light/dark by accent luminance) + gradient stops; apply accessibility adjustments (increase-contrast, reduce-transparency).

This algorithm is platform-neutral (any image-decode + pixel-histogram stack can
reproduce it).

---

## 13. Testing & DI (`PlayerCoreTestSupport`)

A **library product** (not a test target) so app targets and `macamp-cli` can link
it ([`TestSupport/PlayerCoreTestSupport`](TestSupport/PlayerCoreTestSupport)). Ships
`OfflineRenderHarness` (offline AVAudioEngine render + analysis), signal generators,
and every `Fake*` (`FakePlaybackEngine`, `FakeDecoderProvider`,
`FakeMetadataReader/Writer`, `FakeEQPresetStore`, `FakeArtworkProvider`,
`FakeLyricsProvider`, `FakeLibraryScanner`, `PlaybackCoordinator.fake()`).

Run the package suite (requires Xcode's toolchain for Swift Testing / `@Observable`):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel
```

Audio engine suites use `@Suite(.serialized)`. Connect offline render graphs to
`engine.outputNode`, **never** `mainMixerNode` (the mixer's −3 dB mono pan law
corrupts level assertions). See the root [README](../README.md#test) for the full
matrix. Parallel full-suite runs still expose timing/allocation isolation issues;
the serial invocation is the required CI gate. Live-block allocation assertions
do not certify the absence of every transient allocation.

---

## 14. Reimplementation checklist

To port PlayerCore to another OS:

1. **Value types & availability state machine** — `Track`/`Album`/`Artist`/`Playlist`; three-state availability that never deletes rows.
2. **PlaybackEngine** — implement the protocol over your platform's audio graph: decoder → 10-band EQ (global gain = ReplayGain, clamp `−96…+24 dB`) → mixer → output, with a post-EQ tap. Gapless via enqueue; wire `onEndOfAudio`/`onRenderingComplete`.
3. **Decoder abstraction** — `DecoderProviding`/`PCMDecoding` + a typed error ladder; support FLAC/MP3/Ogg/Opus/WavPack/APE/WAV/AIFF/CAF/DSD.
4. **DSP** — 4096 Hann FFT → 2048 mags → 128 log bands (−80 dB floor); a bounded metering ring (16384) with exclusive snapshot ownership and a nonblocking producer; pull-don't-push.
5. **Visualizer** — a `VisualizerBackend` over your GPU API; deterministic SplitMix64; power gating on visibility/app-active for ~0% idle GPU.
6. **Persistence** — the v20 schema; keyset pagination (no OFFSET); FTS-equivalent full-text search; bounded observations; append-only migrations; the availability reconciler; playlist IO (m3u/m3u8/pls/JSPF). Smart-playlist rule compilation and evaluation are implemented in `Persistence/SmartPlaylists`. Stats tables: `playEvent` (denormalized, survivable, `utcOffsetSeconds`), `playEventRollup` (monthly compaction), `playSegmentHeat` (100-bucket replay heatmap), `folderTrackOrder` (per-profile drag order). AI substrate tables: `trackAudioFeature` (cached tempo/energy/brightness), `generatedPlaylist` (AI playlist provenance), `smartPlaylist.rulesVersion`/`lastEvaluatedAt` (rule-schema versioning).
7. **Coordinator + queue** — a pure queue (Fisher–Yates shuffle pinned-first, repeat off/one/all, manual-queue precedence) driving the engine; snapshot/restore; a listen timer.
8. **Metadata/Artwork/Lyrics** — atomic tag writes (temp-copy + atomic rename + self-write suppression); NFC + transliterated sort keys; content-addressed LRU art cache (SHA-256, LRU); layered lyric sources with an `.lrc` parser.
9. **Now-playing integration** — route system transport commands through the coordinator; optionally publish a tiny snapshot through the `SnapshotWriting` seam for out-of-process readers.
10. **DI discipline** — every service behind a protocol with a Fake; keep the core free of platform UI frameworks.

---

## Related

- **Project overview / build & test:** [root `README.md`](../README.md)
- **macOS interface & visual spec:** [`macOS/README.md`](../macOS/README.md)
- **iOS shell (WIP):** [`iOS/README.md`](../iOS/README.md)
- **Engineering contract & invariants:** [`.opencode/skills/macamp/SKILL.md`](../.opencode/skills/macamp/SKILL.md)
- **Audio ADR (Option A):** [`Spikes/ADR-audio-engine.md`](../Spikes/ADR-audio-engine.md)
- **Deep dives:** [`.opencode/skills/macamp/references/`](../.opencode/skills/macamp/references)
