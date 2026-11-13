#!/usr/bin/env bash
#
# Regenerates the two committed spectral-detector fixtures.
#
# ⚠️ THE TESTS NEVER RUN THIS. The two `.flac` files next to this script are
# COMMITTED ARTIFACTS; `SpectralDetectorTests` only reads them. This script
# exists so the provenance is reproducible, not so it can be invoked from a
# test — the suite must stay hermetic and must never shell out to `lame`,
# `ffmpeg` or anything else.
#
# Requires (developer machine only): python3, lame 3.100+, ffmpeg 8+.
#
#   ./generate-fixtures.sh
#
# See README.md for what each artifact proves.

set -euo pipefail

cd "$(dirname "$0")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── 1. The deterministic wideband source ────────────────────────────────────
# A seeded LCG white noise, which is the one signal shape that gives a FLAT
# long-term average spectrum all the way to Nyquist. That flatness is what
# makes the lossless fixture a real false-positive guard: its spectrum has no
# dead band anywhere, so any detector that invents one is caught.
python3 - "$work/source.wav" <<'PY'
import struct, sys

SAMPLE_RATE = 44100
DURATION = 1.0
CHANNELS = 2
PEAK = 0.30
SEED = 20260920

frames = int(SAMPLE_RATE * DURATION)
state = SEED


def next_sample():
    global state
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF
    return (state / 0x7FFFFFFF) * 2.0 - 1.0


channels = []
for _ in range(CHANNELS):
    values = [next_sample() * PEAK for _ in range(frames)]
    fade = int(SAMPLE_RATE * 0.005)  # 5 ms edges, so the ends are not a click
    for i in range(fade):
        gain = i / fade
        values[i] *= gain
        values[frames - 1 - i] *= gain
    channels.append(values)

payload = bytearray()
for frame in range(frames):
    for channel in channels:
        payload += struct.pack('<h', int(round(channel[frame] * 32767)))

header = (
    b'RIFF' + struct.pack('<I', 36 + len(payload)) + b'WAVEfmt ' +
    struct.pack('<IHHIIHH', 16, 1, CHANNELS, SAMPLE_RATE,
                SAMPLE_RATE * 2 * CHANNELS, 2 * CHANNELS, 16) +
    b'data' + struct.pack('<I', len(payload))
)
open(sys.argv[1], 'wb').write(header + bytes(payload))
PY

# ── 2. (b) true-lossless FLAC — the false-positive guard ────────────────────
ffmpeg -y -hide_banner -loglevel error \
    -i "$work/source.wav" \
    -c:a flac -compression_level 8 -sample_fmt s16 \
    wideband-lossless.flac

# ── 3. (a) fake-lossless FLAC — 128 kbps MP3 laundered into FLAC ────────────
# `--lowpass 16` pins the transition band at 15826-16360 Hz. LAME's own default
# for stereo 128 kbps CBR is 16538-17071 Hz, which is a real but unhelpfully
# high edge; 16 kHz is both the figure the plan specifies and the lowpass that
# a great many real 128 kbps encoders (older LAME, Fraunhofer, iTunes) use.
lame -b 128 --cbr -q 2 --lowpass 16 --quiet "$work/source.wav" "$work/transcode.mp3"
ffmpeg -y -hide_banner -loglevel error \
    -i "$work/transcode.mp3" \
    -c:a flac -compression_level 8 -sample_fmt s16 \
    wideband-transcoded-128k.flac

echo "regenerated:"
ls -l wideband-lossless.flac wideband-transcoded-128k.flac
