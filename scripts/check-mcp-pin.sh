#!/usr/bin/env bash
#
# check-mcp-pin.sh
#
# The MCP Swift SDK is pinned EXACT, and it is now pinned in TWO places that
# resolve independently:
#
#   Tuist/Package.swift          -> Tuist/Package.resolved          (the app graph)
#   AIConnectorKit/Package.swift -> AIConnectorKit/Package.resolved (the package graph)
#
# Nothing makes those two agree on its own. `swift build --package-path
# AIConnectorKit` resolves the nested package alone, `tuist install` resolves the
# app's, and each writes its own lockfile — so a bump applied to one manifest
# leaves the other silently on the old revision. MCP is a WIRE FORMAT with dated,
# backwards-incompatible spec revisions, so two halves of one app negotiating two
# different protocol versions is a real failure, and an entirely quiet one: both
# halves compile, both link, and the disagreement only appears against a client
# nobody tested.
#
# Three assertions, because the first two alone would only photograph today:
#
#   1. Both manifests declare the SDK with `exact:` at ${EXPECTED_VERSION}. A
#      `from:` would satisfy assertion 2 today and drift on the next resolve.
#   2. Both lockfiles report version ${EXPECTED_VERSION}.
#   3. Both lockfiles report the SAME revision — a moved tag passes 1 and 2 while
#      shipping different code on either side.
#
#   exit 0  -> clean (both halves pinned to the same SDK, exactly)
#   exit 1  -> pin drift
#   exit 2  -> a manifest or lockfile is missing (run from a MacAMP checkout)
set -euo pipefail

EXPECTED_VERSION="0.12.1"
SDK_IDENTITY="swift-sdk"
SDK_URL="https://github.com/modelcontextprotocol/swift-sdk"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

MANIFESTS=(
  "Tuist/Package.swift"
  "AIConnectorKit/Package.swift"
)
LOCKFILES=(
  "Tuist/Package.resolved"
  "AIConnectorKit/Package.resolved"
)

for file in "${MANIFESTS[@]}" "${LOCKFILES[@]}"; do
  if [[ ! -f "${file}" ]]; then
    echo "error: ${file} not found (run from a MacAMP checkout)" >&2
    exit 2
  fi
done

echo "==> MCP pin guard: ${SDK_IDENTITY} must be exactly ${EXPECTED_VERSION} on both sides"

failed=0

# ── 1. Both manifests must say `exact:` ──────────────────────────────────────
for manifest in "${MANIFESTS[@]}"; do
  # grep exits 1 when nothing matches — a FAIL here, but handled below rather
  # than by `set -e`, so every manifest is reported in one run.
  line="$(grep -F "${SDK_URL}" "${manifest}" || true)"
  if [[ -z "${line}" ]]; then
    echo "FAIL: ${manifest} declares no ${SDK_URL} dependency."
    failed=1
    continue
  fi
  if [[ "${line}" != *"exact: \"${EXPECTED_VERSION}\""* ]]; then
    echo "FAIL: ${manifest} must pin the SDK with exact: \"${EXPECTED_VERSION}\"."
    echo "      found: ${line# }"
    failed=1
  fi
done

# ── 2 + 3. Both lockfiles must report that version, at one shared revision ───
# Parsed as JSON rather than grepped: a lockfile is a generated document whose
# key order is SwiftPM's to change, and a drift guard that reads it positionally
# is a guard that fails open.
read_pin() {
  python3 -c '
import json, sys
path, identity = sys.argv[1], sys.argv[2]
with open(path) as handle:
    document = json.load(handle)
pins = document.get("pins", document.get("object", {}).get("pins", []))
for pin in pins:
    if pin.get("identity") == identity:
        state = pin.get("state", {})
        print(state.get("version", ""), state.get("revision", ""))
        sys.exit(0)
sys.exit(3)
' "$1" "${SDK_IDENTITY}"
}

declare -a revisions=()
for lockfile in "${LOCKFILES[@]}"; do
  if ! pin="$(read_pin "${lockfile}")"; then
    echo "FAIL: ${lockfile} contains no pin for '${SDK_IDENTITY}'."
    failed=1
    continue
  fi
  version="${pin%% *}"
  revision="${pin##* }"
  if [[ "${version}" != "${EXPECTED_VERSION}" ]]; then
    echo "FAIL: ${lockfile} reports ${SDK_IDENTITY} ${version}, expected ${EXPECTED_VERSION}."
    failed=1
  fi
  revisions+=("${revision}")
  echo "     ${lockfile}: ${version} @ ${revision}"
done

if [[ "${#revisions[@]}" -eq 2 && "${revisions[0]}" != "${revisions[1]}" ]]; then
  echo "FAIL: the two lockfiles agree on ${EXPECTED_VERSION} but pin DIFFERENT revisions."
  echo "      ${LOCKFILES[0]}: ${revisions[0]}"
  echo "      ${LOCKFILES[1]}: ${revisions[1]}"
  echo "      A tag moved. Re-resolve both halves against one revision."
  failed=1
fi

if [[ "${failed}" -ne 0 ]]; then
  echo ""
  echo "The MCP SDK pin must be identical in the app graph and the package graph."
  echo "To bump it deliberately: edit BOTH manifests, re-run 'tuist install' and"
  echo "'swift build --package-path AIConnectorKit', then update EXPECTED_VERSION"
  echo "at the top of this script in the same commit."
  exit 1
fi

echo "PASS: ${SDK_IDENTITY} ${EXPECTED_VERSION} pinned exactly, one revision, both sides."
exit 0
