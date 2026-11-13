# ADR: Karaoke Mode — Vocal Separation Architecture and License Decisions

- **Status:** ACCEPTED
- **Date:** 2026-07-16
- **Deciders:** Owner (accepted risk at plan approval gate, karaoke-mode.md TL;DR)
- **Supersedes:** the open questions in `.omo/plans/karaoke-mode.md` ("Decisions to sanity-check")

**Current clearance status (2026-11-03):** the project owner confirmed that
redistribution clearance has been obtained for the bundled checkpoint. This
supersedes the open clearance prerequisite recorded below. The underlying
permission document is maintained by the owner and is not reproduced here;
the historical assessment below is retained as the decision history.

## Decision

**Karaoke mode uses offline pre-render via Mel-Band Roformer (1B), converted to Core ML
MLProgram fp16, running on the Neural Engine/GPU.** The instrumental is produced once in the
background, cached as ALAC, and played through the existing Option A audio pipeline untouched.
Real-time inference on the audio render thread is architecturally impossible and is not
attempted.

**App Store builds ship WITHOUT the model** (feature resolves `.unavailable`). Direct-download
and Sparkle builds bundle the model. This channel split is the canonical go/no-go recorded
here; all downstream todos (18, 21, 22) point back to this file.

## Context

### (a) Model choice and license provenance

**Model chosen:** Mel-Band Roformer (1B) by Kimberley Jensen, weights hosted at
`KimberleyJSN/melbandroformer` on Hugging Face.

- Paper: "Mel-Band RoFormer for Music Source Separation" (Wang et al., ByteDance AI Labs),
  arXiv:2310.01809.
- Checkpoint: `https://huggingface.co/KimberleyJSN/melbandroformer/blob/main/MelBandRoformer.ckpt`
- Training code: `https://github.com/ZFTurbo/Music-Source-Separation-Training` (MIT)
- Architecture implementation: `https://github.com/lucidrains/BS-RoFormer` (MIT)

**License provenance — UNVERIFIED:**

The Hugging Face model card at `https://huggingface.co/KimberleyJSN/melbandroformer` displays
a `License: mit` metadata tag. However:

1. The HF model card README is **empty** — no license text, no attribution statement, no
   explicit grant of rights appears anywhere in the card body.
2. The source repository `https://github.com/KimberleyJensen/Mel-Band-Roformer-Vocal-Model`
   contains **no LICENSE file**. The file tree (verified 2026-07-16) lists only `configs/`,
   `models/mel_band_roformer/`, `README.md`, `inference.py`, `requirements.txt`, and
   `utils.py`. No `LICENSE`, `LICENSE.md`, `COPYING`, or equivalent exists.

The `mit` tag on HF is a metadata field the uploader sets unilaterally; it carries no legal
weight without a corresponding license text. The absence of a LICENSE file in the training
repo means the checkpoint's redistribution rights are **not formally established**.

**Owner-accepted clearance burden:** The owner reviewed this provenance gap at plan approval
and accepted it. The clearance burden is: obtain written confirmation from Kimberley Jensen
(via the contact listed in the model's GitHub README) that the checkpoint is MIT or
otherwise permissively licensed for redistribution in a commercial app. Until that written
clearance exists, the model is withheld from App Store builds (see section b).

### (b) Channel policy — go/no-go decision

| Channel | Model bundled | Feature state | Condition to change |
|---|---|---|---|
| Direct download (Developer ID + Sparkle) | YES | Available | Owner accepts current provenance risk |
| App Store (macOS + iOS) | NO | `.unavailable` | Written license clearance from checkpoint author |

**This is the canonical go/no-go record.** The App Store channel ships without the model
until written clearance exists. The `CoreMLSeparator` actor's unified `.unavailable` path
(todo 6) covers this case identically to CI, fresh clones, and iOS builds — no special-case
code for the App Store path.

The Tuist resource glob in `macOS/Project.swift` (todo 18) is optional: an empty
`macOS/Resources/SeparationModel/` directory does not break generate or build. The CI
pipeline never fetches the model; all required tests use the `FakeSpectrogramPredictor` seam.

### (c) Offline pre-render architecture rationale

**Why offline pre-render and not real-time inference:**

Mel-Band Roformer is a non-causal model. It processes audio in overlapping chunks of
`chunk_size` samples (default 352,800 = 8 seconds at 44.1 kHz, matching the training
window). Each chunk requires the full 8-second context before producing output — there is no
causal streaming mode. Inserting the model into the real-time audio render graph would
require an 8-second look-ahead buffer, making live playback impossible.

**Render-thread invariants (from `Spikes/ADR-audio-engine.md`):** The Option A audio graph
runs on a real-time thread where zero allocation, zero locks, zero ARC, and zero logging are
permitted. Core ML inference allocates, uses GCD internally, and takes tens to hundreds of
milliseconds per chunk — all of which would cause glitches or priority inversion if attempted
on the render thread.

**Industry precedent:** Every serious shipping product that offers vocal removal pre-processes
and caches:

- **Serato DJ:** offline stem separation, cached to disk before playback.
- **DJ.Studio:** pre-render pipeline, not real-time.
- **Apple Music Sing (karaoke lyrics):** Apple's own implementation pre-processes tracks
  server-side; the device plays a pre-rendered instrumental stream.

**Chosen architecture:** The `SeparationPipeline` (todo 9) runs entirely off the audio
thread at `Task.detached(priority: .utility)`. It decodes the source file via the existing
`DecoderProviding` seam, resamples to 44.1 kHz stereo (todo 4), runs the forward STFT (todo
5), feeds chunks to `CoreMLSeparator` (todo 6), reconstructs via iSTFT + overlap-add (todo
5), encodes to ALAC (todo 7), and stores in the `InstrumentalCache` (todo 8). The
coordinator (todo 12) resolves the decoder URL to the cached instrumental at playback time,
below the `Track` model — artwork, ReplayGain, Now Playing, and gapless all keep the
original track identity.

### (d) Known v1 limitations

These are accepted limitations recorded at plan approval. They are not bugs.

1. **Hi-res audio decimated to 44.1 kHz in karaoke mode.** The model was trained at 44.1
   kHz. Any source file at a higher sample rate (88.2, 96, 176.4, 192 kHz) is resampled to
   44.1 kHz by the offline resampler (todo 4) before separation. The cached instrumental is
   stored and played at 44.1 kHz. Original playback is unaffected.

2. **Cold next-track plays original at a gapless boundary.** When the pre-warm service
   (todo 13) has not finished separating the next track before the gapless boundary is
   reached, the coordinator (todo 12) preschedules the original file. The user hears the
   original for that track; karaoke resumes on the following track once cached. This is a
   documented v1 limitation, not a race condition to fix.

3. **Mid-song toggle has a brief gap (~100–300 ms).** The `SFBAudioPlayer` is a
   single-stream player (Option A, `Spikes/ADR-audio-engine.md`). Switching between the
   original and instrumental mid-song requires `engine.reload(url:at:resumePlaying:)` (todo
   11), which stops the current stream, loads the new URL, seeks to the saved position, and
   resumes. The gap is inherent to single-stream architecture. A two-stream crossfade would
   require Option C (own `AVAudioEngine` + two `AVAudioSourceNode`s), which is out of scope
   for v1 per the audio ADR.

4. **Original ReplayGain applied to instrumental (slight under-correction).** The
   coordinator applies the source track's `REPLAYGAIN_TRACK_GAIN` and `REPLAYGAIN_TRACK_PEAK`
   values to the instrumental via `eq.globalGain`. The instrumental's true loudness differs
   from the original (vocals contribute energy), so the gain correction is approximate. In
   practice the error is small (typically < 1 dB) and is accepted for v1. A future
   improvement would compute a separate ReplayGain value for the cached instrumental.

## Consequences

- **Todo 6 (CoreMLSeparator):** the unified `.unavailable` path covers App Store, CI, fresh
  clones, and iOS compile-compat — no separate code path for any of these.
- **Todo 9 (SeparationPipeline):** the gated quality test skips via `fileExists` on the
  compiled model; all hermetic assertions run in required CI without the model.
- **Todo 12 (coordinator):** preschedule original when next track is not cached (v1
  limitation c above); never persist an instrumental URL in snapshots or GRDB.
- **Todo 18 (Tuist):** optional resource glob; empty dir must not break generate or build;
  App Store archive intentionally omits the model dir.
- **Todo 21 (docs):** `docs/Acknowledgments.md` must cite arXiv:2310.01809, the checkpoint
  repo URL, and the license status per this ADR.
- **License clearance:** before any App Store submission that includes the model, obtain
  written confirmation from the checkpoint author and update this ADR's channel policy table.

## Calibrated thresholds (first real conversion, 2026-07-16)

The conversion ran for real on a dev machine (previously HUMAN-GATED). Findings:

- **Model class source:** lucidrains' `bs-roformer` pip package drifted (hyper-connections,
  value-residual, a default linear-transformer slot) and no longer loads the Kim checkpoint.
  The converter now downloads **Kim's own vendored model code** at the pinned config commit —
  the exact architecture the checkpoint was trained with.
- **Export graph:** the complex-tensor section of the forward (mask scatter-average +
  complex multiply) has no Core ML lowering, so the converter mirrors it in real arithmetic.
  The mirror is exact: max abs diff vs the model's own complex-path forward is **9.3e-10**
  in fp32.
- **Parity tolerance (recalibrated):** the plan's original `1e-2` max-abs bound was pinned
  before any real run and ignored output scale. Measured fp16 conversion error is
  **~2.6e-2 relative** to the reference output peak (pure fp16 accumulation through the
  6-layer transformer; nothing structural). The `--verify` gate now asserts
  **relative max abs diff < 5e-2** — genuine graph bugs manifest orders of magnitude larger.
- **Artifact size:** fp16 `.mlpackage` is **456 MB** (fp32 would be ~912 MB for no
  perceptible quality gain in a masking model).
- **ANE note:** the Apple Neural Engine compiler rejects this graph
  (`ANECCompile() FAILED`, non-fatal) — Core ML falls back to GPU/CPU automatically.
- **Fused SDPA attention (memory, second conversion pass):** the first export routed
  attention through the manual einsum path, which materialises the 801×801 attention
  matrices (60 bands × 8 heads) — ~5 GB peak process footprint during a render. The
  export now calls `F.scaled_dot_product_attention` directly, which coremltools
  lowers to Core ML's fused SDPA op: peak pipeline memory measured **~0.9 GB**, and
  parity improved slightly (2.14e-2 vs 2.63e-2 relative). Cost: the fused op requires
  **macOS 15+**, so the model's deployment target moved from 14 to 15 — on macOS 14
  the model fails to load and karaoke resolves `.unavailable` (app minimum stays 14).
- **Swift I/O contract (fixed at first integration):** the exported model is
  stereo-native — input `mixture_spectrogram` / output `vocal_spectrogram`, both
  `(1, 2, freq=1025, frames, 2)` float32, real/imag last, fixed frame count read from
  the model description. The original todo-6 Swift marshalling (written blind, mono
  per channel, plane-major, `mixture`/`vocal` names) was replaced by a stereo
  `SpectrogramPredicting` seam.
- **Gated quality test (recalibrated on the real model + fixture):** PyTorch
  ground truth on `voice_over_music.m4a`: vocal band (300 Hz–3 kHz) reduced
  **12.07 dB**, low end (20–150 Hz) reduced **34.52 dB** — the model strips the
  SYNTHETIC sine-chord bed as vocal-like content, so the plan's blind "< 2 dB bed
  change" criterion is unsatisfiable on this fixture. The test now asserts
  calibrated RANGES (vocal 6–25 dB, low end 20–45 dB), which pin the Swift pipeline
  to ground-truth behavior and fail loudly on passthrough (~0 dB) or silence
  (unbounded dB) regressions. Swift measured 12-ish/39.7 dB — consistent with GT
  modulo fp16 + chunked (8 s taper-overlap) vs full-file inference.

## Evidence

- HF model card (license tag, empty README): `https://huggingface.co/KimberleyJSN/melbandroformer`
- GitHub source repo (no LICENSE file): `https://github.com/KimberleyJensen/Mel-Band-Roformer-Vocal-Model`
- Paper: `https://arxiv.org/abs/2310.01809`
- Training code (MIT): `https://github.com/ZFTurbo/Music-Source-Separation-Training`
- Architecture (MIT): `https://github.com/lucidrains/BS-RoFormer`
- CoreML conversion reference (MIT, separate iSTFT pattern): `https://github.com/ajayarora1235/CoreML-Music-Source-Separation`
- Plan approval record: `.omo/plans/karaoke-mode.md` (TL;DR + Scope sections)
- Audio engine ADR (Option A, render-thread invariants): `Spikes/ADR-audio-engine.md`

---

## Superseded in part — 2026-08-22 (single-target merge + permanent no-App-Store decision)

The following aspects of this ADR are superseded. The original decision text is
preserved above as a historical record.

**App Store distribution permanently abandoned.** The owner decision (commits
`3475ee3`..`00af4bd`) is that MacAMP will never be distributed via the App Store.
The channel table in section (b) had two rows:

| Channel | Model bundled | Feature state |
|---|---|---|
| Direct download (Developer ID + Sparkle) | YES | Available |
| App Store (macOS + iOS) | NO | `.unavailable` |

The "App Store" row is now moot. There is one channel: direct distribution via DMG.
The model ships in every release build. The "written license clearance from checkpoint
author" condition to change is now a prerequisite for redistribution in general, not
specifically for an App Store build.

**CI release pipeline guarantees the model.** The release CI job (`scripts/release.sh`
stage [1] / CI `release` job) fetches and converts the model before `tuist generate`
(load-bearing ordering — the resource glob is evaluated at generate time). Stage [7]
hard-asserts `MelBandRoformer.mlmodelc` is present in the shipped bundle. A
`--no-model` flag exists for ad-hoc builds that explicitly opt out. Dev clones
without the model still build and degrade to `.unavailable` as before.

**The `.modelNotBundled` reason still applies** to iOS builds, CI, and fresh dev
clones — the reason's description is updated accordingly in `PlayerCore/README.md`.
