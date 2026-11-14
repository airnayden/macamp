#!/usr/bin/env bash
#
# release.sh — ONE command that takes this repo to a shippable MacAMP release.
#
# It is a pure ORCHESTRATOR: every unit of real work belongs to a script that
# already exists and is independently runnable. release.sh only decides WHAT
# runs, in WHICH ORDER, and HALTS on the first thing that would produce a
# broken artifact. It never re-implements a step (no venv logic, no key
# generation, no dmg assembly of its own).
#
# Stages (each announced with a banner):
#
#   [0] PREFLIGHT  Required tools present, --version sane, git tree clean?
#                  Chooses the signing mode: Developer ID vs ad-hoc.
#   [1] MODEL      tools/separation/fetch-and-convert-model.sh, then
#                  tools/downloader/fetch-download-tools.sh — the two git-ignored
#                  binary payloads, fetched together because both are consumed by
#                  macOS/Project.swift globs frozen at `tuist generate` time.
#                  FAIL-FAST for both: packaging never continues without a valid
#                  karaoke model (unless --no-model was passed EXPLICITLY) or
#                  without the yt-dlp/ffmpeg helpers (no opt-out — the shipped
#                  app offers YouTube downloads unconditionally).
#                  This stage does MORE work than its name; the numbering and the
#                  exit-code map below are deliberately UNCHANGED so no caller,
#                  runbook, or CI assertion that keys off them has to move.
#   [2] BUILD      scripts/build-macamp.sh --release  (its own MODEL / GENERATE /
#                  CLEAN-SLATE / BUILD stages; --keep-installs is forwarded).
#                  Produces build/MacAMP.app and checks its actual bundle ID
#                  and HTTPS update feed for unfinished release configuration.
#   [3] SIGN       Developer ID  -> scripts/codesign-app.sh (hardened runtime +
#                                   secure timestamp, inside-out).
#                  ad-hoc        -> performed HERE: `codesign --force --deep
#                                   --sign - <app>`. codesign-app.sh exits 3
#                                   without an identity by design, so the
#                                   credential-free path lives in this script —
#                                   the same shape the CI release job uses.
#   [4] DMG        scripts/package-dmg.sh --app <app> --output <dist>/MacAMP-<v>.dmg
#   [5] NOTARIZE   Developer ID + notary credentials -> scripts/notarize.sh.
#                  Otherwise a loud `NOTARIZE: SKIPPED` banner; notarize.sh is
#                  unchanged and never lies about being run.
#   [6] APPCAST    VERIFIES (never generates) the Sparkle EdDSA key:
#                    * the private key is in the login Keychain
#                      (scripts/setup-sparkle-key.sh --print-public)
#                    * the BUILT app's Info.plist carries SUPublicEDKey
#                    * the generated appcast's enclosure really is edSignature'd
#                  Then copies the new .dmg into <dist>/releases/ — an ARCHIVE
#                  that is retained across releases, which is precisely what lets
#                  Sparkle's generate_appcast emit binary DELTA updates — and
#                  runs scripts/make-appcast.sh over that directory.
#   [7] VERIFY     codesign -dv (Signature=adhoc / the Developer ID CN),
#                  spctl --assess, hdiutil verify, the COMPILED
#                  MelBandRoformer.mlmodelc AND libprojectM-4.4.dylib inside the
#                  bundle, measured sizes, and a dist/RELEASE-NOTES-<version>.md
#                  stub.
#   [8] PUBLISH    Only with --publish: scripts/publish-r2.sh uploads the
#                  image, deltas, latest.json, install.sh and (last) the
#                  appcast to the R2 bucket behind downloads.macamp.si. It asks
#                  for confirmation unless --yes is also passed. Then
#                  scripts/github-release.sh tags v<version> (which deploys the
#                  docs) and creates the GitHub Release page that links to the
#                  download. Notes come from release-notes/<version>.md if present.
#
# Usage:
#   scripts/release.sh --version 1.2.3                  # ad-hoc release
#   scripts/release.sh --version 1.2.3 --identity "Developer ID Application: …"
#   scripts/release.sh --version 0.0.0-test --dry-run   # plan only, no secrets
#   scripts/release.sh --version 1.2.3 --publish        # build, then upload to R2
#
# Flags:
#   --version <v>     REQUIRED. Names the .dmg (MacAMP-<v>.dmg) and the release
#                     notes, and is STAMPED INTO THE BUNDLE — stage [2] forwards
#                     it as `build-macamp.sh --app-version`, setting
#                     CFBundleShortVersionString plus a git-commit-count
#                     CFBundleVersion. Sparkle compares the bundle's version, not
#                     the file name, so this is what lets an update be offered at
#                     all. Stage [2] re-reads both keys and warns on a mismatch.
#   --dry-run         Plan the whole pipeline. ZERO Keychain access, ZERO
#                     network, ZERO codesign invocations, and nothing is written
#                     into the output directory (dry-run artifacts go to a temp
#                     dir that is printed and left behind for inspection).
#   --no-model        Ship WITHOUT the karaoke separation model. Disables the
#                     stage [1] fail-fast gate and the stage [7] model check;
#                     karaoke resolves .unavailable in the shipped app.
#   --keep-installs   Forwarded to build-macamp.sh: do not remove other installed
#                     copies of MacAMP.
#   --skip-appcast    Skip stage [6] entirely (no key check, no archive copy, no
#                     appcast). The .dmg is still produced and verified.
#   --identity <id>   Developer ID signing identity; overrides
#                     $DEVELOPER_ID_APPLICATION. Its presence is what selects
#                     Developer-ID mode over ad-hoc.
#   --output-dir <d>  Where the release artifacts land (default: dist/).
#   --publish         Run stage [8]: upload the release to R2 (needs the R2 keys
#                     in the Keychain; see scripts/publish-r2.sh --help).
#   --yes             With --publish: skip the confirmation prompt.
#   --skip-github     With --publish: upload to R2 but don't tag or create the
#                     GitHub Release (run scripts/github-release.sh later).
#   -h | --help       This text.
#
# Env:
#   DEVELOPER_ID_APPLICATION     selects Developer-ID mode when --identity is absent
#   APPLE_ID / NOTARIZATION_TEAM_ID / NOTARIZATION_APP_PASSWORD
#                                required for stage [5] to actually notarize
#   DEVELOPER_DIR                exported here to Xcode when unset (xcodebuild,
#                                @Observable macros and Swift Testing all need it)
#
# Two honest caveats about --dry-run, because "dry run" must never overstate:
#   * scripts/build-macamp.sh has NO --dry-run (it regenerates the workspace,
#     removes stale installs and runs xcodebuild). Stage [2] therefore PRINTS the
#     exact command instead of running it.
#   * scripts/package-dmg.sh --dry-run really does assemble and write an
#     (unsigned) .dmg. Stage [4] chains it only when a built app exists, and
#     redirects its output into the dry-run temp dir so <dist>/ stays untouched.
#
# Exit codes:
#   0  release produced (or dry-run plan printed)
#   1  bad arguments / missing prerequisite
#   2  stage [1] MODEL fail-fast (no valid model and no --no-model, or the
#      downloader tools could not be fetched/verified)
#   3  stage [2] BUILD failed or built release identity is missing/invalid/placeholder
#   4  stage [3] SIGN failed
#   5  stage [4] DMG failed
#   6  stage [5] NOTARIZE failed (real submissions only; a skip is never an error)
#   7  stage [6] APPCAST failed (missing Sparkle key / plist key / generate_appcast)
#   8  stage [7] VERIFY failed
#   9  stage [8] PUBLISH failed
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Xcode's toolchain is required for xcodebuild + the @Observable macro plugin.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# ---------------------------------------------------------------- arguments --
DRY_RUN=0
NO_MODEL=0
KEEP_INSTALLS=0
SKIP_APPCAST=0
PUBLISH=0
ASSUME_YES=0
SKIP_GITHUB=0
VERSION=""
OUTPUT_DIR=""
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"

die() { echo "error: $*" >&2; exit 1; }
fail() { local code="$1"; shift; echo "" >&2; echo "FAIL: $*" >&2; exit "${code}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --no-model) NO_MODEL=1; shift ;;
        --keep-installs) KEEP_INSTALLS=1; shift ;;
        --skip-appcast) SKIP_APPCAST=1; shift ;;
        --publish) PUBLISH=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        --skip-github) SKIP_GITHUB=1; shift ;;
        --version) [[ $# -ge 2 ]] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
        --output-dir) [[ $# -ge 2 ]] || die "--output-dir needs a path"; OUTPUT_DIR="$2"; shift 2 ;;
        --identity) [[ $# -ge 2 ]] || die "--identity needs a value"; IDENTITY="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; s/^#$//'
            exit 0 ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *) die "unexpected argument: $1 (try --help)" ;;
    esac
done

[[ -n "${VERSION}" ]] || die "--version <v> is required (it names the .dmg and the release notes; try --help)"
case "${VERSION}" in
    *[[:space:]]*|*/*) die "--version must not contain whitespace or '/': '${VERSION}'" ;;
    -*) die "--version must not start with '-': '${VERSION}'" ;;
esac

[[ -n "${OUTPUT_DIR}" ]] || OUTPUT_DIR="${REPO_ROOT}/dist"
if [[ "${PUBLISH}" -eq 1 && "${SKIP_APPCAST}" -eq 1 ]]; then
    die "--publish needs the appcast; drop --skip-appcast"
fi
# The GitHub step tags HEAD after the R2 upload; catch what would stop it there
# now, before a long build and an upload have already happened.
if [[ "${PUBLISH}" -eq 1 && "${SKIP_GITHUB}" -eq 0 && "${DRY_RUN}" -eq 0 ]]; then
    command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 \
        || die "--publish also creates the GitHub Release and needs the GitHub CLI signed in:
       brew install gh && gh auth login     (or pass --skip-github)"
    if ! git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
        [[ -z "$(git status --porcelain)" ]] \
            || die "--publish tags this commit as v${VERSION}: commit your changes first (or pass --skip-github)"
        git fetch -q origin 2>/dev/null || true
        git branch -r --contains HEAD 2>/dev/null | grep -q 'origin/' \
            || die "--publish tags this commit as v${VERSION}: git push it to GitHub first (or pass --skip-github)"
    fi
fi
case "${OUTPUT_DIR}" in /*) ;; *) OUTPUT_DIR="${REPO_ROOT}/${OUTPUT_DIR}" ;; esac

# ------------------------------------------------------------ derived paths --
# build-macamp.sh always writes its artifact to build/MacAMP.app; that fixed
# location is this pipeline's hand-off point between stages [2] and [3].
APP_PATH="${REPO_ROOT}/build/MacAMP.app"
DMG_NAME="MacAMP-${VERSION}.dmg"
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"
ARCHIVES_DIR="${OUTPUT_DIR}/releases"
APPCAST_PATH="${OUTPUT_DIR}/appcast.xml"
NOTES_PATH="${OUTPUT_DIR}/RELEASE-NOTES-${VERSION}.md"

MODEL_SCRIPT="tools/separation/fetch-and-convert-model.sh"
MODEL_DIR="macOS/Resources/SeparationModel"
COMPILED_MODEL="${APP_PATH}/Contents/Resources/MelBandRoformer.mlmodelc"
PROJECTM_DYLIB="${APP_PATH}/Contents/Frameworks/libprojectM-4.4.dylib"

TOOLS_SCRIPT="tools/downloader/fetch-download-tools.sh"
TOOLS_DIR="macOS/Resources/DownloaderTools"

# ffmpeg and ffprobe are single files staged by a Tuist copyFiles(.executables)
# phase, which resolves to Contents/MacOS. yt-dlp is a PyInstaller ONE-DIRECTORY
# tree staged by a `.folderReference`, which lands in Contents/Resources — so it
# is asserted as a tree, by name, and never by `find … -name yt-dlp_macos`.
DOWNLOADER_TOOL_NAMES=(ffmpeg ffprobe)
DOWNLOADER_LICENSE_NAMES=(LICENSE-yt-dlp.txt LICENSE-ffmpeg.txt SOURCE-OFFER.txt)
YTDLP_TREE_NAME="yt-dlp"
YTDLP_LAUNCHER_NAME="yt-dlp_macos"
YTDLP_PAYLOAD_NAME="_internal"

SIGN_MODE="adhoc"
[[ -n "${IDENTITY}" ]] && SIGN_MODE="devid"

# A dry run must not touch the real output directory. Everything it would write
# goes here instead; the path is printed so the artifacts can be inspected.
DRY_DIR=""
if [[ "${DRY_RUN}" -eq 1 ]]; then
    DRY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macamp-release-dry.XXXXXX")"
    NOTES_PATH="${DRY_DIR}/RELEASE-NOTES-${VERSION}.md"
fi

# ----------------------------------------------------------------- output ----
banner() {
    echo ""
    echo "================================================================================"
    echo " $*"
    echo "================================================================================"
}
step()  { printf '\n-- %s\n' "$*"; }
note()  { printf '    %s\n' "$*"; }
warn()  { printf '    WARNING: %s\n' "$*"; }
plan()  { printf '    would run: %s\n' "$*"; }

indent() { sed 's/^/    /'; }

# List the retained release archives, newest name last. `find | basename` rather
# than `ls`, so a file name with a newline can never desync the listing.
list_archives() {
    find "$1" -maxdepth 1 -type f -name '*.dmg' -exec basename {} ';' 2>/dev/null | sort
}

# Collected in stage order and reprinted as the closing summary.
SUMMARY_LINES=()
summary() { SUMMARY_LINES+=("$*"); }

human_size() {
    # `du -sh` on a missing path prints nothing useful; keep the summary honest.
    if [[ -e "$1" ]]; then du -sh "$1" 2>/dev/null | awk '{print $1}'; else echo "n/a"; fi
}

# One regular file inside <dir>, or nothing. `-print -quit` stops at the first
# hit, so this answers "is it non-empty" without walking 133 files, and answers
# it the same way for the source tree and for the shipped bundle.
payload_files() {
    [[ -d "$1" ]] || return 0
    find "$1" -type f -print -quit 2>/dev/null
}

# True only when every downloader artifact is present in the source directory:
# the two single-file tools, the three GPLv3 texts, and the yt-dlp tree with BOTH
# its launcher and a non-empty `_internal/` payload. Existence only — hash
# verification is fetch-download-tools.sh's job and is not duplicated here (that
# script is the single source of truth for the pins).
downloader_tools_installed() {
    local name
    for name in "${DOWNLOADER_TOOL_NAMES[@]}" "${DOWNLOADER_LICENSE_NAMES[@]}"; do
        [[ -f "${TOOLS_DIR}/${name}" ]] || return 1
    done
    [[ -f "${TOOLS_DIR}/${YTDLP_TREE_NAME}/${YTDLP_LAUNCHER_NAME}" ]] || return 1
    [[ -n "$(payload_files "${TOOLS_DIR}/${YTDLP_TREE_NAME}/${YTDLP_PAYLOAD_NAME}")" ]] || return 1
    return 0
}

# =============================================================================
banner "[0] PREFLIGHT — tools, version, working tree, signing mode"
# =============================================================================

MISSING_TOOLS=""
for tool in xcodebuild tuist hdiutil codesign spctl plutil ditto du awk; do
    command -v "${tool}" >/dev/null 2>&1 || MISSING_TOOLS="${MISSING_TOOLS} ${tool}"
done
[[ -z "${MISSING_TOOLS}" ]] || die "missing required tool(s):${MISSING_TOOLS}"
note "tools:      xcodebuild tuist hdiutil codesign spctl plutil ditto du — all present"

# python/uv are needed ONLY when the model has to be converted from scratch.
# When the artifacts are already installed the model stage is a pure no-op, so
# demanding a python toolchain up front would be a false prerequisite.
MODEL_INSTALLED=0
if [[ -d "${MODEL_DIR}/MelBandRoformer.mlpackage" && -f "${MODEL_DIR}/model-manifest.json" ]]; then
    MODEL_INSTALLED=1
fi
if [[ "${NO_MODEL}" -eq 1 ]]; then
    note "model:      --no-model — conversion toolchain not required"
elif [[ "${MODEL_INSTALLED}" -eq 1 ]]; then
    note "model:      artifacts present in ${MODEL_DIR}/ — conversion toolchain not required"
else
    if command -v uv >/dev/null 2>&1; then
        note "model:      artifacts ABSENT — uv present, ${MODEL_SCRIPT} can build the venv"
        warn "stage [1] will download the pinned ~900 MB checkpoint on this run"
    else
        die "model artifacts absent from ${MODEL_DIR}/ and 'uv' is not installed.
       Install uv (https://docs.astral.sh/uv/) so ${MODEL_SCRIPT}
       can create .venv-separation, or re-run with --no-model to ship without karaoke."
    fi
fi

if downloader_tools_installed; then
    note "tools:      downloader helpers present in ${TOOLS_DIR}/ — no download needed"
else
    note "tools:      downloader helpers ABSENT — stage [1] will fetch them"
    warn "stage [1] will download ~125 MB of yt-dlp + ffmpeg archives on this run"
    warn "(~251 MB once installed: the yt-dlp one-directory tree alone is 124 MB)"
fi

if git rev-parse --git-dir >/dev/null 2>&1; then
    GIT_DESC="$(git rev-parse --short HEAD 2>/dev/null || echo '<no commits>')"
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        warn "git working tree is DIRTY — this release will not be reproducible from HEAD (${GIT_DESC})"
        git status --porcelain 2>/dev/null | sed 's/^/      /' | head -n 20
    else
        note "git:        clean @ ${GIT_DESC}"
    fi
fi

note "version:    ${VERSION}"
note "output dir: ${OUTPUT_DIR}"
if [[ "${SIGN_MODE}" == "devid" ]]; then
    note "signing:    Developer ID — ${IDENTITY}"
else
    note "signing:    ad-hoc (no DEVELOPER_ID_APPLICATION / --identity) — Gatekeeper will"
    note "            require the user to allow it once via Privacy & Security"
fi
if [[ "${DRY_RUN}" -eq 1 ]]; then
    note "mode:       DRY-RUN — no Keychain, no network, no codesign; artifacts -> ${DRY_DIR}"
fi
summary "version:      ${VERSION}"
summary "signing mode: ${SIGN_MODE}"

# =============================================================================
banner "[1] MODEL — karaoke separation model (fail-fast gate)"
# =============================================================================

BUILD_SKIP_MODEL=0
if [[ "${NO_MODEL}" -eq 1 ]]; then
    note "SKIPPED (--no-model) — ${MODEL_SCRIPT} is not run."
    note "The shipped app will resolve karaoke to .unavailable (modelNotBundled)."
    BUILD_SKIP_MODEL=1
    summary "model:        SKIPPED (--no-model)"
else
    MODEL_RC=0
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        MODEL_LOG="${DRY_DIR}/model-dry-run.log"
        MODEL_OUT="$("${MODEL_SCRIPT}" --dry-run 2>&1)" || MODEL_RC=$?
        printf '%s\n' "${MODEL_OUT}" >"${MODEL_LOG}"
        printf '%s\n' "${MODEL_OUT}" | indent
        if [[ "${MODEL_RC}" -ne 0 ]]; then
            fail 2 "[1] MODEL — ${MODEL_SCRIPT} --dry-run exited ${MODEL_RC}: the installed
      artifacts in ${MODEL_DIR}/ are INVALID. Fix them (--force reconverts) or
      re-run release.sh with --no-model to ship deliberately without karaoke."
        fi
        if grep -q 'reason:.*artifacts absent' "${MODEL_LOG}" 2>/dev/null; then
            warn "no model installed — a REAL run would download the pinned ~900 MB checkpoint here"
            summary "model:        absent (a real run would convert it)"
        else
            summary "model:        present/valid (cached)"
        fi
    else
        "${MODEL_SCRIPT}" || MODEL_RC=$?
        if [[ "${MODEL_RC}" -ne 0 ]]; then
            fail 2 "[1] MODEL — ${MODEL_SCRIPT} exited ${MODEL_RC}.
      Refusing to package a release with a missing or invalid karaoke model.
      Re-run with --no-model to ship without karaoke ON PURPOSE, or fix the
      model stage (exit 2 = no venv/uv, 3 = corrupt artifacts, 4 = unverifiable)."
        fi
        # Independent of the script's own exit status: the artifacts must be there.
        if [[ ! -d "${MODEL_DIR}/MelBandRoformer.mlpackage" || ! -f "${MODEL_DIR}/model-manifest.json" ]]; then
            fail 2 "[1] MODEL — ${MODEL_SCRIPT} reported success but ${MODEL_DIR}/ is
      still incomplete. Refusing to continue to packaging."
        fi
        note "✓ ${MODEL_DIR}/ holds MelBandRoformer.mlpackage + model-manifest.json"
        summary "model:        bundled from ${MODEL_DIR}/"
    fi
fi

# --- same stage, second payload: the YouTube-downloader helpers ---------------
# Deliberately INSIDE stage [1] rather than a stage of its own: the stage numbers
# and the exit-code map are a published contract (docs-site distribution runbook,
# both CI pipelines), and this is the same class of work — fetch a git-ignored
# binary payload that macOS/Project.swift picks up through a glob frozen at
# `tuist generate` time. release.sh stays a pure orchestrator: every byte of the
# fetch/verify/licence logic lives in ${TOOLS_SCRIPT}.
#
# There is no --no-tools counterpart to --no-model. The model is a genuinely
# optional feature with a shipped `.unavailable(.modelNotBundled)` path; the
# downloader UI is unconditional, so an app without these helpers is broken, not
# reduced.
step "Downloader tools — ${TOOLS_SCRIPT}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
    plan "${TOOLS_SCRIPT}"
    note "(not executed: ${TOOLS_SCRIPT} has no --dry-run and would reach the"
    note " network on a cache miss, which a dry run must never do.)"
    if downloader_tools_installed; then
        note "✓ ${TOOLS_DIR}/ already holds every artifact — a real run would be a cached no-op"
        summary "downloader:   present/valid (cached)"
    else
        warn "no downloader tools installed — a REAL run would download ~125 MB here"
        summary "downloader:   absent (a real run would fetch them)"
    fi
else
    TOOLS_RC=0
    "${TOOLS_SCRIPT}" || TOOLS_RC=$?
    if [[ "${TOOLS_RC}" -ne 0 ]]; then
        fail 2 "[1] MODEL — ${TOOLS_SCRIPT} exited ${TOOLS_RC}.
      Refusing to package a release whose YouTube downloader would be dead.
      (exit 2 = no curl/unzip/shasum or the download failed, 3 = installed
      artifacts corrupt or the ffmpeg GPL licence gate rejected the build,
      4 = a SHA-256 pin did not match.)"
    fi
    # Independent of the script's own exit status, exactly as the model check is.
    if ! downloader_tools_installed; then
        fail 2 "[1] MODEL — ${TOOLS_SCRIPT} reported success but ${TOOLS_DIR}/ is
      still incomplete. Refusing to continue to packaging."
    fi
    note "✓ ${TOOLS_DIR}/ holds the yt-dlp tree + ffmpeg + ffprobe and their GPLv3 texts"
    summary "downloader:   bundled from ${TOOLS_DIR}/"
fi

# =============================================================================
banner "[2] BUILD — scripts/build-macamp.sh --release"
# =============================================================================

# --app-version is unconditional: VERSION is required and already validated, and
# it is the ONLY thing that makes the shipped bundle claim this release's version
# (build-macamp.sh maps it to MARKETING_VERSION / CURRENT_PROJECT_VERSION and
# asserts both landed). Without it the .dmg name and the bundle disagree, and
# Sparkle believes the bundle.
BUILD_ARGS=(--release --app-version "${VERSION}")
BUILD_DISPLAY="scripts/build-macamp.sh --release --app-version ${VERSION}"
if [[ "${KEEP_INSTALLS}" -eq 1 ]]; then
    BUILD_ARGS+=(--keep-installs)
    BUILD_DISPLAY="${BUILD_DISPLAY} --keep-installs"
fi
# Only --no-model suppresses build-macamp.sh's own model stage. In the normal
# path it is left ON: stage [1] already made it a ~0.08 s cached no-op, and it
# brings its own "is the compiled model really in the bundle" assertion, which
# fails the build EARLY instead of at stage [7].
if [[ "${BUILD_SKIP_MODEL}" -eq 1 ]]; then
    BUILD_ARGS+=(--skip-model)
    BUILD_DISPLAY="${BUILD_DISPLAY} --skip-model"
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
    plan "${BUILD_DISPLAY}"
    note "(build-macamp.sh has no --dry-run: it regenerates the Tuist workspace,"
    note " removes stale installs and runs a full Release xcodebuild. Not executed.)"
    if [[ -d "${APP_PATH}" ]]; then
        note "a previously built app exists and later stages will inspect it: ${APP_PATH}"
    else
        note "no ${APP_PATH} present — later stages will plan only"
    fi
else
    BUILD_RC=0
    "${SCRIPT_DIR}/build-macamp.sh" "${BUILD_ARGS[@]}" || BUILD_RC=$?
    [[ "${BUILD_RC}" -eq 0 ]] || fail 3 "[2] BUILD — build-macamp.sh exited ${BUILD_RC}"
    [[ -d "${APP_PATH}" ]] || fail 3 "[2] BUILD — build-macamp.sh succeeded but ${APP_PATH} is missing"
    note "✓ ${APP_PATH}"
fi

# Defence in depth. Stage [2] already stamped this version and build-macamp.sh
# asserts it landed, so on a normal run these agree and nothing is printed. The
# check stays because the read is independent of the thing that wrote it: it also
# judges a --dry-run's pre-existing bundle, and it is the only guard for anyone
# invoking build-macamp.sh directly without --app-version.
APP_PLIST="${APP_PATH}/Contents/Info.plist"
APP_SHORT_VERSION=""
if [[ -f "${APP_PLIST}" ]]; then
    APP_SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${APP_PLIST}" 2>/dev/null || true)"
    APP_BUILD_VERSION="$(plutil -extract CFBundleVersion raw -o - "${APP_PLIST}" 2>/dev/null || true)"
    note "bundle version: CFBundleShortVersionString=${APP_SHORT_VERSION:-<unset>} CFBundleVersion=${APP_BUILD_VERSION:-<unset>}"
    if [[ -n "${APP_SHORT_VERSION}" && "${APP_SHORT_VERSION}" != "${VERSION}" ]]; then
        warn "--version '${VERSION}' != the app's CFBundleShortVersionString '${APP_SHORT_VERSION}'."
        warn "Sparkle compares the BUNDLE's version, not the .dmg file name, so this"
        warn "image would announce itself as '${APP_SHORT_VERSION}'."
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            warn "Expected in a dry run: stage [2] did not build, so this is a stale bundle."
        else
            warn "This should be unreachable — stage [2] passed --app-version '${VERSION}'."
            warn "Check that macOS/Project.swift's appInfoPlist still maps both version"
            warn "keys to \$(MARKETING_VERSION) / \$(CURRENT_PROJECT_VERSION)."
        fi
    fi
    summary "bundle:       ${APP_SHORT_VERSION:-<unset>} (${APP_BUILD_VERSION:-<unset>})"
fi

step "Release identity — built Info.plist"
if [[ "${DRY_RUN}" -eq 1 ]]; then
    plan "scripts/check-release-identity.sh ${APP_PLIST}"
    warn "release identity: pending — a real release requires a production bundle ID and HTTPS update feed in the newly built app"
    summary "release identity: pending (dry-run does not build or approve release configuration)"
else
    "${SCRIPT_DIR}/check-release-identity.sh" "${APP_PLIST}" \
        || fail 3 "[2] BUILD — built release identity is not ready; signing and packaging were not started"
    summary "release identity: built bundle ID and HTTPS feed passed the placeholder check"
fi

# =============================================================================
banner "[3] SIGN — ${SIGN_MODE}"
# =============================================================================

if [[ "${SIGN_MODE}" == "devid" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        if [[ -d "${APP_PATH}" ]]; then
            "${SCRIPT_DIR}/codesign-app.sh" --dry-run --app "${APP_PATH}" --identity "${IDENTITY}" \
                | indent
        else
            plan "scripts/codesign-app.sh --app ${APP_PATH} --identity '${IDENTITY}'"
        fi
    else
        SIGN_RC=0
        "${SCRIPT_DIR}/codesign-app.sh" --app "${APP_PATH}" --identity "${IDENTITY}" || SIGN_RC=$?
        [[ "${SIGN_RC}" -eq 0 ]] || fail 4 "[3] SIGN — codesign-app.sh exited ${SIGN_RC}"
    fi
    summary "sign:         Developer ID (${IDENTITY})"
else
    note "No signing identity, so this is the credential-free path: an AD-HOC"
    note "signature, applied here rather than by codesign-app.sh (which exits 3"
    note "without an identity, on purpose). Same shape as the CI release job."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        plan "codesign --force --deep --sign - ${APP_PATH}"
        note "(not executed: a dry run performs ZERO codesign invocations)"
    else
        SIGN_RC=0
        codesign --force --deep --sign - "${APP_PATH}" || SIGN_RC=$?
        [[ "${SIGN_RC}" -eq 0 ]] || fail 4 "[3] SIGN — ad-hoc codesign exited ${SIGN_RC}"
        note "✓ ad-hoc signed ${APP_PATH}"
    fi
    summary "sign:         ad-hoc"
fi

# =============================================================================
banner "[4] DMG — scripts/package-dmg.sh"
# =============================================================================

if [[ "${DRY_RUN}" -eq 1 ]]; then
    if [[ -d "${APP_PATH}" ]]; then
        # package-dmg.sh --dry-run genuinely assembles and writes an UNSIGNED
        # image, so it is redirected into the dry-run temp dir: <dist>/ must stay
        # exactly as the dry run found it.
        plan "scripts/package-dmg.sh --app ${APP_PATH} --output ${DMG_PATH}"
        note "chaining its own --dry-run into ${DRY_DIR}/${DMG_NAME} instead:"
        DMG_RC=0
        DMG_OUT="$("${SCRIPT_DIR}/package-dmg.sh" --dry-run --app "${APP_PATH}" \
            --output "${DRY_DIR}/${DMG_NAME}" 2>&1)" || DMG_RC=$?
        printf '%s\n' "${DMG_OUT}" | indent
        [[ "${DMG_RC}" -eq 0 ]] || warn "package-dmg.sh --dry-run exited ${DMG_RC}"
    else
        plan "scripts/package-dmg.sh --app ${APP_PATH} --output ${DMG_PATH}"
        note "(skipped: no built app to assemble)"
    fi
else
    mkdir -p "${OUTPUT_DIR}"
    DMG_RC=0
    "${SCRIPT_DIR}/package-dmg.sh" --app "${APP_PATH}" --output "${DMG_PATH}" || DMG_RC=$?
    [[ "${DMG_RC}" -eq 0 ]] || fail 5 "[4] DMG — package-dmg.sh exited ${DMG_RC}"
    [[ -f "${DMG_PATH}" ]] || fail 5 "[4] DMG — package-dmg.sh succeeded but ${DMG_PATH} is missing"
    note "✓ ${DMG_PATH}"
fi

# =============================================================================
banner "[5] NOTARIZE"
# =============================================================================

NOTARY_READY=0
if [[ -n "${APPLE_ID:-}" && -n "${NOTARIZATION_TEAM_ID:-}" && -n "${NOTARIZATION_APP_PASSWORD:-}" ]]; then
    NOTARY_READY=1
fi

if [[ "${SIGN_MODE}" != "devid" ]]; then
    echo ""
    echo "    ****************************************************************"
    echo "    *  NOTARIZE: SKIPPED (ad-hoc mode)                             *"
    echo "    ****************************************************************"
    note "Apple only notarizes Developer-ID-signed code. This artifact is ad-hoc"
    note "signed, so there is nothing to submit and nothing to staple."
    note "First-launch consequence for users: macOS reports the app as damaged"
    note "until it is allowed once via System Settings > Privacy & Security >"
    note "\"Open Anyway\". That instruction is written into the release notes."
    summary "notarize:     SKIPPED (ad-hoc)"
elif [[ "${NOTARY_READY}" -eq 0 ]]; then
    echo ""
    echo "    ****************************************************************"
    echo "    *  NOTARIZE: SKIPPED (no notary credentials)                   *"
    echo "    ****************************************************************"
    warn "Developer-ID signed but APPLE_ID / NOTARIZATION_TEAM_ID /"
    warn "NOTARIZATION_APP_PASSWORD are not all set — the .dmg is NOT notarized."
    "${SCRIPT_DIR}/notarize.sh" --check-config | indent || true
    summary "notarize:     SKIPPED (credentials incomplete)"
elif [[ "${DRY_RUN}" -eq 1 ]]; then
    plan "scripts/notarize.sh ${DMG_PATH}"
    note "chaining its credential-only check instead (no upload, no network submit):"
    "${SCRIPT_DIR}/notarize.sh" --check-config | indent || true
    summary "notarize:     planned (dry-run)"
else
    NOTARY_RC=0
    "${SCRIPT_DIR}/notarize.sh" "${DMG_PATH}" || NOTARY_RC=$?
    [[ "${NOTARY_RC}" -eq 0 ]] || fail 6 "[5] NOTARIZE — notarize.sh exited ${NOTARY_RC}"
    summary "notarize:     submitted + stapled"
fi

# =============================================================================
banner "[6] APPCAST — Sparkle key VERIFY + archive retention + generate_appcast"
# =============================================================================

if [[ "${SKIP_APPCAST}" -eq 1 ]]; then
    note "SKIPPED (--skip-appcast) — no key check, no archive copy, no appcast."
    summary "appcast:      SKIPPED (--skip-appcast)"
else
    step "Sparkle EdDSA key (VERIFY only — generation belongs to scripts/setup-sparkle-key.sh)"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        plan "PUBKEY=\"\$(scripts/setup-sparkle-key.sh --print-public)\"  # reads the login Keychain"
        note "chaining its --dry-run instead (ZERO Keychain access):"
        "${SCRIPT_DIR}/setup-sparkle-key.sh" --dry-run | indent || true
    else
        PUBKEY=""
        PUBKEY="$("${SCRIPT_DIR}/setup-sparkle-key.sh" --print-public 2>/dev/null)" || PUBKEY=""
        if [[ -z "${PUBKEY}" ]]; then
            fail 7 "[6] APPCAST — no Sparkle EdDSA signing key in the login Keychain.
      generate_appcast cannot sign the archives without it. Create it ONCE:
          scripts/setup-sparkle-key.sh
      then re-run this release. (Use --skip-appcast to produce the .dmg alone.)"
        fi
        note "✓ private key present in the login Keychain; public key: ${PUBKEY}"
    fi

    # `SUPublicEDKey` is Sparkle's REAL Info.plist key name (verify against the
    # pinned binary: `strings …/Sparkle.framework/Versions/B/Sparkle | grep -E
    # '^SU[A-Za-z]+$'`). A wrong-but-plausible name — this repo shipped
    # `SUEdDSAPublicKey` — is silent at both ends: SPUUpdater finds no key, and
    # generate_appcast emits UNSIGNED appcast items without ever erroring.
    step "Built app's Info.plist must carry the matching SUPublicEDKey"
    if [[ ! -f "${APP_PLIST}" ]]; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            note "(skipped: no built app to inspect)"
        else
            fail 7 "[6] APPCAST — ${APP_PLIST} not found"
        fi
    else
        PLIST_PUBKEY="$(plutil -extract SUPublicEDKey raw -o - "${APP_PLIST}" 2>/dev/null || true)"
        # A dry run inspects whatever build/MacAMP.app happens to be lying around,
        # which may predate the Sparkle wiring entirely. Judging a real release on
        # that is correct; failing a PLAN on it is a false negative.
        if [[ -z "${PLIST_PUBKEY}" ]]; then
            if [[ "${DRY_RUN}" -eq 1 ]]; then
                warn "this (pre-existing) bundle has no SUPublicEDKey — a real run would STOP here"
                summary "sparkle key:  Keychain not read (dry-run); stale bundle lacks the plist key"
            else
                fail 7 "[6] APPCAST — the built app has NO SUPublicEDKey in its Info.plist.
      Sparkle would reject every update it is offered, and generate_appcast
      would emit UNSIGNED appcast items. Add the key to macOS/Project.swift
      (appInfoPlist) — scripts/setup-sparkle-key.sh --print-public prints
      exactly the value to paste — then rebuild. The key NAME must be
      SUPublicEDKey exactly; a near-miss is accepted silently by everything."
            fi
        else
            note "✓ Info.plist SUPublicEDKey: ${PLIST_PUBKEY}"
            if [[ "${DRY_RUN}" -eq 0 && "${PLIST_PUBKEY}" != "${PUBKEY}" ]]; then
                fail 7 "[6] APPCAST — key MISMATCH.
        Keychain:  ${PUBKEY}
        Info.plist:${PLIST_PUBKEY}
      Updates signed with the Keychain key would be rejected by this build.
      Re-sync macOS/Project.swift with scripts/setup-sparkle-key.sh --print-public."
            fi
            summary "sparkle key:  verified (Keychain + Info.plist)"
        fi
    fi

    step "Archive retention — <dist>/releases/ keeps EVERY shipped .dmg"
    note "generate_appcast emits binary DELTA updates only when it can see more"
    note "than one version in the archives directory, so nothing here is ever"
    note "pruned. Old images are the input to the next release's deltas."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        plan "mkdir -p ${ARCHIVES_DIR} && ditto ${DMG_PATH} ${ARCHIVES_DIR}/${DMG_NAME}"
        if [[ -d "${ARCHIVES_DIR}" ]]; then
            note "current archives:"
            list_archives "${ARCHIVES_DIR}" | sed 's/^/      /' || true
        else
            note "(${ARCHIVES_DIR} does not exist yet — it would be created)"
        fi
    else
        mkdir -p "${ARCHIVES_DIR}"
        ditto "${DMG_PATH}" "${ARCHIVES_DIR}/${DMG_NAME}"
        note "✓ archived ${ARCHIVES_DIR}/${DMG_NAME}"
        ARCHIVE_COUNT="$(list_archives "${ARCHIVES_DIR}" | wc -l | tr -d ' ')"
        note "archives now retained (${ARCHIVE_COUNT}):"
        list_archives "${ARCHIVES_DIR}" | sed 's/^/      /'
        if [[ "${ARCHIVE_COUNT}" -lt 2 ]]; then
            note "only one archive — deltas begin with the NEXT release."
        else
            note "≥2 archives — generate_appcast can emit binary deltas."
        fi
        summary "archives:     ${ARCHIVE_COUNT} in ${ARCHIVES_DIR#"${REPO_ROOT}"/}"
    fi

    step "scripts/make-appcast.sh"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        plan "scripts/make-appcast.sh --archives ${ARCHIVES_DIR} --output ${APPCAST_PATH}"
        note "chaining its --dry-run into ${DRY_DIR}/appcast-sample.xml (no key, no network):"
        "${SCRIPT_DIR}/make-appcast.sh" --dry-run --output "${DRY_DIR}/appcast-sample.xml" \
            2>&1 | indent || true
        summary "appcast:      planned (dry-run sample written)"
    else
        APPCAST_RC=0
        "${SCRIPT_DIR}/make-appcast.sh" --archives "${ARCHIVES_DIR}" --output "${APPCAST_PATH}" || APPCAST_RC=$?
        [[ "${APPCAST_RC}" -eq 0 ]] || fail 7 "[6] APPCAST — make-appcast.sh exited ${APPCAST_RC}"
        [[ -f "${APPCAST_PATH}" ]] || fail 7 "[6] APPCAST — make-appcast.sh succeeded but ${APPCAST_PATH} is missing"
        if grep -q "${DMG_NAME}" "${APPCAST_PATH}" 2>/dev/null; then
            note "✓ ${APPCAST_PATH} references ${DMG_NAME}"
        else
            warn "${APPCAST_PATH} does NOT mention ${DMG_NAME} — check generate_appcast's version parsing"
        fi

        # generate_appcast reports success and exits 0 even when it silently
        # decides no signing is required (the failure mode of a wrong Info.plist
        # key name). An unsigned feed is refused by every installed copy, so the
        # signature has to be asserted here rather than inferred from exit 0.
        if grep -q 'sparkle:edSignature="[^"]\{16,\}"' "${APPCAST_PATH}" 2>/dev/null; then
            note "✓ enclosure carries a real sparkle:edSignature"
        else
            fail 7 "[6] APPCAST — ${APPCAST_PATH} has NO sparkle:edSignature.
      generate_appcast exited 0 but signed nothing: it only signs when the app
      bundle declares its public key under the EXACT name SUPublicEDKey.
      Check macOS/Project.swift (appInfoPlist) and rebuild; verify the name
      against the pinned framework binary:
          strings \"\$(find Tuist/.build -path '*Sparkle.framework/Versions/B/Sparkle')\" \\
            | grep -E '^SU[A-Za-z]+\$' | sort -u"
        fi
        summary "appcast:      ${APPCAST_PATH#"${REPO_ROOT}"/}"
    fi
fi

# =============================================================================
banner "[7] VERIFY — signature, Gatekeeper, image, model, sizes, release notes"
# =============================================================================

VERIFY_APP=0
[[ -d "${APP_PATH}" ]] && VERIFY_APP=1
VERIFY_DMG=0
[[ -f "${DMG_PATH}" ]] && VERIFY_DMG=1

SPCTL_STATE="not run"
SIG_STATE="not run"
MODEL_STATE="not checked"

step "codesign -dv --verbose=4"
if [[ "${DRY_RUN}" -eq 1 && "${VERIFY_APP}" -eq 0 ]]; then
    plan "codesign -dv --verbose=4 ${APP_PATH}"
elif [[ "${VERIFY_APP}" -eq 0 ]]; then
    fail 8 "[7] VERIFY — ${APP_PATH} is missing"
else
    CS_OUT="$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1 || true)"
    echo "${CS_OUT}" | indent
    if [[ "${SIGN_MODE}" == "adhoc" ]]; then
        if echo "${CS_OUT}" | grep -q '^Signature=adhoc'; then
            note "✓ Signature=adhoc — as expected for a credential-free release"
            SIG_STATE="adhoc"
        elif [[ "${DRY_RUN}" -eq 1 ]]; then
            warn "not ad-hoc signed (expected: stage [3] does not sign during a dry run)"
            SIG_STATE="unsigned (dry-run)"
        else
            fail 8 "[7] VERIFY — expected 'Signature=adhoc' after stage [3]; codesign says otherwise"
        fi
    else
        if echo "${CS_OUT}" | grep -q "Authority=.*Developer ID Application"; then
            note "✓ Developer ID authority present"
            SIG_STATE="Developer ID"
        elif [[ "${DRY_RUN}" -eq 1 ]]; then
            warn "no Developer ID authority (expected: stage [3] does not sign during a dry run)"
            SIG_STATE="unsigned (dry-run)"
        else
            fail 8 "[7] VERIFY — no 'Developer ID Application' authority in the signature"
        fi
    fi
fi
summary "signature:    ${SIG_STATE}"

step "spctl --assess --type execute"
if [[ "${VERIFY_APP}" -eq 0 ]]; then
    plan "spctl --assess --type execute --verbose=4 ${APP_PATH}"
else
    SPCTL_RC=0
    SPCTL_OUT="$(spctl --assess --type execute --verbose=4 "${APP_PATH}" 2>&1)" || SPCTL_RC=$?
    echo "${SPCTL_OUT}" | indent
    if [[ "${SPCTL_RC}" -eq 0 ]]; then
        note "✓ Gatekeeper accepts this bundle"
        SPCTL_STATE="accepted"
    elif [[ "${SIGN_MODE}" == "adhoc" ]]; then
        echo ""
        echo "    ****************************************************************"
        echo "    *  spctl: EXPECTED (ad-hoc — users need Open Anyway)           *"
        echo "    *  NOT a pipeline failure.                                     *"
        echo "    ****************************************************************"
        note "spctl exited ${SPCTL_RC}; an ad-hoc signature has no Developer ID for"
        note "Gatekeeper to evaluate, so a rejection here is the correct outcome."
        SPCTL_STATE="rejected — EXPECTED (ad-hoc)"
    else
        fail 8 "[7] VERIFY — spctl rejected a Developer-ID-signed bundle (rc ${SPCTL_RC});
      that IS a real failure. Notarize the artifact, or investigate the signature."
    fi
fi
summary "gatekeeper:   ${SPCTL_STATE}"

step "hdiutil verify"
if [[ "${VERIFY_DMG}" -eq 0 ]]; then
    plan "hdiutil verify ${DMG_PATH}"
else
    HDI_RC=0
    HDI_OUT="$(hdiutil verify "${DMG_PATH}" 2>&1)" || HDI_RC=$?
    printf '%s\n' "${HDI_OUT}" | indent
    [[ "${HDI_RC}" -eq 0 ]] || fail 8 "[7] VERIFY — hdiutil verify failed (rc ${HDI_RC}) on ${DMG_PATH}"
    note "✓ disk image checksum verifies"
fi

step "Compiled Core ML model inside the bundle"
if [[ "${NO_MODEL}" -eq 1 ]]; then
    note "skipped (--no-model). Confirming it really is absent:"
    if [[ -d "${COMPILED_MODEL}" ]]; then
        warn "MelBandRoformer.mlmodelc IS present despite --no-model (a stale"
        warn "${MODEL_DIR}/ was still picked up by the Tuist resource glob)."
        MODEL_STATE="present (unexpected under --no-model)"
    else
        note "✓ no MelBandRoformer.mlmodelc — karaoke will resolve .unavailable"
        MODEL_STATE="absent (--no-model)"
    fi
elif [[ "${VERIFY_APP}" -eq 0 ]]; then
    plan "test -d ${COMPILED_MODEL}"
    MODEL_STATE="not checked (no app)"
else
    # The COMPILED .mlmodelc is what CoreMLSeparator loads at runtime; the source
    # .mlpackage never ships. Checking the wrong one would pass on a broken build.
    if [[ -d "${COMPILED_MODEL}" ]]; then
        note "✓ ${COMPILED_MODEL#"${APP_PATH}"/} ($(human_size "${COMPILED_MODEL}"))"
        if [[ -f "${APP_PATH}/Contents/Resources/model-manifest.json" ]]; then
            note "✓ Contents/Resources/model-manifest.json"
        else
            warn "model-manifest.json is missing next to the compiled model"
        fi
        MODEL_STATE="bundled"
    elif [[ "${DRY_RUN}" -eq 1 ]]; then
        warn "no compiled model in this (pre-existing) bundle"
        MODEL_STATE="absent (dry-run inspection)"
    else
        fail 8 "[7] VERIFY — ${COMPILED_MODEL} is missing from the built app.
      Karaoke would resolve .unavailable in a release that claims to ship it.
      (Pass --no-model to build model-less on purpose.)"
    fi
fi
summary "karaoke model: ${MODEL_STATE}"

# No `--no-model` counterpart on purpose: the dylib is COMMITTED under
# macOS/Vendor/projectM/lib/, so unlike the model it can never be legitimately
# absent. If it is missing, the copyFiles phase broke — and the app would launch
# with the projectM renderer offered in the menu and dead on selection.
step "Embedded projectM dylib inside the bundle"
if [[ "${VERIFY_APP}" -eq 0 ]]; then
    plan "test -f ${PROJECTM_DYLIB}"
    PROJECTM_STATE="not checked (no app)"
elif [[ -f "${PROJECTM_DYLIB}" ]]; then
    note "✓ ${PROJECTM_DYLIB#"${APP_PATH}"/} ($(human_size "${PROJECTM_DYLIB}"))"
    PROJECTM_STATE="embedded"
elif [[ "${DRY_RUN}" -eq 1 ]]; then
    warn "no libprojectM-4.4.dylib in this (pre-existing) bundle"
    PROJECTM_STATE="absent (dry-run inspection)"
else
    fail 8 "[7] VERIFY — ${PROJECTM_DYLIB} is missing from the built app.
      The projectM visualizer would fail to load at runtime. The dylib is
      committed at macOS/Vendor/projectM/lib/, so this means the target's
      copyFiles phase is broken — see macOS/Project.swift."
fi
summary "projectM:     ${PROJECTM_STATE}"

# ---------------------------------------------------------------------------
# Bundled downloader tools. Everything below interrogates the SHIPPED ARTIFACT,
# never the stage that produced it: stage [1] succeeding proves the source
# directory was populated, not that a single byte of it reached the .app. The
# path from one to the other runs through a Tuist copyFiles phase and a folder
# reference over a git-ignored directory, and BOTH fail silently — a zero-match
# glob is legal and produces a green build with an empty bundle.
#
# The destinations are SPELLED OUT rather than found by name, and yt-dlp is
# asserted as a TREE. `find … -name yt-dlp_macos` would happily match a lone
# launcher that had lost its `_internal/` sibling: that passes every existence
# check, signs cleanly, and then dies at first exec with
# "Failed to load Python shared library '…/_internal/Python'". Spelling the
# destination out also means a Tuist destination change fails HERE, loudly,
# rather than being silently absorbed by a recursive search.
# ---------------------------------------------------------------------------
step "Bundled downloader tools inside the bundle"
TOOLS_STATE="not checked"
BUNDLED_YTDLP=""
BUNDLED_FFMPEG=""
YTDLP_TREE_DIR="${APP_PATH}/Contents/Resources/${YTDLP_TREE_NAME}"
YTDLP_TREE_LAUNCHER="${YTDLP_TREE_DIR}/${YTDLP_LAUNCHER_NAME}"
YTDLP_TREE_PAYLOAD="${YTDLP_TREE_DIR}/${YTDLP_PAYLOAD_NAME}"
if [[ "${VERIFY_APP}" -eq 0 ]]; then
    plan "test -f ${YTDLP_TREE_LAUNCHER}"
    plan "find ${YTDLP_TREE_PAYLOAD} -type f -print -quit   # must be non-empty"
    plan "test -f ${APP_PATH}/Contents/MacOS/{ffmpeg,ffprobe}"
    plan "test -f ${APP_PATH}/Contents/Resources/{LICENSE-yt-dlp,LICENSE-ffmpeg,SOURCE-OFFER}.txt"
    TOOLS_STATE="not checked (no app)"
else
    TOOLS_MISSING=""
    if [[ -f "${YTDLP_TREE_LAUNCHER}" ]]; then
        note "✓ ${YTDLP_TREE_LAUNCHER#"${APP_PATH}"/} ($(human_size "${YTDLP_TREE_LAUNCHER}"))"
        BUNDLED_YTDLP="${YTDLP_TREE_LAUNCHER}"
    else
        TOOLS_MISSING="${TOOLS_MISSING} ${YTDLP_TREE_NAME}/${YTDLP_LAUNCHER_NAME}"
    fi
    if [[ -n "$(payload_files "${YTDLP_TREE_PAYLOAD}")" ]]; then
        PAYLOAD_COUNT="$(find "${YTDLP_TREE_PAYLOAD}" -type f 2>/dev/null | wc -l | tr -d ' ')"
        note "✓ ${YTDLP_TREE_PAYLOAD#"${APP_PATH}"/}/ ($(human_size "${YTDLP_TREE_PAYLOAD}"), ${PAYLOAD_COUNT} files)"
    else
        TOOLS_MISSING="${TOOLS_MISSING} ${YTDLP_TREE_NAME}/${YTDLP_PAYLOAD_NAME}/"
    fi
    for tool_name in "${DOWNLOADER_TOOL_NAMES[@]}"; do
        TOOL_PATH="${APP_PATH}/Contents/MacOS/${tool_name}"
        if [[ -f "${TOOL_PATH}" ]]; then
            note "✓ ${TOOL_PATH#"${APP_PATH}"/} ($(human_size "${TOOL_PATH}"))"
            [[ "${tool_name}" == "ffmpeg" ]] && BUNDLED_FFMPEG="${TOOL_PATH}"
        else
            TOOLS_MISSING="${TOOLS_MISSING} ${tool_name}"
        fi
    done
    for license_name in "${DOWNLOADER_LICENSE_NAMES[@]}"; do
        if [[ -f "${APP_PATH}/Contents/Resources/${license_name}" ]]; then
            note "✓ Contents/Resources/${license_name}"
        else
            TOOLS_MISSING="${TOOLS_MISSING} ${license_name}"
        fi
    done
    if [[ -n "${TOOLS_MISSING}" ]]; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            warn "missing from this (pre-existing) bundle:${TOOLS_MISSING}"
            TOOLS_STATE="incomplete (dry-run inspection)"
        else
            fail 8 "[7] VERIFY — missing from the built app:${TOOLS_MISSING}
      YouTube downloads would be dead in a release that offers them, and a
      GPLv3 binary shipped without its licence text + written source offer is a
      licence violation. ${TOOLS_SCRIPT} must run BEFORE \`tuist generate\` —
      the copyFiles phase and the .folderReference in macOS/Project.swift are
      both frozen there.
      If only ${YTDLP_TREE_NAME}/${YTDLP_PAYLOAD_NAME}/ is listed, the tree was
      flattened or truncated: the launcher cannot start without that sibling and
      exits with \"Failed to load Python shared library\"."
        fi
    else
        TOOLS_STATE="bundled"
    fi
fi

# The nested tool signatures are the ONLY thing --deep --strict adds over the
# top-level check stage [3] already implies: an unsigned or broken Mach-O in
# Contents/MacOS invalidates the seal, and nothing before this point would say so.
#
# The status is captured through a command substitution, NOT through
# `cmd | indent || true` + ${PIPESTATUS[0]}. Under `set -o pipefail` the failing
# pipeline makes `|| true` RUN, and `true` — being a pipeline of its own — resets
# PIPESTATUS to (0). So the read that follows always answered 0 and this gate
# could never fire: measured 2026-09-10 against a bundle whose sealed yt-dlp
# launcher had been swapped, where codesign itself printed "a sealed resource is
# missing or invalid" and the script still reported ✓. Same shape, same reason,
# at the MODEL / DMG / hdiutil sites. Do not "simplify" it back to a pipe.
step "codesign --verify --deep --strict (nested tool signatures)"
if [[ "${VERIFY_APP}" -eq 0 ]]; then
    plan "codesign --verify --deep --strict --verbose=2 ${APP_PATH}"
else
    CS_VERIFY_RC=0
    CS_VERIFY_OUT="$(codesign --verify --deep --strict --verbose=2 "${APP_PATH}" 2>&1)" || CS_VERIFY_RC=$?
    printf '%s\n' "${CS_VERIFY_OUT}" | indent
    if [[ "${CS_VERIFY_RC}" -eq 0 ]]; then
        note "✓ bundle and every nested component verify"
    elif [[ "${DRY_RUN}" -eq 1 ]]; then
        warn "codesign --verify exited ${CS_VERIFY_RC} (expected: stage [3] does not sign during a dry run)"
    else
        fail 8 "[7] VERIFY — codesign --verify --deep --strict exited ${CS_VERIFY_RC}.
      A nested component (most likely one of the bundled downloader tools) is
      unsigned or its signature does not seal. Notarization would reject this."
    fi
fi

# Exec smoke on the SIGNED, BUNDLED yt-dlp specifically, and it now proves TWO
# things at once.
#
#   1. Signing. yt-dlp is a PyInstaller build that dlopen()s a CPython runtime
#      and ~100 `.so` modules, so it is the binary a hardened signature without
#      com.apple.security.cs.disable-library-validation kills — at runtime, in
#      Release only, with a green build and a green codesign --verify. Running
#      the copy that actually shipped is the only check that catches it.
#   2. Tree integrity. In the one-directory shape the launcher resolves
#      `_internal/Python` at startup, so a flattened, truncated, or wrongly
#      staged tree fails HERE rather than on a user's machine. The existence
#      asserts above cover the shape; this covers whether it actually runs.
#
# The static ffmpeg has no such dependency and needs no equivalent probe.
step "Exec smoke: bundled yt-dlp --version"
if [[ -z "${BUNDLED_YTDLP}" ]]; then
    plan "<bundled yt-dlp tree>/yt-dlp_macos --version"
    note "(skipped: no bundled yt-dlp launcher to run)"
else
    YTDLP_RC=0
    YTDLP_OUT="$("${BUNDLED_YTDLP}" --version 2>&1)" || YTDLP_RC=$?
    if [[ "${YTDLP_RC}" -ne 0 ]]; then
        fail 8 "[7] VERIFY — the BUNDLED yt-dlp failed to execute (rc ${YTDLP_RC}):
${YTDLP_OUT}
      Two readings, both fatal. A code-signature kill means the tool was signed
      with the Hardened Runtime but WITHOUT
      com.apple.security.cs.disable-library-validation — see
      macOS/DownloaderTools.entitlements and phase 0 of codesign-app.sh. A
      \"Failed to load Python shared library\" means the one-directory tree
      reached the bundle without an intact ${YTDLP_PAYLOAD_NAME}/ sibling."
    fi
    # The version is REPORTED, never compared against a literal. The pin lives in
    # ${TOOLS_SCRIPT} (which hash-verifies it); a second copy here would have to
    # be edited on every bump and would fail a release for a reason that is not a
    # release defect. The shape check catches the one thing exit 0 does not: a
    # launcher that starts and prints nothing.
    if [[ ! "${YTDLP_OUT}" =~ [0-9]{4}\.[0-9]{2}\.[0-9]{2} ]]; then
        fail 8 "[7] VERIFY — the BUNDLED yt-dlp exited 0 but printed no version tag:
${YTDLP_OUT}
      yt-dlp tags releases YYYY.MM.DD, so this is not the engine answering."
    fi
    note "✓ ${BUNDLED_YTDLP#"${APP_PATH}"/} → ${YTDLP_OUT}"
fi

# The exec smoke above CANNOT tell the two PyInstaller shapes apart, and that is
# the whole regression this migration exists to prevent: a ONEFILE
# `yt-dlp_macos` is published in the same release, right beside the
# `yt-dlp_macos.zip` one-directory asset. Install it by mistake and it RUNS —
# ignoring the `_internal/` sibling entirely — so every existence assert, the
# signature seal, and `--version` all stay green while ~12 s of self-extraction
# is silently reinstated on every engine spawn, paid twice per download.
# Measured 2026-09-10: a onefile swapped into a re-sealed bundle passed this
# script AND both CI blocks with exit 0.
#
# The one property that separates the shapes is that a ONE-DIRECTORY launcher
# CANNOT start without its payload. Proving it by copying the launcher ALONE
# into a scratch directory never touches the shipped bundle, and is sound in
# THIS position only: the step above has already established that the launcher
# runs correctly in place, so a failure here can only be the missing payload and
# not a signature kill.
step "One-directory shape: the launcher must not run without its payload"
if [[ -z "${BUNDLED_YTDLP}" ]]; then
    plan "<launcher copied alone into a scratch dir> --version   # must FAIL"
    note "(skipped: no bundled yt-dlp launcher to run)"
else
    SHAPE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macamp-ytdlp-shape.XXXXXX")"
    cp "${BUNDLED_YTDLP}" "${SHAPE_DIR}/${YTDLP_LAUNCHER_NAME}"
    SHAPE_RC=0
    SHAPE_OUT="$("${SHAPE_DIR}/${YTDLP_LAUNCHER_NAME}" --version 2>&1)" || SHAPE_RC=$?
    rm -rf "${SHAPE_DIR}"
    if [[ "${SHAPE_RC}" -eq 0 ]]; then
        fail 8 "[7] VERIFY — the bundled yt-dlp launcher ran WITHOUT its
      ${YTDLP_PAYLOAD_NAME}/ payload beside it, so it is a PyInstaller ONEFILE
      build and not the one-directory tree this bundle claims to ship:
${SHAPE_OUT}
      A onefile ignores ${YTDLP_PAYLOAD_NAME}/ and unpacks ~37 MB to \$TMPDIR on
      EVERY exec — ~12 s before any work, twice per download. ${TOOLS_SCRIPT}
      must fetch ${YTDLP_LAUNCHER_NAME}.zip (the 'Unpackaged MacOS' asset), never
      the bare ${YTDLP_LAUNCHER_NAME} onefile published beside it in the same
      release."
    fi
    note "✓ launcher alone exits ${SHAPE_RC} — ${YTDLP_PAYLOAD_NAME}/ is load-bearing"
fi

# The GPL gate, re-run ON THE SHIPPED ARTIFACT. ${TOOLS_SCRIPT} runs the same
# check at fetch time, which is necessary but NOT sufficient: a fresh CI runner
# with a warm artifact cache, a pin bump, or a hand-placed binary all reach this
# point without that check ever having run on THIS ffmpeg. A --enable-nonfree
# build (fdk-aac) is not redistributable, so every shipped .dmg would be a
# licence violation. The claim "asserted by the release VERIFY stage" has to be
# literally true, which means executing the bundled copy right here.
step "GPL licence gate: bundled ffmpeg configure line"
FFMPEG_LICENSE_STATE="not checked"
if [[ -z "${BUNDLED_FFMPEG}" ]]; then
    plan "<bundled ffmpeg> -version | grep configuration"
    note "(skipped: no bundled ffmpeg to run)"
    FFMPEG_LICENSE_STATE="not checked (no ffmpeg)"
else
    FFMPEG_RC=0
    FFMPEG_OUT="$("${BUNDLED_FFMPEG}" -version 2>&1)" || FFMPEG_RC=$?
    if [[ "${FFMPEG_RC}" -ne 0 ]]; then
        fail 8 "[7] VERIFY — the BUNDLED ffmpeg failed to execute (rc ${FFMPEG_RC}):
${FFMPEG_OUT}"
    fi
    FFMPEG_CONFIG_LINE="$(printf '%s\n' "${FFMPEG_OUT}" | grep '^ *configuration:' || true)"
    if [[ -z "${FFMPEG_CONFIG_LINE}" ]]; then
        fail 8 "[7] VERIFY — the bundled ffmpeg printed no 'configuration:' line, so its
      licence flags cannot be established. Refusing to ship an unverifiable
      GPL binary."
    fi
    if ! printf '%s\n' "${FFMPEG_CONFIG_LINE}" | grep -q -- '--enable-gpl'; then
        fail 8 "[7] VERIFY — the bundled ffmpeg was NOT configured with --enable-gpl.
      SOURCE-OFFER.txt makes a GPLv3 written offer for this binary; shipping a
      build that does not match it is a licence violation.
      configuration: ${FFMPEG_CONFIG_LINE}"
    fi
    if printf '%s\n' "${FFMPEG_CONFIG_LINE}" | grep -q -- '--enable-nonfree'; then
        fail 8 "[7] VERIFY — the bundled ffmpeg carries --enable-nonfree. A nonfree build
      (e.g. fdk-aac) is NOT redistributable, so every shipped .dmg would be a
      licence violation. Re-run ${TOOLS_SCRIPT} --force against a GPL build.
      configuration: ${FFMPEG_CONFIG_LINE}"
    fi
    note "✓ --enable-gpl present, --enable-nonfree absent"
    FFMPEG_LICENSE_STATE="GPL (nonfree absent)"
fi
summary "downloader:   ${TOOLS_STATE} — ffmpeg licence: ${FFMPEG_LICENSE_STATE}"

step "Measured sizes"
APP_SIZE="$(human_size "${APP_PATH}")"
DMG_SIZE="$(human_size "${DMG_PATH}")"
if [[ "${DRY_RUN}" -eq 1 && "${VERIFY_DMG}" -eq 0 ]]; then
    DMG_SIZE="$(human_size "${DRY_DIR}/${DMG_NAME}")"
    note "(.dmg size measured from the dry-run image in ${DRY_DIR})"
fi
note "app: ${APP_SIZE}    dmg: ${DMG_SIZE}"
note "(measured, never asserted — a size threshold would rot on the first dependency bump)"
summary "sizes:        app ${APP_SIZE}, dmg ${DMG_SIZE}"

step "Release notes stub -> ${NOTES_PATH}"
mkdir -p "$(dirname "${NOTES_PATH}")"
{
    echo "# MacAMP ${VERSION}"
    echo ""
    echo "_Stub generated by \`scripts/release.sh\` — replace the placeholder sections"
    echo "with the real changelog before publishing._"
    echo ""
    echo "## What's new"
    echo ""
    echo "- TODO: real release notes."
    echo ""
    echo "## Installing"
    echo ""
    echo "Open \`${DMG_NAME}\` and drag **MacAMP** to your Applications folder."
    echo ""
    echo "### First launch (Gatekeeper)"
    echo ""
    if [[ "${SIGN_MODE}" == "adhoc" ]]; then
        echo "This build is **ad-hoc-signed** (not Developer-ID notarized), so macOS"
        echo "Sequoia reports it as \"damaged\" on first launch; right-click → Open no"
        echo "longer bypasses this, so you must allow it once via **System Settings →"
        echo "Privacy & Security → \"Open Anyway\"**."
    else
        echo "This build is signed with a Developer ID certificate. If it was also"
        echo "notarized it launches with no prompt. For reference, an **ad-hoc-signed**"
        echo "build (not Developer-ID notarized) is reported by macOS Sequoia as"
        echo "\"damaged\" on first launch; right-click → Open no longer bypasses this,"
        echo "so users must allow it once via **System Settings → Privacy & Security →"
        echo "\"Open Anyway\"**."
    fi
    echo ""
    echo "## Requirements"
    echo ""
    echo "- **macOS 14 or later** for the app itself."
    echo "- **macOS 15 or later for Karaoke (vocal removal).** The Core ML separation"
    echo "  model relies on a fused SDPA attention op that does not exist before"
    echo "  macOS 15; on macOS 14 the model fails to load and Karaoke resolves to"
    echo "  *Unavailable*. Everything else works on macOS 14."
    if [[ "${NO_MODEL}" -eq 1 ]]; then
        echo "- This build ships **without** the separation model, so Karaoke is"
        echo "  unavailable on every macOS version."
    fi
    echo ""
    echo "## Artifacts"
    echo ""
    echo "| Artifact | Size |"
    echo "|---|---|"
    echo "| MacAMP.app | ${APP_SIZE} |"
    echo "| ${DMG_NAME} | ${DMG_SIZE} |"
    echo ""
    echo "Signing: ${SIGN_MODE}. Gatekeeper assessment: ${SPCTL_STATE}."
} > "${NOTES_PATH}"
note "✓ wrote ${NOTES_PATH}"
summary "notes:        ${NOTES_PATH}"

# =============================================================================
banner "[8] PUBLISH — scripts/publish-r2.sh"
# =============================================================================

if [[ "${PUBLISH}" -eq 0 ]]; then
    note "not requested (pass --publish, or run scripts/publish-r2.sh --version ${VERSION} later)"
    summary "publish:      not requested"
elif [[ "${DRY_RUN}" -eq 1 ]]; then
    plan "scripts/publish-r2.sh --version ${VERSION} --output-dir ${OUTPUT_DIR}"
    [[ "${SKIP_GITHUB}" -eq 1 ]] || plan "scripts/github-release.sh --version ${VERSION} --output-dir ${OUTPUT_DIR}"
    summary "publish:      planned (dry-run)"
else
    PUBLISH_ARGS=(--version "${VERSION}" --output-dir "${OUTPUT_DIR}")
    [[ "${ASSUME_YES}" -eq 1 ]] && PUBLISH_ARGS+=(--yes)
    PUBLISH_RC=0
    "${SCRIPT_DIR}/publish-r2.sh" "${PUBLISH_ARGS[@]}" || PUBLISH_RC=$?
    [[ "${PUBLISH_RC}" -eq 0 ]] || fail 9 "[8] PUBLISH — publish-r2.sh exited ${PUBLISH_RC}"
    summary "publish:      live at https://downloads.macamp.si"
    if [[ "${SKIP_GITHUB}" -eq 1 ]]; then
        note "GitHub Release skipped (--skip-github); later: scripts/github-release.sh --version ${VERSION}"
        summary "github:       skipped"
    else
        GITHUB_RC=0
        "${SCRIPT_DIR}/github-release.sh" --version "${VERSION}" --output-dir "${OUTPUT_DIR}" || GITHUB_RC=$?
        [[ "${GITHUB_RC}" -eq 0 ]] || fail 9 "[8] PUBLISH — the download is live, but github-release.sh exited ${GITHUB_RC}.
      Fix the cause and run: scripts/github-release.sh --version ${VERSION}"
        summary "github:       https://github.com/airnayden/macamp/releases/tag/v${VERSION}"
    fi
fi

# =============================================================================
banner "RELEASE SUMMARY — ${VERSION}"
# =============================================================================
printf '    %s\n' ${SUMMARY_LINES[@]+"${SUMMARY_LINES[@]}"}
echo ""
if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRY-RUN complete: no Keychain access, no network, no codesign, and"
    echo "${OUTPUT_DIR} was not modified. Dry-run artifacts: ${DRY_DIR}"
    echo "Re-run without --dry-run to produce a real release."
else
    echo "PASS: MacAMP ${VERSION} released to ${OUTPUT_DIR}"
    echo "      app:     ${APP_PATH}"
    echo "      dmg:     ${DMG_PATH}"
    [[ "${SKIP_APPCAST}" -eq 1 ]] || echo "      appcast: ${APPCAST_PATH}"
    echo "      notes:   ${NOTES_PATH}"
fi
exit 0
