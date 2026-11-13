#!/usr/bin/env bash
#
# codesign-app.sh
#
# Code-sign a BUILT MacAMP `.app` for Developer-ID (direct) distribution with the
# Hardened Runtime enabled (`--options runtime`) and a secure timestamp — both are
# MANDATORY for Apple notarization to succeed.
#
# THE LOAD-BEARING RULE: every bundled Mach-O — the downloader tools (ffmpeg and
# ffprobe in Contents/MacOS, plus the whole yt-dlp one-directory tree in
# Contents/Resources), loose dylibs (projectM), the SFB codec frameworks, GRDB,
# and Sparkle (incl. its nested XPC services + helper apps) — MUST be signed
# BEFORE the enclosing bundle. codesign signs INSIDE-OUT; if a nested
# dylib/framework is left unsigned (or is signed AFTER its container) the notary
# service rejects the whole submission with
# "The binary is not signed with a valid Developer ID certificate". This script
# enumerates and signs them in the correct order, then seals the `.app` last.
#
# The downloader tools get their OWN entitlements file
# (macOS/DownloaderTools.entitlements) in phase 0, granting exactly one exception:
# com.apple.security.cs.disable-library-validation, without which the hardened
# PyInstaller yt-dlp is killed at its first dlopen and every download fails in
# Release only. The phase is skipped in silence when the tools are absent.
#
# yt-dlp is a PyInstaller ONE-DIRECTORY tree, so phase 0 signs 107 Mach-O files
# rather than one. A `.folderReference` carries NO codeSignOnCopy, so that tree
# arrives in the bundle completely unsigned as far as our identity is concerned —
# unlike ffmpeg/ffprobe, which ride a copyFiles phase that signs on copy. Phase 0
# is therefore the ONLY thing that puts our signature on the download engine.
#
# Signing identity comes from the environment (NEVER hardcoded / committed):
#   DEVELOPER_ID_APPLICATION   e.g. "Developer ID Application: Jane Roe (TEAMID123)"
# or pass --identity "<id>". A --dry-run lists exactly what WOULD be signed, in
# order, and needs NO identity (so it runs in CI / on contributor machines without
# any Apple secrets).
#
# Usage:
#   scripts/codesign-app.sh [--dry-run] <path/to/MacAMP.app>
#   scripts/codesign-app.sh --app <path/to/MacAMP.app> [--identity "<id>"] \
#                           [--entitlements <path>]
#
#   --dry-run                List the signing plan (no identity required). Default
#                            off → performs real signing (identity REQUIRED).
#   --app <path>             The built .app to sign (also accepted positionally).
#   --identity <id>          Override $DEVELOPER_ID_APPLICATION.
#   --entitlements <path>    Entitlements for the MAIN app bundle. Defaults to
#                            macOS/macampMac.entitlements in the repo.
#   -h | --help              Show this help.
#
# Exit codes:
#   0  success (signed, or dry-run plan printed)
#   1  bad arguments
#   2  app bundle not found / not a directory
#   3  signing identity required but absent (real-sign mode only)
#   4  a codesign invocation failed
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DRY_RUN=0
APP_PATH=""
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
ENTITLEMENTS="${REPO_ROOT}/macOS/macampMac.entitlements"

usage() {
  sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; s/^#$//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --app) [[ $# -ge 2 ]] || die "--app needs a path"; APP_PATH="$2"; shift 2 ;;
    --identity) [[ $# -ge 2 ]] || die "--identity needs a value"; IDENTITY="$2"; shift 2 ;;
    --entitlements) [[ $# -ge 2 ]] || die "--entitlements needs a path"; ENTITLEMENTS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) [[ -z "${APP_PATH}" ]] || die "unexpected extra argument: $1"; APP_PATH="$1"; shift ;;
  esac
done

[[ -n "${APP_PATH}" ]] || die "no .app given (pass a path or --app <path>; try --help)"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app bundle not found or not a directory: ${APP_PATH}" >&2
  exit 2
fi

# Normalise to an absolute path so relative-path stripping in the log is stable.
APP_PATH="$(cd "${APP_PATH}/.." && pwd)/$(basename "${APP_PATH}")"
FRAMEWORKS_DIR="${APP_PATH}/Contents/Frameworks"
PLUGINS_DIR="${APP_PATH}/Contents/PlugIns"
MACOS_DIR="${APP_PATH}/Contents/MacOS"

# The bundled downloader helpers in Contents/MacOS. Named EXPLICITLY rather than
# globbed, because that directory also holds the app's own main executable —
# which must NEVER be signed on its own here (phase 5 seals it as part of the
# bundle, with the app's entitlements). A `find -type f` over it would grab it.
#
# yt-dlp is NOT in this list: it is a directory tree in Contents/Resources with
# its own phase (0b) below.
DOWNLOADER_TOOL_NAMES=(ffmpeg ffprobe)
DOWNLOADER_ENTITLEMENTS="${REPO_ROOT}/macOS/DownloaderTools.entitlements"

YTDLP_TREE_DIR="${APP_PATH}/Contents/Resources/yt-dlp"
YTDLP_LAUNCHER="${YTDLP_TREE_DIR}/yt-dlp_macos"

# Shared codesign flags. --force re-signs in place; --options runtime turns on the
# Hardened Runtime; --timestamp obtains Apple's secure timestamp (REQUIRED for the
# notary service). Verbose so the audit trail in CI logs is legible.
CODESIGN_FLAGS=(--force --options runtime --timestamp --verbose)

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "==> codesign DRY-RUN — signing PLAN for: ${APP_PATH}"
  echo "    (no identity used; nothing is modified)"
  echo "    Hardened Runtime: --options runtime   Secure timestamp: --timestamp"
  if [[ -n "${IDENTITY}" ]]; then
    echo "    Identity that WOULD be used: ${IDENTITY}"
  else
    echo "    Identity that WOULD be used: \$DEVELOPER_ID_APPLICATION (currently unset)"
  fi
  echo "    Entitlements (main app): ${ENTITLEMENTS}"
  echo ""
else
  if [[ -z "${IDENTITY}" ]]; then
    echo "error: no signing identity. Export DEVELOPER_ID_APPLICATION or pass" >&2
    echo "       --identity \"Developer ID Application: NAME (TEAMID)\"." >&2
    echo "       (Run with --dry-run to preview the signing plan without one.)" >&2
    exit 3
  fi
  echo "==> codesign — Developer-ID signing: ${APP_PATH}"
  echo "    Identity: ${IDENTITY}"
fi

# rel <abs-path> -> path relative to the .app's PARENT, for compact logging.
rel() {
  printf '%s' "${1#"$(dirname "${APP_PATH}")"/}"
}

SIGN_COUNT=0

# sign_target <path> [extra codesign args...]
# In dry-run: print the planned target. Otherwise: invoke codesign and bail on
# the first failure (exit 4) so a partial bundle is never shipped.
sign_target() {
  local target="$1"; shift
  SIGN_COUNT=$((SIGN_COUNT + 1))
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '  [%2d] would sign: %s\n' "${SIGN_COUNT}" "$(rel "${target}")"
    return 0
  fi
  printf '  [%2d] signing: %s\n' "${SIGN_COUNT}" "$(rel "${target}")"
  if [[ -f "${target}" && "$(dirname "${target}")" == *.framework ]]; then
    sign_out_of_place "${target}" "$@"
    return 0
  fi
  if ! codesign "${CODESIGN_FLAGS[@]}" "$@" --sign "${IDENTITY}" "${target}"; then
    echo "error: codesign failed for ${target}" >&2
    exit 4
  fi
}

# sign_out_of_place <mach-o file> [extra codesign args...]
#
# codesign reads "<name>.framework/<file>" as a BUNDLE reference rather than as a
# plain Mach-O. yt-dlp's bundled Python.framework is symlink-free (Versions/Current
# is a real directory and the framework root holds its own copy of the binary), so
# codesign cannot classify it and refuses BOTH the framework and the binary
# directly inside it with
#     bundle format is ambiguous (could be app or framework)
# Signing a copy staged outside any .framework directory is byte-equivalent here:
# the binary has no bundle-relative references, and all four copies of it in this
# tree are already identical (verified by sha256). The signed bytes are written
# back through the ORIGINAL inode, so mode and ownership are untouched.
sign_out_of_place() {
  local target="$1"; shift
  local staged
  staged="$(mktemp "${TMPDIR:-/tmp}/macamp-fwsign.XXXXXX")" \
    || { echo "error: could not stage ${target} for signing" >&2; exit 4; }
  if ! cat "${target}" > "${staged}"; then
    rm -f "${staged}"
    echo "error: could not copy ${target} to its signing staging area" >&2
    exit 4
  fi
  if ! codesign "${CODESIGN_FLAGS[@]}" "$@" --sign "${IDENTITY}" "${staged}"; then
    rm -f "${staged}"
    echo "error: codesign failed for ${target} (staged as ${staged})" >&2
    exit 4
  fi
  if ! cat "${staged}" > "${target}"; then
    rm -f "${staged}"
    echo "error: could not write the signed bytes back to ${target}" >&2
    exit 4
  fi
  rm -f "${staged}"
}

# is_mach_o <path> — true when the file's CONTENT is Mach-O.
#
# Content, never file name. The yt-dlp tree carries five Mach-O files that match
# no `*.dylib` / `*.so` glob: the `yt-dlp_macos` launcher, `_internal/Python`
# (the Python shared library the launcher loads by that exact name), and its
# three duplicates inside `_internal/Python.framework`. A name-based filter signs
# 102 of 107 and leaves the Python runtime itself carrying only its upstream
# ad-hoc signature — which the notary service rejects and which library
# validation kills at the first dlopen.
is_mach_o() {
  file -b "$1" 2>/dev/null | head -n 1 | grep -q 'Mach-O'
}

# sign_downloader_tool <path> — one downloader Mach-O, with the tools' own
# entitlements when that file is present.
sign_downloader_tool() {
  if [[ -f "${DOWNLOADER_ENTITLEMENTS}" ]]; then
    sign_target "$1" --entitlements "${DOWNLOADER_ENTITLEMENTS}"
  else
    sign_target "$1"
  fi
}

# Iterate find(1) results null-delimited via process substitution (NOT a pipe) so
# SIGN_COUNT survives the loop (no subshell) and paths with spaces are safe. Each
# phase is a no-op when its directory / matches are absent.
sign_glob() {
  # sign_glob <root-dir> <find-expr...>
  local root="$1"; shift
  [[ -d "${root}" ]] || return 0
  local target
  while IFS= read -r -d '' target; do
    sign_target "${target}"
  done < <(find "${root}" "$@" -print0 2>/dev/null | sort -z 2>/dev/null || find "${root}" "$@" -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Phase 0 — the bundled downloader tools, signed with their OWN entitlements file
# and BEFORE everything else. They are independent Mach-O code, so inside-out
# order applies to them exactly as it does to a nested framework.
#
# The entitlements are not optional paperwork: yt-dlp is a PyInstaller build that
# dlopen()s a CPython runtime and ~100 `.so` extension modules. Under the Hardened
# Runtime (--options runtime, applied to every target in this script) library
# validation refuses any library not signed by our Team ID, so a gap here is a
# code-signature kill at the first dlopen and every download fails — in RELEASE
# ONLY, because ad-hoc dev/CI builds never arm library validation. See
# macOS/DownloaderTools.entitlements for the full rationale.
#
# The whole phase is skipped in silence when the tools are absent: they are
# fetched into a git-ignored directory by tools/downloader/fetch-download-tools.sh,
# so a dev build, a fresh clone, or any build that skipped the fetch legitimately
# has none.
# ---------------------------------------------------------------------------
if [[ ! -f "${DOWNLOADER_ENTITLEMENTS}" ]]; then
  echo "     warning: ${DOWNLOADER_ENTITLEMENTS} not found; the downloader tools" >&2
  echo "              will be signed WITHOUT disable-library-validation, and yt-dlp" >&2
  echo "              will fail to dlopen its payload in a hardened build." >&2
fi

echo "-- phase 0a: bundled transcoder (ffmpeg / ffprobe in Contents/MacOS) --"
DOWNLOADER_TOOLS_FOUND=0
for tool_name in "${DOWNLOADER_TOOL_NAMES[@]}"; do
  tool_path="${MACOS_DIR}/${tool_name}"
  [[ -f "${tool_path}" ]] || continue
  DOWNLOADER_TOOLS_FOUND=$((DOWNLOADER_TOOLS_FOUND + 1))
  sign_downloader_tool "${tool_path}"
done
[[ "${DOWNLOADER_TOOLS_FOUND}" -gt 0 ]] || echo "     (no ffmpeg/ffprobe in this bundle — skipped)"

# ---------------------------------------------------------------------------
# Phase 0b — the yt-dlp PyInstaller ONE-DIRECTORY tree in Contents/Resources.
#
# Every Mach-O in it is signed individually, NESTED FIRST and the `yt-dlp_macos`
# launcher LAST, because a container signed before its contents invalidates
# itself. Nothing in the tree is signed as a bundle, so the launcher is the only
# container and "everything else, then the launcher" is the whole ordering rule.
#
# `codesign --deep` is NOT an option here, and that is measured rather than
# assumed: the tree is a plain directory, and codesign answers
# "bundle format unrecognized, invalid, or unsuitable" for it with OR without
# --deep. The other reading of --deep — letting phase 5 recurse into the app —
# fails for a second, independent reason: --deep propagates the identity but NOT
# entitlements, so the launcher would be sealed WITHOUT
# disable-library-validation, which is exactly the release-only dlopen kill this
# phase exists to prevent. Apple's own guidance ("--deep is a fallback, not a
# substitute for signing components explicitly") points the same way. The cost of
# doing it explicitly was measured at ~2.8 s for all 107 files, ad-hoc.
# ---------------------------------------------------------------------------
echo "-- phase 0b: bundled yt-dlp one-directory tree (Contents/Resources/yt-dlp) --"
YTDLP_TREE_SIGNED=0
if [[ ! -d "${YTDLP_TREE_DIR}" ]]; then
  echo "     (no Contents/Resources/yt-dlp tree in this bundle — skipped)"
  if [[ "${DOWNLOADER_TOOLS_FOUND}" -eq 0 ]]; then
    echo "     run tools/downloader/fetch-download-tools.sh BEFORE tuist generate"
    echo "     to bundle the tools; the Tuist globs resolve at generate time."
  fi
elif [[ ! -f "${YTDLP_LAUNCHER}" ]]; then
  echo "error: ${YTDLP_TREE_DIR} exists but its yt-dlp_macos launcher does not." >&2
  echo "       A truncated engine tree must never be signed and shipped." >&2
  exit 4
else
  while IFS= read -r -d '' candidate; do
    [[ "${candidate}" == "${YTDLP_LAUNCHER}" ]] && continue
    is_mach_o "${candidate}" || continue
    sign_downloader_tool "${candidate}"
    YTDLP_TREE_SIGNED=$((YTDLP_TREE_SIGNED + 1))
  done < <(find "${YTDLP_TREE_DIR}" -type f -print0 2>/dev/null | sort -z 2>/dev/null \
    || find "${YTDLP_TREE_DIR}" -type f -print0 2>/dev/null)
  sign_downloader_tool "${YTDLP_LAUNCHER}"
  YTDLP_TREE_SIGNED=$((YTDLP_TREE_SIGNED + 1))
  echo "     ${YTDLP_TREE_SIGNED} Mach-O in the yt-dlp tree (launcher signed last)"
fi

# ---------------------------------------------------------------------------
# Phase 1 — loose dylibs in Contents/Frameworks (e.g. projectM's
# libprojectM-4.4.dylib, embedded in the one macampMac target).
# ---------------------------------------------------------------------------
echo "-- phase 1: bundled dylibs (projectM etc.) --"
sign_glob "${FRAMEWORKS_DIR}" -type f -name '*.dylib'
if [[ "${DRY_RUN}" -eq 1 && ! -d "${FRAMEWORKS_DIR}" ]]; then
  echo "     (no Contents/Frameworks — nothing embedded yet)"
fi
# Informational: surface the projectM dylib's repo path so the plan is explicit
# even when the bundle hasn't been built yet.
PROJECTM_DYLIB="${REPO_ROOT}/macOS/Vendor/projectM/lib/libprojectM-4.4.dylib"
if [[ ! -e "${FRAMEWORKS_DIR}/libprojectM-4.4.dylib" && -e "${PROJECTM_DYLIB}" ]]; then
  echo "     note: projectM dylib present in repo but NOT in this bundle"
  echo "           (embedded by the macampMac target at build time):"
  echo "           ${PROJECTM_DYLIB#"${REPO_ROOT}"/}"
fi

# ---------------------------------------------------------------------------
# Phase 2 — nested helpers INSIDE frameworks, signed before their framework.
# Sparkle ships an XPC pair (Downloader.xpc / Installer.xpc), an Autoupdate
# helper executable, and an Updater.app — each is independent code and must be
# sealed first. Generic globs catch them for ANY framework that bundles helpers.
# ---------------------------------------------------------------------------
echo "-- phase 2: nested framework helpers (Sparkle XPC / Autoupdate / Updater.app) --"
sign_glob "${FRAMEWORKS_DIR}" -name '*.xpc' -type d
sign_glob "${FRAMEWORKS_DIR}" -name '*.app' -type d
sign_glob "${FRAMEWORKS_DIR}" -type f -name 'Autoupdate'

# ---------------------------------------------------------------------------
# Phase 3 — the framework bundles themselves (SFB codec frameworks, GRDB,
# Sparkle). codesign seals the versioned bundle; nested code is already signed.
# ---------------------------------------------------------------------------
echo "-- phase 3: framework bundles (SFB codecs, GRDB, Sparkle) --"
sign_glob "${FRAMEWORKS_DIR}" -maxdepth 1 -name '*.framework' -type d

# ---------------------------------------------------------------------------
# Phase 4 — embedded app extensions (the WidgetKit widget, Contents/PlugIns).
# ---------------------------------------------------------------------------
echo "-- phase 4: app extensions (Contents/PlugIns/*.appex) --"
sign_glob "${PLUGINS_DIR}" -maxdepth 1 -name '*.appex' -type d

# ---------------------------------------------------------------------------
# Phase 5 — the main app bundle LAST, with entitlements. Sealing the outer
# bundle after every nested component is the whole point of inside-out signing.
# ---------------------------------------------------------------------------
echo "-- phase 5: main app bundle (with entitlements) --"
if [[ -f "${ENTITLEMENTS}" ]]; then
  sign_target "${APP_PATH}" --entitlements "${ENTITLEMENTS}"
else
  echo "     warning: entitlements not found at ${ENTITLEMENTS}; signing without them" >&2
  sign_target "${APP_PATH}"
fi

echo ""
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "PLAN: ${SIGN_COUNT} component(s) would be signed (inside-out)."
  echo "      Provide DEVELOPER_ID_APPLICATION and re-run WITHOUT --dry-run to sign."
  exit 0
fi

echo "==> verifying signature (codesign --verify --deep --strict)"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
echo "PASS: ${SIGN_COUNT} component(s) signed; bundle verifies."
echo "      Next: scripts/package-dmg.sh then scripts/notarize.sh"
exit 0
