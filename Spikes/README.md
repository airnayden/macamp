# Spikes — throwaway audio architecture spike (Task 7)

> **THROWAWAY.** This folder exists only to make the Phase 0 audio-engine decision
> empirically. None of this code is imported into `PlayerCore` or shipped.

The decision and full rationale live in **[ADR-audio-engine.md](ADR-audio-engine.md)** —
**Decision: Option A** (`SFBAudioPlayer`; native crossfade deferred), because
`SFBAudioPlayerNode` does not exist in the pinned SFBAudioEngine 0.12.1, which makes
Option B unbuildable.

## What it proves

`SpikeAudio` is one multiplatform SwiftUI app (macOS + iOS) that runs the end-to-end pipeline
on **both** platforms:

```
SFBAudioPlayer decode (FLAC + MP3) -> 10-band AVAudioUnitEQ -> installTap(mainMixer, post-EQ)
  -> lock-free SPSC ring buffer -> vDSP FFT (4096 / Hann / hop 1024) -> Metal spectrum (~60 fps)
```

It demonstrates gapless `enqueue`, EQ insertion via `modifyProcessingGraph` + the
`reconfigureProcessingGraph` delegate, a `@Sendable` (audio-thread-safe) tap, and that the EQ
is genuinely in the rendered signal path (a -24 dB mid cut drops the tapped RMS ~30x).

## Layout

- `SpikeAudio/` — app sources (engine, FFT, ring buffer, Metal view + offscreen snapshot,
  runtime-compiled shader, SwiftUI harness) and `Resources/sweep.{flac,mp3}` fixtures.
- `Project.swift`, `Tuist.swift`, `Tuist/Package.swift` — a self-contained Tuist project,
  isolated from the repo-root workspace.

## Test fixtures

`SpikeAudio/Resources/sweep.flac` and `sweep.mp3` are 8 s, 44.1 kHz stereo chirps generated
with ffmpeg (rising 200->2 kHz tone + harmonic for FLAC; a 1.5 kHz->750 Hz tremolo tone for
MP3) so the spectrum visibly animates. Regenerate, e.g.:

```sh
ffmpeg -f lavfi -i "aevalsrc=exprs='0.4*sin(2*PI*(200*t+112.5*t*t))':d=8:s=44100" -c:a flac sweep.flac
```

## Reproduce

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
tuist install  --path Spikes
tuist generate --path Spikes --no-open

# macOS (headless: writes two spectrum PNGs ~1 s apart via SPIKE_SNAPSHOT_DIR, then exits)
xcodebuild -workspace Spikes/Spike.xcworkspace -scheme SpikeAudio -destination 'platform=macOS' \
  -derivedDataPath Spikes/.build/DerivedData build
SPIKE_SNAPSHOT_DIR=/abs/out \
  Spikes/.build/DerivedData/Build/Products/Debug/SpikeAudio.app/Contents/MacOS/SpikeAudio

# iOS simulator
xcodebuild -workspace Spikes/Spike.xcworkspace -scheme SpikeAudio -destination 'id=<SIM_UDID>' \
  ONLY_ACTIVE_ARCH=YES -derivedDataPath Spikes/.build/DerivedData build
xcrun simctl install booted Spikes/.build/DerivedData/Build/Products/Debug-iphonesimulator/SpikeAudio.app
xcrun simctl launch booted com.example.macamp.spike
```

Build notes are encoded in `Project.swift`: SFB links statically here, so the app needs
`OTHER_LDFLAGS = -lc++ -ObjC`; the shader is compiled at runtime to dodge the separately
downloadable Xcode 26 Metal Toolchain.
