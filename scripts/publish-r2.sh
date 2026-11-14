#!/usr/bin/env bash
#
# publish-r2.sh — upload a finished MacAMP release to the Cloudflare R2 bucket
# behind https://downloads.macamp.si, which is what the website, install.sh and
# every installed copy's Sparkle updater read from.
#
# It publishes artifacts that scripts/release.sh already produced and verified;
# it never builds, signs or generates anything itself.
#
# Bucket layout (public URLs on downloads.macamp.si):
#
#   releases/MacAMP-<v>.dmg   every shipped image, immutable (Sparkle enclosures)
#   releases/*.delta          Sparkle binary deltas, immutable
#   MacAMP.dmg                copy of the newest image (the website's button)
#   latest.json               {version, url, sha256, size, ...} for install.sh
#   install.sh                the curl installer (scripts/install.sh)
#   appcast.xml               the Sparkle feed (SUFeedURL), uploaded LAST
#
# Order matters: the feed is uploaded only after every file it points at is in
# place, so no installed copy is ever offered an update it cannot download.
#
# Usage:
#   scripts/publish-r2.sh --version 1.2.3            # asks before uploading
#   scripts/publish-r2.sh --version 1.2.3 --yes      # no prompt
#   scripts/publish-r2.sh --version 1.2.3 --dry-run  # plan only, no Keychain, no network
#
# Flags:
#   --version <v>     REQUIRED. Publishes dist/releases/MacAMP-<v>.dmg.
#   --output-dir <d>  The release.sh output directory (default: dist/).
#   --yes             Skip the confirmation prompt.
#   --dry-run         Print what would be uploaded; touch nothing.
#   -h | --help       This text.
#
# Credentials (never stored in this repo):
#   The R2 S3 keys come from the login Keychain, created once with:
#     security add-generic-password -s macamp-r2 -a access-key-id -w
#     security add-generic-password -s macamp-r2 -a secret-access-key -w
#   R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY in the environment override them.
#
# Env:
#   R2_ACCOUNT_ID   Cloudflare account ID (not a secret; default below)
#   R2_BUCKET       bucket name (default: macamp-downloads)
#   PUBLIC_BASE     public base URL (default: https://downloads.macamp.si)
#
# Requires the AWS CLI (brew install awscli); R2 speaks the S3 API.
#
# Exit codes:
#   0  published (or dry-run plan printed)    1  bad arguments / missing input
#   2  missing credentials or tools           3  upload failed
#   4  post-upload verification failed
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-7abb802f0eebeac4d48c5d1731fffcfc}"
R2_BUCKET="${R2_BUCKET:-macamp-downloads}"
PUBLIC_BASE="${PUBLIC_BASE:-https://downloads.macamp.si}"
KEYCHAIN_SERVICE="macamp-r2"

# Cache-Control per object class. Versioned files never change; the moving
# pointers (feed, latest copy, manifest, installer) stay fresh within minutes.
CC_IMMUTABLE="public, max-age=31536000, immutable"
CC_POINTER="public, max-age=300"

VERSION=""
OUTPUT_DIR=""
ASSUME_YES=0
DRY_RUN=0

die() { echo "error: $*" >&2; exit 1; }
fail() { local code="$1"; shift; echo "FAIL: $*" >&2; exit "${code}"; }
step() { printf '\n-- %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) [[ $# -ge 2 ]] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
        --output-dir) [[ $# -ge 2 ]] || die "--output-dir needs a path"; OUTPUT_DIR="$2"; shift 2 ;;
        --yes) ASSUME_YES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help)
            sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; s/^#$//'
            exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[[ -n "${VERSION}" ]] || die "--version <v> is required (try --help)"
case "${VERSION}" in *[[:space:]]*|*/*|-*) die "invalid --version: '${VERSION}'" ;; esac
[[ -n "${OUTPUT_DIR}" ]] || OUTPUT_DIR="${REPO_ROOT}/dist"
case "${OUTPUT_DIR}" in /*) ;; *) OUTPUT_DIR="${REPO_ROOT}/${OUTPUT_DIR}" ;; esac

ARCHIVES_DIR="${OUTPUT_DIR}/releases"
DMG_NAME="MacAMP-${VERSION}.dmg"
DMG_PATH="${ARCHIVES_DIR}/${DMG_NAME}"
APPCAST_PATH="${OUTPUT_DIR}/appcast.xml"
INSTALLER_PATH="${SCRIPT_DIR}/install.sh"
S3="s3://${R2_BUCKET}"
DMG_URL="${PUBLIC_BASE}/releases/${DMG_NAME}"

# ------------------------------------------------------------- local checks --
step "Checking the release artifacts"
[[ -f "${DMG_PATH}" ]] || fail 1 "${DMG_PATH} not found — run scripts/release.sh --version ${VERSION} first"
[[ -f "${APPCAST_PATH}" ]] || fail 1 "${APPCAST_PATH} not found — release.sh stage [6] writes it"
[[ -f "${INSTALLER_PATH}" ]] || fail 1 "${INSTALLER_PATH} not found"

# The feed must be EdDSA-signed and must point at this version under the
# public releases/ prefix; anything else would strand installed copies.
grep -q 'sparkle:edSignature=' "${APPCAST_PATH}" || fail 1 "appcast.xml has no sparkle:edSignature — refusing to publish an unsigned feed"
grep -q "${DMG_URL}" "${APPCAST_PATH}" || fail 1 "appcast.xml does not reference ${DMG_URL} — check make-appcast.sh's --download-url-prefix"

xpath() {
    xmllint --xpath "string(//*[local-name()='item'][*[local-name()='shortVersionString']='${VERSION}']/*[local-name()=\"$1\"])" "${APPCAST_PATH}" 2>/dev/null || true
}
BUILD="$(xpath version)"
MIN_OS="$(xpath minimumSystemVersion)"
[[ -n "${BUILD}" ]] || fail 1 "appcast.xml has no item for version ${VERSION}"
[[ -n "${MIN_OS}" ]] || MIN_OS="14.0"

SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
SIZE="$(stat -f %z "${DMG_PATH}")"
DELTAS=()
while IFS= read -r f; do DELTAS+=("$f"); done < <(find "${ARCHIVES_DIR}" -maxdepth 1 -type f -name '*.delta' -exec basename {} ';' | sort)

note "version:   ${VERSION} (build ${BUILD}, macOS ${MIN_OS}+)"
note "image:     ${DMG_PATH} ($(du -h "${DMG_PATH}" | awk '{print $1}'))"
note "sha256:    ${SHA256}"
note "deltas:    ${#DELTAS[@]}"
note "bucket:    ${R2_BUCKET} (account ${R2_ACCOUNT_ID})"
note "public at: ${PUBLIC_BASE}"

LATEST_JSON="$(mktemp "${TMPDIR:-/tmp}"/macamp-latest.XXXXXX)"
trap 'rm -f "${LATEST_JSON}"' EXIT
cat > "${LATEST_JSON}" <<JSON
{
  "name": "MacAMP",
  "version": "${VERSION}",
  "build": "${BUILD}",
  "url": "${DMG_URL}",
  "sha256": "${SHA256}",
  "size": ${SIZE},
  "minimumSystemVersion": "${MIN_OS}",
  "architectures": ["arm64"],
  "published": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSON
plutil -convert xml1 -o /dev/null "${LATEST_JSON}" 2>/dev/null || fail 1 "generated latest.json is not valid JSON"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    step "DRY RUN — would upload, in this order:"
    note "${S3}/releases/${DMG_NAME}            (${CC_IMMUTABLE})"
    for d in ${DELTAS[@]+"${DELTAS[@]}"}; do note "${S3}/releases/${d}   (${CC_IMMUTABLE})"; done
    note "${S3}/install.sh                    (${CC_POINTER})"
    note "${S3}/MacAMP.dmg                    (server-side copy, ${CC_POINTER})"
    note "${S3}/latest.json                   (${CC_POINTER}):"
    sed 's/^/        /' "${LATEST_JSON}"
    note "${S3}/appcast.xml                   (${CC_POINTER}) — last"
    echo ""
    echo "DRY-RUN complete: no Keychain access, no network."
    exit 0
fi

# --------------------------------------------------------- tools + secrets --
command -v aws >/dev/null 2>&1 || fail 2 "the AWS CLI is required: brew install awscli"
command -v curl >/dev/null 2>&1 || fail 2 "curl is required"

keychain() { security find-generic-password -s "${KEYCHAIN_SERVICE}" -a "$1" -w 2>/dev/null || true; }
ACCESS_KEY="${R2_ACCESS_KEY_ID:-$(keychain access-key-id)}"
SECRET_KEY="${R2_SECRET_ACCESS_KEY:-$(keychain secret-access-key)}"
[[ -n "${ACCESS_KEY}" && -n "${SECRET_KEY}" ]] || fail 2 "no R2 credentials. Store them once with:
      security add-generic-password -s ${KEYCHAIN_SERVICE} -a access-key-id -w
      security add-generic-password -s ${KEYCHAIN_SERVICE} -a secret-access-key -w"

# Scope the credentials to this process and ignore any ~/.aws profile, so a
# personal AWS setup can never redirect or authenticate these uploads.
export AWS_ACCESS_KEY_ID="${ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${SECRET_KEY}"
export AWS_DEFAULT_REGION="auto"
export AWS_CONFIG_FILE=/dev/null
export AWS_SHARED_CREDENTIALS_FILE=/dev/null
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
unset AWS_PROFILE AWS_SESSION_TOKEN
r2() { aws --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" --no-cli-pager "$@"; }

# ------------------------------------------------------------- confirmation --
if [[ "${ASSUME_YES}" -eq 0 ]]; then
    echo ""
    echo "This publishes MacAMP ${VERSION} to ${PUBLIC_BASE}. Installed copies will be"
    echo "offered the update within the hour."
    read -r -p "Type the version to confirm: " ANSWER </dev/tty
    [[ "${ANSWER}" == "${VERSION}" ]] || fail 1 "not confirmed — nothing was uploaded"
fi

put() { # put <local> <key> <content-type> <cache-control>
    note "↑ $2"
    r2 s3 cp "$1" "${S3}/$2" --only-show-errors --content-type "$3" --cache-control "$4" \
        || fail 3 "upload of $2 failed"
}

step "Uploading"
put "${DMG_PATH}" "releases/${DMG_NAME}" "application/x-apple-diskimage" "${CC_IMMUTABLE}"
for d in ${DELTAS[@]+"${DELTAS[@]}"}; do
    if r2 s3api head-object --bucket "${R2_BUCKET}" --key "releases/${d}" >/dev/null 2>&1; then
        note "= releases/${d} (already published)"
    else
        put "${ARCHIVES_DIR}/${d}" "releases/${d}" "application/octet-stream" "${CC_IMMUTABLE}"
    fi
done
put "${INSTALLER_PATH}" "install.sh" "text/x-shellscript; charset=utf-8" "${CC_POINTER}"
note "⇉ MacAMP.dmg (copy of releases/${DMG_NAME})"
r2 s3 cp "${S3}/releases/${DMG_NAME}" "${S3}/MacAMP.dmg" --only-show-errors \
    --metadata-directive REPLACE --content-type "application/x-apple-diskimage" \
    --cache-control "${CC_POINTER}" || fail 3 "copy to MacAMP.dmg failed"
put "${LATEST_JSON}" "latest.json" "application/json" "${CC_POINTER}"
put "${APPCAST_PATH}" "appcast.xml" "application/xml; charset=utf-8" "${CC_POINTER}"

# ------------------------------------------------------------------- verify --
step "Verifying the uploaded objects (R2 API)"
for key in "releases/${DMG_NAME}" "MacAMP.dmg"; do
    got="$(r2 s3api head-object --bucket "${R2_BUCKET}" --key "${key}" --query ContentLength --output text 2>/dev/null || true)"
    [[ "${got}" == "${SIZE}" ]] || fail 4 "${S3}/${key} is ${got:-missing}, expected ${SIZE} bytes"
    note "✓ ${key} (${SIZE} bytes)"
done
for key in latest.json install.sh appcast.xml; do
    r2 s3api head-object --bucket "${R2_BUCKET}" --key "${key}" >/dev/null 2>&1 || fail 4 "${S3}/${key} is missing"
    note "✓ ${key}"
done

# The public check resolves the host through Cloudflare's resolver, so a stale
# DNS cache on this Mac (router, VPN, local dnsmasq) cannot fail a good release.
step "Verifying the public URLs"
PUBLIC_HOST="${PUBLIC_BASE#https://}"; PUBLIC_HOST="${PUBLIC_HOST%%/*}"
PUBLIC_IP="$(dig +short A "${PUBLIC_HOST}" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)"
public() {
    if [[ -n "${PUBLIC_IP}" ]]; then
        curl -fsS --max-time 30 --resolve "${PUBLIC_HOST}:443:${PUBLIC_IP}" "$@"
    else
        curl -fsS --max-time 30 "$@"
    fi
}
PUBLIC_WARNINGS=0
public_check() { # public_check <label> <command…>; warns instead of failing
    if "${@:2}"; then note "✓ $1"; else note "⚠ $1 — not reachable from this Mac yet"; PUBLIC_WARNINGS=1; fi
}
size_ok() { [[ "$(public -I "$1" | awk 'tolower($1)=="content-length:" {gsub("\r",""); print $2}' | tail -1)" == "${SIZE}" ]]; }
public_check "${DMG_URL}" size_ok "${DMG_URL}"
public_check "${PUBLIC_BASE}/MacAMP.dmg" size_ok "${PUBLIC_BASE}/MacAMP.dmg"
feed_ok() { public "${PUBLIC_BASE}/appcast.xml?v=${VERSION}" | grep -qF "${DMG_URL}"; }
manifest_ok() { public "${PUBLIC_BASE}/latest.json?v=${VERSION}" | grep -qF "\"${VERSION}\""; }
public_check "${PUBLIC_BASE}/appcast.xml" feed_ok
public_check "${PUBLIC_BASE}/latest.json" manifest_ok
if [[ "${PUBLIC_WARNINGS}" -eq 1 ]]; then
    note "The upload itself is verified above. Re-check the public URLs in a few"
    note "minutes, e.g.: curl -I ${PUBLIC_BASE}/MacAMP.dmg"
fi

echo ""
echo "PASS: MacAMP ${VERSION} is live at ${PUBLIC_BASE}"
echo "      Next: scripts/github-release.sh --version ${VERSION} tags v${VERSION}"
echo "      (deploying the docs) and creates the GitHub Release page."
exit 0
