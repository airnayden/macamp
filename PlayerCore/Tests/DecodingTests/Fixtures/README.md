# DecodingTests fixtures

Small, committed audio fixtures for the `Decoding` module's Swift Testing suites.
They are loaded by path via `#filePath` (this directory is `exclude`d from the
build in `Package.swift`), so the tests stay hermetic and need no tooling at run
time. Each tone is a 440 Hz mono sine (DSD is 1 kHz stereo) so suites can assert
the decoded PCM peak frequency with `Analysis.peakBin`.

| File | What | How it was generated |
|------|------|----------------------|
| `tone.wav` | 440 Hz, 44.1 kHz, mono, 0.5 s, 32-bit float | `macamp-cli synth --tone 440 --rate 44100 --seconds 0.5 --out tone.wav` (dogfoods the offline render harness) |
| `tone.flac` | same tone, 16-bit FLAC | `ffmpeg -i tone.wav -c:a flac -sample_fmt s16 tone.flac` |
| `tone.mp3` | same tone, MP3 192 kbps CBR | `ffmpeg -i tone.wav -c:a libmp3lame -b:a 192k tone.mp3` |
| `tone.dsf` | 1 kHz, DSD64 (2.8224 MHz), stereo, 0.5 s | `python3 generate_dsf.py tone.dsf 1000 0.5 0.4` (ffmpeg cannot *encode* DSD) |
| `tone-dsd128.dsf` | 1 kHz, DSD128 (5.6448 MHz), stereo, 0.02 s | `python3 generate_dsf.py tone-dsd128.dsf 1000 0.02 0.4 5644800` — the REFUSAL fixture |
| `corrupt.flac` | `fLaC` magic + 512 garbage bytes | written by hand so SFB recognises the FLAC marker but rejects the stream |

## Regenerating

```sh
BIN=.build/arm64-apple-macosx/debug/macamp-cli   # after: swift build --product macamp-cli
FIX=PlayerCore/Tests/DecodingTests/Fixtures

"$BIN" synth --tone 440 --rate 44100 --seconds 0.5 --out "$FIX/tone.wav"
ffmpeg -y -i "$FIX/tone.wav" -c:a flac -sample_fmt s16 "$FIX/tone.flac"
ffmpeg -y -i "$FIX/tone.wav" -c:a libmp3lame -b:a 192k "$FIX/tone.mp3"
python3 "$FIX/generate_dsf.py" "$FIX/tone.dsf" 1000 0.5 0.4
python3 "$FIX/generate_dsf.py" "$FIX/tone-dsd128.dsf" 1000 0.02 0.4 5644800
python3 -c "open('$FIX/corrupt.flac','wb').write(b'fLaC'+bytes([0xDB])*512)"
```

`generate_dsf.py` synthesises a DSD64 bitstream with a 1st-order sigma-delta
modulator; the per-byte popcount carries the low-frequency tone, which the
SFBAudioEngine DSD→PCM decimation filter recovers (output PCM is 352.8 kHz).
The 0.4 amplitude keeps the tone clear of full scale after SFB's default +6 dB
DSD gain.

## The DSD128 refusal fixture

`tone-dsd128.dsf` exists to be **rejected**, so its audio content is irrelevant
and its duration is 0.02 s — just enough for four 4096-byte blocks per channel
(32 KB total). SFBAudioEngine converts DSD64 only, so `SFBDecoderProvider`
inspects the raw DSD rate at open and throws
`DecodingError.unsupportedSampleRate(url:detail:)` with the detail token
`"DSD128 (5644800 Hz)"`. DSD128/256/512 are never resampled.

The sample rate is the FIFTH positional argument; omitting it yields DSD64, so
the `tone.dsf` command above still regenerates that file byte-for-byte.
