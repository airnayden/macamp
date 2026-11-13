#!/usr/bin/env bash
#
# generate_fixtures.sh — (re)generate the MetadataTests binary fixtures.
#
# Produces small, hermetic, fully-tagged audio files the Metadata suites load by
# path via `#filePath` (this directory is `exclude`d from the SPM build). Every
# file shares the SAME logical tags (a "The Beatles / Abbey Road" track) so the
# suites can assert NFC values, article-stripped sort keys, embedded art and
# ReplayGain across FLAC / MP3 / M4A from one expectation set.
#
# Requires ffmpeg (tested with 8.x). Run from the repo root or anywhere:
#   bash PlayerCore/Tests/MetadataTests/Fixtures/generate_fixtures.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COVER="${DIR}/cover.png"
TONE="${DIR}/tone.wav"

# Shared tag values (kept in sync with SFBMetadataReaderTests expectations).
TITLE="Come Together"
ARTIST="The Beatles"
ALBUM="Abbey Road"
ALBUM_ARTIST="The Beatles"
GENRE="Rock"
COMPOSER="Lennon-McCartney"
YEAR="1969"
TRACK="1/17"
DISC="1/1"
LYRICS="Here come old flat top"

# ReplayGain (Vorbis-comment / ID3 TXXX style; values are illustrative).
RG_REF="89.0 dB"
RG_TRACK_GAIN="-7.50 dB"
RG_TRACK_PEAK="0.988553"
RG_ALBUM_GAIN="-8.20 dB"
RG_ALBUM_PEAK="0.997162"

echo "==> cover art (64x64 crimson PNG)"
ffmpeg -y -loglevel error -f lavfi -i "color=c=crimson:s=64x64:d=1" -frames:v 1 "${COVER}"

echo "==> base tone (440 Hz, 44.1 kHz, stereo, 0.5 s)"
ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=44100" -ac 2 "${TONE}"

common_meta=(
  -metadata title="${TITLE}"
  -metadata artist="${ARTIST}"
  -metadata album="${ALBUM}"
  -metadata album_artist="${ALBUM_ARTIST}"
  -metadata genre="${GENRE}"
  -metadata composer="${COMPOSER}"
  -metadata date="${YEAR}"
  -metadata track="${TRACK}"
  -metadata disc="${DISC}"
  -metadata lyrics="${LYRICS}"
  -metadata LYRICS="${LYRICS}"
)

replaygain_meta=(
  -metadata REPLAYGAIN_REFERENCE_LOUDNESS="${RG_REF}"
  -metadata REPLAYGAIN_TRACK_GAIN="${RG_TRACK_GAIN}"
  -metadata REPLAYGAIN_TRACK_PEAK="${RG_TRACK_PEAK}"
  -metadata REPLAYGAIN_ALBUM_GAIN="${RG_ALBUM_GAIN}"
  -metadata REPLAYGAIN_ALBUM_PEAK="${RG_ALBUM_PEAK}"
)

echo "==> full.flac (16-bit FLAC: full tags + embedded front cover + ReplayGain)"
ffmpeg -y -loglevel error -i "${TONE}" -i "${COVER}" \
  -map 0:a -map 1:v -c:a flac -sample_fmt s16 -c:v copy \
  -disposition:v:0 attached_pic \
  -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" \
  "${common_meta[@]}" "${replaygain_meta[@]}" \
  "${DIR}/full.flac"

echo "==> full.mp3 (MP3 192k CBR: tags + embedded cover via ID3v2.3 APIC + ReplayGain TXXX)"
ffmpeg -y -loglevel error -i "${TONE}" -i "${COVER}" \
  -map 0:a -map 1:v -c:a libmp3lame -b:a 192k -c:v copy -id3v2_version 3 \
  -disposition:v:0 attached_pic -metadata:s:v title="cover" -metadata:s:v comment="Cover (front)" \
  "${common_meta[@]}" "${replaygain_meta[@]}" \
  "${DIR}/full.mp3"

echo "==> full.m4a (AAC in MP4: tags + embedded cover atom)"
ffmpeg -y -loglevel error -i "${TONE}" -i "${COVER}" \
  -map 0:a -map 1:v -c:a aac -b:a 192k -c:v copy -disposition:v:0 attached_pic \
  "${common_meta[@]}" \
  "${DIR}/full.m4a"

echo "==> corrupt.flac (valid fLaC magic + garbage so the parser claims then rejects it)"
python3 -c "open('${DIR}/corrupt.flac','wb').write(b'fLaC'+bytes([0xDB])*512)"

echo "==> cleanup intermediates"
rm -f "${TONE}" "${COVER}"

echo "==> done. fixtures:"
ls -l "${DIR}"/*.flac "${DIR}"/*.mp3 "${DIR}"/*.m4a
