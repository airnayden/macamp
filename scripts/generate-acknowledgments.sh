#!/usr/bin/env bash
#
# generate-acknowledgments.sh — MacAMP open-source acknowledgments generator
#
# Aggregates the third-party software MacAMP bundles into a single human-readable
# document (docs-site/content/docs/acknowledgments.mdx, the shipped Fumadocs
# page). The Swift Package Manager dependencies are read straight from the
# resolved lockfile (Tuist/Package.resolved) so the version numbers can never
# drift from what actually ships; each package identity is mapped to its license
# + role via a curated license map (the `license_for` function below). Non-SPM
# assets that are vendored or injected at runtime — the projectM (MilkDrop)
# visualizer, its preset + texture packs, the General-MIDI SoundFont, and the
# karaoke separation model — are appended as curated sections, INCLUDING their
# explicit redistribution terms.
#
# The output is deterministic (no timestamp) so CI can diff it: a stale doc means
# a dependency changed and the doc was not regenerated.
#
# Keep two things in sync when a dependency changes:
#   1. the `license_for` map in this script (drives acknowledgments.mdx), and
#   2. `Acknowledgments.all` in
#      PlayerCore/Sources/DesignSystem/Acknowledgments/Acknowledgment.swift
#      (drives the in-app Acknowledgments screen).
#
# Bash 3.2 compatible (macOS system bash): NO associative arrays.
#
#   exit 0  -> docs-site/content/docs/acknowledgments.mdx written
#   exit 2  -> Tuist/Package.resolved not found
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

PACKAGE_RESOLVED="Tuist/Package.resolved"
OUT_DIR="docs-site/content/docs"
OUT="${OUT_DIR}/acknowledgments.mdx"

if [[ ! -f "${PACKAGE_RESOLVED}" ]]; then
  echo "error: ${PACKAGE_RESOLVED} not found (run from a MacAMP checkout)" >&2
  exit 2
fi

mkdir -p "${OUT_DIR}"

# Extract the quoted value from a `"key" : "value"` JSON line. Prints nothing when
# the line has no quoted value (e.g. the lockfile's top-level `"version" : 3`).
json_value() {
  printf '%s\n' "$1" | sed -nE 's/.*:[[:space:]]*"([^"]*)".*/\1/p'
}

# Curated license map: package identity -> "Display Name|License|Role".
# A package not listed here still appears in the doc (falls through to the wildcard)
# so a newly-added dependency can never silently vanish from the acknowledgments.
license_for() {
  case "$1" in
    sfbaudioengine)             printf '%s' 'SFBAudioEngine|MIT|Audio decoding & playback engine' ;;
    avfaudioextensions)         printf '%s' 'AVFAudioExtensions|MIT|SFBAudioEngine support library' ;;
    cxxaudioringbuffer)         printf '%s' 'CXXAudioRingBuffer|MIT|SFBAudioEngine support library' ;;
    cxxringbuffer)              printf '%s' 'CXXRingBuffer|MIT|SFBAudioEngine support library' ;;
    cxxdispatchsemaphore)       printf '%s' 'CXXDispatchSemaphore|MIT|SFBAudioEngine support library' ;;
    cxxunfairlock)              printf '%s' 'CXXUnfairLock|MIT|SFBAudioEngine support library' ;;
    cxxtaglib)                  printf '%s' 'TagLib (CXXTagLib)|LGPL-2.1-or-later / MPL-1.1|Audio metadata reader' ;;
    cxxmonkeysaudio)            printf '%s' "Monkey's Audio (CXXMonkeysAudio)|BSD-3-Clause|Lossless APE decoder" ;;
    cdumb)                      printf '%s' 'DUMB (CDUMB)|BSD-like (DUMB license)|Tracker/module decoder' ;;
    cspeex)                     printf '%s' 'Speex (CSpeex)|BSD-3-Clause (Xiph.Org)|Speech codec' ;;
    flac-binary-xcframework)    printf '%s' 'FLAC / libFLAC|BSD-3-Clause (Xiph.Org)|Lossless codec' ;;
    lame-binary-xcframework)    printf '%s' 'LAME|LGPL-2.0-or-later|MP3 encoder/decoder' ;;
    mpc-binary-xcframework)     printf '%s' 'Musepack (libmpcdec)|BSD-3-Clause|Lossy codec' ;;
    mpg123-binary-xcframework)  printf '%s' 'mpg123|LGPL-2.1-only|MP3 decoder' ;;
    ogg-binary-xcframework)     printf '%s' 'Ogg / libogg|BSD-3-Clause (Xiph.Org)|Container format' ;;
    opus-binary-xcframework)    printf '%s' 'Opus / libopus|BSD-3-Clause (Xiph.Org)|Lossy codec' ;;
    sndfile-binary-xcframework) printf '%s' 'libsndfile|LGPL-2.1-or-later|PCM / WAV / AIFF / CAF I/O' ;;
    tta-cpp-binary-xcframework) printf '%s' 'True Audio (TTA)|LGPL-2.1-or-later|Lossless codec' ;;
    vorbis-binary-xcframework)  printf '%s' 'Vorbis / libvorbis|BSD-3-Clause (Xiph.Org)|Lossy codec' ;;
    wavpack-binary-xcframework) printf '%s' 'WavPack|BSD-3-Clause|Lossless / hybrid codec' ;;
    grdb.swift)                 printf '%s' 'GRDB.swift|MIT|SQLite application database' ;;
    sparkle)                    printf '%s' 'Sparkle|MIT (macOS only)|Software-update framework' ;;
    eventsource)                printf '%s' 'EventSource|MIT|Server-sent event transport' ;;
    swift-atomics)              printf '%s' 'Swift Atomics|Apache-2.0 with Swift exception|Atomic operations' ;;
    swift-collections)          printf '%s' 'Swift Collections|Apache-2.0 with Swift exception|Collection data structures' ;;
    swift-log)                  printf '%s' 'SwiftLog|Apache-2.0|Logging' ;;
    swift-nio)                  printf '%s' 'SwiftNIO|Apache-2.0|Asynchronous networking' ;;
    swift-sdk)                  printf '%s' 'MCP Swift SDK|Apache-2.0 / MIT (see upstream LICENSE)|Model Context Protocol transport' ;;
    swift-system)               printf '%s' 'Swift System|Apache-2.0 with Swift exception|System interfaces' ;;
    *)                          printf '%s' "$1|See upstream project|Dependency" ;;
  esac
}

# --- Header (Fumadocs frontmatter + intro) ----------------------------------------

cat > "${OUT}" <<'HEADER'
---
title: Acknowledgments
description: Open-source libraries, assets, and AI model components used in MacAMP, with license information.
---

{/* Generated from scripts/generate-acknowledgments.sh and docs/translation-review.md */}

MacAMP plays local music and performs audio analysis and karaoke separation on
your device. It contains no advertising or third-party analytics. Optional online
features send requests to their services: metadata and lyrics lookup, artist and
album information, downloads, software updates, and configured AI connectors.
Cloud AI receives the messages and library information allowed by your connector
permissions. Enabling external MCP access lets a local client read the library
information exposed by its tools. See the settings disclosures and each app's
bundled `PrivacyInfo.xcprivacy` for the relevant controls.

## MacAMP

MacAMP is free software by **Nayden Panchev** ([drpanchev.com](https://drpanchev.com)),
licensed under the [GNU General Public License v3.0](https://github.com/airnayden/macamp/blob/main/LICENSE)
with the additional attribution and naming terms in its
[NOTICE](https://github.com/airnayden/macamp/blob/main/NOTICE) file. Source code:
[github.com/airnayden/macamp](https://github.com/airnayden/macamp).

MacAMP is built with — and gratefully acknowledges — the open-source software
listed below. Each component remains under its own license; the names and links
here point to the canonical upstream project and full license text.

## Open-source libraries (Swift Package Manager)

The following Swift packages are resolved and linked into the app. Versions are
read verbatim from `Tuist/Package.resolved`.

HEADER

# --- SPM dependencies (parsed from Package.resolved) -----------------------------

cur_identity=""
cur_location=""
cur_version=""

flush_pin() {
  [[ -n "${cur_identity}" ]] || return 0
  local mapped display license role version_label
  mapped="$(license_for "${cur_identity}")"
  IFS='|' read -r display license role <<< "${mapped}"
  if [[ -n "${cur_version}" ]]; then
    version_label="v${cur_version}"
  else
    version_label="(pinned revision)"
  fi
  {
    printf -- '- **%s** — %s — %s<br />\n' "${display}" "${license}" "${version_label}"
    printf -- '  %s — [%s](%s)\n' "${role}" "${cur_location}" "${cur_location}"
  } >> "${OUT}"
  cur_location=""
  cur_version=""
}

while IFS= read -r line; do
  case "${line}" in
    *'"identity"'*)
      # A new pin begins at every identity line — flush the previous one first.
      flush_pin
      cur_identity="$(json_value "${line}")"
      ;;
    *'"location"'*)
      cur_location="$(json_value "${line}")"
      ;;
    *'"version" : "'*)
      cur_version="$(json_value "${line}")"
      ;;
  esac
done < "${PACKAGE_RESOLVED}"
flush_pin

# --- Curated, non-SPM bundled / injected assets ----------------------------------

cat >> "${OUT}" <<'ASSETS'

## Audio engine note

The codec libraries above are consumed through **SFBAudioEngine**. The LGPL-licensed
codecs (mpg123, libsndfile, True Audio, LAME) ship as dynamically-linked
XCFrameworks so the LGPL relink requirement is satisfied; the BSD/MIT codecs may be
linked statically or dynamically.

## Visualizer — projectM / MilkDrop (macOS only)

The projectM (MilkDrop) visualizer is OpenGL-based and LGPL-licensed. It ships in
the `macampMac` target (compiled with `MACAMP_PROJECTM`, dynamically linked) and
never on iOS.

- **libprojectM 4.1.6** — LGPL-2.1 — dynamically linked (`libprojectM-4.4.dylib`,
  embedded under `Contents/Frameworks`, loaded via `@rpath`). MacAMP's one-file
  patch is kept under the LGPL. Full text and notice:
  `macOS/Vendor/projectM/LICENSE-projectM-LGPL-2.1.txt` and
  `macOS/Vendor/projectM/ACKNOWLEDGMENTS-projectM.md`.

### Preset pack — "Cream of the Crop" (MilkDrop presets)

- **Source**: [https://github.com/projectM-visualizer/presets-cream-of-the-crop](https://github.com/projectM-visualizer/presets-cream-of-the-crop)
- **License / redistribution terms (explicit)**: MilkDrop presets were, in almost
  all cases, not released under any specific license. Each preset author retains
  copyright, but because the presets were freely released and have been bundled and
  redistributed across many applications for two decades, they are treated as
  **public domain**. If a preset author does not want their creation included, the
  projectM team removes the preset(s) from future releases. MacAMP bundles a curated
  allowlist subset (~40 presets), not the full pack. Full text:
  `macOS/Vendor/projectM/LICENSE-presets-cream-of-the-crop.md`.

### Texture pack — "MilkDrop Texture Pack"

- **Source**: [https://github.com/projectM-visualizer/presets-milkdrop-texture-pack](https://github.com/projectM-visualizer/presets-milkdrop-texture-pack)
- **License / redistribution terms (explicit)**: the pack collects the textures
  originally released with MilkDrop plus commonly-used community textures, and is
  recommended for bundling with any projectM application that ships presets. The
  presets reference these textures via `projectm_set_texture_search_paths`. See
  `macOS/Vendor/projectM/README-texture-pack.md`.

## SoundFont — General-MIDI instrument bank

MacAMP renders MIDI files through Apple's `AVAudioUnitSampler`, loaded with the
**GeneralUser GS** SoundFont by S. Christian Collins as its General-MIDI instrument
bank.

- **Name**: GeneralUser GS
- **Author**: S. Christian Collins
- **License**: GeneralUser GS License (custom, royalty-free)
- **Source**: [https://www.schristiancollins.com/generaluser.php](https://www.schristiancollins.com/generaluser.php)
- **Redistribution terms (explicit)**:
  - Free to use and distribute **bundled inside** software, games and other
    products — including commercial ones — with **no royalties** and **no
    attribution requirement**.
  - When the SoundFont is redistributed **by itself** (a standalone `.sf2` file
    rather than embedded in an application), the accompanying license and
    documentation text **must** be included, and the SoundFont may **not** be sold
    on its own.
  - MacAMP bundles the bank **inside** the application, so the embedded-use terms
    apply; the upstream license/readme is shipped alongside the bank in the app's
    resources for completeness.

> Repository note: only a tiny, self-authored test fixture
> (`PlayerCore/Tests/MIDITests/Fixtures/tiny.sf2` — public domain, MacAMP-owned) is
> currently committed to the repository. The production GeneralUser GS bank is
> injected into the sampler by the app shell at runtime; its `.sf2` file and
> license/readme must be placed in the app's bundled resources before MIDI playback
> ships.

## Karaoke mode — AI model and tooling

Karaoke mode uses an offline vocal-separation pipeline built on the following
components. Standard macOS releases include the model. Karaoke separation is
unavailable in iOS builds and macOS builds without the model. The model
provenance and owner confirmation are recorded in `Spikes/ADR-karaoke-separation.md`.

### Mel-Band Roformer (vocal separation model)

- **Paper:** "Mel-Band RoFormer for Music Source Separation" — Wang et al.,
  ByteDance AI Labs — arXiv:2310.01809 — [https://arxiv.org/abs/2310.01809](https://arxiv.org/abs/2310.01809)
- **Checkpoint author:** Kimberley Jensen
- **Checkpoint repository:** [https://huggingface.co/KimberleyJSN/melbandroformer](https://huggingface.co/KimberleyJSN/melbandroformer)
- **Training code (MIT):** [https://github.com/ZFTurbo/Music-Source-Separation-Training](https://github.com/ZFTurbo/Music-Source-Separation-Training)
- **Architecture implementation (MIT):** [https://github.com/lucidrains/BS-RoFormer](https://github.com/lucidrains/BS-RoFormer)

**Redistribution clearance:** the project owner confirmed on 2026-11-03 that
clearance has been obtained for the bundled checkpoint. The confirmation is
recorded in `Spikes/ADR-karaoke-separation.md`; the underlying permission record
is maintained by the owner. This notice does not assign the model weights the
licenses of the separate training or architecture code.

### coremltools (model conversion, build-time only)

The Mel-Band Roformer checkpoint is converted to Core ML MLProgram fp16 format
using Apple's **coremltools** library. coremltools is used at build time only and
is not bundled in the app.

- **License:** BSD-3-Clause
- **Source:** [https://github.com/apple/coremltools](https://github.com/apple/coremltools)

## Downloads — yt-dlp and ffmpeg (macOS only)

The YouTube downloader feature ships two bundled command-line tools. Both are
macOS-only (`macampMac`). They are copied out of the app bundle to
`~/Library/Application Support/MacAMP/Tools/` on first use and are never part
of `PlayerCore`.

### yt-dlp

- **Pinned version:** 2026.08.19
- **Upstream source:** [https://github.com/yt-dlp/yt-dlp](https://github.com/yt-dlp/yt-dlp)
- **Asset:** `yt-dlp_macos.zip` — the universal (x86_64 + arm64) PyInstaller **one-directory** build, macOS 10.15+. It ships in the app bundle as a whole directory tree at `Contents/Resources/yt-dlp/`: a `yt-dlp_macos` launcher plus a sibling `_internal/` holding the CPython runtime and ~100 shared libraries. The launcher resolves `_internal/Python` at startup, so the two are inseparable.
- **Source license:** [The Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE) — yt-dlp's own source code is in the public domain.
- **Shipped binary license:** The macOS release asset is a **PyInstaller bundle** — a combined work that packages yt-dlp's Unlicense source together with the CPython interpreter and several GPL-licensed runtime libraries. Per yt-dlp's own release documentation, the resulting binary is a **GPLv3+ combined work**. Shipping it as a directory rather than a single file changes the packaging, not the licence: every one of those libraries is the same combined work, and the offer below covers all of it.
- **Source offer:** the in-bundle `SOURCE-OFFER.txt` (shipped flat under `Contents/Resources/`, beside the `yt-dlp/` tree rather than inside it) provides the written offer required by GPLv3 §6(b). It cites yt-dlp's source repository at the pinned release tag as the corresponding source.

### ffmpeg and ffprobe

- **Pinned version:** 9.0.1
- **Build source:** [https://git.martin-riedl.de/ffmpeg/build-script](https://git.martin-riedl.de/ffmpeg/build-script) — Martin Riedl's open-source macOS static build service ([https://ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de))
- **Upstream source:** [https://ffmpeg.org](https://ffmpeg.org) / [https://git.ffmpeg.org/ffmpeg.git](https://git.ffmpeg.org/ffmpeg.git)
- **License:** The shipped binary is configured with `--enable-gpl` and `--enable-version3` (without `--enable-nonfree`), making it a **GPLv3** static build. This matches the GPLv3+ yt-dlp binary it ships alongside, giving the bundled tool set a single license story.
- **Source offer:** the in-bundle `SOURCE-OFFER.txt` cites the build recipe URL as the corresponding source for the GPL build.

> **Opus quality note:** when a YouTube source is already served as an opus
> stream, yt-dlp remuxes (stream-copies) rather than re-encoding. The
> `--audio-quality` flag is therefore inert for those items, which avoids a
> generation-loss opus-to-opus transcode.

## Test and development infrastructure

The following components are used at build/test time only and are not shipped in the app binary.

### libbs2b (crossfeed reference vectors)

The crossfeed kernel (`PlayerCore/Sources/DSP/CrossfeedKernel.swift`) is validated against
ground-truth impulse responses generated from **libbs2b 3.1.0**. The library's C source
(`vendor/bs2b.c` and three headers) is committed verbatim under
`tools/fixtures/bs2b/vendor/` solely to compile a tiny fixture generator; neither the
C source nor any compiled output ships in the app.

- **Upstream project:** [libbs2b — Bauer stereophonic-to-binaural DSP](https://bs2b.sourceforge.net/)
- **Version:** 3.1.0
- **Author:** Boris Mikhaylov
- **License:** MIT — see `tools/fixtures/bs2b/vendor/COPYING`
- **Tarball SHA-256:** `6aaafd81aae3898ee40148dd1349aab348db9bfae9767d0e66e0b07ddd4b2528`
  (cross-checked against the Homebrew formula pin — see `tools/fixtures/bs2b/README.md`)

## Apple frameworks

MacAMP builds on Apple's SDK frameworks (SwiftUI, AVFAudio, AudioToolbox,
Accelerate, MediaPlayer, CoreML, GRDB-linked system SQLite, Metal, and — on
macOS only, for projectM — the deprecated-but-functional OpenGL.framework).
These are used under the Apple SDK license and are not redistributed by MacAMP.
ASSETS

echo "Wrote ${OUT}"
