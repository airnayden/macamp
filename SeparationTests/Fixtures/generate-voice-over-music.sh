#!/usr/bin/env bash
#
# generate-voice-over-music.sh — builds the `voice_over_music.m4a` fixture that the
# GATED separation-quality test (SeparationQualityTests) consumes.
#
# The fixture is speech (real formants — NOT tones — rendered by macOS `say`, whose
# output the vocal-separation model should treat as vocals) mixed over a synthesized
# chord bed. The gated test then asserts the rendered instrumental attenuates the
# 300 Hz–3 kHz vocal band by >= 6 dB while leaving < 2 dB of change below 150 Hz.
#
# HUMAN-GATED: run this on a machine that has the compiled `MelBandRoformer.mlmodelc`
# beside this script. Neither the model nor this generated fixture is committed, so
# the gated test SKIPS (never fails) everywhere the model is absent (CI, fresh
# clones, iOS, App Store, and the development sandbox this task shipped from).
#
# PINNED FALLBACK (no executor judgment — plan todo 9): a singing-trained model may
# not treat synthetic `say` speech as vocals. If, on this machine, the real model
# reduces the 300 Hz–3 kHz band by < 6 dB on the synthetic mix, RE-RUN with
# `--librivox`: it substitutes the first 10 s of the public-domain LibriVox reading
#   https://ia800503.us.archive.org/8/items/count_monte_cristo_0711_librivox/count_of_monte_cristo_001_dumas.mp3
# The dB the real model actually achieves is then recorded in
# `Spikes/ADR-karaoke-separation.md` as the calibrated threshold, and the test
# asserts that calibrated value.
#
# Dependencies: macOS `say` + `afconvert` (system) and `ffmpeg` (synthesis / mix).
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${FIXTURE_DIR}/voice_over_music.m4a"
LIBRIVOX_URL="https://ia800503.us.archive.org/8/items/count_monte_cristo_0711_librivox/count_of_monte_cristo_001_dumas.mp3"
USE_LIBRIVOX=0
DURATION=10
SAMPLE_RATE=44100

for arg in "$@"; do
  case "$arg" in
    --librivox) USE_LIBRIVOX=1 ;;
    *) echo "usage: $0 [--librivox]" >&2; exit 2 ;;
  esac
done

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required but not installed" >&2; exit 1; }
}
require ffmpeg

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

VOICE_WAV="${WORK}/voice.wav"

if [[ "$USE_LIBRIVOX" -eq 1 ]]; then
  require curl
  echo "==> Fetching LibriVox fallback speech (first ${DURATION}s)…"
  curl -fsSL "$LIBRIVOX_URL" -o "${WORK}/librivox.mp3"
  ffmpeg -y -loglevel error -t "$DURATION" -i "${WORK}/librivox.mp3" \
    -ac 1 -ar "$SAMPLE_RATE" "$VOICE_WAV"
else
  require say
  require afconvert
  echo "==> Rendering synthetic speech via 'say' (real formants)…"
  say -o "${WORK}/voice.aiff" \
    "Karaoke mode removes the lead vocal while the instruments keep playing. \
     This narration exists only to exercise the stem separation quality test."
  afconvert -f WAVE -d LEI16@"${SAMPLE_RATE}" -c 1 "${WORK}/voice.aiff" "$VOICE_WAV"
fi

echo "==> Synthesizing a chord bed (A minor: 220 / 261.63 / 329.63 Hz)…"
CHORDS_WAV="${WORK}/chords.wav"
ffmpeg -y -loglevel error \
  -f lavfi -i "sine=frequency=220:sample_rate=${SAMPLE_RATE}:duration=${DURATION}" \
  -f lavfi -i "sine=frequency=261.63:sample_rate=${SAMPLE_RATE}:duration=${DURATION}" \
  -f lavfi -i "sine=frequency=329.63:sample_rate=${SAMPLE_RATE}:duration=${DURATION}" \
  -filter_complex "[0][1][2]amix=inputs=3:normalize=1,volume=0.6[bed]" \
  -map "[bed]" -ac 2 -ar "$SAMPLE_RATE" "$CHORDS_WAV"

echo "==> Mixing speech over the chord bed and encoding to ALAC .m4a…"
ffmpeg -y -loglevel error \
  -i "$VOICE_WAV" -i "$CHORDS_WAV" \
  -filter_complex "[0]volume=0.9,aformat=channel_layouts=stereo[v];[1][v]amix=inputs=2:normalize=0[mix]" \
  -map "[mix]" -c:a alac -ar "$SAMPLE_RATE" -ac 2 "$OUTPUT"

echo "==> Wrote ${OUTPUT}"
echo "    Next: run SeparationQualityTests on this machine; if the vocal-band"
echo "    reduction is < 6 dB, re-run with --librivox and record the calibrated dB"
echo "    in Spikes/ADR-karaoke-separation.md."
