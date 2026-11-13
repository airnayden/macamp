#!/usr/bin/env bash
#
# check-downloader-boundary.sh — MacAMP YouTube-downloader boundary guard
#
# The downloader is the one feature in MacAMP that runs a THIRD-PARTY BINARY and
# fetches bytes off the public internet. Both powers are real: a child process is
# arbitrary code execution on the listener's machine, and an unbounded HTTP client
# is an egress path nothing else in the feature can see. Neither is avoidable — the
# feature is yt-dlp — so instead of pretending otherwise, each is confined to a
# NAMED FILE and this grep holds the line.
#
#     macOS/Sources/Downloads/YtDlpProcessRunner.swift        <- the only spawn
#     macOS/Sources/Downloads/DownloadToolReleaseClient.swift <- engine self-update
#     macOS/Sources/Downloads/YouTubeOEmbedClient.swift       <- oEmbed + thumbnails
#
# Everything else in the surface — the PlayerCore queue and its view models, the
# rest of the macOS shell's download UI, the Downloads preference pane — reaches
# the outside world only THROUGH those files, via `ToolProcessRunning`,
# `ToolReleaseFetching` and `OEmbedFetching`. That is what makes the whole download
# state machine drivable from `FakeToolProcessRunner` / `FakeToolReleaseFetcher` /
# `FakeOEmbedFetcher` with no process and no network, and it is what keeps "which
# code can run a program on your Mac?" answerable by reading one file.
#
# ── WHY THE TRANSPORT ALLOWANCE IS A LIST AND THE SPAWN ALLOWANCE IS NOT ─────
#
# Spawning stays at exactly one file: there is one engine, and "what can this app
# run?" must have a one-file answer. Transport is a LIST because two genuinely
# different egresses exist — the engine self-update (GitHub releases, checksum
# verified) and the keyless oEmbed lookup (paste-time titles and poster frames).
# Widening the list is a deliberate act that shows up in this file's diff; it is
# not something a new file can do by existing. Every entry is matched EXACTLY, so
# renaming or splitting any of them re-arms the guard.
#
# ── THE AsyncImage SCAN: A SECOND EGRESS THAT WOULD NOT LOOK LIKE ONE ────────
#
# `AsyncImage` fetches over the network from inside the view layer. It carries no
# deadline this surface set, no size ceiling, no session policy, and — worst — it
# would not appear in ANY transport sweep, because the URLSession it uses is
# SwiftUI's, not ours. That is precisely the "unreviewed egress path" this guard
# exists to prevent, so it is refused OUTRIGHT in this surface with no allowed
# file at all: download thumbnails are fetched as bytes through
# `OEmbedFetching.fetchThumbnail(url:)` and rendered from memory.
#
# ── WHAT THIS GUARD ACTUALLY ASSERTS ─────────────────────────────────────────
#
# Read it precisely; a guard that overstates itself is worse than one that states
# less:
#
#   THIS ASSERTS: our downloader SOURCE names no `URLSession`, no `AsyncImage`, and
#                 no process spawn outside the allowed files.
#   IT DOES NOT ASSERT: nothing in the feature reaches the network. It obviously
#                 does — yt-dlp is a downloader, and the whole point of the
#                 spawn file is to run it. The claim is about WHERE that power
#                 is written, not whether it is used.
#
# No allowed file is exempted as a DIRECTORY, and none is dropped from the scan.
# Every exemption is a post-filter on individual matches, so every other file in
# `macOS/Sources/Downloads` stays fully guarded and only the named paths are let
# through, per pattern. The exemptions are also independent: the spawn file may
# not open a `URLSession`, and neither transport file may spawn.
#
# SCANNED (exact list; see `.omo/plans/youtube-downloader.md` todo 8):
#   PlayerCore/Sources/Services/Downloads    <- the queue, the seams, the argument
#                                               builder and the progress parser.
#                                               Portable core: it may not import
#                                               `Process` (which does not exist on
#                                               iOS) nor open a session
#   PlayerCore/Sources/ViewModels/Downloads  <- the shared download view models
#   macOS/Sources/Downloads                  <- the shell's download surface,
#                                               including every allowed file
#   macOS/Sources/Preferences/Downloads*     <- glob: every macOS Downloads pane
#                                               MUST carry the `Downloads` filename
#                                               prefix or it escapes this guard
#
# A scan target that does not exist yet is SKIPPED, not an error, so a checkout
# that predates a pane still passes rather than failing on an unexpanded glob.
#
# This guard is deliberately SEPARATE from `scripts/check-ai-network-boundary.sh`.
# That one is the AI surface's, with its own homes and its own exemption; the two
# assert different invariants about different code and must be able to move
# independently. `PlayerCore/Sources/ViewModels` is scanned by both — the AI guard
# already covers the directory as a whole, this one names the downloads subtree so
# the assertion survives a future narrowing on either side.
#
# COMMENT ANCHORING (same rationale as scripts/check-ai-network-boundary.sh):
# a line whose first non-whitespace token is `//`, `/*` or `*` is prose, not
# transport. `ToolProcessRunning.swift` documents this very boundary by NAMING
# `Process` and `URLSession` in its header — describing a boundary is not crossing
# it, exactly as `// MUST NOT import AppKit or UIKit` is not an import. Trailing
# comments on a code line are NOT stripped: that direction fails loudly, which is
# the safe way for a guard to be wrong. Known conservative edge: a bare
# continuation line inside a `/* … */` block that starts with neither `*` nor `/`
# would be flagged; the tree uses `//` throughout.
#
# USAGE
#   check-downloader-boundary.sh              run the guard
#   check-downloader-boundary.sh --self-test  prove the guard still has teeth
#
#   exit 0  -> clean (no spawn, no transport outside the allowed files, no
#              AsyncImage anywhere in the surface)
#   exit 1  -> boundary violation found (offending file:line printed)
#   exit 2  -> checkout incomplete (an allowed file missing, or no scan target
#              exists at all). NOT a pass: the assertion never ran.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SELF_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

cd "${REPO_ROOT}"

# ── SELF-TEST ────────────────────────────────────────────────────────────────
#
# A guard whose only evidence is a green run on a clean tree is indistinguishable
# from a guard that scans nothing — the failure this epic has now recorded five
# times. So the teeth are provable on demand: four cases, in order, each writing a
# scratch file into a REAL scanned directory (never touching a tracked file) and
# removing it again through a `trap`.
#
#   [0] clean tree                       -> must exit 0  (a passing baseline)
#   [1] a THIRD file naming URLSession   -> must exit 1  (the list is membership,
#                                                         not "anything goes")
#   [2] a file naming AsyncImage         -> must exit 1  (the new scan fires)
#   [3] clean again                      -> must exit 0  (no residue)
if [[ "${1:-}" == "--self-test" ]]; then
  SCRATCH_TRANSPORT="macOS/Sources/Downloads/__BoundaryGuardScratchTransport$$.swift"
  SCRATCH_IMAGE="macOS/Sources/Downloads/__BoundaryGuardScratchImage$$.swift"
  trap 'rm -f "${SCRATCH_TRANSPORT}" "${SCRATCH_IMAGE}"' EXIT

  echo "==> Downloader boundary guard SELF-TEST"
  echo "    scratch transport file: ${SCRATCH_TRANSPORT}"
  echo "    scratch image file:     ${SCRATCH_IMAGE}"
  echo ""

  self_test_failures=0

  run_case() {
    local label="$1"
    local expected="$2"
    local actual=0
    if "${SELF_PATH}" >/dev/null 2>&1; then actual=0; else actual=$?; fi
    if [[ "${actual}" -eq "${expected}" ]]; then
      echo "  ok   ${label} -> exit ${actual} (expected ${expected})"
    else
      echo "  FAIL ${label} -> exit ${actual} (expected ${expected})" >&2
      self_test_failures=$((self_test_failures + 1))
    fi
  }

  run_case "[0] clean tree" 0

  printf 'import Foundation\nlet scratchSession = URLSession.shared\n' >"${SCRATCH_TRANSPORT}"
  run_case "[1] a third file naming URLSession" 1
  rm -f "${SCRATCH_TRANSPORT}"

  printf 'import SwiftUI\nlet scratchImage = AsyncImage(url: URL(string: "https://example.invalid"))\n' \
    >"${SCRATCH_IMAGE}"
  run_case "[2] a file naming AsyncImage" 1
  rm -f "${SCRATCH_IMAGE}"

  run_case "[3] clean again" 0

  echo ""
  if [[ "${self_test_failures}" -eq 0 ]]; then
    echo "SELF-TEST PASS: all four cases behaved as designed."
    exit 0
  fi
  echo "SELF-TEST FAIL: ${self_test_failures} case(s) did not behave as designed." >&2
  exit 1
fi

# Exact target list from the plan. The unquoted glob expands here; when it matches
# nothing bash leaves the literal pattern behind, which the existence filter below
# drops.
CANDIDATE_TARGETS=(
  "PlayerCore/Sources/Services/Downloads"
  "PlayerCore/Sources/ViewModels/Downloads"
  "macOS/Sources/Downloads"
  macOS/Sources/Preferences/Downloads*
)

# Running a third-party binary is arbitrary code execution, so it lives in one file.
PROCESS_PATTERN='Process[[:space:]]*\(|Process\.init|posix_spawn|NSTask'
PROCESS_ALLOWED_FILE="macOS/Sources/Downloads/YtDlpProcessRunner.swift"

# Fetching bytes is the surface's hand-rolled egress, so it lives in named files —
# a different set from the spawn file, so neither power implies the other.
TRANSPORT_PATTERN='URLSession'
TRANSPORT_ALLOWED_FILES=(
  "macOS/Sources/Downloads/DownloadToolReleaseClient.swift"
  "macOS/Sources/Downloads/YouTubeOEmbedClient.swift"
)

# A view that fetches is an egress no transport sweep can see. Allowed NOWHERE.
IMAGE_FETCH_PATTERN='AsyncImage'

SCAN_TARGETS=()
SKIPPED_TARGETS=()
for target in "${CANDIDATE_TARGETS[@]}"; do
  if [[ -e "${target}" ]]; then
    SCAN_TARGETS+=("${target}")
  else
    SKIPPED_TARGETS+=("${target}")
  fi
done

for allowed in "${PROCESS_ALLOWED_FILE}" "${TRANSPORT_ALLOWED_FILES[@]}"; do
  if [[ ! -f "${allowed}" ]]; then
    echo "error: ${allowed} not found (run from a MacAMP checkout)" >&2
    echo "exit 2 is SKIPPED, not PASS — the boundary assertion never ran." >&2
    exit 2
  fi
done

if [[ "${#SCAN_TARGETS[@]}" -eq 0 ]]; then
  echo "error: none of the downloader boundary scan targets exist" >&2
  echo "exit 2 is SKIPPED, not PASS — the boundary assertion never ran." >&2
  exit 2
fi

echo "==> Downloader boundary guard: one file may spawn, named files may transport"
echo "    scanning: ${SCAN_TARGETS[*]}"
if [[ "${#SKIPPED_TARGETS[@]}" -gt 0 ]]; then
  echo "    skipped (absent): ${SKIPPED_TARGETS[*]}"
fi
echo "    process spawn allowed ONLY in: ${PROCESS_ALLOWED_FILE}"
echo "    URLSession allowed ONLY in these ${#TRANSPORT_ALLOWED_FILES[@]} file(s):"
for allowed in "${TRANSPORT_ALLOWED_FILES[@]}"; do
  echo "      - ${allowed}"
done
echo "    AsyncImage allowed NOWHERE in this surface"
echo ""

# Prose, not transport — see COMMENT ANCHORING above.
is_comment_line() {
  local comment_re='^[[:space:]]*(//|/\*|\*)'
  [[ "$1" =~ ${comment_re} ]]
}

PROCESS_VIOL_FILE="$(mktemp)"
TRANSPORT_VIOL_FILE="$(mktemp)"
IMAGE_VIOL_FILE="$(mktemp)"
trap 'rm -f "${PROCESS_VIOL_FILE}" "${TRANSPORT_VIOL_FILE}" "${IMAGE_VIOL_FILE}"' EXIT

# Appends every NON-COMMENT match of $1 across the target dirs into file $2,
# skipping any match whose file is one of the $3 exempt paths that follow.
#
# Arguments: <pattern> <outfile> <exempt-count> <exempt…> <target…>
# The count is what splits the two variadic tails; pass 0 for no exemption at all
# (the AsyncImage scan). Exemptions FILTER MATCHES rather than narrowing the scan —
# see the header for why.
#
# `-H` forces the `file:line:content` shape even when a single plain file is the
# only operand, which the Downloads* glob can produce; without it that one case
# parses as `line:content` and the exemption compare would silently never match.
#
# grep exits 1 when nothing matches — the PASS case — so guard against pipefail.
# Same `|| true` idiom as scripts/check-playercore-portability.sh.
scan_for() {
  local pattern="$1"
  local outfile="$2"
  local exempt_count="$3"
  shift 3
  local exempt=()
  local index
  for ((index = 0; index < exempt_count; index++)); do
    exempt+=("$1")
    shift
  done
  local match file rest line content candidate exempted
  while IFS= read -r match; do
    [[ -z "${match}" ]] && continue
    file="${match%%:*}"
    rest="${match#*:}"
    line="${rest%%:*}"
    content="${rest#*:}"
    exempted=0
    if [[ "${exempt_count}" -gt 0 ]]; then
      for candidate in "${exempt[@]}"; do
        if [[ "${file}" == "${candidate}" ]]; then
          exempted=1
          break
        fi
      done
    fi
    [[ "${exempted}" -eq 1 ]] && continue
    if is_comment_line "${content}"; then continue; fi
    printf '%s:%s:%s\n' "${file}" "${line}" "${content}" >>"${outfile}"
  done < <(grep -rnHE "${pattern}" "$@" 2>/dev/null || true)
}

scan_for "${PROCESS_PATTERN}" "${PROCESS_VIOL_FILE}" \
  1 "${PROCESS_ALLOWED_FILE}" "${SCAN_TARGETS[@]}"
scan_for "${TRANSPORT_PATTERN}" "${TRANSPORT_VIOL_FILE}" \
  "${#TRANSPORT_ALLOWED_FILES[@]}" "${TRANSPORT_ALLOWED_FILES[@]}" "${SCAN_TARGETS[@]}"
scan_for "${IMAGE_FETCH_PATTERN}" "${IMAGE_VIOL_FILE}" \
  0 "${SCAN_TARGETS[@]}"

if [[ -s "${PROCESS_VIOL_FILE}" ]]; then
  count="$(wc -l <"${PROCESS_VIOL_FILE}" | tr -d '[:space:]')"
  echo "FAIL: ${count} process-spawn reference(s) outside ${PROCESS_ALLOWED_FILE}." >&2
  echo "      Launching a child is arbitrary code execution on the listener's Mac," >&2
  echo "      and it is egress no URLSession sweep can see. Exactly one file owns" >&2
  echo "      that power so the answer to 'what can this app run?' stays one file" >&2
  echo "      long. Route the call through ToolProcessRunning — whose production" >&2
  echo "      conformer is ${PROCESS_ALLOWED_FILE} — rather than widening this guard." >&2
  echo "" >&2
  echo "Offending occurrences:" >&2
  cat "${PROCESS_VIOL_FILE}" >&2
  exit 1
fi

if [[ -s "${TRANSPORT_VIOL_FILE}" ]]; then
  count="$(wc -l <"${TRANSPORT_VIOL_FILE}" | tr -d '[:space:]')"
  echo "FAIL: ${count} direct URLSession reference(s) outside the sanctioned transport files." >&2
  echo "      The downloader's own network access belongs to the engine it drives;" >&2
  echo "      the app's hand-rolled fetches are the engine self-update and the" >&2
  echo "      keyless oEmbed lookup, each bounded (HTTPS, status check, deadline," >&2
  echo "      size ceiling) in one place. A further session would be an unreviewed" >&2
  echo "      egress path. Route it through ToolReleaseFetching or OEmbedFetching —" >&2
  echo "      whose production conformers are:" >&2
  for allowed in "${TRANSPORT_ALLOWED_FILES[@]}"; do
    echo "        - ${allowed}" >&2
  done
  echo "      — instead of widening this list." >&2
  echo "" >&2
  echo "Offending occurrences:" >&2
  cat "${TRANSPORT_VIOL_FILE}" >&2
  exit 1
fi

if [[ -s "${IMAGE_VIOL_FILE}" ]]; then
  count="$(wc -l <"${IMAGE_VIOL_FILE}" | tr -d '[:space:]')"
  echo "FAIL: ${count} AsyncImage reference(s) in the downloader surface." >&2
  echo "      AsyncImage fetches from inside the view layer, over SwiftUI's own" >&2
  echo "      URLSession — so it is egress that no transport sweep here can see," >&2
  echo "      with no deadline, no size ceiling and no session policy of ours." >&2
  echo "      Fetch the bytes through OEmbedFetching.fetchThumbnail(url:) and" >&2
  echo "      render them from memory (see DownloadThumbnailStore)." >&2
  echo "" >&2
  echo "Offending occurrences:" >&2
  cat "${IMAGE_VIOL_FILE}" >&2
  exit 1
fi

# Corroboration only, never gating: shows both powers really are present in their
# permitted homes, so a reader can tell a clean tree from an empty one.
PROCESS_HITS="$(grep -cE "${PROCESS_PATTERN}" "${PROCESS_ALLOWED_FILE}" 2>/dev/null || echo 0)"
echo "    ${PROCESS_ALLOWED_FILE} spawn references: ${PROCESS_HITS}  [informational]"
for allowed in "${TRANSPORT_ALLOWED_FILES[@]}"; do
  transport_hits="$(grep -c "${TRANSPORT_PATTERN}" "${allowed}" 2>/dev/null || echo 0)"
  echo "    ${allowed} URLSession references: ${transport_hits}  [informational]"
done
echo ""
echo "PASS: no process spawn outside ${PROCESS_ALLOWED_FILE}."
echo "PASS: no direct URLSession use outside these ${#TRANSPORT_ALLOWED_FILES[@]} file(s):"
for allowed in "${TRANSPORT_ALLOWED_FILES[@]}"; do
  echo "        - ${allowed}"
done
echo "PASS: no AsyncImage anywhere in the downloader surface."
exit 0
