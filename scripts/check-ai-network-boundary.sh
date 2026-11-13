#!/usr/bin/env bash
#
# check-ai-network-boundary.sh — MacAMP AI transport-boundary guard
#
# ONE place in this repo is allowed to speak HTTP on behalf of the AI surface:
#
#     AIConnectorKit/Sources/AIConnectorKit/        <- the transport home
#
# Everything ABOVE that seam — the PlayerCore assistant/insight services, the
# shared view models, the macOS Intelligence preference panes, and the
# AIConnectorBridge glue — must reach the network only THROUGH a connector. If
# any of them touches `URLSession` directly it has bypassed the deadline, the
# payload budget, the consent gate and the error taxonomy that the kit owns, and
# the "default state makes zero network calls" promise stops being provable from
# the kit alone.
#
# This guard replaces the retired blanket premise from
# `.omo/plans/local-ai-playlists.md` ("new modules => zero URLSession"). That
# premise died with `Spikes/ADR-ai-provider-connectors.md` (ACCEPTED): the
# assistant surface MAY now make outbound calls. What survives it is narrower and
# still load-bearing — outbound calls may originate ONLY inside the kit.
#
# ── WHAT THIS GUARD ACTUALLY ASSERTS (invariant shift, recorded deliberately) ──
#
# Read the assertion precisely, because the MCP client (`AIConnectorMCP`, added to
# the scan list by `.omo/plans/ai-chat-refinement.md` todo 11) widened the set of
# places bytes can leave from, and a guard that overstates itself is worse than
# one that states less:
#
#   THIS ASSERTS: our AI-surface SOURCE names no `URLSession` and no process
#                 spawn outside the allowed homes.
#   IT DOES NOT ASSERT: all egress is confined to one directory.
#
# Two structural reasons the stronger claim is not available:
#
#   1. TRANSPORT_HOME itself is never scanned — by design; it is the home. The
#      guard proves nothing about what happens inside it.
#   2. The MCP SDK's `HTTPClientTransport` performs its own `URLSession` I/O
#      INSIDE SDK code (it even takes a `URLSessionConfiguration` parameter).
#      That source is a resolved package checkout, covered by no scan target here
#      and not ours to police.
#
# So after todo 11 there are TWO egress homes, not one:
#
#   AIConnectorKit/Sources/AIConnectorKit/   <- our own URLSession transport
#   the MCP SDK's transports                 <- reached through AIConnectorMCP
#
# The value that survives is unchanged in kind: nothing in the AI surface may
# open its own side channel — not an HTTP session, not a child process — without
# that being a deliberate, reviewed edit to this file.
#
# SCANNED (exact list; see `.omo/plans/ai-provider-connectors.md` todo 23 and
# `.omo/plans/ai-chat-refinement.md` todo 11):
#   PlayerCore/Sources/Services/Assistant
#   PlayerCore/Sources/Services/Insight        <- mix code lives here; there is
#                                                 NO Services/Mix directory
#   PlayerCore/Sources/Services/Toolbox        <- the ten library tools. "The
#                                                 toolbox is offline by
#                                                 construction" was a documented
#                                                 invariant with no guard behind
#                                                 it until this entry existed
#                                                 (library-chat W6b, O2)
#   PlayerCore/Sources/ViewModels
#   macOS/Sources/Preferences/Intelligence*    <- glob: every macOS AI pane/sheet
#                                                 MUST carry the `Intelligence`
#                                                 filename prefix or it escapes
#                                                 this guard
#   AIConnectorKit/Sources/AIConnectorBridge
#   macOS/Sources/MCP                          <- the in-process MCP server; see
#                                                 the INBOUND-ONLY section below
#   AIConnectorKit/Sources/AIConnectorMCP      <- the MCP CLIENT. URLSession stays
#                                                 forbidden here: MCP egress rides
#                                                 the SDK's own transports, so a
#                                                 hand-rolled session in our
#                                                 wrapper would be a second,
#                                                 unreviewed HTTP path
#   macOS/Sources/Assistant                    <- the macOS chat UI. A view has no
#                                                 business holding a session
#
# A scan target that does not exist yet is SKIPPED, not an error, so a checkout
# that predates a pane still passes rather than failing on an unexpanded glob.
#
# ── macOS/Sources/MCP IS INBOUND ONLY, AND THAT NEEDS ITS OWN ASSERTION ───────
#
# The MCP server is the one place in the AI surface that legitimately imports
# `Network`, so the URLSession sweep alone would leave it half-guarded: a socket
# opened with `NWConnection(...)` reaches the network without ever naming
# `URLSession`. `MCPLibraryServer` states the invariant in its own header — "a
# listener, its accepted connections, and no `NWConnection` this process ever
# initiates" — and this is the grep that holds it to it.
#
# The distinction is CONSTRUCTION, not mention. `NWConnection` as a TYPE is how
# an ACCEPTED connection is carried (`connections: [ObjectIdentifier:
# NWConnection]`, `func accept(_ connection: NWConnection, …)`,
# `MCPHTTPConnectionLoop.run(connection:source:port:)`) — those arrive from
# `NWListener.newConnectionHandler` and are inbound by definition. Calling an
# `NWConnection` INITIALISER is the only way this process dials out, so the
# pattern anchors on `NWConnection(` / `NWConnection.init` and nothing else.
# `NWListener`, `NWParameters` and `NWEndpoint` are deliberately NOT matched:
# forbidding them would forbid the server itself.
#
# ── PROCESS SPAWN: ONE FILE, NOT ONE DIRECTORY ───────────────────────────────
#
# A child process is egress the URLSession sweep cannot see: `curl`, `ssh`, or an
# MCP server binary reaches the network without our source naming a session at
# all. It is also arbitrary code execution on the user's machine. So `Process(` /
# `Process.init` / `posix_spawn` / `NSTask` are forbidden across EVERY scan
# target, with exactly one exemption:
#
#     AIConnectorKit/Sources/AIConnectorMCP/MCPProcessTransport.swift
#
# That file exists to own a stdio MCP server's lifecycle — launch, pipes,
# termination — and the SDK does not spawn processes itself, so someone must.
#
# The exemption is a FILE, deliberately not a directory, and is applied as a
# post-filter on matches rather than by dropping a path from the scan. Excluding
# the directory would silently unguard every other file in the MCP client; a
# post-filter keeps `AIConnectorMCP` fully scanned and lets exactly one known
# path through. Renaming or splitting that file re-arms the guard, which is the
# intended failure mode: process spawning should not migrate quietly.
#
# COMMENT ANCHORING (same rationale as scripts/check-playercore-portability.sh):
# a line whose first non-whitespace token is `//`, `/*` or `*` is prose, not
# transport. `AIConnectorBridge/ConnectorQueryParser.swift` documents the seam by
# NAMING `URLSessionTransport` in a doc comment — describing the boundary is not
# crossing it, exactly as `// MUST NOT import AppKit or UIKit` is not an import.
# Trailing comments on a code line are NOT stripped: that direction fails loudly,
# which is the safe way for a guard to be wrong. Known conservative edge: a bare
# continuation line inside a `/* … */` block that starts with neither `*` nor `/`
# would be flagged; the tree uses `//` throughout.
#
#   exit 0  -> clean (no transport, and no process spawn, outside the allowed
#              homes)
#   exit 1  -> boundary violation found (offending file:line printed)
#   exit 2  -> checkout incomplete (transport home missing, or no scan target
#              exists at all). NOT a pass: the assertion never ran.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

# The ONE directory permitted to construct a URLSession. Never scanned.
TRANSPORT_HOME="AIConnectorKit/Sources/AIConnectorKit"

# Exact target list from the plan. The unquoted glob expands here; when it
# matches nothing bash leaves the literal pattern behind, which the existence
# filter below drops.
CANDIDATE_TARGETS=(
  "PlayerCore/Sources/Services/Assistant"
  "PlayerCore/Sources/Services/Insight"
  "PlayerCore/Sources/Services/Toolbox"
  "PlayerCore/Sources/ViewModels"
  macOS/Sources/Preferences/Intelligence*
  "AIConnectorKit/Sources/AIConnectorBridge"
  "macOS/Sources/MCP"
  "AIConnectorKit/Sources/AIConnectorMCP"
  "macOS/Sources/Assistant"
)

# The in-process MCP server, and only it, additionally may not DIAL OUT. See the
# INBOUND-ONLY section above for why the pattern anchors on construction.
CANDIDATE_OUTBOUND_TARGETS=(
  "macOS/Sources/MCP"
)
OUTBOUND_PATTERN='NWConnection[[:space:]]*\(|NWConnection\.init'

# Spawning is egress the URLSession sweep cannot see, so it is forbidden across
# every scan target. See the PROCESS SPAWN section above for why the single
# exemption is a file rather than a directory.
PROCESS_PATTERN='Process[[:space:]]*\(|Process\.init|posix_spawn|NSTask'
PROCESS_ALLOWED_FILE="AIConnectorKit/Sources/AIConnectorMCP/MCPProcessTransport.swift"

SCAN_TARGETS=()
SKIPPED_TARGETS=()
for target in "${CANDIDATE_TARGETS[@]}"; do
  if [[ -e "${target}" ]]; then
    SCAN_TARGETS+=("${target}")
  else
    SKIPPED_TARGETS+=("${target}")
  fi
done

OUTBOUND_TARGETS=()
for target in "${CANDIDATE_OUTBOUND_TARGETS[@]}"; do
  if [[ -e "${target}" ]]; then
    OUTBOUND_TARGETS+=("${target}")
  fi
done

if [[ ! -d "${TRANSPORT_HOME}" ]]; then
  echo "error: ${TRANSPORT_HOME} not found (run from a MacAMP checkout)" >&2
  echo "exit 2 is SKIPPED, not PASS — the boundary assertion never ran." >&2
  exit 2
fi

if [[ "${#SCAN_TARGETS[@]}" -eq 0 ]]; then
  echo "error: none of the AI boundary scan targets exist" >&2
  echo "exit 2 is SKIPPED, not PASS — the boundary assertion never ran." >&2
  exit 2
fi

echo "==> AI network-boundary guard: URLSession may live ONLY in ${TRANSPORT_HOME}"
echo "    scanning: ${SCAN_TARGETS[*]}"
if [[ "${#SKIPPED_TARGETS[@]}" -gt 0 ]]; then
  echo "    skipped (absent): ${SKIPPED_TARGETS[*]}"
fi
if [[ "${#OUTBOUND_TARGETS[@]}" -gt 0 ]]; then
  echo "    inbound-only (no outbound dial): ${OUTBOUND_TARGETS[*]}"
fi
echo "    no process spawn anywhere except: ${PROCESS_ALLOWED_FILE}"
echo ""

# Prose, not transport — see COMMENT ANCHORING above.
is_comment_line() {
  local comment_re='^[[:space:]]*(//|/\*|\*)'
  [[ "$1" =~ ${comment_re} ]]
}

VIOL_FILE="$(mktemp)"
OUTBOUND_VIOL_FILE="$(mktemp)"
PROCESS_VIOL_FILE="$(mktemp)"
trap 'rm -f "${VIOL_FILE}" "${OUTBOUND_VIOL_FILE}" "${PROCESS_VIOL_FILE}"' EXIT

# Appends every NON-COMMENT match of $1 across the target dirs $4.. into file $2,
# skipping any match whose file is exactly $3 (pass "" for no exemption — see the
# PROCESS SPAWN section for why the exemption filters matches instead of
# narrowing the scan).
#
# `-H` forces the `file:line:content` shape even when a single plain file is the
# only operand, which the Intelligence* glob can produce; without it that one
# case parses as `line:content` and the exemption compare would silently never
# match.
#
# grep exits 1 when nothing matches — the PASS case — so guard against pipefail.
# Same `|| true` idiom as scripts/check-playercore-portability.sh.
scan_for() {
  local pattern="$1"
  local outfile="$2"
  local exempt="$3"
  shift 3
  local match file rest line content
  while IFS= read -r match; do
    [[ -z "${match}" ]] && continue
    file="${match%%:*}"
    rest="${match#*:}"
    line="${rest%%:*}"
    content="${rest#*:}"
    if [[ -n "${exempt}" && "${file}" == "${exempt}" ]]; then continue; fi
    if is_comment_line "${content}"; then continue; fi
    printf '%s:%s:%s\n' "${file}" "${line}" "${content}" >>"${outfile}"
  done < <(grep -rnHE "${pattern}" "$@" 2>/dev/null || true)
}

scan_for 'URLSession' "${VIOL_FILE}" "" "${SCAN_TARGETS[@]}"
if [[ "${#OUTBOUND_TARGETS[@]}" -gt 0 ]]; then
  scan_for "${OUTBOUND_PATTERN}" "${OUTBOUND_VIOL_FILE}" "" "${OUTBOUND_TARGETS[@]}"
fi
scan_for "${PROCESS_PATTERN}" "${PROCESS_VIOL_FILE}" "${PROCESS_ALLOWED_FILE}" "${SCAN_TARGETS[@]}"

if [[ -s "${VIOL_FILE}" ]]; then
  count="$(wc -l <"${VIOL_FILE}" | tr -d '[:space:]')"
  echo "FAIL: ${count} direct URLSession reference(s) outside ${TRANSPORT_HOME}." >&2
  echo "      The AI surface reaches the network ONLY through a connector, so the" >&2
  echo "      kit's deadline, payload budget, consent gate and error taxonomy" >&2
  echo "      cannot be bypassed. Move the transport into ${TRANSPORT_HOME}" >&2
  echo "      and call it through AIConnectorKit's connector protocol instead." >&2
  echo "" >&2
  echo "Offending occurrences:" >&2
  cat "${VIOL_FILE}" >&2
  exit 1
fi

if [[ -s "${OUTBOUND_VIOL_FILE}" ]]; then
  count="$(wc -l <"${OUTBOUND_VIOL_FILE}" | tr -d '[:space:]')"
  echo "FAIL: ${count} outbound NWConnection construction(s) in ${OUTBOUND_TARGETS[*]}." >&2
  echo "      That surface is INBOUND ONLY: an NWListener bound to 127.0.0.1 and the" >&2
  echo "      connections it accepts. A connection this process initiates leaves the" >&2
  echo "      app without passing the connector seam, so the 'external access never" >&2
  echo "      calls out' promise stops being provable. Accept connections from the" >&2
  echo "      listener instead of dialling one." >&2
  echo "" >&2
  echo "Offending occurrences:" >&2
  cat "${OUTBOUND_VIOL_FILE}" >&2
  exit 1
fi

if [[ -s "${PROCESS_VIOL_FILE}" ]]; then
  count="$(wc -l <"${PROCESS_VIOL_FILE}" | tr -d '[:space:]')"
  echo "FAIL: ${count} process-spawn reference(s) outside ${PROCESS_ALLOWED_FILE}." >&2
  echo "      A child process is egress the URLSession sweep cannot see — and it is" >&2
  echo "      arbitrary code execution on the user's machine. Exactly one file owns" >&2
  echo "      that power, because exactly one thing needs it: launching a stdio MCP" >&2
  echo "      server. If another surface genuinely must spawn, route it through" >&2
  echo "      ${PROCESS_ALLOWED_FILE} rather than widening this guard." >&2
  echo "" >&2
  echo "Offending occurrences:" >&2
  cat "${PROCESS_VIOL_FILE}" >&2
  exit 1
fi

# Corroboration only, never gating: shows the transport really does live in its
# one permitted home, and that the MCP listener really is present, so a reader
# can tell a clean tree from an empty one.
HOME_HITS="$(grep -rc 'URLSession' "${TRANSPORT_HOME}" 2>/dev/null | awk -F: '{ total += $2 } END { print total + 0 }')"
echo "    ${TRANSPORT_HOME} URLSession references: ${HOME_HITS}  [informational]"
if [[ "${#OUTBOUND_TARGETS[@]}" -gt 0 ]]; then
  LISTENER_HITS="$(grep -rcE 'NWListener[[:space:]]*\(' "${OUTBOUND_TARGETS[@]}" 2>/dev/null | awk -F: '{ total += $2 } END { print total + 0 }')"
  echo "    ${OUTBOUND_TARGETS[*]} NWListener constructions: ${LISTENER_HITS}  [informational]"
fi
echo ""
echo "PASS: no direct URLSession use outside ${TRANSPORT_HOME}."
if [[ "${#OUTBOUND_TARGETS[@]}" -gt 0 ]]; then
  echo "PASS: no outbound NWConnection construction in ${OUTBOUND_TARGETS[*]}."
fi
echo "PASS: no process spawn outside ${PROCESS_ALLOWED_FILE}."
exit 0
