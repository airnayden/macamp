#!/usr/bin/env bash
#
# github-release.sh — tag a published MacAMP version and create its GitHub
# Release page. The page carries the notes and links to the download on
# downloads.macamp.si; no binaries are uploaded to GitHub.
#
# Pushing the v<version> tag also deploys the user guide (docs.yml), so after
# this script the website download, the docs and the release page all match.
#
# Run it after scripts/publish-r2.sh (scripts/release.sh --publish does both).
#
# Usage:
#   scripts/github-release.sh --version 1.2.3
#   scripts/github-release.sh --version 1.2.3 --dry-run   # print the page, change nothing
#
# Flags:
#   --version <v>     REQUIRED. Tags HEAD as v<v> (or reuses an existing v<v> tag).
#   --output-dir <d>  The release.sh output directory (default: dist/), used for
#                     the image's size and SHA-256.
#   --notes <file>    Markdown for the "What's new" section. Default:
#                     release-notes/<v>.md when it exists.
#   --dry-run         Print the tag and release page that would be created.
#   -h | --help       This text.
#
# Requires the GitHub CLI, signed in once:  brew install gh && gh auth login
#
# Exit codes:
#   0  done (or dry run)     1  bad arguments / missing input
#   2  gh missing or signed out     3  git state unsuitable     4  GitHub call failed
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

REPO="airnayden/macamp"
PUBLIC_BASE="https://downloads.macamp.si"
DOCS_URL="https://docs.macamp.si/docs/install/"

VERSION=""
OUTPUT_DIR=""
NOTES_FILE=""
DRY_RUN=0

die() { echo "error: $*" >&2; exit 1; }
fail() { local code="$1"; shift; echo "FAIL: $*" >&2; exit "${code}"; }
step() { printf '\n-- %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) [[ $# -ge 2 ]] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
        --output-dir) [[ $# -ge 2 ]] || die "--output-dir needs a path"; OUTPUT_DIR="$2"; shift 2 ;;
        --notes) [[ $# -ge 2 ]] || die "--notes needs a file"; NOTES_FILE="$2"; shift 2 ;;
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
if [[ -z "${NOTES_FILE}" && -f "${REPO_ROOT}/release-notes/${VERSION}.md" ]]; then
    NOTES_FILE="${REPO_ROOT}/release-notes/${VERSION}.md"
fi
[[ -z "${NOTES_FILE}" || -f "${NOTES_FILE}" ]] || die "notes file not found: ${NOTES_FILE}"

TAG="v${VERSION}"
DMG_NAME="MacAMP-${VERSION}.dmg"
DMG_PATH="${OUTPUT_DIR}/releases/${DMG_NAME}"
DMG_URL="${PUBLIC_BASE}/releases/${DMG_NAME}"
[[ -f "${DMG_PATH}" ]] || fail 1 "${DMG_PATH} not found — publish the release first (scripts/release.sh --publish)"

PRERELEASE=0
[[ "${VERSION}" == *-* ]] && PRERELEASE=1

# ------------------------------------------------------------------ git ------
step "Checking the source"
# A dry run reports what would stop a real run instead of stopping.
blocker() { if [[ "${DRY_RUN}" -eq 1 ]]; then note "⚠ a real run would stop here: $*"; else fail 3 "$*"; fi; }
git rev-parse --git-dir >/dev/null 2>&1 || fail 3 "not a git repository"
HEAD_SHA="$(git rev-parse HEAD)"
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    TAG_SHA="$(git rev-list -n 1 "${TAG}")"
    note "tag ${TAG} exists at ${TAG_SHA:0:7}"
    NEED_TAG=0
else
    [[ -z "$(git status --porcelain)" ]] || blocker "uncommitted changes — commit them before tagging ${TAG}"
    git fetch -q origin 2>/dev/null || true
    git branch -r --contains "${HEAD_SHA}" 2>/dev/null | grep -q 'origin/' \
        || blocker "HEAD (${HEAD_SHA:0:7}) is not on GitHub yet — git push first"
    note "will tag HEAD ${HEAD_SHA:0:7} as ${TAG}"
    NEED_TAG=1
fi

# ---------------------------------------------------------------- page -------
SIZE_MB="$(awk -v b="$(stat -f %z "${DMG_PATH}")" 'BEGIN { printf "%.0f", b / 1048576 }')"
SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
BODY="$(mktemp "${TMPDIR:-/tmp}"/macamp-release-body.XXXXXX)"
trap 'rm -f "${BODY}"' EXIT
{
    echo "## Download"
    echo ""
    echo "**[Download MacAMP ${VERSION} for Mac](${DMG_URL})** · ${SIZE_MB} MB · macOS 14 or later · Apple silicon"
    echo ""
    echo "Or install it from Terminal:"
    echo ""
    echo '```sh'
    echo "curl -fsSL ${PUBLIC_BASE}/install.sh | bash"
    echo '```'
    echo ""
    echo "Already using MacAMP? It updates itself; check any time with **MacAMP › Check for Updates…**"
    echo ""
    if [[ -n "${NOTES_FILE}" ]]; then
        echo "## What's new"
        echo ""
        cat "${NOTES_FILE}"
        echo ""
    fi
    echo "## First launch"
    echo ""
    echo "Releases aren't notarized yet, so macOS asks you to approve a downloaded DMG once: open **System Settings › Privacy & Security** and click **Open Anyway**. The Terminal install skips this. [Install guide](${DOCS_URL})"
    echo ""
    echo "<details><summary>Checksum</summary>"
    echo ""
    echo '```'
    echo "SHA-256 (${DMG_NAME}) = ${SHA256}"
    echo '```'
    echo "</details>"
} > "${BODY}"

GH_ARGS=(--repo "${REPO}" --title "MacAMP ${VERSION}" --notes-file "${BODY}" --generate-notes --verify-tag)
if [[ "${PRERELEASE}" -eq 1 ]]; then GH_ARGS+=(--prerelease); else GH_ARGS+=(--latest); fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
    step "DRY RUN — would run:"
    [[ "${NEED_TAG}" -eq 1 ]] && note "git tag -a ${TAG} -m 'MacAMP ${VERSION}' && git push origin ${TAG}"
    note "gh release create ${TAG} ${GH_ARGS[*]}"
    step "Release page body:"
    sed 's/^/    | /' "${BODY}"
    exit 0
fi

command -v gh >/dev/null 2>&1 || fail 2 "the GitHub CLI is required: brew install gh && gh auth login"
gh auth status >/dev/null 2>&1 || fail 2 "the GitHub CLI is signed out: gh auth login"

if [[ "${NEED_TAG}" -eq 1 ]]; then
    step "Tagging ${TAG}"
    git tag -a "${TAG}" -m "MacAMP ${VERSION}" || fail 3 "git tag failed"
fi
git push -q origin "refs/tags/${TAG}" || fail 3 "git push of ${TAG} failed"
note "✓ ${TAG} is on GitHub (this also deploys docs.macamp.si)"

step "GitHub Release"
if gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
    gh release edit "${TAG}" --repo "${REPO}" --title "MacAMP ${VERSION}" --notes-file "${BODY}" >/dev/null \
        || fail 4 "gh release edit failed"
    note "✓ updated the existing release"
else
    gh release create "${TAG}" "${GH_ARGS[@]}" >/dev/null || fail 4 "gh release create failed"
    note "✓ created"
fi

echo ""
echo "PASS: https://github.com/${REPO}/releases/tag/${TAG}"
exit 0
