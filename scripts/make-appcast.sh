#!/usr/bin/env bash
#
# make-appcast.sh
#
# Generate the Sparkle EdDSA-signed `appcast.xml` that MacAMP's in-app updater
# polls. In a real release this delegates to Sparkle's own `generate_appcast`
# tool, which scans a folder of release archives (.dmg/.zip), reads each app's
# version, signs every archive with your EdDSA PRIVATE key (held in the login
# keychain, created once by Sparkle's `generate_keys`), and emits the appcast.
#
#     generate_appcast <archives-dir>           # writes <archives-dir>/appcast.xml
#
# This is RELEASE SCAFFOLDING: it runs with NO key and NO network.
#   --dry-run  emits a fully-formed SAMPLE appcast.xml (placeholder EdDSA
#              signature + enclosure) so the structure can be reviewed and the
#              app's feed URL wired up — WITHOUT a private key or generate_appcast.
#   (default)  locates generate_appcast and signs a real archives directory.
#
# The matching PUBLIC EdDSA key must be embedded in the app's Info.plist under
# `SUPublicEDKey`; the private key NEVER leaves your keychain and is NEVER
# committed. See docs/Distribution.md for the one-time key setup.
#
# That key NAME is exact and load-bearing. generate_appcast reads the archived
# app's Info.plist to decide whether an item needs EdDSA signing — under any
# other name it concludes "not required", exits 0, and writes appcast items with
# NO sparkle:edSignature at all. No error, no warning, an unusable feed. Verify
# the name against the PINNED framework rather than any doc:
#
#   strings "$(find Tuist/.build -path '*Sparkle.framework/Versions/B/Sparkle')" \
#     | grep -E '^SU[A-Za-z]+$' | sort -u
#
# release.sh stage [6] asserts the emitted feed really is signed, which is the
# only way this failure becomes loud.
#
# Usage:
#   scripts/make-appcast.sh --dry-run [--output dist/appcast.xml]
#   scripts/make-appcast.sh --archives <dir> [--output <dir>/appcast.xml] \
#                           [--download-url-prefix https://example.com/releases/] \
#                           [--channel beta]
#
# Env:
#   SPARKLE_BIN   explicit path to `generate_appcast` (else common SPM/Homebrew
#                 locations are searched).
#
# Exit codes:
#   0  success      1  bad arguments      2  archives dir not found (real mode)
#   3  generate_appcast not found (real mode)      4  generate_appcast failure
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DRY_RUN=0
ARCHIVES=""
OUTPUT=""
URL_PREFIX="https://downloads.macamp.si/releases/"
CHANNEL=""

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --archives) [[ $# -ge 2 ]] || die "--archives needs a dir"; ARCHIVES="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || die "--output needs a path"; OUTPUT="$2"; shift 2 ;;
    --download-url-prefix) [[ $# -ge 2 ]] || die "--download-url-prefix needs a URL"; URL_PREFIX="$2"; shift 2 ;;
    --channel) [[ $# -ge 2 ]] || die "--channel needs a name"; CHANNEL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; s/^#$//'
      exit 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) die "unexpected argument: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# --dry-run: write a representative, key-free SAMPLE appcast.xml.
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" -eq 1 ]]; then
  [[ -n "${OUTPUT}" ]] || OUTPUT="${REPO_ROOT}/dist/appcast-sample.xml"
  mkdir -p "$(dirname "${OUTPUT}")"

  VERSION="1.0.0"          # CFBundleShortVersionString (display)
  BUILD="100"             # CFBundleVersion (monotonic, what Sparkle compares)
  MIN_OS="14.0"           # matches LSMinimumSystemVersion in macOS/Project.swift
  PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
  FILE_NAME="MacAMP-${VERSION}.dmg"
  ENCLOSURE_URL="${URL_PREFIX}${FILE_NAME}"
  CHANNEL_TAG=""
  [[ -n "${CHANNEL}" ]] && CHANNEL_TAG="
      <sparkle:channel>${CHANNEL}</sparkle:channel>"

  echo "==> make-appcast DRY-RUN — writing SAMPLE appcast to ${OUTPUT}"
  echo "    (placeholder EdDSA signature; no private key / generate_appcast used)"

  cat > "${OUTPUT}" <<XML
<?xml version="1.0" encoding="utf-8"?>
<!--
  SAMPLE appcast for MacAMP, written by the make-appcast.sh dry run mode.
  In a real release this file is produced by Sparkle's generate_appcast, which
  fills sparkle:edSignature with a REAL EdDSA signature over the .dmg and sets
  the true enclosure length. DO NOT ship this sample: the signature below is a
  placeholder and Sparkle will reject it.
-->
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>MacAMP</title>
    <link>${URL_PREFIX}appcast.xml</link>
    <description>Most recent MacAMP updates.</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>${CHANNEL_TAG}
      <description><![CDATA[
        <h2>What's new in ${VERSION}</h2>
        <ul><li>Sample release notes — replace with real notes per release.</li></ul>
      ]]></description>
      <enclosure
        url="${ENCLOSURE_URL}"
        sparkle:version="${BUILD}"
        sparkle:shortVersionString="${VERSION}"
        sparkle:edSignature="PLACEHOLDER_EDDSA_SIGNATURE_REPLACED_BY_generate_appcast=="
        length="12345678"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

  echo ""
  echo "-- sample appcast.xml:"
  sed 's/^/   /' "${OUTPUT}"
  echo ""
  # Best-effort well-formedness check (xmllint ships with the macOS dev tools).
  if command -v xmllint >/dev/null 2>&1; then
    if xmllint --noout "${OUTPUT}" 2>/dev/null; then
      echo "well-formedness: xmllint OK"
    else
      echo "well-formedness: xmllint reported issues" >&2
    fi
  fi
  echo "DRY-RUN: sample written. Real signing needs the EdDSA key + generate_appcast"
  echo "         (see docs/Distribution.md)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Real mode: run Sparkle's generate_appcast over a directory of archives.
# ---------------------------------------------------------------------------
[[ -n "${ARCHIVES}" ]] || die "no --archives <dir> (or use --dry-run; try --help)"
if [[ ! -d "${ARCHIVES}" ]]; then
  echo "error: archives directory not found: ${ARCHIVES}" >&2
  exit 2
fi

# Locate generate_appcast: explicit override, then PATH, then common SPM /
# Homebrew locations. (SPM vends Sparkle's tools inside the resolved artifacts.)
GENERATE_APPCAST="${SPARKLE_BIN:-}"
if [[ -z "${GENERATE_APPCAST}" ]] && command -v generate_appcast >/dev/null 2>&1; then
  GENERATE_APPCAST="$(command -v generate_appcast)"
fi
if [[ -z "${GENERATE_APPCAST}" ]]; then
  for root in \
    "${REPO_ROOT}/Tuist/.build" \
    "${REPO_ROOT}/.build" \
    "${HOME}/Library/Developer/Xcode/DerivedData" \
    "${HOME}/Library/Caches/org.swift.swiftpm"; do
    [[ -d "${root}" ]] || continue
    found="$(find "${root}" -type f -name generate_appcast -perm -111 2>/dev/null | head -n 1)"
    if [[ -n "${found}" ]]; then
      GENERATE_APPCAST="${found}"
      break
    fi
  done
fi
if [[ -z "${GENERATE_APPCAST}" ]]; then
  echo "error: generate_appcast not found. Set SPARKLE_BIN=/path/to/generate_appcast" >&2
  echo "       (Sparkle ships it; run 'tuist install' to resolve the package first," >&2
  echo "        or 'brew install --cask sparkle'.) See docs/Distribution.md." >&2
  exit 3
fi

[[ -n "${OUTPUT}" ]] || OUTPUT="${ARCHIVES%/}/appcast.xml"

echo "==> make-appcast — signing release archives in ${ARCHIVES}"
echo "    Tool:   ${GENERATE_APPCAST}"
echo "    Output: ${OUTPUT}"
echo "    URL prefix: ${URL_PREFIX}"

GA_ARGS=()
[[ -n "${URL_PREFIX}" ]] && GA_ARGS+=(--download-url-prefix "${URL_PREFIX}")
[[ -n "${CHANNEL}" ]] && GA_ARGS+=(--channel "${CHANNEL}")
GA_ARGS+=(-o "${OUTPUT}")

if ! "${GENERATE_APPCAST}" "${GA_ARGS[@]}" "${ARCHIVES}"; then
  echo "error: generate_appcast failed (is the EdDSA private key in your keychain?)" >&2
  echo "       Create one ONCE with Sparkle's generate_keys; see docs/Distribution.md." >&2
  exit 4
fi
echo "PASS: ${OUTPUT} written + EdDSA-signed. Publish it with scripts/publish-r2.sh (feed: https://downloads.macamp.si/appcast.xml)"
exit 0
