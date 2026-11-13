#!/usr/bin/env bash
#
# build-macamp.sh — one-shot "everything included" build of the macOS app.
#
# Produces a Debug (default) or Release build of macampMac with the karaoke
# separation model bundled, by running, in order:
#
#   1. MODEL   — delegate to tools/separation/fetch-and-convert-model.sh, THE
#                single source of truth for the model stage: it ensures
#                macOS/Resources/SeparationModel/{MelBandRoformer.mlpackage,
#                model-manifest.json} exist (venv + converter + verify), and
#                exits fast when they already do. Pass --skip-model to build
#                model-less (the CI shape).
#                The SAME stage then delegates to
#                tools/downloader/fetch-download-tools.sh, the equivalent single
#                source of truth for the YouTube-downloader helpers
#                (macOS/Resources/DownloaderTools/{yt-dlp/,ffmpeg,ffprobe} +
#                their GPLv3 licence texts). Both fetches MUST happen before
#                stage 2: macOS/Project.swift reaches into both directories
#                through globs that are frozen at `tuist generate` time, so a
#                payload fetched afterwards never enters the build graph and the
#                app ships without it while the build stays green. Pass
#                --skip-tools to build tool-less.
#   2. GENERATE — tuist install (if Tuist/.build is missing) + tuist generate.
#                ALWAYS regenerates: SPM `.external` file lists are frozen at
#                generate time, so a stale workspace breaks builds after new
#                PlayerCore files land.
#   3. CLEAN-SLATE — optionally remove OTHER installed copies of MacAMP.
#                Default OFF; --clean-installs opts in. --keep-installs opts
#                out for compatibility. Candidates come from
#                Spotlight (mdfind on kMDItemCFBundleIdentifier) plus explicit
#                probes of /Applications/MacAMP.app and ~/Applications/MacAMP.app.
#                Three hard guards — every decision is logged with a reason:
#                  * EXCLUDED — anything inside this repo, any */DerivedData/*
#                    path, this run's build-products dir, or an .xcarchive.
#                  * VERIFIED — the bundle's own CFBundleIdentifier must equal
#                    the target id EXACTLY (a foreign app is never deleted).
#                  * RUNNING  — a bundle whose executable has a live process
#                    (pgrep -f, then lsof) is SKIPPED, never rm -rf'd.
#   4. BUILD   — xcodebuild macampMac (CODE_SIGNING_ALLOWED=NO), then verify the
#                built .app actually contains the compiled MelBandRoformer.mlmodelc
#                + model-manifest.json (unless --skip-model), and the embedded
#                libprojectM-4.4.dylib (always).
#                With --app-version, MARKETING_VERSION + CURRENT_PROJECT_VERSION
#                are passed as command-line build settings, which outrank both the
#                project and the target, so the bundle ships that version.
#
# VERSION STAMPING (--app-version <v>)
#   Sparkle compares the BUNDLE's version, never the .dmg file name. Without this
#   flag the bundle keeps macOS/Project.swift's defaults, 1.0 (1) — an update that
#   would never be offered. With it:
#       CFBundleShortVersionString <- <v>            (MARKETING_VERSION)
#       CFBundleVersion            <- build number   (CURRENT_PROJECT_VERSION)
#   The build number is `git rev-list --count HEAD`: an integer that only ever
#   grows with history, needs no state file, and is reproducible from any clone.
#   Outside a git repo it falls back to a UTC yyyymmddHHMM stamp (also monotonic,
#   but much larger — do not mix the two schemes across releases of one app).
#   MACAMP_BUILD_NUMBER overrides both for CI or a re-cut of an existing tag.
#
#   This works ONLY because macOS/Project.swift's appInfoPlist maps both keys to
#   $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION). Tuist's default template
#   hardcodes the literals 1.0 and 1, and a command-line build setting cannot
#   override a literal already written into the plist — it is silently ignored.
#   Revert that indirection and this flag becomes a no-op with no error.
#
# NOTE: CLEAN-SLATE keys every removal off the bundle id `si.macamp.MacAMP`
#       (macOS/Project.swift), so CLEAN_SLATE_BUNDLE_ID below must stay in sync
#       with it. Builds from before the rename used `com.example.macamp`; pass
#       MACAMP_CLEAN_SLATE_BUNDLE_ID=com.example.macamp to clean those up.
#
# Usage:
#   scripts/build-macamp.sh                  # Debug, model bundled
#   scripts/build-macamp.sh --release        # Release, model bundled
#   scripts/build-macamp.sh --skip-model     # build without the model (CI shape)
#   scripts/build-macamp.sh --skip-tools     # build without the downloader tools
#   scripts/build-macamp.sh --clean-installs # remove eligible other installs
#   scripts/build-macamp.sh --keep-installs  # preserve installs (the default)
#   scripts/build-macamp.sh --clean-only     # enable cleanup and run ONLY that stage
#   scripts/build-macamp.sh --open           # reveal the built .app when done
#   scripts/build-macamp.sh --app-version 1.2.3   # stamp the bundle (see above)
#
# Cleanup options are applied left to right: the last of --clean-installs,
# --keep-installs and --clean-only wins. --clean-only always skips the build.
#
# Env (CLEAN-SLATE test seams — every guard above still applies to both):
#   MACAMP_CLEAN_SLATE_PATHS      colon-separated list of candidate .app paths
#                                 that REPLACES discovery entirely (no mdfind,
#                                 no /Applications probe).
#   MACAMP_CLEAN_SLATE_BUNDLE_ID  target bundle id override. Lets a test drive
#                                 the REAL discovery branch against a decoy id,
#                                 so a live /Applications scan provably cannot
#                                 reach the installed app.
#   MACAMP_BUILD_NUMBER           CFBundleVersion override, used INSTEAD of the
#                                 git commit count. Integer or dot-separated
#                                 integers only. Ignored without --app-version.
#
#   exit 0 -> build succeeded (model + downloader tools verified in the bundle,
#             unless the matching --skip flag was passed)
#   exit 1 -> a step failed (message printed)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

MODEL_DIR="macOS/Resources/SeparationModel"
MODEL_SCRIPT="tools/separation/fetch-and-convert-model.sh"
TOOLS_DIR="macOS/Resources/DownloaderTools"
TOOLS_SCRIPT="tools/downloader/fetch-download-tools.sh"
# ffmpeg/ffprobe are single files in Contents/MacOS; yt-dlp is a DIRECTORY in
# Contents/Resources (PyInstaller onedir), so it is asserted separately below.
DOWNLOADER_BINARY_NAMES=(ffmpeg ffprobe)
YTDLP_TREE_NAME="yt-dlp"
DOWNLOADER_LICENSE_NAMES=(LICENSE-yt-dlp.txt LICENSE-ffmpeg.txt SOURCE-OFFER.txt)
# Must match the app's bundleId in macOS/Project.swift. See the NOTE in the header.
CLEAN_SLATE_BUNDLE_ID="${MACAMP_CLEAN_SLATE_BUNDLE_ID:-si.macamp.MacAMP}"
CONFIGURATION="Debug"
SKIP_MODEL=0
SKIP_TOOLS=0
OPEN_APP=0
CLEAN_SLATE=0
CLEAN_ONLY=0
APP_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) CONFIGURATION="Release"; shift ;;
        --skip-model) SKIP_MODEL=1; shift ;;
        --skip-tools) SKIP_TOOLS=1; shift ;;
        --clean-installs) CLEAN_SLATE=1; shift ;;
        --keep-installs) CLEAN_SLATE=0; shift ;;
        --clean-only) CLEAN_ONLY=1; CLEAN_SLATE=1; shift ;;
        --open) OPEN_APP=1; shift ;;
        --app-version)
            [[ $# -ge 2 ]] || { echo "error: --app-version needs a value" >&2; exit 1; }
            APP_VERSION="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "error: unknown option '$1' (see --help)" >&2; exit 1 ;;
    esac
done

case "${APP_VERSION}" in
    "") ;;
    *[[:space:]]*|*/*) echo "error: --app-version must not contain whitespace or '/': '${APP_VERSION}'" >&2; exit 1 ;;
    -*) echo "error: --app-version must not start with '-': '${APP_VERSION}'" >&2; exit 1 ;;
esac

step() { printf '\n==> %s\n' "$1"; }

# CFBundleVersion is what Sparkle actually compares, so it has to be monotonic
# AND well-formed: Gatekeeper and Sparkle accept only dot-separated integers.
resolve_build_number() {
    local count
    if [[ -n "${MACAMP_BUILD_NUMBER:-}" ]]; then
        printf '%s\n' "${MACAMP_BUILD_NUMBER}"
    elif count="$(git rev-list --count HEAD 2>/dev/null)" && [[ -n "${count}" ]]; then
        printf '%s\n' "${count}"
    else
        date -u +%Y%m%d%H%M
    fi
}

# Throwaway build-products dir. Created up here (not inside BUILD) so CLEAN-SLATE
# can exclude it from the removal candidates.
DERIVED_DATA="$(mktemp -d /tmp/macamp-build.XXXXXX)"
trap 'rm -rf "${DERIVED_DATA}"' EXIT

# Symlink-resolved forms, compared against equally-resolved candidate paths.
REPO_ROOT_PHYS="$(cd "${REPO_ROOT}" && pwd -P)"
DERIVED_DATA_PHYS="$(cd "${DERIVED_DATA}" && pwd -P)"

# --------------------------------------------------- CLEAN-SLATE stage helpers

# Reasons/pids are returned through these globals (bash 3.2: no nameref).
CLEAN_SLATE_REJECTION=""
CLEAN_SLATE_RUNNING_BY=""

# Absolute, symlink-resolved form of $1. Falls back to the input unchanged when
# the parent directory does not exist.
clean_slate_canonical() {
    local path="$1" dir base parent
    dir="$(dirname "${path}")"
    base="$(basename "${path}")"
    (
        cd "${dir}" 2>/dev/null || exit 1
        parent="$(pwd -P)"
        if [ "${parent}" = "/" ]; then parent=""; fi
        printf '%s/%s\n' "${parent}" "${base}"
    ) || printf '%s\n' "${path}"
}

# Escape every ERE metacharacter so a path can be used as a literal pgrep -f
# pattern (paths legally contain +, (, ), [, ], {, }, ., etc.).
clean_slate_regex_escape() {
    printf '%s' "$1" | sed 's/[]\\.^$*+?(){}|[]/\\&/g'
}

# 0 when <path> IS <ancestor> or lives below it.
clean_slate_is_under() {
    local path="$1" ancestor="${2%/}"
    if [ -z "${ancestor}" ]; then return 1; fi
    case "${path}" in
        "${ancestor}"|"${ancestor}"/*) return 0 ;;
    esac
    return 1
}

# 0 when the candidate is a removal-eligible foreign install. On rejection,
# returns 1 and puts the human-readable reason in CLEAN_SLATE_REJECTION.
clean_slate_is_removable() {
    local path="$1" found_id depth
    CLEAN_SLATE_REJECTION=""

    # --- rm -rf sanity rails: absolute, .app-suffixed, real directory, deep enough.
    case "${path}" in
        /*) ;;
        *) CLEAN_SLATE_REJECTION="not an absolute path"; return 1 ;;
    esac
    case "${path}" in
        *.app) ;;
        *) CLEAN_SLATE_REJECTION="not a .app bundle"; return 1 ;;
    esac
    if [ -L "${path}" ]; then
        CLEAN_SLATE_REJECTION="symlink, not a real bundle"
        return 1
    fi
    if [ ! -d "${path}" ]; then
        CLEAN_SLATE_REJECTION="not installed"
        return 1
    fi
    depth="$(printf '%s' "${path}" | tr -cd '/' | wc -c | tr -d ' ')"
    if [ "${depth}" -lt 2 ]; then
        CLEAN_SLATE_REJECTION="refusing to touch a top-level path"
        return 1
    fi

    # --- exclusions: never reap our own tree or any build artifact.
    if clean_slate_is_under "${path}" "${REPO_ROOT_PHYS}"; then
        CLEAN_SLATE_REJECTION="inside the repo working tree"
        return 1
    fi
    if clean_slate_is_under "${path}" "${DERIVED_DATA_PHYS}"; then
        CLEAN_SLATE_REJECTION="this run's build-products dir"
        return 1
    fi
    case "${path}" in
        */DerivedData/*)
            CLEAN_SLATE_REJECTION="Xcode DerivedData build product"
            return 1
            ;;
        *.xcarchive/*)
            CLEAN_SLATE_REJECTION="inside an .xcarchive"
            return 1
            ;;
    esac

    # --- identity: the bundle must claim OUR id, exactly.
    if [ ! -f "${path}/Contents/Info.plist" ]; then
        CLEAN_SLATE_REJECTION="no Contents/Info.plist (not an app bundle)"
        return 1
    fi
    found_id="$(plutil -extract CFBundleIdentifier raw -o - "${path}/Contents/Info.plist" 2>/dev/null || true)"
    if [ "${found_id}" != "${CLEAN_SLATE_BUNDLE_ID}" ]; then
        CLEAN_SLATE_REJECTION="CFBundleIdentifier '${found_id:-<unreadable>}' != ${CLEAN_SLATE_BUNDLE_ID}"
        return 1
    fi
    return 0
}

# 0 when the bundle looks live. Deliberately biased toward "running": an
# unreadable Info.plist or a pgrep error also answers yes, because the only
# unsafe answer here is a false "no".
clean_slate_is_running() {
    local path="$1" exe_name exe_path pattern pids rc pid
    CLEAN_SLATE_RUNNING_BY=""

    exe_name="$(plutil -extract CFBundleExecutable raw -o - "${path}/Contents/Info.plist" 2>/dev/null || true)"
    if [ -n "${exe_name}" ]; then
        exe_path="${path}/Contents/MacOS/${exe_name}"
    else
        exe_path="${path}/Contents/MacOS"
    fi

    pattern="$(clean_slate_regex_escape "${exe_path}")"
    set +e
    pids="$(pgrep -f -- "${pattern}" 2>/dev/null)"
    rc=$?
    set -e
    if [ "${rc}" -gt 1 ]; then
        CLEAN_SLATE_RUNNING_BY="process scan failed (pgrep rc ${rc})"
        return 0
    fi
    for pid in ${pids}; do
        # Our own process tree is not "the app running".
        if [ "${pid}" = "$$" ] || [ "${pid}" = "${PPID}" ]; then continue; fi
        CLEAN_SLATE_RUNNING_BY="pid ${pid}"
        return 0
    done

    if [ -f "${exe_path}" ] && command -v lsof >/dev/null 2>&1; then
        if lsof -- "${exe_path}" >/dev/null 2>&1; then
            CLEAN_SLATE_RUNNING_BY="open executable (lsof)"
            return 0
        fi
    fi
    return 1
}

# Collect candidates into CLEAN_SLATE_CANDIDATES (bash 3.2: no nameref).
clean_slate_collect() {
    local path old_ifs
    CLEAN_SLATE_CANDIDATES=()

    if [ -n "${MACAMP_CLEAN_SLATE_PATHS:-}" ]; then
        echo "    source: MACAMP_CLEAN_SLATE_PATHS (discovery overridden)"
        old_ifs="${IFS}"
        set -f
        IFS=':'
        for path in ${MACAMP_CLEAN_SLATE_PATHS}; do
            if [ -n "${path}" ]; then CLEAN_SLATE_CANDIDATES+=("${path}"); fi
        done
        IFS="${old_ifs}"
        set +f
        return 0
    fi

    echo "    source: mdfind(kMDItemCFBundleIdentifier) + /Applications + ~/Applications"
    while IFS= read -r path; do
        if [ -n "${path}" ]; then CLEAN_SLATE_CANDIDATES+=("${path}"); fi
    done < <(mdfind "kMDItemCFBundleIdentifier == '${CLEAN_SLATE_BUNDLE_ID}'" 2>/dev/null || true)
    CLEAN_SLATE_CANDIDATES+=("/Applications/MacAMP.app")
    CLEAN_SLATE_CANDIDATES+=("${HOME}/Applications/MacAMP.app")
}

clean_slate() {
    local path canonical parent seen removed skipped total
    removed=0
    skipped=0
    seen=$'\n'

    clean_slate_collect
    total="${#CLEAN_SLATE_CANDIDATES[@]}"
    if [ "${total}" -eq 0 ]; then
        echo "    (no candidates)"
        return 0
    fi

    for path in "${CLEAN_SLATE_CANDIDATES[@]}"; do
        canonical="$(clean_slate_canonical "${path}")"
        case "${seen}" in
            *$'\n'"${canonical}"$'\n'*) continue ;;
        esac
        seen="${seen}${canonical}"$'\n'

        if ! clean_slate_is_removable "${canonical}"; then
            printf '    skip    %s — %s\n' "${canonical}" "${CLEAN_SLATE_REJECTION}"
            skipped=$((skipped + 1))
            continue
        fi
        if clean_slate_is_running "${canonical}"; then
            printf '    skip    %s — RUNNING (%s); a live bundle is never removed\n' \
                "${canonical}" "${CLEAN_SLATE_RUNNING_BY}"
            skipped=$((skipped + 1))
            continue
        fi
        parent="$(dirname "${canonical}")"
        if [ ! -w "${parent}" ]; then
            printf '    skip    %s — %s is not writable (needs admin)\n' "${canonical}" "${parent}"
            skipped=$((skipped + 1))
            continue
        fi
        if rm -rf "${canonical}" 2>/dev/null; then
            printf '    REMOVED %s — stale install of %s\n' "${canonical}" "${CLEAN_SLATE_BUNDLE_ID}"
            removed=$((removed + 1))
        else
            printf '    skip    %s — rm -rf failed (permissions?)\n' "${canonical}"
            skipped=$((skipped + 1))
        fi
    done

    printf '    ✓ %d removed, %d skipped\n' "${removed}" "${skipped}"
}

run_clean_slate_stage() {
    if [[ "${CLEAN_SLATE}" -eq 0 ]]; then
        step "CLEAN-SLATE: skipped — other MacAMP installs left alone (use --clean-installs to opt in)"
        return 0
    fi
    step "CLEAN-SLATE: removing other installs of ${CLEAN_SLATE_BUNDLE_ID}"
    clean_slate
}

if [[ "${CLEAN_ONLY}" -eq 1 ]]; then
    run_clean_slate_stage
    exit 0
fi

# ---------------------------------------------------------------- 1. MODEL
if [[ "${SKIP_MODEL}" -eq 1 ]]; then
    step "MODEL: skipped (--skip-model) — karaoke will resolve .unavailable"
else
    step "MODEL: ensuring ${MODEL_DIR}/ via ${MODEL_SCRIPT}"
    "${MODEL_SCRIPT}"
fi

# Same stage, second payload: both are git-ignored directories consumed by globs
# that macOS/Project.swift freezes at `tuist generate` time (stage 2 below), so
# both fetches have to land here or the build silently ships without them.
if [[ "${SKIP_TOOLS}" -eq 1 ]]; then
    step "MODEL: downloader tools skipped (--skip-tools) — downloads will be unavailable"
else
    step "MODEL: ensuring ${TOOLS_DIR}/ via ${TOOLS_SCRIPT}"
    "${TOOLS_SCRIPT}"
fi

# ------------------------------------------------------------- 2. GENERATE
if [[ ! -d "Tuist/.build" ]]; then
    step "GENERATE: Tuist dependencies missing — tuist install"
    tuist install --force-resolved-versions
fi
step "GENERATE: tuist generate (never skipped — stale SPM file lists break builds)"
tuist generate --no-open

# ---------------------------------------------------------- 3. CLEAN-SLATE
run_clean_slate_stage

# ---------------------------------------------------------------- 4. BUILD
# Empty unless --app-version was passed, so an un-stamped build is byte-for-byte
# the command it has always been and keeps macOS/Project.swift's 1.0 (1).
VERSION_SETTINGS=()
if [[ -n "${APP_VERSION}" ]]; then
    BUILD_NUMBER="$(resolve_build_number)"
    BUILD_NUMBER_RE='^[0-9]+(\.[0-9]+)*$'
    if [[ ! "${BUILD_NUMBER}" =~ ${BUILD_NUMBER_RE} ]]; then
        echo "error: build number '${BUILD_NUMBER}' is not an integer or dot-separated integers." >&2
        echo "       CFBundleVersion rejects anything else. Set MACAMP_BUILD_NUMBER." >&2
        exit 1
    fi
    VERSION_SETTINGS=("MARKETING_VERSION=${APP_VERSION}" "CURRENT_PROJECT_VERSION=${BUILD_NUMBER}")
    step "BUILD: stamping bundle version ${APP_VERSION} (${BUILD_NUMBER})"
    echo "    CFBundleShortVersionString <- MARKETING_VERSION=${APP_VERSION}"
    echo "    CFBundleVersion            <- CURRENT_PROJECT_VERSION=${BUILD_NUMBER}"
fi

step "BUILD: xcodebuild macampMac (${CONFIGURATION})"
# ARCHS=arm64 ONLY_ACTIVE_ARCH=NO is REQUIRED, not an optimization: Release
# defaults to a UNIVERSAL build and the vendored
# macOS/Vendor/projectM/lib/libprojectM-4.4.dylib ships arm64 ONLY, so the
# x86_64 slice fails to link with undefined `_projectm_*` symbols. `-destination
# arch=arm64` does NOT prevent that — it selects the run destination, not ARCHS.
# CI passes both on its own xcodebuild call (.github/workflows/ci.yml); this
# script did not, so `--release` here — and `release.sh`, whose BUILD stage is
# this script — failed where CI passed.
xcodebuild build \
    -workspace MacAMP.xcworkspace \
    -scheme macampMac \
    -configuration "${CONFIGURATION}" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${DERIVED_DATA}" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"} \
    -quiet

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/MacAMP.app"
[[ -d "${APP_PATH}" ]] || { echo "error: built app not found at ${APP_PATH}" >&2; exit 1; }

# A stamp that silently fails to land is the whole bug this flag exists to fix,
# and it fails silently by construction: a literal in the plist beats a
# command-line build setting with no warning. So assert it, never assume it.
if [[ -n "${APP_VERSION}" ]]; then
    step "VERIFY: stamped version reached the bundle"
    BUILT_PLIST="${APP_PATH}/Contents/Info.plist"
    BUILT_SHORT="$(plutil -extract CFBundleShortVersionString raw -o - "${BUILT_PLIST}" 2>/dev/null || true)"
    BUILT_BUILD="$(plutil -extract CFBundleVersion raw -o - "${BUILT_PLIST}" 2>/dev/null || true)"
    if [[ "${BUILT_SHORT}" != "${APP_VERSION}" || "${BUILT_BUILD}" != "${BUILD_NUMBER}" ]]; then
        echo "error: --app-version did not reach the built bundle." >&2
        echo "       wanted: CFBundleShortVersionString=${APP_VERSION} CFBundleVersion=${BUILD_NUMBER}" >&2
        echo "       got:    CFBundleShortVersionString=${BUILT_SHORT:-<unset>} CFBundleVersion=${BUILT_BUILD:-<unset>}" >&2
        echo "       macOS/Project.swift's appInfoPlist must map both keys to" >&2
        echo "       \$(MARKETING_VERSION) / \$(CURRENT_PROJECT_VERSION) — a literal there wins." >&2
        exit 1
    fi
    echo "    ✓ CFBundleShortVersionString=${BUILT_SHORT}  CFBundleVersion=${BUILT_BUILD}"
fi

if [[ "${SKIP_MODEL}" -eq 0 ]]; then
    step "VERIFY: compiled model inside the bundle"
    COMPILED_MODEL="${APP_PATH}/Contents/Resources/MelBandRoformer.mlmodelc"
    BUNDLED_MANIFEST="${APP_PATH}/Contents/Resources/model-manifest.json"
    [[ -d "${COMPILED_MODEL}" ]] || { echo "error: ${COMPILED_MODEL} missing from the bundle" >&2; exit 1; }
    [[ -f "${BUNDLED_MANIFEST}" ]] || { echo "error: ${BUNDLED_MANIFEST} missing from the bundle" >&2; exit 1; }
    echo "    ✓ MelBandRoformer.mlmodelc + model-manifest.json bundled"
fi

# Unconditional, unlike the model check above: the dylib is COMMITTED under
# macOS/Vendor/projectM/lib/, so it can never be legitimately absent and there is
# no --skip flag to honour. A miss means the copyFiles phase broke, which the link
# alone will NOT catch — OTHER_LDFLAGS links it straight from $(SRCROOT) while the
# app resolves it at runtime via @rpath in Contents/Frameworks.
step "VERIFY: embedded projectM dylib inside the bundle"
PROJECTM_DYLIB="${APP_PATH}/Contents/Frameworks/libprojectM-4.4.dylib"
[[ -f "${PROJECTM_DYLIB}" ]] || {
    echo "error: ${PROJECTM_DYLIB} missing from the bundle" >&2
    echo "       the projectM visualizer would fail to load — check the copyFiles" >&2
    echo "       phase in macOS/Project.swift" >&2
    exit 1
}
echo "    ✓ libprojectM-4.4.dylib embedded"

# Fails EARLY here rather than at release.sh's VERIFY stage. THREE destinations
# are asserted separately because the three artifact kinds are staged by three
# different mechanisms:
#
#   ffmpeg / ffprobe   copyFiles(.executables) -> Contents/MacOS  (measured; NOT
#                      the Contents/Executables the name suggests)
#   yt-dlp tree        .folderReference        -> Contents/Resources/yt-dlp/
#   licence texts      resources: glob         -> Contents/Resources
#
# The yt-dlp check asserts the DIRECTORY and its `_internal/` payload, not just
# the launcher: a flattened copy still puts a `yt-dlp_macos` in the bundle, and it
# dies at first launch with `Failed to load Python shared library`.
if [[ "${SKIP_TOOLS}" -eq 0 ]]; then
    step "VERIFY: bundled downloader tools inside the bundle"
    for tool_name in "${DOWNLOADER_BINARY_NAMES[@]}"; do
        BUNDLED_TOOL="${APP_PATH}/Contents/MacOS/${tool_name}"
        [[ -f "${BUNDLED_TOOL}" ]] || {
            echo "error: ${BUNDLED_TOOL} missing from the bundle" >&2
            echo "       YouTube downloads would be unavailable in this build." >&2
            echo "       ${TOOLS_SCRIPT} must run BEFORE tuist generate — the" >&2
            echo "       copyFiles glob in macOS/Project.swift is frozen there." >&2
            exit 1
        }
    done
    BUNDLED_YTDLP_TREE="${APP_PATH}/Contents/Resources/${YTDLP_TREE_NAME}"
    [[ -x "${BUNDLED_YTDLP_TREE}/yt-dlp_macos" && -d "${BUNDLED_YTDLP_TREE}/_internal" ]] || {
        echo "error: ${BUNDLED_YTDLP_TREE}/ is missing or incomplete" >&2
        echo "       Expected the yt-dlp onedir tree: an executable yt-dlp_macos" >&2
        echo "       beside an _internal/ directory. YouTube downloads would be" >&2
        echo "       unavailable, or the engine would die at launch." >&2
        echo "       ${TOOLS_SCRIPT} must run BEFORE tuist generate — the" >&2
        echo "       .folderReference in macOS/Project.swift is resolved there." >&2
        exit 1
    }
    for license_name in "${DOWNLOADER_LICENSE_NAMES[@]}"; do
        BUNDLED_LICENSE="${APP_PATH}/Contents/Resources/${license_name}"
        [[ -f "${BUNDLED_LICENSE}" ]] || {
            echo "error: ${BUNDLED_LICENSE} missing from the bundle" >&2
            echo "       Shipping GPLv3 binaries without their licence texts and" >&2
            echo "       written source offer is a licence violation." >&2
            exit 1
        }
    done
    echo "    ✓ yt-dlp/ onedir tree (launcher + _internal/) + ffmpeg + ffprobe embedded, GPLv3 texts bundled"
fi

# Keep the artifact: move it out of the throwaway DerivedData before the trap fires.
OUT_DIR="build"
mkdir -p "${OUT_DIR}"
rm -rf "${OUT_DIR}/MacAMP.app"
mv "${APP_PATH}" "${OUT_DIR}/MacAMP.app"

step "DONE: ${OUT_DIR}/MacAMP.app (${CONFIGURATION})"
[[ "${OPEN_APP}" -eq 1 ]] && open -R "${OUT_DIR}/MacAMP.app"
exit 0
