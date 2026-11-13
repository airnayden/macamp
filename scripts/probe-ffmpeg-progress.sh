#!/usr/bin/env bash
#
# probe-ffmpeg-progress.sh — CAPABILITY probe for ffmpeg's `-progress` hook reaching
# the ExtractAudio post-processor through yt-dlp's `--postprocessor-args`.
#
# MacAMP wants a TRUTHFUL conversion progress bar. The only number ffmpeg will ever
# volunteer about its own progress is what `-progress <file>` writes, and the only way
# to hand that flag to the ffmpeg invocation yt-dlp spawns for audio extraction is
#
#     --postprocessor-args "ExtractAudio+ffmpeg:-progress <file>"
#
# Nothing about that is guaranteed. `-progress` is documented as a GLOBAL ffmpeg
# option while yt-dlp appends post-processor args among the OUTPUT options; the value
# after the `NAME+EXE:` prefix is `shlex.split`, not passed through verbatim; and the
# extraction MacAMP depends on (plus the two embed passes and the three `MACAMP-*`
# sentinels the app's own output interpreter reads) all have to survive the addition.
#
# ── WHAT THIS PROBE ANSWERS, AND WHAT IT DELIBERATELY DOES NOT ────────────────
#
# Read this precisely. The gate is CAPABILITY, not representativeness:
#
#   IT ASSERTS: adding that one flag to MacAMP's own argument vector still produces a
#               finished file, still prints the sentinels in the same shape, still
#               embeds cover art, writes a progress file that ends where ffmpeg says
#               it ends, and truncates a stale progress file rather than appending.
#
#   IT DOES NOT ASSERT: that any particular NUMBER of progress samples will arrive at
#               runtime. Whether `--audio-format m4a` transcodes (an Opus source must
#               be re-encoded — many samples) or stream-copies (an AAC itag-140 source
#               is only remuxed — approximately zero samples) is a property of the
#               VIDEO, not of the flag and not of the format. A single video's sample
#               count generalises in NEITHER direction, so sample counts are RECORDED
#               and never gated on. The shipped implementation absorbs both by being
#               determinate only while real samples arrive.
#
# ── THE ASSERTIONS ───────────────────────────────────────────────────────────
#
#   A0  the progress file exists and is non-empty            (flag reached ffmpeg)
#   A1  extraction succeeded: one MACAMP-FILE line, exit 0, file on disk
#   A2  MACAMP-P / MACAMP-PP / MACAMP-FILE shapes are IDENTICAL to a control run
#       of the same cell WITHOUT the flag
#   A3  embedded cover art survives (an ffprobe attached_pic stream)
#   A4  nothing is written to the progress file after ffmpeg's own `progress=end`
#   A5  a pre-seeded stale progress file is OVERWRITTEN, not appended to
#
# A0 is this script's own addition to the five the work plan names. Without it a flag
# that silently did nothing at all would satisfy every one of the other five and the
# probe would report CAPABLE while measuring nothing — the failure mode this repo has
# now recorded four times. A0 failing is reported as BROKEN with the mode named.
#
# A2 is an A/B, not a hardcoded expectation. Each cell runs TWICE: once with the exact
# vector `YtDlpCommandBuilder` produces (control) and once with that vector plus the
# two extra elements (treatment). Comparing the two is what gives A2 teeth — and the
# control run doubles as proof the harness produces non-zero sentinel counts at all.
#
# ── THE QUOTING SUB-PROBE (reported, not gated) ──────────────────────────────
#
# yt-dlp `shlex.split`s the argument string, and MacAMP's real staging directory is
# `~/Library/Application Support/MacAMP/Downloads-Staging` — a path containing
# SPACES. An unquoted `-progress /…/Application Support/…` would therefore be torn
# into three arguments before ffmpeg ever sees it. The three gated cells use a
# whitespace-free scratch path so the capability question stays isolated from the
# quoting question; two extra `m4a` runs then measure the quoting question directly,
# against a path shaped exactly like the one the shipped builder will emit
# (`…/<dir with space>/ffprogress [<videoID>].txt`), unquoted and quoted. Those two
# runs do NOT move the verdict — they are a constraint on how the path is composed.
#
# ── DISCIPLINE ───────────────────────────────────────────────────────────────
#
# - Runs the STAGED bundled tools (`~/Library/Application Support/MacAMP/Tools`), the
#   same copies the app runs. Never a Homebrew ffmpeg, never the repo seed.
# - Every byte this probe writes goes to a `mktemp -d` scratch tree: its own `home:`
#   and `temp:` directories and its own progress files. The app's real destination
#   folder and real staging directory are never touched. The scratch tree is removed
#   on exit (`--keep-scratch` opts out); the evidence directory is what survives.
# - `--cache-dir` keeps the builder's own shape, `<toolsDirectory>/yt-dlp-cache`,
#   which is the app's own cache and is written by every normal download.
# - ONE short Creative-Commons-licensed video, and the licence is VERIFIED from
#   yt-dlp's own metadata rather than asserted in a comment.
# - The child environment is stripped of the same keys `YtDlpProcessRunner` strips.
#
# Usage:
#   scripts/probe-ffmpeg-progress.sh [options]
#     --video-id <id>     video to probe          (default: SkVqJ1SGeL0)
#     --output-dir <dir>  evidence directory      (default: .omo/evidence/dlv2-08-probe)
#     --tools-dir <dir>   staged tools directory  (default: Application Support/MacAMP/Tools)
#     --keep-scratch      leave the scratch tree in place for inspection
#     --dry-run           compose and record every vector, run nothing, touch no network
#
# Exit status: 0 when the verdict is CAPABLE, 1 when it is BROKEN, 2 on a setup
# failure that means no verdict was reached at all.
set -uo pipefail

readonly SETUP_FAILURE=2

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

VIDEO_ID="SkVqJ1SGeL0"
OUTPUT_DIR="$REPO_ROOT/.omo/evidence/dlv2-08-probe"
TOOLS_DIR="$HOME/Library/Application Support/MacAMP/Tools"
KEEP_SCRATCH=0
DRY_RUN=0

# How long one yt-dlp run may take before it is signalled. A network probe that hangs
# must fail the probe, not the session.
readonly RUN_DEADLINE_SECONDS=300

log() { printf '%s\n' "$*"; }
die() { printf 'probe-ffmpeg-progress: %s\n' "$*" >&2; exit "$SETUP_FAILURE"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --video-id) [ $# -ge 2 ] || die "--video-id needs a value"; VIDEO_ID="$2"; shift 2 ;;
        --output-dir) [ $# -ge 2 ] || die "--output-dir needs a value"; OUTPUT_DIR="$2"; shift 2 ;;
        --tools-dir) [ $# -ge 2 ] || die "--tools-dir needs a value"; TOOLS_DIR="$2"; shift 2 ;;
        --keep-scratch) KEEP_SCRATCH=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '/^# Usage:/,/^# Exit status/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

# ── Tool resolution — the same layout DownloadToolManager installs ────────────
#
# yt-dlp is a PyInstaller ONE-DIRECTORY tree: the `yt-dlp_macos` launcher is useless
# without its `_internal/` sibling, so both are checked. `ffmpegDirectoryURL` is the
# tools directory itself, which is what the builder passes as `--ffmpeg-location`.
readonly YTDLP_TREE_NAME="yt-dlp"
readonly YTDLP_EXECUTABLE_NAME="yt-dlp_macos"

YTDLP="$TOOLS_DIR/$YTDLP_TREE_NAME/$YTDLP_EXECUTABLE_NAME"
FFMPEG="$TOOLS_DIR/ffmpeg"
FFPROBE="$TOOLS_DIR/ffprobe"

[ -x "$YTDLP" ] || die "staged yt-dlp not found at $YTDLP — launch MacAMP once so the tools are copied out of the bundle, or pass --tools-dir"
[ -d "$TOOLS_DIR/$YTDLP_TREE_NAME/_internal" ] || die "yt-dlp tree at $TOOLS_DIR/$YTDLP_TREE_NAME has no _internal/ — a lone launcher cannot run"
[ -x "$FFMPEG" ] || die "staged ffmpeg not found at $FFMPEG"
[ -x "$FFPROBE" ] || die "staged ffprobe not found at $FFPROBE"

mkdir -p "$OUTPUT_DIR" || die "cannot create evidence directory $OUTPUT_DIR"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/macamp-ffprogress-probe.XXXXXX")" || die "cannot create scratch directory"
cleanup() {
    if [ "$KEEP_SCRATCH" -eq 1 ]; then
        log "scratch tree kept at $SCRATCH"
    else
        rm -rf "$SCRATCH"
    fi
}
trap cleanup EXIT

DOWNLOADS_DIR="$SCRATCH/home"
STAGING_DIR="$SCRATCH/temp"
PROGRESS_DIR="$SCRATCH/progress"
# Deliberately contains a space, mirroring "Application Support" in the real staging
# path — see THE QUOTING SUB-PROBE above.
SPACED_PROGRESS_DIR="$SCRATCH/spaced progress"
mkdir -p "$DOWNLOADS_DIR" "$STAGING_DIR" "$PROGRESS_DIR" "$SPACED_PROGRESS_DIR"

case "$PROGRESS_DIR" in
    *[[:space:]]*) die "scratch progress directory contains whitespace; the gated cells require a whitespace-free path" ;;
esac

# ── The argument vector, mirroring YtDlpCommandBuilder exactly ────────────────
#
# Every literal below is a transcription of
# `PlayerCore/Sources/Services/Downloads/YtDlpCommandBuilder.swift` and
# `YtDlpArgumentTables.swift`. This script is the one place they are duplicated, and
# the duplication is deliberate: a probe that composed its vector by calling the app
# would prove the app agrees with itself, not that the ENGINE accepts what the app
# sends. The golden-array tests pin the Swift side; this file records what was
# actually executed.
readonly OUTPUT_TEMPLATE='%(title)s [%(id)s].%(ext)s'
readonly CACHE_DIRECTORY_NAME="yt-dlp-cache"
readonly DOWNLOAD_PROGRESS_TEMPLATE='download:MACAMP-P|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.eta)s|%(progress.speed)s'
readonly POSTPROCESS_PROGRESS_TEMPLATE='postprocess:MACAMP-PP|%(progress.status)s|%(progress.postprocessor)s'
readonly FILE_PATH_PRINT_TEMPLATE='after_move:MACAMP-FILE|%(filepath)s'

readonly SENTINEL_PROGRESS='MACAMP-P|'
readonly SENTINEL_POSTPROCESS='MACAMP-PP|'
readonly SENTINEL_FILE='MACAMP-FILE|'

# YtDlpArgumentTables.audioQuality — flac is deliberately EMPTY: neither the flag nor
# a value is emitted for a lossless format.
audio_quality_argument() {
    case "$1/$2" in
        mp3/best) printf '0' ;;
        mp3/high) printf '5' ;;
        mp3/medium) printf '7' ;;
        m4a/best) printf '256K' ;;
        m4a/high) printf '192K' ;;
        m4a/medium) printf '128K' ;;
        opus/best) printf '192K' ;;
        opus/high) printf '128K' ;;
        opus/medium) printf '96K' ;;
        flac/*) printf '' ;;
        *) die "no audio-quality row for $1/$2" ;;
    esac
}

VECTOR=()

# Composes VECTOR for one cell. `$3` is the whole `--postprocessor-args` value, or
# empty for a control run — the ONLY difference between the two vectors is those two
# elements, which is what makes the A/B comparison in A2 meaningful.
build_vector() {
    local format="$1" quality="$2" ppa_value="$3"
    local quality_value
    quality_value="$(audio_quality_argument "$format" "$quality")"

    VECTOR=(
        # reportingArguments
        "--ignore-config"
        "--no-config-locations"
        "--no-color"
        "--newline"
        "--progress"
        "--no-playlist"
        "--progress-template" "$DOWNLOAD_PROGRESS_TEMPLATE"
        "--progress-template" "$POSTPROCESS_PROGRESS_TEMPLATE"
        "--print" "$FILE_PATH_PRINT_TEMPLATE"
        # audioArguments
        "-x"
        "--audio-format" "$format"
    )
    if [ -n "$quality_value" ]; then
        VECTOR+=("--audio-quality" "$quality_value")
    fi
    VECTOR+=("--embed-thumbnail" "--embed-metadata")

    # The probe's addition. Position is not load-bearing for the capability question —
    # control and treatment share every other element — so it sits with the other
    # post-processing concerns rather than after the URL.
    if [ -n "$ppa_value" ]; then
        VECTOR+=("--postprocessor-args" "$ppa_value")
    fi

    # destinationArguments
    VECTOR+=(
        "-P" "home:$DOWNLOADS_DIR"
        "-P" "temp:$STAGING_DIR"
        "-o" "$OUTPUT_TEMPLATE"
        "--ffmpeg-location" "$TOOLS_DIR"
        "--cache-dir" "$TOOLS_DIR/$CACHE_DIRECTORY_NAME"
        "https://www.youtube.com/watch?v=$VIDEO_ID"
    )
}

# ── Running one vector ───────────────────────────────────────────────────────
#
# stdout and stderr are captured SEPARATELY, because which stream carries which
# sentinel is a measured property of yt-dlp (progress and --print on stdout, the
# postprocess template on stderr) that the app's interpreter deliberately does not
# depend on. Keeping them apart is what lets this probe record it again.
RUN_EXIT=0

run_vector() {
    local stdout_file="$1" stderr_file="$2"
    local pid watchdog
    (
        unset YTDLP_CONFIG_HOME XDG_CONFIG_HOME YTDLP_NO_PLUGINS YTDLP_NO_LAZY_EXTRACTORS \
              PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONEXECUTABLE PYTHONWARNINGS
        exec "$YTDLP" "${VECTOR[@]}"
    ) >"$stdout_file" 2>"$stderr_file" </dev/null &
    pid=$!
    ( sleep "$RUN_DEADLINE_SECONDS"; kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) &
    watchdog=$!
    wait "$pid"
    RUN_EXIT=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return 0
}

# ── Sentinel measurement helpers ─────────────────────────────────────────────
#
# `MACAMP-P|` is not a prefix of `MACAMP-PP|` (after `MACAMP-P` the latter has another
# `P`, not the separator), so a fixed-string match on either never sees the other.
# That is the same property the app's parser relies on.
count_sentinel() {
    local prefix="$1"; shift
    cat "$@" 2>/dev/null | grep -c -F -- "$prefix" 2>/dev/null || true
}

# The set of `|`-separated field counts, so a template that lost or gained a field is
# visible as a shape change rather than hidden behind a line count.
sentinel_field_counts() {
    local prefix="$1"; shift
    cat "$@" 2>/dev/null | grep -F -- "$prefix" 2>/dev/null | awk -F'|' '{print NF}' | sort -u | paste -sd, -
}

sentinel_field_values() {
    local prefix="$1" field="$2"; shift 2
    cat "$@" 2>/dev/null | grep -F -- "$prefix" 2>/dev/null | cut -d'|' -f"$field" | sort -u | paste -sd, -
}

extracted_path() {
    cat "$@" 2>/dev/null | grep -F -- "$SENTINEL_FILE" 2>/dev/null | head -1 | sed "s/^.*${SENTINEL_FILE}//"
}

file_signature() {
    stat -f '%z:%m' "$1" 2>/dev/null || printf 'absent'
}

# ── Verdict accumulation ─────────────────────────────────────────────────────
FAILURES=()
SUMMARY_ROWS=()
SUBPROBE_ROWS=()

record_failure() { FAILURES+=("$1"); }

# assert <cell> <id> <description> <ok:0|1>
CELL_FAILED=0
assert_cell() {
    local cell="$1" id="$2" description="$3" ok="$4"
    if [ "$ok" -eq 1 ]; then
        printf '  %-3s PASS  %s\n' "$id" "$description" | tee -a "$CELL_ASSERTIONS"
    else
        printf '  %-3s FAIL  %s\n' "$id" "$description" | tee -a "$CELL_ASSERTIONS"
        record_failure "$cell/$id ($description)"
        CELL_FAILED=1
    fi
}

# ── Environment + licence record ─────────────────────────────────────────────
ENVIRONMENT_FILE="$OUTPUT_DIR/environment.txt"
{
    printf 'probe-ffmpeg-progress.sh — environment\n'
    printf 'date                : %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'repo HEAD           : %s\n' "$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
    printf 'tools directory     : %s\n' "$TOOLS_DIR"
    printf 'yt-dlp launcher     : %s\n' "$YTDLP"
    printf 'yt-dlp version      : %s\n' "$("$YTDLP" --version 2>&1 | tail -1)"
    printf 'ffmpeg              : %s\n' "$("$FFMPEG" -version 2>&1 | head -1)"
    printf 'ffprobe             : %s\n' "$("$FFPROBE" -version 2>&1 | head -1)"
    printf 'scratch tree        : %s\n' "$SCRATCH"
    printf 'video id            : %s\n' "$VIDEO_ID"
    printf 'dry run             : %s\n' "$DRY_RUN"
    printf 'disk free (/)       : %s\n' "$(df -h / | tail -1)"
} >"$ENVIRONMENT_FILE"

if [ "$DRY_RUN" -eq 0 ]; then
    log "verifying the probe video's licence …"
    METADATA="$("$YTDLP" --ignore-config --no-config-locations --no-color --no-warnings \
        --skip-download --print '%(license)s|%(duration)s|%(title)s|%(uploader)s|%(acodec)s|%(format_id)s' \
        --cache-dir "$TOOLS_DIR/$CACHE_DIRECTORY_NAME" \
        "https://www.youtube.com/watch?v=$VIDEO_ID" 2>>"$OUTPUT_DIR/licence-check.stderr.txt" | tail -1)"
    {
        printf 'licence line        : %s\n' "$METADATA"
    } >>"$ENVIRONMENT_FILE"
    case "$METADATA" in
        *"Creative Commons"*) log "  licence OK: ${METADATA%%|*}" ;;
        *) die "video $VIDEO_ID is not Creative-Commons licensed (metadata: ${METADATA:-<none>}) — this probe only touches CC material" ;;
    esac
fi

# ── One gated cell ───────────────────────────────────────────────────────────
run_cell() {
    local format="$1" quality="$2"
    local cell="$format/$quality"
    local slug="$format"
    local progress_file="$PROGRESS_DIR/probe.ffprogress"

    CELL_ASSERTIONS="$OUTPUT_DIR/cell-$slug-assertions.txt"
    CELL_FAILED=0
    : >"$CELL_ASSERTIONS"
    log ""
    log "── cell $cell ─────────────────────────────────────────────"

    local control_out="$OUTPUT_DIR/cell-$slug-control.stdout.txt"
    local control_err="$OUTPUT_DIR/cell-$slug-control.stderr.txt"
    local treat_out="$OUTPUT_DIR/cell-$slug-treatment.stdout.txt"
    local treat_err="$OUTPUT_DIR/cell-$slug-treatment.stderr.txt"

    # ---- control: the exact builder vector, no added flag ----
    build_vector "$format" "$quality" ""
    printf '%s\n' "${VECTOR[@]}" >"$OUTPUT_DIR/cell-$slug-vector-control.txt"
    if [ "$DRY_RUN" -eq 1 ]; then
        build_vector "$format" "$quality" "ExtractAudio+ffmpeg:-progress $progress_file"
        printf '%s\n' "${VECTOR[@]}" >"$OUTPUT_DIR/cell-$slug-vector-treatment.txt"
        log "  dry run: vectors recorded, nothing executed"
        return 0
    fi

    rm -rf "$DOWNLOADS_DIR" "$STAGING_DIR"; mkdir -p "$DOWNLOADS_DIR" "$STAGING_DIR"
    log "  control run (no --postprocessor-args) …"
    run_vector "$control_out" "$control_err"
    local control_exit="$RUN_EXIT"
    local control_file; control_file="$(extracted_path "$control_out" "$control_err")"
    local control_probe="$OUTPUT_DIR/cell-$slug-control.ffprobe.txt"
    if [ -n "$control_file" ] && [ -f "$control_file" ]; then
        "$FFPROBE" -v error -select_streams v -show_streams -of default=noprint_wrappers=1 "$control_file" >"$control_probe" 2>&1
    else
        printf 'no control output file\n' >"$control_probe"
    fi

    # ---- treatment: the same vector plus the two extra elements ----
    rm -rf "$DOWNLOADS_DIR" "$STAGING_DIR"; mkdir -p "$DOWNLOADS_DIR" "$STAGING_DIR"

    # A5's teeth: seed a stale file with a sentinel that CANNOT occur in ffmpeg's own
    # output, and prove it is there before the run so its later absence means something.
    local stale_sentinel="MACAMP-STALE-SENTINEL-$slug"
    {
        printf '%s\n' "$stale_sentinel"
        printf 'out_time_us=999999999\n'
        printf 'progress=continue\n'
    } >"$progress_file"
    cp "$progress_file" "$OUTPUT_DIR/cell-$slug-seed.ffprogress.txt"
    local seeded=0
    grep -q -F -- "$stale_sentinel" "$progress_file" && seeded=1

    build_vector "$format" "$quality" "ExtractAudio+ffmpeg:-progress $progress_file"
    printf '%s\n' "${VECTOR[@]}" >"$OUTPUT_DIR/cell-$slug-vector-treatment.txt"
    log "  treatment run (with --postprocessor-args) …"
    run_vector "$treat_out" "$treat_err"
    local treat_exit="$RUN_EXIT"

    local signature_at_exit; signature_at_exit="$(file_signature "$progress_file")"
    sleep 2
    local signature_after_settle; signature_after_settle="$(file_signature "$progress_file")"

    local treat_file; treat_file="$(extracted_path "$treat_out" "$treat_err")"
    local treat_probe="$OUTPUT_DIR/cell-$slug-treatment.ffprobe.txt"
    if [ -n "$treat_file" ] && [ -f "$treat_file" ]; then
        "$FFPROBE" -v error -select_streams v -show_streams -of default=noprint_wrappers=1 "$treat_file" >"$treat_probe" 2>&1
    else
        printf 'no treatment output file\n' >"$treat_probe"
    fi

    local progress_copy="$OUTPUT_DIR/cell-$slug-treatment.ffprogress.txt"
    if [ -f "$progress_file" ]; then
        cp "$progress_file" "$progress_copy"
    else
        printf '<progress file was never created>\n' >"$progress_copy"
    fi

    # ---- measurements ----
    local control_p control_pp control_f treat_p treat_pp treat_f
    control_p="$(count_sentinel "$SENTINEL_PROGRESS" "$control_out" "$control_err")"
    control_pp="$(count_sentinel "$SENTINEL_POSTPROCESS" "$control_out" "$control_err")"
    control_f="$(count_sentinel "$SENTINEL_FILE" "$control_out" "$control_err")"
    treat_p="$(count_sentinel "$SENTINEL_PROGRESS" "$treat_out" "$treat_err")"
    treat_pp="$(count_sentinel "$SENTINEL_POSTPROCESS" "$treat_out" "$treat_err")"
    treat_f="$(count_sentinel "$SENTINEL_FILE" "$treat_out" "$treat_err")"

    local control_p_shape treat_p_shape control_pp_shape treat_pp_shape
    control_p_shape="$(sentinel_field_counts "$SENTINEL_PROGRESS" "$control_out" "$control_err")"
    treat_p_shape="$(sentinel_field_counts "$SENTINEL_PROGRESS" "$treat_out" "$treat_err")"
    control_pp_shape="$(sentinel_field_counts "$SENTINEL_POSTPROCESS" "$control_out" "$control_err")"
    treat_pp_shape="$(sentinel_field_counts "$SENTINEL_POSTPROCESS" "$treat_out" "$treat_err")"

    local control_statuses treat_statuses control_pp_names treat_pp_names
    control_statuses="$(sentinel_field_values "$SENTINEL_PROGRESS" 2 "$control_out" "$control_err")"
    treat_statuses="$(sentinel_field_values "$SENTINEL_PROGRESS" 2 "$treat_out" "$treat_err")"
    control_pp_names="$(sentinel_field_values "$SENTINEL_POSTPROCESS" 3 "$control_out" "$control_err")"
    treat_pp_names="$(sentinel_field_values "$SENTINEL_POSTPROCESS" 3 "$treat_out" "$treat_err")"

    # Sample counts — RECORDED, never gated. See the header.
    local samples_out_time_us samples_out_time_ms blocks_continue blocks_end progress_lines
    samples_out_time_us="$(grep -c -F -- 'out_time_us=' "$progress_copy" 2>/dev/null || true)"
    samples_out_time_ms="$(grep -c -F -- 'out_time_ms=' "$progress_copy" 2>/dev/null || true)"
    blocks_continue="$(grep -c -F -- 'progress=continue' "$progress_copy" 2>/dev/null || true)"
    blocks_end="$(grep -c -F -- 'progress=end' "$progress_copy" 2>/dev/null || true)"
    progress_lines="$(wc -l <"$progress_copy" 2>/dev/null | tr -d ' ' || printf '0')"

    {
        printf 'cell %s\n' "$cell"
        printf '  control exit=%s  MACAMP-P=%s MACAMP-PP=%s MACAMP-FILE=%s\n' "$control_exit" "$control_p" "$control_pp" "$control_f"
        printf '  treat   exit=%s  MACAMP-P=%s MACAMP-PP=%s MACAMP-FILE=%s\n' "$treat_exit" "$treat_p" "$treat_pp" "$treat_f"
        printf '  MACAMP-P  field counts   control=[%s] treatment=[%s]\n' "$control_p_shape" "$treat_p_shape"
        printf '  MACAMP-PP field counts   control=[%s] treatment=[%s]\n' "$control_pp_shape" "$treat_pp_shape"
        printf '  MACAMP-P  statuses       control=[%s] treatment=[%s]\n' "$control_statuses" "$treat_statuses"
        printf '  MACAMP-PP postprocessors control=[%s] treatment=[%s]\n' "$control_pp_names" "$treat_pp_names"
        printf '  control file  : %s\n' "${control_file:-<none>}"
        printf '  treatment file: %s\n' "${treat_file:-<none>}"
        printf '  progress file signature at exit=%s after 2s settle=%s\n' "$signature_at_exit" "$signature_after_settle"
        printf '  SAMPLE COUNTS (recorded, NOT gated): out_time_us=%s out_time_ms=%s progress=continue:%s progress=end:%s lines=%s\n' \
            "$samples_out_time_us" "$samples_out_time_ms" "$blocks_continue" "$blocks_end" "$progress_lines"
        printf '\n'
    } >>"$CELL_ASSERTIONS"

    # ---- assertions ----
    local ok

    # A0 — the flag reached ffmpeg at all.
    ok=0; { [ -f "$progress_file" ] && [ -s "$progress_file" ]; } && ok=1
    assert_cell "$cell" A0 "progress file exists and is non-empty (flag reached ffmpeg)" "$ok"

    # A1 — extraction succeeded.
    ok=0
    if [ "$treat_exit" -eq 0 ] && [ "$treat_f" -eq 1 ] && [ -n "$treat_file" ] && [ -f "$treat_file" ]; then ok=1; fi
    assert_cell "$cell" A1 "extraction succeeded: exit 0, exactly one MACAMP-FILE, file on disk" "$ok"

    # A2 — sentinel shapes unchanged versus the control run. The `-gt 0` clauses are
    # the baseline teeth: two runs that both emitted nothing would otherwise "match".
    ok=0
    if [ "$control_p" -gt 0 ] && [ "$control_pp" -gt 0 ] \
        && [ "$treat_p" -gt 0 ] && [ "$treat_pp" -gt 0 ] \
        && [ "$control_f" -eq 1 ] && [ "$treat_f" -eq 1 ] \
        && [ "$control_p_shape" = "$treat_p_shape" ] \
        && [ "$control_pp_shape" = "$treat_pp_shape" ] \
        && [ "$control_statuses" = "$treat_statuses" ] \
        && [ "$control_pp_names" = "$treat_pp_names" ]; then ok=1; fi
    assert_cell "$cell" A2 "MACAMP-P/PP/FILE shapes, statuses and postprocessor names identical to the control run" "$ok"

    # A3 — embedded cover art survived the added flag.
    ok=0
    grep -q -F -- 'attached_pic=1' "$treat_probe" 2>/dev/null && ok=1
    assert_cell "$cell" A3 "embedded artwork survives (ffprobe reports an attached_pic stream)" "$ok"

    # A4 — nothing written after ffmpeg's own terminal marker.
    local last_progress_line
    last_progress_line="$(grep -F -- 'progress=' "$progress_copy" 2>/dev/null | tail -1)"
    local trailing_after_end
    trailing_after_end="$(awk '/^progress=end$/ {seen=1; next} seen && NF {print}' "$progress_copy" 2>/dev/null | wc -l | tr -d ' ')"
    ok=0
    if [ "$blocks_end" -eq 1 ] \
        && [ "$last_progress_line" = "progress=end" ] \
        && [ "$trailing_after_end" -eq 0 ] \
        && [ "$signature_at_exit" = "$signature_after_settle" ]; then ok=1; fi
    assert_cell "$cell" A4 "no writes after progress=end (single terminal marker, nothing trailing, size/mtime stable)" "$ok"

    # A5 — the stale file was truncated, not appended to.
    ok=0
    if [ "$seeded" -eq 1 ] && ! grep -q -F -- "$stale_sentinel" "$progress_copy" 2>/dev/null; then ok=1; fi
    assert_cell "$cell" A5 "pre-seeded stale progress file was overwritten (seed sentinel gone)" "$ok"

    local cell_result="CAPABLE"
    [ "$CELL_FAILED" -eq 1 ] && cell_result="BROKEN"
    SUMMARY_ROWS+=("$(printf '%-10s %-8s exit=%s  out_time_us=%-4s continue=%-4s end=%-2s  MACAMP-P=%-3s MACAMP-PP=%-3s' \
        "$cell" "$cell_result" "$treat_exit" "$samples_out_time_us" "$blocks_continue" "$blocks_end" "$treat_p" "$treat_pp")")
}

# ── The quoting sub-probe — reported, never gated ─────────────────────────────
run_quoting_subprobe() {
    local label="$1" ppa_value="$2" progress_file="$3"
    local slug="subprobe-$label"
    local out="$OUTPUT_DIR/$slug.stdout.txt"
    local err="$OUTPUT_DIR/$slug.stderr.txt"

    log ""
    log "── quoting sub-probe: $label ──────────────────────────────"
    rm -rf "$DOWNLOADS_DIR" "$STAGING_DIR"; mkdir -p "$DOWNLOADS_DIR" "$STAGING_DIR"
    rm -f "$progress_file"

    VECTOR=()
    build_vector "m4a" "best" "$ppa_value"
    printf '%s\n' "${VECTOR[@]}" >"$OUTPUT_DIR/$slug-vector.txt"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "  dry run: vector recorded, nothing executed"
        return 0
    fi

    run_vector "$out" "$err"
    local exit_code="$RUN_EXIT"
    local produced; produced="$(extracted_path "$out" "$err")"
    local samples=0
    local copy="$OUTPUT_DIR/$slug.ffprogress.txt"
    if [ -f "$progress_file" ]; then
        cp "$progress_file" "$copy"
        samples="$(grep -c -F -- 'out_time_us=' "$copy" 2>/dev/null || true)"
    else
        printf '<progress file was never created>\n' >"$copy"
    fi
    local outcome="WORKS"
    if [ "$exit_code" -ne 0 ] || [ -z "$produced" ]; then outcome="EXTRACTION BROKEN"
    elif [ ! -f "$progress_file" ]; then outcome="NO PROGRESS FILE"
    fi
    SUBPROBE_ROWS+=("$(printf '%-22s %-18s exit=%s out_time_us=%-4s file=%s' \
        "$label" "$outcome" "$exit_code" "$samples" "${produced:-<none>}")")
    log "  $label → $outcome (exit=$exit_code, out_time_us=$samples)"
}

# ── Drive ────────────────────────────────────────────────────────────────────
log "probe-ffmpeg-progress.sh"
log "  tools    : $TOOLS_DIR"
log "  evidence : $OUTPUT_DIR"
log "  scratch  : $SCRATCH"

run_cell m4a best
run_cell mp3 best
run_cell flac best

SPACED_UNQUOTED="$SPACED_PROGRESS_DIR/ffprogress [$VIDEO_ID].txt"
run_quoting_subprobe "spaced-path-unquoted" "ExtractAudio+ffmpeg:-progress $SPACED_UNQUOTED" "$SPACED_UNQUOTED"
run_quoting_subprobe "spaced-path-quoted" "ExtractAudio+ffmpeg:-progress \"$SPACED_UNQUOTED\"" "$SPACED_UNQUOTED"

# ── Summary + verdict ────────────────────────────────────────────────────────
SUMMARY="$OUTPUT_DIR/summary.txt"
{
    printf 'probe-ffmpeg-progress.sh — summary\n'
    printf '==================================\n\n'
    cat "$ENVIRONMENT_FILE"
    printf '\nGATED CELLS (verdict is decided by these three)\n'
    printf -- '----------------------------------------------\n'
    if [ "${#SUMMARY_ROWS[@]}" -gt 0 ]; then
        printf '%s\n' "${SUMMARY_ROWS[@]}"
    else
        printf '(none — dry run)\n'
    fi
    printf '\nSample counts above are RECORDED, NOT GATED. Whether a cell transcodes or\n'
    printf 'stream-copies is a property of the probe VIDEO (this one furnishes Opus audio,\n'
    printf 'so every cell re-encodes); an AAC itag-140 source would remux and produce near\n'
    printf 'zero samples with the identical flag. No pass/fail is keyed to these numbers.\n'
    printf '\nQUOTING SUB-PROBE (reported, NOT gated — a constraint on path composition)\n'
    printf -- '-------------------------------------------------------------------------\n'
    if [ "${#SUBPROBE_ROWS[@]}" -gt 0 ]; then
        printf '%s\n' "${SUBPROBE_ROWS[@]}"
    else
        printf '(none — dry run)\n'
    fi
    printf '\nASSERTION DETAIL\n'
    printf -- '----------------\n'
    for detail in "$OUTPUT_DIR"/cell-*-assertions.txt; do
        [ -f "$detail" ] || continue
        printf '\n--- %s\n' "$(basename "$detail")"
        cat "$detail"
    done
    printf '\n'
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'VERDICT: NOT RUN (dry run — vectors recorded, no network, no verdict)\n'
    elif [ "${#FAILURES[@]}" -eq 0 ]; then
        printf 'VERDICT: CAPABLE\n'
        printf 'All of A0-A5 hold in all three cells (m4a/best, mp3/best, flac/best).\n'
    else
        printf 'VERDICT: BROKEN (%s)\n' "$(printf '%s; ' "${FAILURES[@]}" | sed 's/; $//')"
    fi
} >"$SUMMARY"

log ""
log "───────────────────────────────────────────────────────────"
tail -n 4 "$SUMMARY"
log "───────────────────────────────────────────────────────────"
log "evidence: $OUTPUT_DIR"

if [ "$DRY_RUN" -eq 1 ]; then
    exit 0
fi
[ "${#FAILURES[@]}" -eq 0 ] || exit 1
exit 0
