#!/usr/bin/env bash
#
# fetch-download-tools.sh — ensure the YouTube-downloader helper binaries are installed.
#
# THE single source of truth for the "downloader tools stage". Every caller that
# needs macOS/Resources/DownloaderTools/ populated — scripts/build-macamp.sh, the
# release pipeline, a human following the distribution runbook — calls THIS
# script. Never re-implement the fetch / verify / license dance anywhere else.
# (Structural sibling of tools/separation/fetch-and-convert-model.sh: same
# inspect → fetch → verify → install state machine, same typed exit codes.)
#
# ── yt-dlp SHIPS AS A PyInstaller ONE-DIRECTORY TREE, NOT A SINGLE FILE ──────
#
# The `yt-dlp_macos` onefile asset re-unpacks ~37 MB into $TMPDIR/_MEI* on EVERY
# exec and never warms up: measured 13.61s / 14.10s / 13.07s for a bare
# `--version`, against 0.51s / 0.56s / 0.46s for the onedir build of the same
# release. MacAMP spawns the engine twice per download plus once per playlist
# paste, so onefile cost ~27s of pure startup per download. This script
# therefore installs the `yt-dlp_macos.zip` asset — a `yt-dlp_macos` launcher
# plus a SIBLING `_internal/` directory (134 files, 102 of them .dylib/.so,
# 124 MB on disk).
#
# `_internal/` MUST remain a sibling of the launcher. Removing or relocating it
# fails at launch with
#     [PYI-…:ERROR] Failed to load Python shared library '…/_internal/Python'
# so the tree can never be flattened, and everything downstream (the Tuist
# `.folderReference`, the copy-out in DownloadToolManager, the release VERIFY)
# moves the whole directory or nothing.
#
# Stages:
#   0. INSPECT — are all six artifacts already installed, do ffmpeg/ffprobe hash
#                to their pins, and does the yt-dlp TREE hash to its pin? If yes
#                (and no --force), exit 0 immediately ("cached"): no network, no
#                unzip, no exec. A leftover onefile `yt-dlp_macos` from the old
#                layout is deleted here — the one thing stage 0 ever writes.
#   1. FETCH   — download yt-dlp_macos.zip + ffmpeg.zip + ffprobe.zip + the four
#                upstream license texts into a scratch dir, SHA-256-verifying
#                every single one against the pins in this header. The yt-dlp
#                ZIP is verified BEFORE it is extracted.
#   2. VERIFY  — unzip, then EXECUTE the fetched ffmpeg once (`ffmpeg -version`)
#                and hard-fail unless its configure line carries --enable-gpl and
#                does NOT carry --enable-nonfree. A nonfree build (fdk-aac) is
#                not redistributable and would make every shipped .dmg a license
#                violation. The captured configure line is verbatim what lands in
#                SOURCE-OFFER.txt. Also execs the extracted yt-dlp tree once to
#                confirm its version — which is simultaneously proof that
#                `_internal/` extracted intact.
#   3. INSTALL — move the verified ffmpeg/ffprobe binaries and the whole yt-dlp
#                directory tree into macOS/Resources/DownloaderTools/ and compose
#                LICENSE-yt-dlp.txt, LICENSE-ffmpeg.txt and SOURCE-OFFER.txt
#                beside them.
#   4. VERIFY  — re-inspect the installed directory exactly as stage 0 does.
#
# The idempotent stage-0 fast path is safe ONLY because the SHA-256 pins below
# make the installed artifacts bit-identical to the ones this script verified at
# install time. For yt-dlp that means the WHOLE tree, not just its launcher: 102
# of the 134 files are shared libraries dlopen'd at run time, so a pin on the
# launcher alone would let a corrupt `_internal/Python` sail through the fast
# path forever. ``YTDLP_TREE_SHA256`` closes that. Bumping ANY pin makes the
# installed bytes mismatch, which drops out of the fast path and re-runs the
# FULL verify — including the ffmpeg GPL configure-line gate — by construction.
# Never weaken a check to a size/mtime comparison, and never add a "skip verify"
# flag: the gate's correctness rests entirely on hash identity.
#
# NOTHING here is ever committed to git (see .gitignore:
# macOS/Resources/DownloaderTools/). The binaries are fetched at build time and
# bundled into the .app; at APP RUNTIME they are executed only from the
# Application Support copy, never from inside the bundle. This script's own
# stage-2 verify (and its recorded QA probes) are the deliberate, sole
# build-time exception — running ffmpeg is the only way to prove the GPL claim.
#
# Usage:
#   tools/downloader/fetch-download-tools.sh            # ensure (cached-fast)
#   tools/downloader/fetch-download-tools.sh --force    # re-fetch regardless
#
# Flags:
#   --force      Re-fetch and re-install even when valid artifacts are present.
#                Also bypasses the corrupt-artifact hard stop (exit 3).
#   -h, --help   This text.
#
# Exit codes:
#   0  artifacts installed (fetched) or already valid (cached)
#   1  bad arguments
#   2  network or tooling unusable (no curl/unzip/shasum, download failed, or
#      the host cannot execute the arm64 ffmpeg — an Apple-silicon Mac is
#      required, matching the arm64-only shipping build)
#   3  present-but-invalid: installed artifacts are corrupt / hash-mismatched
#      (re-run with --force, or delete the directory), OR the fetched ffmpeg
#      FAILS the GPL licence gate (missing --enable-gpl, or --enable-nonfree)
#   4  fetched-but-unverifiable: a download's SHA-256 did not match its pin, or
#      the freshly installed artifacts did not pass the post-install re-inspect
#
set -euo pipefail

# ============================================================================
# PINS — researched and verified 2026-09-09. Every value below is a LITERAL.
# Nothing here resolves "latest" at run time; that is the whole point.
#
# To bump: change the version/URL, re-download by hand, recompute every hash
# with `shasum -a 256`, paste them in, then run this script with --force. The
# GPL configure-line gate re-runs automatically because the pins changed.
# ============================================================================

# ---- yt-dlp ------------------------------------------------------------------
# Universal (x86_64 + arm64) PyInstaller ONE-DIRECTORY build, macOS 10.15+.
# The `.zip` asset (51.4 MB) from the SAME release as the onefile `yt-dlp_macos`
# asset it replaces; it expands to `yt-dlp_macos` + `_internal/` (124 MB).
#
# THREE hashes, each answering a different question:
#   *_ZIP_SHA256  the published archive, verified BEFORE extraction. Taken
#                 verbatim from the release's own SHA2-256SUMS, then re-verified
#                 against the downloaded bytes.
#   *_BIN_SHA256  the extracted launcher — the one file that is exec'd.
#   *_TREE_SHA256 a deterministic digest over ALL 134 extracted files
#                 (`ytdlp_tree_digest`), which is what the stage-0 fast path
#                 re-checks. The archive is gone by then, and the launcher alone
#                 says nothing about the 102 shared libraries beside it.
YTDLP_VERSION="2026.08.19"
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos.zip"
YTDLP_ZIP_SHA256="07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8"
YTDLP_BIN_SHA256="4f54eb67e4e96c7c3ffa49dd5deb81bc348bbb495080889b47d157d5c6d74443"
YTDLP_TREE_SHA256="60a64cf56a888f09c0173bef90d766b311117fd03030855019192baf7c3a18c5"
YTDLP_SUMS_URL="https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/SHA2-256SUMS"
YTDLP_RELEASE_URL="https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19"
YTDLP_SOURCE_URL="https://github.com/yt-dlp/yt-dlp/archive/refs/tags/2026.08.19.tar.gz"

# ---- ffmpeg / ffprobe --------------------------------------------------------
# Martin Riedl's FFmpeg build server, macOS Apple-Silicon/arm64 RELEASE build
# (not a snapshot). Chosen over osxexperts.net because it publishes a per-file
# SHA-256, a stable per-build URL, AND the full build recipe as open source.
# yt-dlp's own FFmpeg-Builds ships no macOS binaries at all.
#
# TWO hashes per tool on purpose: *_ZIP_SHA256 is the builder's own published
# checksum (verified on download, proves we got what upstream advertises);
# *_BIN_SHA256 is the extracted Mach-O (what actually gets installed and what
# the stage-0 fast path re-checks).
FFMPEG_VERSION="9.0.1"
FFMPEG_BUILD_ID="1787073674_9.0.1"
FFMPEG_BUILD_DATE="2026-08-18"
FFMPEG_BASE_URL="https://ffmpeg.martin-riedl.de/download/macos/arm64/1787073674_9.0.1"
FFMPEG_ZIP_SHA256="8287a1b2229e05eb41859f073e18e6c52c60a778f2f5e6881070fe51b79407fe"
FFMPEG_BIN_SHA256="393e4c395020a1cb7cbd77fbe00599ce69d1c6466fee0dbd59d13f86a81a1611"
FFPROBE_ZIP_SHA256="102a26b8940a053298d9929bfaae71e4b6ef65ba5f19a99a88c433108560741a"
FFPROBE_BIN_SHA256="7abc49fb2bdf2204f018e76dc6e0a8ae7643313bae09a9fa43e7eb12442271bc"
FFMPEG_BUILDER_URL="https://ffmpeg.martin-riedl.de/"
FFMPEG_RECIPE_URL="https://git.martin-riedl.de/ffmpeg/build-script"
FFMPEG_SOURCE_URL="https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n9.0.1.tar.gz"

# ---- upstream licence texts --------------------------------------------------
# Each is pinned to the same tag as the binary it documents, and hash-verified.
YTDLP_LICENSE_URL="https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.08.19/LICENSE"
YTDLP_LICENSE_SHA256="7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c"
YTDLP_THIRD_PARTY_URL="https://raw.githubusercontent.com/yt-dlp/yt-dlp/2026.08.19/THIRD_PARTY_LICENSES.txt"
GPL3_URL="https://www.gnu.org/licenses/gpl-3.0.txt"
GPL3_SHA256="3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"
FFMPEG_LICENSE_URL="https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.1/LICENSE.md"
FFMPEG_LICENSE_SHA256="2e1d16c72fd74e12063776371da757322f8b77589386532f4fd8634bde7de1af"
FFMPEG_GPL3_URL="https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.1/COPYING.GPLv3"
FFMPEG_GPL3_SHA256="8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903"

# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Self-location guard. With a broken PATH `dirname` is unavailable and the
# command substitution above silently degrades to the current directory, which
# would point REPO_ROOT at the repo's PARENT and install six binaries into a
# stranger's tree. Assert the script actually found itself before cd-ing.
if [[ ! -f "${SCRIPT_DIR}/fetch-download-tools.sh" || "${SCRIPT_DIR}" != "${REPO_ROOT}/tools/downloader" ]]; then
    echo "error: could not determine the repository root from '${BASH_SOURCE[0]}'." >&2
    echo "       resolved SCRIPT_DIR='${SCRIPT_DIR}' REPO_ROOT='${REPO_ROOT}'" >&2
    echo "       Basic tooling (dirname) is probably missing from PATH. NOTHING was touched." >&2
    exit 2
fi

cd "${REPO_ROOT}"

TOOLS_DIR="macOS/Resources/DownloaderTools"
# The onedir tree ships as ONE opaque directory (Tuist `.folderReference`), so
# every consumer names the DIRECTORY and reaches the launcher through it.
YTDLP_TREE_DIR="${TOOLS_DIR}/yt-dlp"
YTDLP_BIN="${YTDLP_TREE_DIR}/yt-dlp_macos"
YTDLP_INTERNAL_DIR="${YTDLP_TREE_DIR}/_internal"
# Where the pre-onedir layout put the 35 MB onefile binary. Deleted on sight.
YTDLP_LEGACY_BIN="${TOOLS_DIR}/yt-dlp_macos"
FFMPEG_BIN="${TOOLS_DIR}/ffmpeg"
FFPROBE_BIN="${TOOLS_DIR}/ffprobe"
YTDLP_LICENSE_FILE="${TOOLS_DIR}/LICENSE-yt-dlp.txt"
FFMPEG_LICENSE_FILE="${TOOLS_DIR}/LICENSE-ffmpeg.txt"
SOURCE_OFFER_FILE="${TOOLS_DIR}/SOURCE-OFFER.txt"

FORCE=0
STAGING=""

die() { echo "error: $*" >&2; exit 1; }
fail() { local code="$1"; shift; echo "error: $*" >&2; exit "${code}"; }
step() { printf '\n==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

cleanup() { [[ -n "${STAGING}" && -d "${STAGING}" ]] && rm -rf "${STAGING}"; return 0; }
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        -h|--help)
            sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; s/^#$//'
            exit 0 ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
done

# ------------------------------------------------------------------- helpers

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# A reproducible SHA-256 over every file in the tree rooted at $1.
#
# `shasum`'s own output embeds each path, so a moved, renamed or added file
# changes the digest as surely as an edited byte does. `-print0`/`sort -z`/
# `xargs -0` keep it correct for any future upstream filename, and LC_ALL=C
# fixes the collation so the same tree digests identically on any machine.
ytdlp_tree_digest() {
    ( cd "$1" && find . -type f -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 shasum -a 256 \
        | shasum -a 256 | awk '{print $1}' )
}

# Echoes a human-readable problem and returns 1 when the yt-dlp onedir tree at
# $1 is absent, incomplete, not executable, or does not digest to $2.
tree_problem() {
    local root="$1" want="$2" got
    if [[ ! -d "${root}" ]]; then echo "absent"; return 1; fi
    if [[ ! -f "${root}/yt-dlp_macos" ]]; then echo "launcher yt-dlp_macos missing"; return 1; fi
    if [[ ! -d "${root}/_internal" ]]; then echo "_internal/ missing (the tree was flattened)"; return 1; fi
    if [[ ! -x "${root}/yt-dlp_macos" ]]; then echo "launcher not executable"; return 1; fi
    got="$(ytdlp_tree_digest "${root}")"
    if [[ "${got}" != "${want}" ]]; then
        echo "tree SHA-256 mismatch (have ${got}, want ${want})"
        return 1
    fi
    return 0
}

# Echoes a human-readable problem and returns 1 when the binary at $1 is absent,
# does not hash to $2, or is not executable. Returns 0 (silently) otherwise.
binary_problem() {
    local path="$1" want="$2" got
    if [[ ! -f "${path}" ]]; then echo "absent"; return 1; fi
    got="$(sha256_of "${path}")"
    if [[ "${got}" != "${want}" ]]; then
        echo "SHA-256 mismatch (have ${got}, want ${want})"
        return 1
    fi
    if [[ ! -x "${path}" ]]; then echo "not executable"; return 1; fi
    return 0
}

# Echoes a human-readable problem and returns 1 when the text file at $1 is
# absent, empty, or does not contain the literal marker $2.
text_problem() {
    local path="$1" marker="$2"
    if [[ ! -f "${path}" ]]; then echo "absent"; return 1; fi
    if [[ ! -s "${path}" ]]; then echo "empty"; return 1; fi
    if ! grep -qF -- "${marker}" "${path}"; then
        echo "missing required marker '${marker}'"
        return 1
    fi
    return 0
}

ACC_PROBLEMS=""
ACC_ABSENT=0
ACC_TOTAL=0
acc() { # label problem-or-empty
    ACC_TOTAL=$((ACC_TOTAL + 1))
    [[ -z "$2" ]] && return 0
    [[ "$2" == "absent" ]] && ACC_ABSENT=$((ACC_ABSENT + 1))
    ACC_PROBLEMS="${ACC_PROBLEMS}${ACC_PROBLEMS:+; }$1: $2"
    return 0
}

# Sets INSTALL_STATE to ok | absent | corrupt and INSTALL_DETAIL to the reason.
INSTALL_STATE=""
INSTALL_DETAIL=""
inspect_install() {
    ACC_PROBLEMS=""; ACC_ABSENT=0; ACC_TOTAL=0
    acc "yt-dlp/ (onedir)"   "$(tree_problem "${YTDLP_TREE_DIR}" "${YTDLP_TREE_SHA256}" || true)"
    acc "ffmpeg"             "$(binary_problem "${FFMPEG_BIN}" "${FFMPEG_BIN_SHA256}" || true)"
    acc "ffprobe"            "$(binary_problem "${FFPROBE_BIN}" "${FFPROBE_BIN_SHA256}" || true)"
    acc "LICENSE-yt-dlp.txt" "$(text_problem "${YTDLP_LICENSE_FILE}" "GNU GENERAL PUBLIC LICENSE" || true)"
    acc "LICENSE-ffmpeg.txt" "$(text_problem "${FFMPEG_LICENSE_FILE}" "GNU GENERAL PUBLIC LICENSE" || true)"
    acc "SOURCE-OFFER.txt"   "$(text_problem "${SOURCE_OFFER_FILE}" "--enable-gpl" || true)"

    if [[ -z "${ACC_PROBLEMS}" ]]; then
        INSTALL_STATE="ok"
        INSTALL_DETAIL="${ACC_TOTAL}/${ACC_TOTAL} artifacts present, yt-dlp tree + 2/2 binaries match their SHA-256 pins"
    elif [[ "${ACC_ABSENT}" -eq "${ACC_TOTAL}" ]]; then
        INSTALL_STATE="absent"
        INSTALL_DETAIL="nothing installed in ${TOOLS_DIR}/"
    else
        INSTALL_STATE="corrupt"
        INSTALL_DETAIL="${ACC_PROBLEMS}"
    fi
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail 2 "required tool '$1' not found on PATH"
}

fetch() { # url dest label
    curl --fail --silent --show-error --location \
         --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 \
         -o "$2" "$1" \
        || fail 2 "download failed ($3): $1"
}

verify_sha() { # path expected label
    local got
    got="$(sha256_of "$1")"
    if [[ "${got}" != "$2" ]]; then
        echo "error: SHA-256 mismatch for $3" >&2
        echo "       expected ${2}" >&2
        echo "       actual   ${got}" >&2
        echo "       The pin in this script no longer matches upstream (re-uploaded asset," >&2
        echo "       stale pin, or a tampered download). NOTHING was installed." >&2
        exit 4
    fi
}

# ---------------------------------------------------------------- 0. INSPECT
step "DOWNLOADER TOOLS: inspecting ${TOOLS_DIR}/"

# The onefile→onedir migration seam, and the ONLY write stage 0 ever performs.
# It removes a 35 MB artifact THIS script installed under the previous layout,
# inside a git-ignored directory this script owns. Doing it here rather than at
# INSTALL is deliberate: an already-cached machine never reaches INSTALL, so the
# stale binary would otherwise survive every future build — and `release.sh`
# still locates the engine with `find … -name yt-dlp_macos`, which would then
# match the slow onefile instead of the bundled tree.
LEGACY_SWEPT=0
if [[ -f "${YTDLP_LEGACY_BIN}" ]]; then
    rm -f "${YTDLP_LEGACY_BIN}"
    LEGACY_SWEPT=1
    note "removed the pre-onedir ${YTDLP_LEGACY_BIN} (superseded by ${YTDLP_TREE_DIR}/)"
fi

inspect_install
note "state: ${INSTALL_STATE} — ${INSTALL_DETAIL}"
note "pins:  yt-dlp ${YTDLP_VERSION} · ffmpeg/ffprobe ${FFMPEG_VERSION} (arm64, martin-riedl.de)"

# A machine coming from the onefile layout has ffmpeg, ffprobe and the licence
# texts installed but no yt-dlp tree, which `inspect_install` can only read as
# "corrupt" — and that verdict is a hard stop demanding --force, which
# `build-macamp.sh` never passes. The sweep above is the discriminator: when it
# actually fired, this absence is a KNOWN migration rather than a suspicious
# half-deleted directory, so repair it instead of refusing. The guard is not
# weakened for any other partial state.
if [[ "${INSTALL_STATE}" == "corrupt" && "${FORCE}" -eq 0 && "${LEGACY_SWEPT}" -eq 0 ]]; then
    echo "error: ${TOOLS_DIR}/ holds INVALID artifacts — ${INSTALL_DETAIL}" >&2
    echo "       Re-run with --force to re-fetch them, or delete ${TOOLS_DIR}/ and retry." >&2
    exit 3
fi

if [[ "${INSTALL_STATE}" == "ok" && "${FORCE}" -eq 0 ]]; then
    step "DOWNLOADER TOOLS: cached — ${TOOLS_DIR}/ already valid, nothing to do"
    note "every binary is bit-identical to the verified pin, so the stage-2 GPL"
    note "configure-line gate cannot have changed. Pass --force to re-fetch."
    exit 0
fi

REASON="artifacts absent"
if [[ "${INSTALL_STATE}" == "corrupt" && "${LEGACY_SWEPT}" -eq 1 && "${FORCE}" -eq 0 ]]; then
    REASON="migrating from the onefile layout to the onedir tree"
elif [[ "${INSTALL_STATE}" == "corrupt" ]]; then
    REASON="artifacts invalid, --force given"
elif [[ "${INSTALL_STATE}" == "ok" ]]; then
    REASON="--force given (valid artifacts will be overwritten)"
fi

require_tool curl
require_tool unzip
require_tool shasum

# ------------------------------------------------------------------ 1. FETCH
step "DOWNLOADER TOOLS: fetching — ${REASON}"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/macamp-dltools.XXXXXX")"

note "yt-dlp_macos.zip ${YTDLP_VERSION} (onedir) …"
fetch "${YTDLP_URL}" "${STAGING}/yt-dlp_macos.zip" "yt-dlp_macos.zip"
verify_sha "${STAGING}/yt-dlp_macos.zip" "${YTDLP_ZIP_SHA256}" "yt-dlp_macos.zip"

note "ffmpeg ${FFMPEG_VERSION} (arm64) …"
fetch "${FFMPEG_BASE_URL}/ffmpeg.zip" "${STAGING}/ffmpeg.zip" "ffmpeg.zip"
verify_sha "${STAGING}/ffmpeg.zip" "${FFMPEG_ZIP_SHA256}" "ffmpeg.zip"

note "ffprobe ${FFMPEG_VERSION} (arm64) …"
fetch "${FFMPEG_BASE_URL}/ffprobe.zip" "${STAGING}/ffprobe.zip" "ffprobe.zip"
verify_sha "${STAGING}/ffprobe.zip" "${FFPROBE_ZIP_SHA256}" "ffprobe.zip"

note "licence texts (4) …"
fetch "${YTDLP_LICENSE_URL}" "${STAGING}/ytdlp-LICENSE" "yt-dlp LICENSE"
verify_sha "${STAGING}/ytdlp-LICENSE" "${YTDLP_LICENSE_SHA256}" "yt-dlp LICENSE"
fetch "${GPL3_URL}" "${STAGING}/gpl-3.0.txt" "GNU GPLv3"
verify_sha "${STAGING}/gpl-3.0.txt" "${GPL3_SHA256}" "GNU GPLv3"
fetch "${FFMPEG_LICENSE_URL}" "${STAGING}/ffmpeg-LICENSE.md" "FFmpeg LICENSE.md"
verify_sha "${STAGING}/ffmpeg-LICENSE.md" "${FFMPEG_LICENSE_SHA256}" "FFmpeg LICENSE.md"
fetch "${FFMPEG_GPL3_URL}" "${STAGING}/ffmpeg-COPYING.GPLv3" "FFmpeg COPYING.GPLv3"
verify_sha "${STAGING}/ffmpeg-COPYING.GPLv3" "${FFMPEG_GPL3_SHA256}" "FFmpeg COPYING.GPLv3"

note "✓ 7/7 downloads match their SHA-256 pins"

# ----------------------------------------------------------------- 2. VERIFY
step "DOWNLOADER TOOLS: verifying"

STAGED_TREE="${STAGING}/yt-dlp"
mkdir -p "${STAGED_TREE}"
unzip -oq "${STAGING}/yt-dlp_macos.zip" -d "${STAGED_TREE}" \
    || fail 4 "yt-dlp_macos.zip could not be extracted"
unzip -oq "${STAGING}/ffmpeg.zip" ffmpeg -d "${STAGING}" \
    || fail 4 "ffmpeg.zip does not contain an 'ffmpeg' entry"
unzip -oq "${STAGING}/ffprobe.zip" ffprobe -d "${STAGING}" \
    || fail 4 "ffprobe.zip does not contain an 'ffprobe' entry"
chmod 755 "${STAGED_TREE}/yt-dlp_macos" "${STAGING}/ffmpeg" "${STAGING}/ffprobe"

[[ -d "${STAGED_TREE}/_internal" ]] \
    || fail 4 "yt-dlp_macos.zip extracted without an _internal/ directory — the launcher cannot start without it"

verify_sha "${STAGED_TREE}/yt-dlp_macos" "${YTDLP_BIN_SHA256}" "extracted yt-dlp launcher"
STAGED_TREE_DIGEST="$(ytdlp_tree_digest "${STAGED_TREE}")"
if [[ "${STAGED_TREE_DIGEST}" != "${YTDLP_TREE_SHA256}" ]]; then
    echo "error: SHA-256 mismatch for the extracted yt-dlp onedir tree" >&2
    echo "       expected ${YTDLP_TREE_SHA256}" >&2
    echo "       actual   ${STAGED_TREE_DIGEST}" >&2
    echo "       The archive matched its pin but expanded to a different tree — a" >&2
    echo "       partial unzip, or a changed pin. NOTHING was installed." >&2
    exit 4
fi
note "✓ yt-dlp tree: $(find "${STAGED_TREE}" -type f | wc -l | tr -d ' ') files match the pinned tree digest"

verify_sha "${STAGING}/ffmpeg" "${FFMPEG_BIN_SHA256}" "extracted ffmpeg binary"
verify_sha "${STAGING}/ffprobe" "${FFPROBE_BIN_SHA256}" "extracted ffprobe binary"
note "✓ extracted ffmpeg + ffprobe match their binary SHA-256 pins"

note "arch: yt-dlp_macos → $(file -b "${STAGED_TREE}/yt-dlp_macos" | head -1)"
note "arch: ffmpeg       → $(file -b "${STAGING}/ffmpeg")"
note "arch: ffprobe      → $(file -b "${STAGING}/ffprobe")"

# The ONE deliberate build-time execution of a fetched binary. Running ffmpeg is
# the only way to read its real configure line, and the licence claim in
# SOURCE-OFFER.txt must be measured, never assumed.
FFMPEG_VERSION_OUTPUT=""
if ! FFMPEG_VERSION_OUTPUT="$("${STAGING}/ffmpeg" -hide_banner -version 2>&1)"; then
    echo "error: could not execute the fetched arm64 ffmpeg on this host." >&2
    echo "       ${FFMPEG_VERSION_OUTPUT}" >&2
    echo "       This build is arm64-only (matching the shipping ARCHS=arm64 app), so an" >&2
    echo "       Apple-silicon Mac is required. NOTHING was installed." >&2
    exit 2
fi

FFMPEG_CONFIGURE_LINE="$(printf '%s\n' "${FFMPEG_VERSION_OUTPUT}" \
    | awk '/^configuration:/ { sub(/^configuration: */, ""); print; exit }')"
FFMPEG_BANNER="$(printf '%s\n' "${FFMPEG_VERSION_OUTPUT}" | head -1)"
note "${FFMPEG_BANNER}"

[[ -n "${FFMPEG_CONFIGURE_LINE}" ]] \
    || fail 3 "ffmpeg -version printed no 'configuration:' line — the GPL licence gate cannot be evaluated"

case "${FFMPEG_CONFIGURE_LINE}" in
    *--enable-nonfree*)
        echo "error: LICENCE GATE FAILED — the fetched ffmpeg is a NONFREE build." >&2
        echo "       configure: ${FFMPEG_CONFIGURE_LINE}" >&2
        echo "       A --enable-nonfree binary (typically fdk-aac) may NOT be redistributed;" >&2
        echo "       shipping it would make every MacAMP .dmg a licence violation." >&2
        echo "       Pin the other candidate source (osxexperts.net) instead. NOTHING was installed." >&2
        exit 3 ;;
esac
case "${FFMPEG_CONFIGURE_LINE}" in
    *--enable-gpl*) : ;;
    *)
        echo "error: LICENCE GATE FAILED — the fetched ffmpeg was not built with --enable-gpl." >&2
        echo "       configure: ${FFMPEG_CONFIGURE_LINE}" >&2
        echo "       MacAMP's bundle documents this binary as GPL; an LGPL-only build would make" >&2
        echo "       SOURCE-OFFER.txt false. Pin a --enable-gpl build. NOTHING was installed." >&2
        exit 3 ;;
esac
note "✓ licence gate: --enable-gpl present, --enable-nonfree absent"

# Running the launcher is simultaneously the proof that `_internal/` expanded
# intact: PyInstaller resolves its Python shared library out of that sibling
# directory, so a truncated tree fails here rather than on a listener's machine.
YTDLP_VERSION_OUTPUT=""
if ! YTDLP_VERSION_OUTPUT="$("${STAGED_TREE}/yt-dlp_macos" --version 2>&1)"; then
    echo "error: could not execute the fetched yt-dlp_macos on this host." >&2
    echo "       ${YTDLP_VERSION_OUTPUT}" >&2
    echo "       NOTHING was installed." >&2
    exit 2
fi
YTDLP_REPORTED="$(printf '%s\n' "${YTDLP_VERSION_OUTPUT}" | tail -1)"
[[ "${YTDLP_REPORTED}" == "${YTDLP_VERSION}" ]] \
    || fail 4 "yt-dlp reports version '${YTDLP_REPORTED}' but the pin says '${YTDLP_VERSION}'"
note "✓ yt-dlp reports ${YTDLP_REPORTED}"

# ---------------------------------------------------------------- 3. INSTALL
step "DOWNLOADER TOOLS: installing into ${TOOLS_DIR}/"
mkdir -p "${TOOLS_DIR}"

install_binary() { # staged-name dest
    rm -f "$2"
    mv "${STAGING}/$1" "$2"
    chmod 755 "$2"
}
# The tree moves WHOLE. `rm -rf` first so a shrinking upstream release cannot
# leave orphaned files behind that the pinned tree digest would then reject.
rm -rf "${YTDLP_TREE_DIR}"
mv "${STAGED_TREE}" "${YTDLP_TREE_DIR}"
chmod 755 "${YTDLP_BIN}"
install_binary ffmpeg "${FFMPEG_BIN}"
install_binary ffprobe "${FFPROBE_BIN}"
note "yt-dlp/ ($(find "${YTDLP_TREE_DIR}" -type f | wc -l | tr -d ' ') files incl. _internal/), ffmpeg, ffprobe (mode 755)"

{
    cat <<EOF
MacAMP — licence notice for the bundled yt-dlp binary
=====================================================

Bundled artifact : yt-dlp/ (PyInstaller one-directory build: the yt-dlp_macos
                   launcher plus its sibling _internal/ support directory)
Version (pinned) : ${YTDLP_VERSION}
Download URL     : ${YTDLP_URL}
SHA-256 (archive): ${YTDLP_ZIP_SHA256}
SHA-256 (launcher): ${YTDLP_BIN_SHA256}
Upstream project : https://github.com/yt-dlp/yt-dlp

yt-dlp's own source code is released into the public domain under the Unlicense
(reproduced in PART 1 below). However, the PyInstaller-bundled release
executables — which is exactly what MacAMP ships — include GPLv3+ licensed
code, so THE COMBINED WORK IS LICENSED UNDER GPLv3+ (reproduced in PART 2
below). This is upstream's own statement in README.md, section
"Release Files → Licensing".

A full third-party licence inventory for the release binaries is published by
upstream at:
    ${YTDLP_THIRD_PARTY_URL}

Complete corresponding source code, and MacAMP's written offer for it, are
recorded in SOURCE-OFFER.txt beside this file.

--------------------------------------------------------------------------------
PART 1 — yt-dlp project licence (Unlicense), verbatim from
         ${YTDLP_LICENSE_URL}
--------------------------------------------------------------------------------

EOF
    cat "${STAGING}/ytdlp-LICENSE"
    cat <<EOF

--------------------------------------------------------------------------------
PART 2 — GNU General Public License v3, verbatim from
         ${GPL3_URL}
         (the licence of the combined PyInstaller executable MacAMP bundles)
--------------------------------------------------------------------------------

EOF
    cat "${STAGING}/gpl-3.0.txt"
} > "${YTDLP_LICENSE_FILE}"

{
    cat <<EOF
MacAMP — licence notice for the bundled FFmpeg binaries
=======================================================

Bundled artifacts : ffmpeg, ffprobe (static, arm64)
Version (pinned)  : ${FFMPEG_VERSION}
Build             : ${FFMPEG_BUILD_ID} (built ${FFMPEG_BUILD_DATE})
Builder           : Martin Riedl's FFmpeg Build Server — ${FFMPEG_BUILDER_URL}
Download URLs     : ${FFMPEG_BASE_URL}/ffmpeg.zip
                    ${FFMPEG_BASE_URL}/ffprobe.zip
SHA-256 (ffmpeg)  : ${FFMPEG_BIN_SHA256}
SHA-256 (ffprobe) : ${FFPROBE_BIN_SHA256}
Upstream project  : https://ffmpeg.org/

These binaries were configured with BOTH --enable-gpl and --enable-version3 and
WITHOUT --enable-nonfree, so they are distributed under the GNU General Public
License version 3 (reproduced in PART 2 below). The exact configure line this
script measured by running \`ffmpeg -version\` is:

    ${FFMPEG_CONFIGURE_LINE}

Complete corresponding source code, and MacAMP's written offer for it, are
recorded in SOURCE-OFFER.txt beside this file.

--------------------------------------------------------------------------------
PART 1 — FFmpeg's own LICENSE.md, verbatim from
         ${FFMPEG_LICENSE_URL}
--------------------------------------------------------------------------------

EOF
    cat "${STAGING}/ffmpeg-LICENSE.md"
    cat <<EOF

--------------------------------------------------------------------------------
PART 2 — GNU General Public License v3, verbatim from
         ${FFMPEG_GPL3_URL}
--------------------------------------------------------------------------------

EOF
    cat "${STAGING}/ffmpeg-COPYING.GPLv3"
} > "${FFMPEG_LICENSE_FILE}"

note "LICENSE-yt-dlp.txt, LICENSE-ffmpeg.txt"

cat > "${SOURCE_OFFER_FILE}" <<EOF
MacAMP — WRITTEN OFFER FOR COMPLETE CORRESPONDING SOURCE CODE
=============================================================

MacAMP redistributes the unmodified third-party executables listed below. They
are covered by the GNU General Public License version 3 (see LICENSE-yt-dlp.txt
and LICENSE-ffmpeg.txt beside this file). This document is the written offer
required by GPLv3 section 6, and it records the exact provenance of every
bundled binary so that the corresponding source can be obtained.

This file is GENERATED by tools/downloader/fetch-download-tools.sh from the
literal pins in that script's header. It is never hand-edited.

--------------------------------------------------------------------------------
1. yt-dlp
--------------------------------------------------------------------------------
Bundled files     : yt-dlp/yt-dlp_macos + yt-dlp/_internal/ (PyInstaller
                    one-directory build, redistributed whole)
Version (pinned)  : ${YTDLP_VERSION}
Licence           : GPLv3+ (the PyInstaller-bundled executable is a combined
                    work; yt-dlp's own sources are Unlicense)
Archive URL       : ${YTDLP_URL}
Archive SHA-256   : ${YTDLP_ZIP_SHA256}
Launcher SHA-256  : ${YTDLP_BIN_SHA256}
Tree SHA-256      : ${YTDLP_TREE_SHA256}
                    (digest over all files extracted from the archive)
Publisher hashes  : ${YTDLP_SUMS_URL}
Release page      : ${YTDLP_RELEASE_URL}
SOURCE CODE       : ${YTDLP_SOURCE_URL}
Third-party audit : ${YTDLP_THIRD_PARTY_URL}
Modifications     : NONE. The binary is redistributed byte-for-byte as
                    published upstream; the SHA-256 above proves it.

--------------------------------------------------------------------------------
2. FFmpeg (ffmpeg + ffprobe)
--------------------------------------------------------------------------------
Bundled files     : ffmpeg, ffprobe
Version (pinned)  : ${FFMPEG_VERSION}  (upstream tag n${FFMPEG_VERSION})
Build identifier  : ${FFMPEG_BUILD_ID}, built ${FFMPEG_BUILD_DATE}, static, arm64
Licence           : GPLv3 (--enable-gpl + --enable-version3, no --enable-nonfree)
Binary URLs       : ${FFMPEG_BASE_URL}/ffmpeg.zip
                    ${FFMPEG_BASE_URL}/ffprobe.zip
Archive SHA-256   : ${FFMPEG_ZIP_SHA256}  (ffmpeg.zip)
                    ${FFPROBE_ZIP_SHA256}  (ffprobe.zip)
Binary SHA-256    : ${FFMPEG_BIN_SHA256}  (ffmpeg)
                    ${FFPROBE_BIN_SHA256}  (ffprobe)
Builder           : ${FFMPEG_BUILDER_URL}
BUILD RECIPE      : ${FFMPEG_RECIPE_URL}
                    (the third-party builder's published, open-source build
                    scripts — the exact steps that produced these binaries)
SOURCE CODE       : ${FFMPEG_SOURCE_URL}
Modifications     : NONE by MacAMP. The binaries are redistributed byte-for-byte
                    as published by the builder; the SHA-256 values above prove
                    it. The builder applies no source patches — see the recipe.

FULL CONFIGURE LINE, read at build time from \`ffmpeg -version\` on the exact
binary that ships (not copied from any web page):

${FFMPEG_CONFIGURE_LINE}

--------------------------------------------------------------------------------
3. WRITTEN OFFER
--------------------------------------------------------------------------------
For any of the GPL-licensed binaries listed above, the complete corresponding
source code is available at the SOURCE CODE URLs given for each component. In
addition, and for at least three years from the date you received this copy of
MacAMP, the MacAMP maintainers will, on request, provide you with a complete
machine-readable copy of the corresponding source code for the exact versions
listed above, for no more than the cost of physically performing the
distribution. Requests should be filed as an issue on the MacAMP project
repository.

No MacAMP source code is combined into these executables. They are separate,
unmodified programs, invoked as child processes at arm's length; MacAMP's own
code is not a derivative work of either.
EOF

note "SOURCE-OFFER.txt"

# ----------------------------------------------------------------- 4. VERIFY
step "DOWNLOADER TOOLS: verifying installed artifacts"
inspect_install
case "${INSTALL_STATE}" in
    ok) note "✓ ${INSTALL_DETAIL}" ;;
    absent) fail 4 "install finished but ${TOOLS_DIR}/ is empty" ;;
    *) fail 4 "install finished but the artifacts are invalid — ${INSTALL_DETAIL}" ;;
esac

step "DOWNLOADER TOOLS: done — ${TOOLS_DIR}/ ready (never committed to git)"
exit 0
