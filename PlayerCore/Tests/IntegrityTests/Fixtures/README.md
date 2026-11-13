# IntegrityTests fixtures

This directory is `exclude:`d from the `IntegrityTests` target in `Package.swift`,
so anything placed here is a resource read by path — never compiled.

## What does NOT live here

**The FLAC MD5 fixtures (todo 26).** They are encoded IN-TEST by
`FLACFixtureWriter`, through SFBAudioEngine's own FLAC encoder, from a
deterministic integer signal. That is deliberate, and it is the stronger design:

- A committed `.flac` would have to be *trusted*. An in-test encode makes the
  encoder the oracle — `FLAC__stream_encoder_finish` rewrites STREAMINFO with
  libFLAC's own MD5 of the samples it was handed, so a `.match` verdict proves
  MacAMP's canonical-sample reconstruction agrees with libFLAC's, sample for
  sample. A checked-in file can only prove the digest is stable.
- Regenerating a committed fixture would need an external tool at some point in
  its life, and the plan forbids test-time tool invocation.

The mismatch and "no stored MD5" cases are produced by patching a **temp copy**
of that encoder output in the STREAMINFO checksum field — see `FLACStreamInfo`.

## What this directory is for

Committed binary fixtures for the fake-lossless spectral detector (todo 27),
which genuinely cannot be synthesised in-test: they require a real lossy
encoder round trip (a FLAC transcoded from a 128 kbps MP3) plus a true-lossless
twin of the same signal as the false-positive guard.

## The spectral-detector fixtures (todo 27)

| File | What it is | What it proves |
|---|---|---|
| `wideband-lossless.flac` | The source signal, FLAC-encoded directly | **False-positive guard.** Its spectrum is flat to Nyquist, so a detector that invents a cutoff is caught. Must read `.consistent`. |
| `wideband-transcoded-128k.flac` | The same source, laundered through a 128 kbps MP3 | The lowpass a lossy encoder leaves behind. Must read `.suspectTranscode` with a cutoff of 15.5–16.5 kHz. |

Both derive from ONE source: 1.0 s of stereo 44.1 kHz / 16-bit white noise from a
seeded LCG (`SEED = 20260920`), peak 0.30, with 5 ms fades. White noise is the
choice because its long-term average spectrum is **flat all the way to Nyquist** —
that is exactly what makes the lossless twin a real guard, and it gives the
transcoded twin a clean cliff instead of a rolloff that has to be argued about.

`generate-fixtures.sh` next to them is the reproducible recipe (python3 + lame +
ffmpeg). **The tests never run it** — they only read the two committed `.flac`
files. Shelling out to an encoder from a test would break hermeticity, which is
why the artifacts are committed in the first place.

The MP3 stage passes `--lowpass 16`, pinning LAME's polyphase transition band at
15826–16360 Hz. LAME's own default for stereo 128 kbps CBR is 16538–17071 Hz —
a real edge, but high enough that the measured cutoff lands at ~17.1 kHz, outside
the band this fixture is supposed to demonstrate. 16 kHz is both the figure the
plan specifies and the lowpass a great many real 128 kbps encoders use.

Measured against the shipped estimator: transcoded **≈16.25 kHz** (ratio 0.737),
lossless **≈22.04 kHz** (ratio 1.000).
