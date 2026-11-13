# MetadataTests fixtures

Small, committed, fully-tagged audio fixtures for the `Metadata` module's Swift
Testing suites. They are loaded by path via `#filePath` (this directory is
`exclude`d from the build in `Package.swift`), so the tests stay hermetic and
need no tooling at run time.

Every file shares the **same logical tags** — a "The Beatles / Abbey Road"
track — so the suites assert NFC values, article-stripped sort keys (artist
`"The Beatles"` → sort key `"beatles"`), embedded cover art and ReplayGain from
one expectation set across all three containers.

| File | What | Carries |
|------|------|---------|
| `full.flac` | 16-bit FLAC, 44.1 kHz, stereo, 0.5 s | full Vorbis-comment tags + embedded PNG front cover + ReplayGain |
| `full.mp3` | MP3 192 kbps CBR, ID3v2.3 | full tags + embedded APIC PNG cover + ReplayGain TXXX frames |
| `full.m4a` | AAC in MP4 | tags + embedded `covr` PNG cover (no ReplayGain) |
| `corrupt.flac` | `fLaC` magic + 512 garbage bytes | parser claims then rejects → typed `MetadataError`, never a crash |

The `corrupt.flac` byte layout is identical to the Decoding module's fixture so
both layers exercise the same parser-claims-then-rejects path. The DecodingTests
`Fixtures/` are NOT modified by this target (read-only reuse policy); these are a
separate, self-contained set because metadata tests need rich tags the decode
tones do not carry.

## Regenerating

```sh
bash PlayerCore/Tests/MetadataTests/Fixtures/generate_fixtures.sh
```

`generate_fixtures.sh` synthesises a 440 Hz tone + a 64×64 crimson PNG cover with
ffmpeg, then encodes the three tagged containers and writes `corrupt.flac` by
hand. ReplayGain is written as standard `REPLAYGAIN_*` tags (Vorbis comments for
FLAC, `TXXX` frames for MP3); SFBAudioEngine / TagLib reads them back into the
native `replayGain*` properties. Requires `ffmpeg` (tested with 8.x) on `PATH`.
