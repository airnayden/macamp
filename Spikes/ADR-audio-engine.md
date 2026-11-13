# ADR: MacAMP Audio Engine Architecture (Phase 0 Spike)

- **Status:** ACCEPTED
- **Date:** 2026-06-22
- **Deciders:** Phase 0 audio spike (Task 7) — empirical, throwaway harness in `Spikes/`
- **Supersedes:** the unresolved A/B/C contradiction in `.omo/plans/macamp-research.md` ("CRITICAL: audio integration contradiction")

## Decision

**Decision: Option A** — MacAMP's audio pipeline is built on SFBAudioEngine's high-level
`SFBAudioPlayer` (Swift `AudioPlayer`), which owns the `AVAudioEngine`. The 10-band
`AVAudioUnitEQ` is inserted between the player's `sourceNode` and `mainMixerNode`; the
visualizer taps `mainMixerNode` (post-EQ). Gapless is free via `enqueue(_:)`. **Native
crossfade is DEFERRED** (not offered by Option A in this version).

This was not a preference call — **Option B is not buildable on the pinned dependency**
(see below), so the research's "prefer B" rule resolves to its documented fallback.

## Context

The source research proposed three incompatible audio architectures and required the
Phase 0 spike to pick exactly one:

| Option | Engine ownership | Gapless | Crossfade | EQ + tap | Risk |
|---|---|---|---|---|---|
| **A** `SFBAudioPlayer` (1 node, owns engine) | SFB | free (`enqueue`) | ❌ none | `modifyProcessingGraph` + tap mainMixer | least |
| **B** own `AVAudioEngine` + 2× `SFBAudioPlayerNode` | us | free per-node | ✅ two nodes → mixer | we wire | medium |
| **C** own engine + `AVAudioSourceNode` + raw SFB `AudioDecoder` PCM | us | reimplement | ✅ | we wire | most |

**Decision rule (from research):** prefer **B**; choose it only if it achieves gapless +
EQ insertion + mainMixer tap + a **working crossfade on BOTH macOS and iOS**. Otherwise
fall back to **A** and defer crossfade.

## Empirical findings

The spike (`Spikes/SpikeAudio/`) built the full pipeline and ran it on **macOS 26** and the
**iOS 26.5 simulator (iPhone 17)**: SFBAudioEngine decode (FLAC + MP3) → 10-band
`AVAudioUnitEQ` → `installTap` → lock-free SPSC ring buffer → vDSP FFT (4096 / Hann /
hop 1024) → Metal spectrum at ~60 fps.

### 1. Option B is INFEASIBLE on the pinned SFBAudioEngine 0.12.1 (the decisive finding)

Option B requires `SFBAudioPlayerNode` (an `AVAudioSourceNode` subclass) so two of them
can live in our own engine. **That class does not exist in 0.12.1.** Verified against the
checked-out source (`Tuist/.build/checkouts/SFBAudioEngine`):

```
$ grep -rn "AudioPlayerNode" Sources/   →   0 matches
```

The public surface is `SFBAudioPlayer` only; it exposes its source as a plain
`AVAudioSourceNode *sourceNode` (not a reusable player node), plus `mainMixerNode`,
`outputNode`, `modifyProcessingGraph`, `enqueue(_:)`, and the
`audioPlayer(_:reconfigureProcessingGraph:with:)` delegate.

Therefore "Option B" could only be realized by dropping to **Option C** (own engine + two
`AVAudioSourceNode`s fed by raw `SFBAudioDecoder` PCM), which the research classifies as the
highest-risk path (we reimplement gapless, scheduling, and all format-change handling).
Per the "least complexity that meets requirements" mandate, Option C is out of scope for v1.

Because B cannot even be built (let alone prove a cross-platform crossfade), the decision
rule's fallback applies → **Option A, crossfade deferred.**

### 2. Option A is fully proven on BOTH platforms

Identical pipeline, both platforms (see `.omo/evidence/`):

- **FLAC + MP3 decode:** `play sweep.flac (engineRunning=true)`, `enqueued sweep.mp3
  (queueIsEmpty=false)` — gapless enqueue confirmed.
- **Tap fires + FFT non-zero:** `tap samples=24000→316800 … fftPeak≈0.95 nonZero=YES`.
- **Spectrum animates:** the two macOS frames differ (MD5 `97aa5e1a…` ≠ `eb6f20c5…`); the
  chirp's moving peak is visible across `frame1`/`frame2`.
- **EQ actually affects the signal:** engaging a −24 dB cut on the 250 Hz–4 kHz bands drops
  the tapped window RMS from **0.316 → 0.0096** (~−30 dB) on macOS *and* iOS — proving the
  EQ is genuinely in the rendered path that the tap observes.
- **iOS mobile assumption CONFIRMED:** the one flagged risk — "SFB EQ-via-`modifyProcessingGraph`
  + `mainMixerNode` tap on iOS" — works on the simulator exactly as on macOS (log + screenshot).

### 3. Build / link / concurrency requirements discovered (downstream MUST apply these)

These are real and would block Tasks 8–10/19 if not carried forward:

1. **SFB links as a STATIC framework here → `OTHER_LDFLAGS` needs `-lc++` AND `-ObjC`.**
   `CSFBAudioEngine` is C++ (without `-lc++`: undefined `std::` symbols at link). Its decoder
   subclasses self-register at ObjC load time; without `-ObjC` the linker dead-strips them and
   SFB returns *"The type of the file could not be determined"* for FLAC/MP3. (Alternative:
   integrate SFB as a **dynamic** framework, which avoids both flags.)
2. **Xcode 26 Metal Toolchain is a separate downloadable component** and was absent, so
   build-time `.metal` compilation fails (`cannot execute tool 'metal'`). The spike compiles the
   shader at **runtime** via `device.makeLibrary(source:)` (works on macOS + iOS sim). Production
   should either `xcodebuild -downloadComponent MetalToolchain` in CI or keep runtime compilation.
3. **Swift 6 audio-thread invariant is enforced by the runtime.** A tap/render closure created
   inside a `@MainActor` type inherits `@MainActor` isolation; when AVFAudio invokes it on the
   render thread, `swift_task_checkIsolatedSwift` → `dispatch_assert_queue_fail` → **SIGTRAP**.
   The tap closure MUST be `@Sendable` (non-isolated) and touch only `Sendable`, pre-allocated
   state. This is the spike's confirmation that the zero-alloc/lock/ARC tap invariant is both
   achievable and machine-checked.

## Chosen graph

```
        ┌───────────────── SFBAudioPlayer (owns the AVAudioEngine) ──────────────────┐
        │                                                                            │
 decoder ─▶ sourceNode ─▶ AVAudioUnitEQ (10 bands) ─▶ mainMixerNode ─▶ outputNode ─▶ 🔊
 (FLAC/MP3   (AVAudioSourceNode)   globalGain =            │
  via SFB)                         ReplayGain              │  installTap(bus 0)  ← POST-EQ
                                                           ▼
                                       @Sendable tap: memcpy ch0 → SPSC ring buffer
                                       (no alloc / lock / ARC / log on the audio thread)
                                                           │  pull (no per-frame main.async)
                                                           ▼
                                       vDSP real FFT 4096 / Hann / hop 1024 → log bands
                                                           │
                                                           ▼
                                       Metal spectrum (~60 fps, pulls latest frame)
```

- EQ insertion is done once via `modifyProcessingGraph`; the
  `audioPlayer(_:reconfigureProcessingGraph:with:)` delegate re-establishes
  `EQ → mainMixer` (and re-installs the tap) on any sample-rate/channel change, using the
  **passed** format (the node's own format is stale during reconfiguration).
- Tap point is `mainMixerNode` (stereo → stereo), so the `AVAudioMixerNode` −3 dB mono pan
  law does not apply here; level-based DSP that taps a mono node must account for it.

## ReplayGain placement (invariant across A and B)

ReplayGain is applied through **`eq.globalGain`** (−96…+24 dB; both boost and attenuate),
set in the rendering-will-start delegate — **not** a separate AU. This placement is identical
whether the engine is Option A or B, so this decision is stable regardless of the A/B outcome.
Clip-guard: if `REPLAYGAIN_TRACK_PEAK × 10^(gain/20) > 1.0`, reduce the gain (optional
`kAudioUnitSubType_PeakLimiter` as a last-resort safety net).

## Crossfade go / no-go

**NO-GO for v1.** `SFBAudioPlayer` is a single-stream player with no native crossfade, and a
two-`SFBAudioPlayer` crossfade is not viable (each owns its own engine/output graph, and iOS
exposes no output-volume API on `SFBAudioPlayer`). If crossfade becomes a hard requirement, a
**future** spike must evaluate **Option C**: our own `AVAudioEngine` + two `AVAudioSourceNode`s
fed by SFB `AudioDecoder` PCM → per-source gain mixers → shared 10-band EQ → mainMixer (tap),
accepting the cost of reimplementing gapless continuity and format-change handling. Gapless,
EQ, ReplayGain, and the visualizer tap are unaffected by deferring crossfade.

## Consequences

- **Task 8 (engine):** implement `PlayerCore` audio around `SFBAudioPlayer`; carry the EQ
  insertion + reconfigure-delegate pattern; the `-lc++`/`-ObjC` (or dynamic-framework) linkage
  and the `@Sendable` tap rule are mandatory.
- **Task 9 (DSP/visualizer):** the SPSC-ring → vDSP-FFT → Metal pull pipeline in this spike is
  the validated shape (don't ship this code — re-implement in `PlayerCore` per the invariant).
- **Task 10 (gapless/ReplayGain):** gapless via `enqueue` pre-scheduled on `.dataConsumed`;
  ReplayGain via `eq.globalGain`.
- **Task 19 / crossfade:** parked behind a future Option-C spike; do not promise native crossfade.
- The plan must stop treating A and B as both-viable — **A is the architecture.**

## Evidence

- `.omo/evidence/task-7-spike-macos-frame1.png`, `…-frame2.png` — animating macOS spectrum (differ).
- `.omo/evidence/task-7-ios-spectrum.png` — spectrum rendering on iPhone 17 simulator.
- `.omo/evidence/task-7-ios-adr.txt` — iOS run log + the `Decision: Option A` grep.
- This spike is THROWAWAY: it lives only in `Spikes/`, never imported into `PlayerCore`.
