# CueTests fixtures

Hand-written `.cue` sheets. Text only — **no audio ships here on purpose**: the parser
must never decode or read tags, so the tests resolve `FILE` operands through a stub
locator, and the one test that uses the real `FileManagerCueAudioFileLocator` relies on
this directory having no audio in it to prove the unresolved-reference path.

`Fixtures/` is `exclude`d in `Package.swift` and loaded by `#filePath`, matching the
Decoding / Metadata / PlaylistIO fixture pattern.

| File | Shape | Why it exists |
|---|---|---|
| `standard-single-file.cue` | One `FILE`, 4 tracks, one `INDEX 00`, one `PREGAP` | The common single-file album rip. Pins exact `INDEX 01` → frame arithmetic and the "track ends where the next one starts" rule. |
| `multi-file.cue` | Three `FILE`s, one track each, compliant | Proves offsets restart per `FILE`: track 2 starts at frame 183 (`00:02:33`), not at a cumulative disc offset. |
| `eac-appended-gaps.cue` | Three `FILE`s, tracks 2 and 3 declared TWICE | The non-compliant EAC "gaps appended to previous track" variant. Each trailing `INDEX 00`-only declaration sits in the PRIOR file's block. |
| `eac-compliant-twin.cue` | Same album, compliant | The normalization target. `eac-appended-gaps.cue` must resolve to a byte-identical segment list. |
| `malformed-missing-index01.cue` | One `FILE`, track 2 has `INDEX 00` and no `INDEX 01` | Textually the same orphan shape as the EAC variant, but with no later `FILE` to fold into — so it must be refused as `missingIndexOne(trackNumber: 2, line: 8)` rather than silently accepted. This pair is what pins the fold's precondition. |

## Frame arithmetic

`MM:SS:FF` at 75 frames per second → `(MM·60 + SS)·75 + FF`.

| Timecode | Frames |
|---|---|
| `00:00:00` | 0 |
| `00:02:00` | 150 |
| `00:02:33` | 183 |
| `04:41:25` | 21100 |
| `04:43:00` | 21225 |
| `05:20:40` | 24040 |
| `05:42:03` | 25653 |
| `08:27:37` | 38062 |
| `12:47:15` | 57540 |
