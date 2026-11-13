#!/usr/bin/env bash
#
# package-dmg.sh
#
# Assemble a distributable disk image (.dmg) from a BUILT, signed MacAMP `.app`.
# The image lays out the canonical drag-to-install experience:
#
#     /Volumes/MacAMP/
#       MacAMP.app            <- the (signed) application
#       Applications -> /Applications   <- drop target symlink
#       .background/background.png       <- optional window backdrop
#
# This is RELEASE SCAFFOLDING: it runs end-to-end with NO Apple credentials.
#   --dry-run  assembles the staging layout AND builds an UNSIGNED .dmg, then
#              reports — it never code-signs the image. Use it to validate the
#              layout on any machine / in CI.
#   (default)  additionally code-signs the finished .dmg with
#              $DEVELOPER_ID_APPLICATION when that identity is present (the app
#              inside must already be signed by scripts/codesign-app.sh).
#
# Finder *visual* styling (background image, icon positions, window size) needs a
# GUI Finder session and is therefore an OPTIONAL, best-effort step that is
# SKIPPED when no window server is available (e.g. CI). The functional image —
# app + Applications symlink — is produced regardless.
#
# Usage:
#   scripts/package-dmg.sh [--dry-run] <path/to/MacAMP.app>
#   scripts/package-dmg.sh --app <path> [--output dist/MacAMP.dmg] \
#                          [--volname MacAMP] [--background <png>]
#
# Exit codes:
#   0  success      1  bad arguments      2  app bundle not found
#   4  hdiutil / assembly failure
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DRY_RUN=0
APP_PATH=""
OUTPUT=""
VOLNAME="MacAMP"
BACKGROUND=""
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --app) [[ $# -ge 2 ]] || die "--app needs a path"; APP_PATH="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || die "--output needs a path"; OUTPUT="$2"; shift 2 ;;
    --volname) [[ $# -ge 2 ]] || die "--volname needs a value"; VOLNAME="$2"; shift 2 ;;
    --background) [[ $# -ge 2 ]] || die "--background needs a path"; BACKGROUND="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; s/^#$//'
      exit 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) [[ -z "${APP_PATH}" ]] || die "unexpected extra argument: $1"; APP_PATH="$1"; shift ;;
  esac
done

[[ -n "${APP_PATH}" ]] || die "no .app given (pass a path or --app <path>; try --help)"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: app bundle not found or not a directory: ${APP_PATH}" >&2
  exit 2
fi
APP_PATH="$(cd "${APP_PATH}/.." && pwd)/$(basename "${APP_PATH}")"
APP_NAME="$(basename "${APP_PATH}")"

# Default output under dist/ (gitignored build output, created on demand).
[[ -n "${OUTPUT}" ]] || OUTPUT="${REPO_ROOT}/dist/${VOLNAME}.dmg"

# Default background: macOS/Resources/dmg-background.png if it exists.
if [[ -z "${BACKGROUND}" ]]; then
  default_bg="${REPO_ROOT}/macOS/Resources/dmg-background.png"
  [[ -f "${default_bg}" ]] && BACKGROUND="${default_bg}"
fi

MODE_LABEL=""
[[ "${DRY_RUN}" -eq 1 ]] && MODE_LABEL=" (DRY-RUN)"
echo "==> package-dmg${MODE_LABEL}"
echo "    App:     ${APP_PATH}"
echo "    Volume:  ${VOLNAME}"
echo "    Output:  ${OUTPUT}"
echo "    Backdrop:${BACKGROUND:+ ${BACKGROUND}}${BACKGROUND:-  (none)}"
echo ""

# --- assemble the staging layout in a temp dir ------------------------------
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/macamp-dmg.XXXXXX")"
# Invoked indirectly via the EXIT trap below (shellcheck can't see that link).
# shellcheck disable=SC2329
cleanup() { rm -rf "${STAGING}"; }
trap cleanup EXIT

echo "-- assembling layout in ${STAGING}"
# ditto preserves the bundle (symlinks, resource forks, signature) faithfully.
ditto "${APP_PATH}" "${STAGING}/${APP_NAME}"
echo "   + ${APP_NAME}"

ln -s /Applications "${STAGING}/Applications"
echo "   + Applications -> /Applications (drop target)"

if [[ -n "${BACKGROUND}" && -f "${BACKGROUND}" ]]; then
  mkdir -p "${STAGING}/.background"
  ditto "${BACKGROUND}" "${STAGING}/.background/background.png"
  echo "   + .background/background.png"
else
  echo "   . no background image (functional layout only)"
fi

echo ""
echo "-- staged layout (top level; the .app is not expanded):"
printf '   %s\n' "${APP_NAME}/   ($(du -sh "${STAGING}/${APP_NAME}" 2>/dev/null | cut -f1))"
printf '   %s\n' "Applications -> /Applications  (drop target symlink)"
if [[ -d "${STAGING}/.background" ]]; then
  printf '   %s\n' ".background/background.png"
fi
echo ""

# --- create the .dmg --------------------------------------------------------
mkdir -p "$(dirname "${OUTPUT}")"
rm -f "${OUTPUT}"

echo "-- creating disk image (hdiutil create, UDZO compressed)"
if ! hdiutil create \
      -volname "${VOLNAME}" \
      -srcfolder "${STAGING}" \
      -fs HFS+ \
      -format UDZO \
      -ov \
      "${OUTPUT}"; then
  echo "error: hdiutil create failed" >&2
  exit 4
fi
echo "   wrote ${OUTPUT}"
echo ""

# --- sign the image (real mode only, when an identity is available) ---------
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "DRY-RUN: image assembled + built UNSIGNED (no Developer ID applied)."
  echo "         Re-run without --dry-run (and with DEVELOPER_ID_APPLICATION set)"
  echo "         to code-sign the .dmg, then notarize it via scripts/notarize.sh."
  exit 0
fi

if [[ -n "${IDENTITY}" ]]; then
  echo "-- code-signing the disk image"
  codesign --force --timestamp --sign "${IDENTITY}" "${OUTPUT}"
  echo "   signed ${OUTPUT} with: ${IDENTITY}"
else
  echo "note: DEVELOPER_ID_APPLICATION unset — .dmg left UNSIGNED."
  echo "      (notarization staples the image regardless; signing the .dmg is optional.)"
fi
echo ""
echo "PASS: ${OUTPUT} ready. Next: scripts/notarize.sh ${OUTPUT}"
exit 0
