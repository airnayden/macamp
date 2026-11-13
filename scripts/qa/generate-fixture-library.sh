#!/usr/bin/env bash
#
# generate-fixture-library.sh — synthetic, REAL-DECODABLE fixture library generator
#
# Builds a nested tree of N genuinely decodable `.m4a` files for scale QA of
# MacAMP's launch path (lyrics sweep, per-row availability probing, keyset
# pagination) at 15k-track scale.
#
# ---------------------------------------------------------------------------
# WHY REAL AUDIO, NOT ZERO-BYTE STUBS
# ---------------------------------------------------------------------------
# The launch cost being measured is dominated by *opening every file*:
#   * `LyricsSweepService` opens each track through TagLib/SFB looking for
#     embedded lyrics, and
#   * the availability reconciler stats every row.
# A zero-byte stub is rejected before any decoder work happens, so a stub tree
# measures ~0 for the dominant term and makes a BEFORE/AFTER comparison vacuous.
# Every file this script emits is a real AAC-in-MP4 container that
# `macamp-cli decode` (and `afinfo`) opens successfully.
#
# ---------------------------------------------------------------------------
# EXTENSION CHOICE
# ---------------------------------------------------------------------------
# `m4a` IS in `LibraryScanner.audioExtensions`
# (PlayerCore/Sources/Services/Scanner/LibraryScanner.swift:25-29 — the set is
# flac mp3 m4a m4b aac mp4 ogg oga opus wv ape mpc wav aif aiff aifc dsf dff
# mod xm it s3m). Verified before this script was written; no substitute needed.
#
# ---------------------------------------------------------------------------
# SYNTHESIS RECIPE (stock macOS only — no network, no Homebrew)
# ---------------------------------------------------------------------------
#   perl pack()      ->  44-byte canonical RIFF/WAVE header
#   dd if=/dev/zero  ->  raw silent PCM appended to it
#   afconvert -f caff -d LEI16@44100 -c 1   ->  CAF intermediate
#   afconvert -f m4af -d aac                ->  AAC-in-MP4
# Synthesised ONCE, then hard-copied N times. Re-encoding per file would take
# tens of minutes at 15k; copying takes seconds and produces byte-identical,
# equally-decodable containers.
#
# GOTCHA: `afconvert` CANNOT read a headerless raw file — piping `dd`'s zeros
# straight in fails with `Couldn't open input file ('typ?')`. The 44-byte RIFF
# header written by stock `/usr/bin/perl` is the minimum that makes the zeros a
# container afconvert will open; both prescribed afconvert stages are unchanged.
#
# ---------------------------------------------------------------------------
# NAMING
# ---------------------------------------------------------------------------
#   "Artist %04d - Title %04d.m4a"
# The title index is the global running index (so filenames are unique); the
# artist index cycles every ARTIST_CYCLE titles so the corpus has several tracks
# per artist. The files carry NO embedded tags on purpose — the filename is the
# only metadata, which is exactly the corpus shape the filename-based
# auto-populate work needs, and TagLib/SFB still pays the full open cost.
#
# ---------------------------------------------------------------------------
# LAUNCH-TIMING BASELINE RECIPE (documented here, executed by the QA operator)
# ---------------------------------------------------------------------------
# Library roots are NO LONGER a UserDefaults array. Since schema v12 they live
# in the per-profile GRDB `libraryRoot` table
# (macOS/Sources/FileAccess/GRDBLibraryRootsStore.swift). The legacy
# `com.example.macamp.libraryRoots` defaults key is READ EXACTLY ONCE, guarded by
# `com.example.macamp.legacyRootsImported`; on any machine that has already run
# MacAMP that flag is set, so writing the legacy key does nothing. Register roots
# by inserting into the table directly — the row shape is trivial
# (`profileId`, `path`), Guest is profile id 1:
#
#   DB=~/Library/Application\ Support/MacAMP/library.sqlite
#   # 0. BACK UP the real user library first — this is destructive to library state.
#   for s in "" -wal -shm; do cp "$DB$s" "$DB$s.userbackup"; done
#   # 1. Populate the track table with the real scanner (real TagLib reads):
#   swift build --product macamp-cli
#   for r in "$DEST"/Root*; do .build/debug/macamp-cli scan "$r" --db "$DB"; done
#   # 2. Register the roots for Guest (profile id 1):
#   for r in "$DEST"/Root*; do
#     sqlite3 "$DB" "INSERT OR IGNORE INTO libraryRoot (profileId, path) VALUES (1, '$r');"
#   done
#   # 3. Measure a cold-ish launch to first visible All Tracks row:
#   START=$(perl -MTime::HiRes -e 'print Time::HiRes::time()')
#   open -a /path/to/MacAMP.app
#   # poll via System Events until the first table row exists, then:
#   END=$(perl -MTime::HiRes -e 'print Time::HiRes::time()')
#   # NOTE: BSD `date` has NO %N — `date +%s.%N` prints a literal "N" on macOS.
#   #       Use perl's Time::HiRes (stock) or python3 for sub-second stamps.
#   # 4. RESTORE the user library when finished.
#
# Timings are EVIDENCE-ONLY prints. Never assert on them in a test.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   scripts/qa/generate-fixture-library.sh --dest <dir> [--count N] [--roots R]
#                                          [--depth D] [--seconds S]
#
#   --dest    <dir>  REQUIRED. Refuses an existing NON-EMPTY directory.
#   --count   <N>    number of audio files to emit          (default 15000)
#   --roots   <R>    top-level Root<i> directories          (default 3)
#   --depth   <D>    directory nesting levels, 1..3         (default 3)
#   --seconds <S>    duration of the synthesised silence    (default 15)
#
# Exit codes: 0 ok · 1 bad usage / refused dest · 2 synthesis failure
set -euo pipefail

# ---------------------------------------------------------------------------
# defaults
# ---------------------------------------------------------------------------
COUNT=15000
DEST=""
ROOTS=3
DEPTH=3
SECONDS_PER_FILE=15

SAMPLE_RATE=44100
BYTES_PER_FRAME=2   # LEI16, 1 channel
ARTIST_CYCLE=12     # titles per artist — gives a realistic multi-track artist corpus
SUBS_PER_ROOT=8
DEEPS_PER_SUB=4

die() { printf 'error: %s\n' "$*" >&2; exit "${2:-1}"; }

usage() {
    sed -n '/^# USAGE/,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --count)   [ $# -ge 2 ] || die "--count needs a value";   COUNT="$2";            shift 2 ;;
        --dest)    [ $# -ge 2 ] || die "--dest needs a value";    DEST="$2";             shift 2 ;;
        --roots)   [ $# -ge 2 ] || die "--roots needs a value";   ROOTS="$2";            shift 2 ;;
        --depth)   [ $# -ge 2 ] || die "--depth needs a value";   DEPTH="$2";            shift 2 ;;
        --seconds) [ $# -ge 2 ] || die "--seconds needs a value"; SECONDS_PER_FILE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$DEST" ] || { usage >&2; die "--dest is required"; }

case "$COUNT"            in ''|*[!0-9]*) die "--count must be a positive integer (got '$COUNT')" ;; esac
case "$ROOTS"            in ''|*[!0-9]*) die "--roots must be a positive integer (got '$ROOTS')" ;; esac
case "$DEPTH"            in ''|*[!0-9]*) die "--depth must be a positive integer (got '$DEPTH')" ;; esac
case "$SECONDS_PER_FILE" in ''|*[!0-9]*) die "--seconds must be a positive integer (got '$SECONDS_PER_FILE')" ;; esac

[ "$COUNT" -ge 1 ]            || die "--count must be >= 1"
[ "$ROOTS" -ge 1 ]            || die "--roots must be >= 1"
[ "$DEPTH" -ge 1 ] && [ "$DEPTH" -le 3 ] || die "--depth must be between 1 and 3"
[ "$SECONDS_PER_FILE" -ge 1 ] || die "--seconds must be >= 1"

# ---------------------------------------------------------------------------
# destination guard — REFUSE an existing non-empty directory
# ---------------------------------------------------------------------------
if [ -e "$DEST" ]; then
    [ -d "$DEST" ] || die "--dest exists and is not a directory: $DEST"
    if [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
        die "--dest already exists and is NOT empty: $DEST
       Refusing to write into it. Remove it or choose another path."
    fi
fi
mkdir -p "$DEST"
DEST_ABS=$(cd "$DEST" && pwd)

command -v afconvert >/dev/null 2>&1 || die "afconvert not found (stock macOS tool)" 2

# ---------------------------------------------------------------------------
# 1. synthesise ONE real, decodable silent AAC file
# ---------------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/macamp-fixture-src.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

WAV="$WORK/silence.wav"
CAF="$WORK/silence.caf"
SRC="$WORK/silence.m4a"

RAW_BYTES=$(( SAMPLE_RATE * BYTES_PER_FRAME * SECONDS_PER_FILE ))
BYTE_RATE=$(( SAMPLE_RATE * BYTES_PER_FRAME ))

printf '[1/3] synthesising source audio (%ss silence, %d Hz mono LEI16)…\n' \
    "$SECONDS_PER_FILE" "$SAMPLE_RATE"

perl -e 'print pack("A4 V A4 A4 V v v V V v v A4 V", "RIFF", 36 + $ARGV[0], "WAVE",
                    "fmt ", 16, 1, 1, $ARGV[1], $ARGV[2], 2, 16, "data", $ARGV[0])' \
    "$RAW_BYTES" "$SAMPLE_RATE" "$BYTE_RATE" > "$WAV" \
    || die "perl failed to write the RIFF header" 2
dd if=/dev/zero bs="$RAW_BYTES" count=1 2>/dev/null >> "$WAV" \
    || die "dd failed to append raw PCM" 2
afconvert -f caff -d LEI16@"$SAMPLE_RATE" -c 1 "$WAV" "$CAF" >/dev/null 2>&1 \
    || die "afconvert (wav -> caf) failed" 2
afconvert -f m4af -d aac "$CAF" "$SRC" >/dev/null 2>&1 \
    || die "afconvert (caf -> m4a/aac) failed" 2
[ -s "$SRC" ] || die "synthesised source file is empty" 2

SRC_BYTES=$(stat -f%z "$SRC")
printf '      source: %s (%d bytes)\n' "$(basename "$SRC")" "$SRC_BYTES"

# self-check: the container must actually be readable by CoreAudio
if command -v afinfo >/dev/null 2>&1; then
    afinfo "$SRC" >/dev/null 2>&1 || die "synthesised file is not decodable (afinfo failed)" 2
    printf '      decode self-check: afinfo OK\n'
fi

# ---------------------------------------------------------------------------
# 2. build the directory skeleton
# ---------------------------------------------------------------------------
printf '[2/3] building directory skeleton (%d root(s), depth %d)…\n' "$ROOTS" "$DEPTH"

LEAVES=""
LEAF_COUNT=0
root=1
while [ "$root" -le "$ROOTS" ]; do
    root_dir=$(printf '%s/Root%d' "$DEST_ABS" "$root")
    if [ "$DEPTH" -eq 1 ]; then
        mkdir -p "$root_dir"
        LEAVES="$LEAVES$root_dir
"
        LEAF_COUNT=$(( LEAF_COUNT + 1 ))
    else
        sub=1
        while [ "$sub" -le "$SUBS_PER_ROOT" ]; do
            sub_dir=$(printf '%s/Sub%d' "$root_dir" "$sub")
            if [ "$DEPTH" -eq 2 ]; then
                mkdir -p "$sub_dir"
                LEAVES="$LEAVES$sub_dir
"
                LEAF_COUNT=$(( LEAF_COUNT + 1 ))
            else
                deep=1
                while [ "$deep" -le "$DEEPS_PER_SUB" ]; do
                    deep_dir=$(printf '%s/Deep%d' "$sub_dir" "$deep")
                    mkdir -p "$deep_dir"
                    LEAVES="$LEAVES$deep_dir
"
                    LEAF_COUNT=$(( LEAF_COUNT + 1 ))
                    deep=$(( deep + 1 ))
                done
            fi
            sub=$(( sub + 1 ))
        done
    fi
    root=$(( root + 1 ))
done

# materialise the leaf list as a positional array (bash 3.2 compatible)
OLD_IFS=$IFS
IFS='
'
# shellcheck disable=SC2086
set -- $LEAVES
IFS=$OLD_IFS
printf '      %d leaf director%s\n' "$LEAF_COUNT" "$([ "$LEAF_COUNT" -eq 1 ] && echo y || echo ies)"

# ---------------------------------------------------------------------------
# 3. copy the source file into every leaf, round-robin
# ---------------------------------------------------------------------------
printf '[3/3] emitting %d file(s)…\n' "$COUNT"

PROGRESS_EVERY=$(( COUNT / 20 ))
[ "$PROGRESS_EVERY" -lt 1 ] && PROGRESS_EVERY=1

index=1
while [ "$index" -le "$COUNT" ]; do
    leaf_index=$(( (index - 1) % LEAF_COUNT + 1 ))
    eval "leaf=\${$leaf_index}"
    artist=$(( (index - 1) / ARTIST_CYCLE + 1 ))
    name=$(printf 'Artist %04d - Title %04d.m4a' "$artist" "$index")
    cp "$SRC" "$leaf/$name"
    if [ $(( index % PROGRESS_EVERY )) -eq 0 ] || [ "$index" -eq "$COUNT" ]; then
        printf '      %d/%d\r' "$index" "$COUNT"
    fi
    index=$(( index + 1 ))
done
printf '\n'

# ---------------------------------------------------------------------------
# summary — per-root counts
# ---------------------------------------------------------------------------
printf '\nFixture library: %s\n' "$DEST_ABS"
TOTAL=0
root=1
while [ "$root" -le "$ROOTS" ]; do
    root_dir=$(printf '%s/Root%d' "$DEST_ABS" "$root")
    n=$(find "$root_dir" -type f -name '*.m4a' | wc -l | tr -d ' ')
    printf '  Root%-3d %8d file(s)\n' "$root" "$n"
    TOTAL=$(( TOTAL + n ))
    root=$(( root + 1 ))
done
printf '  %-8s %8d file(s)\n' 'TOTAL' "$TOTAL"
printf '  %-8s %8s\n' 'on disk' "$(du -sh "$DEST_ABS" | cut -f1)"

[ "$TOTAL" -eq "$COUNT" ] || die "emitted $TOTAL files but expected $COUNT" 2

printf '\nVerify one file decodes for real:\n'
printf '  afinfo "%s"\n' "$(find "$DEST_ABS" -type f -name '*.m4a' | head -1)"
printf '  .build/debug/macamp-cli decode "%s"\n' "$(find "$DEST_ABS" -type f -name '*.m4a' | head -1)"
