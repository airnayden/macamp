#!/usr/bin/env bash
#
# notarize.sh
#
# Submit a signed MacAMP artifact (.dmg / .zip / .app) to Apple's notary service
# and staple the resulting ticket so the app launches without a Gatekeeper prompt
# even offline.
#
#     xcrun notarytool submit <artifact> --wait      (upload + block for verdict)
#     xcrun stapler staple    <target>               (attach the ticket)
#     xcrun stapler validate  <target>               (prove it stuck)
#
# Credentials come ONLY from the environment (NEVER hardcoded / committed):
#   APPLE_ID                    Apple ID e-mail of the notarization account
#   NOTARIZATION_TEAM_ID        10-char Developer Team ID
#   NOTARIZATION_APP_PASSWORD   app-specific password (appleid.apple.com)
#
# Base CI MUST run WITHOUT these secrets. Use:
#   --check-config   Validate the env-var contract and EXIT 0. When the creds are
#                    absent it prints a clear "would need a Developer ID" message
#                    and still succeeds, so this is safe to call in unprivileged CI.
#
# Usage:
#   scripts/notarize.sh --check-config
#   scripts/notarize.sh <path/to/MacAMP.dmg>
#   scripts/notarize.sh --target <path> [--no-staple]
#
# Exit codes:
#   0  success (notarized + stapled, or --check-config reported state)
#   1  bad arguments
#   2  target artifact not found
#   3  required credentials missing (real submit only)
#   4  notarytool / stapler failure
#
set -euo pipefail

CHECK_CONFIG=0
TARGET=""
DO_STAPLE=1

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-config) CHECK_CONFIG=1; shift ;;
    --target) [[ $# -ge 2 ]] || die "--target needs a path"; TARGET="$2"; shift 2 ;;
    --no-staple) DO_STAPLE=0; shift ;;
    -h|--help)
      sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; s/^#$//'
      exit 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) [[ -z "${TARGET}" ]] || die "unexpected extra argument: $1"; TARGET="$1"; shift ;;
  esac
done

# Pull credentials (empty when unset; we NEVER echo the password's value).
APPLE_ID_VAL="${APPLE_ID:-}"
TEAM_ID_VAL="${NOTARIZATION_TEAM_ID:-}"
APP_PW_VAL="${NOTARIZATION_APP_PASSWORD:-}"

# present_state <name> <value> -> echo "set"/"MISSING" and return 0/1
present_state() {
  if [[ -n "$2" ]]; then
    printf '  %-28s present\n' "$1:"
    return 0
  fi
  printf '  %-28s MISSING\n' "$1:"
  return 1
}

# ---------------------------------------------------------------------------
# --check-config: report the env-var contract, ALWAYS exit 0 (base CI safe).
# ---------------------------------------------------------------------------
if [[ "${CHECK_CONFIG}" -eq 1 ]]; then
  echo "==> notarize --check-config: validating the credential contract"
  echo ""
  present=0
  present_state "APPLE_ID" "${APPLE_ID_VAL}" || present=$((present + 1))
  present_state "NOTARIZATION_TEAM_ID" "${TEAM_ID_VAL}" || present=$((present + 1))
  present_state "NOTARIZATION_APP_PASSWORD" "${APP_PW_VAL}" || present=$((present + 1))
  # The signing identity used by codesign-app.sh — reported for completeness.
  present_state "DEVELOPER_ID_APPLICATION" "${DEVELOPER_ID_APPLICATION:-}" || present=$((present + 1))
  echo ""
  if [[ "${present}" -eq 4 ]]; then
    echo "RESULT: all 4 absent — notarization is NOT configured on this machine."
    echo "        This is EXPECTED for base CI and contributor checkouts."
    echo "        To notarize a release you would need a paid Apple Developer"
    echo "        Program account and a 'Developer ID Application' certificate;"
    echo "        see docs/Distribution.md for how to obtain and export them."
    exit 0
  fi
  if [[ "${present}" -eq 0 ]]; then
    echo "RESULT: credentials COMPLETE — ready to notarize."
    echo "        Run: scripts/notarize.sh <path/to/MacAMP.dmg>"
    exit 0
  fi
  echo "RESULT: PARTIAL configuration (${present} of 4 missing above)."
  echo "        Set the remaining variable(s) before notarizing. Exiting 0 so base"
  echo "        CI is never blocked by missing release secrets."
  exit 0
fi

# ---------------------------------------------------------------------------
# Real submission path.
# ---------------------------------------------------------------------------
[[ -n "${TARGET}" ]] || die "no artifact given (pass a .dmg/.zip/.app or --check-config; try --help)"
if [[ ! -e "${TARGET}" ]]; then
  echo "error: artifact not found: ${TARGET}" >&2
  exit 2
fi

missing=""
[[ -n "${APPLE_ID_VAL}" ]] || missing="${missing} APPLE_ID"
[[ -n "${TEAM_ID_VAL}" ]] || missing="${missing} NOTARIZATION_TEAM_ID"
[[ -n "${APP_PW_VAL}" ]] || missing="${missing} NOTARIZATION_APP_PASSWORD"
if [[ -n "${missing}" ]]; then
  echo "error: missing required credential(s):${missing}" >&2
  echo "       Run 'scripts/notarize.sh --check-config' to inspect the contract," >&2
  echo "       or see docs/Distribution.md to obtain a Developer ID." >&2
  exit 3
fi

# notarytool accepts .dmg / .zip / .pkg. A bare .app must be zipped first
# (ditto -c -k --keepParent preserves the bundle + its signature).
SUBMIT_ARTIFACT="${TARGET}"
TMP_ZIP=""
case "${TARGET}" in
  *.app)
    TMP_ZIP="$(mktemp -d "${TMPDIR:-/tmp}/macamp-notarize.XXXXXX")/$(basename "${TARGET%.app}").zip"
    echo "==> zipping .app for submission: ${TMP_ZIP}"
    ditto -c -k --keepParent "${TARGET}" "${TMP_ZIP}"
    SUBMIT_ARTIFACT="${TMP_ZIP}"
    ;;
esac
# Invoked indirectly via the EXIT trap below (shellcheck can't see that link).
# shellcheck disable=SC2329
cleanup() { [[ -n "${TMP_ZIP}" ]] && rm -rf "$(dirname "${TMP_ZIP}")"; }
trap cleanup EXIT

echo "==> submitting to the notary service (notarytool submit --wait)"
echo "    Artifact: ${SUBMIT_ARTIFACT}"
echo "    Apple ID: ${APPLE_ID_VAL}    Team: ${TEAM_ID_VAL}"
if ! xcrun notarytool submit "${SUBMIT_ARTIFACT}" \
      --apple-id "${APPLE_ID_VAL}" \
      --team-id "${TEAM_ID_VAL}" \
      --password "${APP_PW_VAL}" \
      --wait; then
  echo "error: notarytool submission failed (run 'xcrun notarytool log <id>' for detail)" >&2
  exit 4
fi

if [[ "${DO_STAPLE}" -eq 0 ]]; then
  echo "PASS: notarized. Stapling skipped (--no-staple)."
  exit 0
fi

# Staple the ORIGINAL target (the .dmg/.app), not the throwaway .zip.
echo "==> stapling the ticket (stapler staple)"
if ! xcrun stapler staple "${TARGET}"; then
  echo "error: stapler staple failed" >&2
  exit 4
fi
echo "==> validating the staple (stapler validate)"
xcrun stapler validate "${TARGET}"
echo "PASS: ${TARGET} notarized + stapled."
exit 0
