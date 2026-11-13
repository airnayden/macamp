#!/bin/bash
# Reject unfinished release configuration in the actual built Info.plist.
# Checks syntax and known placeholders only; no DNS, ownership, or reachability check.
# Usage: scripts/check-release-identity.sh path/to/MacAMP.app/Contents/Info.plist
set -euo pipefail
export LC_ALL=C
fail() { echo "error: release identity: $*" >&2; exit 1; }
[[ $# -eq 1 ]] || fail 'expected the built app Info.plist path'
PLIST="$1"
[[ -f "${PLIST}" ]] || fail "Info.plist not found: ${PLIST}"
plutil -lint -s "${PLIST}" >/dev/null 2>&1 || fail 'Info.plist is not a valid property list'
# A sentinel preserves trailing newlines in plist strings through command substitution.
read_string() {
    plutil -extract "$1" raw -expect string -n -o - "${PLIST}" 2>/dev/null && printf '.'
}
BUNDLE_ID="$(read_string CFBundleIdentifier)" || fail 'CFBundleIdentifier must be present and a string'
BUNDLE_ID="${BUNDLE_ID%.}"
FEED="$(read_string SUFeedURL)" || fail 'SUFeedURL must be present and a string'
FEED="${FEED%.}"

ID_PATTERN='^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
[[ "${BUNDLE_ID}" =~ ${ID_PATTERN} ]] || fail 'CFBundleIdentifier must be a nonempty reverse-DNS identifier'
ID_LOWER="$(printf '%s' "${BUNDLE_ID}" | tr '[:upper:]' '[:lower:]')"
case ".${ID_LOWER}." in
    *.example.*|*.todo.*|*.placeholder.*|*.changeme.*|*.yourcompany.*|*.yourdomain.*)
        fail 'CFBundleIdentifier contains a placeholder; choose the production identifier before releasing' ;;
esac

FEED_LOWER="$(printf '%s' "${FEED}" | tr '[:upper:]' '[:lower:]')"
case "${FEED_LOWER}" in https://*) ;; *) fail 'SUFeedURL must be a nonempty HTTPS URL' ;; esac
case "${FEED}" in
    *[[:space:][:cntrl:]]*|*\\*|*'"'*|*'<'*|*'>'*|*'{'*|*'}'*|*'|'*|*'^'*|*'`'*|*'#'*)
        fail 'SUFeedURL contains invalid URL characters or a fragment' ;;
esac
AUTHORITY="${FEED_LOWER#https://}"
AUTHORITY="${AUTHORITY%%[/?]*}"
HOST_PATTERN='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?(:[0-9]{1,5})?$'
[[ "${AUTHORITY}" =~ ${HOST_PATTERN} ]] || fail 'SUFeedURL must have a valid DNS hostname and optional numeric port, without credentials'
HOST="${AUTHORITY%%:*}"
[[ ${#HOST} -le 253 ]] || fail 'SUFeedURL hostname is too long'
LABELS="${HOST}"
while [[ -n "${LABELS}" ]]; do
    LABEL="${LABELS%%.*}"
    [[ ${#LABEL} -le 63 ]] || fail 'SUFeedURL hostname label is too long'
    [[ "${LABELS}" == *.* ]] || break
    LABELS="${LABELS#*.}"
done
if [[ "${AUTHORITY}" == *:* ]]; then
    PORT="${AUTHORITY##*:}"
    [[ $((10#${PORT})) -ge 1 && $((10#${PORT})) -le 65535 ]] || fail 'SUFeedURL port is outside 1 through 65535'
fi
case "${HOST}" in
    example.com|*.example.com|example.net|*.example.net|example.org|*.example.org|example|*.example|invalid|*.invalid|localhost|*.localhost)
        fail 'SUFeedURL uses a placeholder hostname; choose the production feed before releasing' ;;
esac
case ".${HOST}." in
    *.todo.*|*.placeholder.*|*.changeme.*|*.yourcompany.*|*.yourdomain.*)
        fail 'SUFeedURL hostname contains a placeholder' ;;
esac
case "${FEED_LOWER}" in
    */todo|*/todo/*|*/placeholder|*/placeholder/*|*/changeme|*/changeme/*)
        fail 'SUFeedURL path contains a placeholder' ;;
esac
ESCAPES="${FEED}"
while [[ "${ESCAPES}" == *%* ]]; do
    ESCAPES="${ESCAPES#*%}"
    [[ "${ESCAPES}" =~ ^[[:xdigit:]]{2} ]] || fail 'SUFeedURL contains an invalid percent escape'
    ESCAPES="${ESCAPES:2}"
done
echo 'PASS: release identity has no known placeholders and the feed is a syntactically valid HTTPS URL'
