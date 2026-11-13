#!/usr/bin/env bash
#
# check-playercore-portability.sh
#
# PlayerCore is the platform-agnostic shared core of MacAMP. It is compiled
# verbatim into the macOS app, the iOS app and the Widget extension, so it MUST
# NOT import any platform-UI framework (AppKit on macOS, UIKit on iOS).
#
# AIConnectorKit is held to the same rule for the same reason: it is a reusable
# package meant to lift into another app unchanged, and its bridge target is
# compiled into both shells.
#
# This guard greps every Swift source under those source roots and fails the
# build if it finds `import AppKit` or `import UIKit`. It is wired into CI as a
# HARD failure (never continue-on-error): the shared-core invariant is
# load-bearing for cross-platform reuse.
#
#   exit 0  -> clean (no AppKit/UIKit imports)
#   exit 1  -> portability violation found (offending file:line printed)
#   exit 2  -> PlayerCore/Sources directory not found
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_DIR="PlayerCore/Sources"
# Additional portable source roots. Absent directories are skipped, so a
# checkout that predates a package still passes rather than erroring out.
EXTRA_DIRS=(
  "AIConnectorKit/Sources"
)

cd "${REPO_ROOT}"

if [[ ! -d "${TARGET_DIR}" ]]; then
  echo "error: ${TARGET_DIR} not found (run from a MacAMP checkout)" >&2
  exit 2
fi

SCAN_DIRS=("${TARGET_DIR}")
for dir in "${EXTRA_DIRS[@]}"; do
  [[ -d "${dir}" ]] && SCAN_DIRS+=("${dir}")
done

echo "==> PlayerCore portability guard: scanning ${SCAN_DIRS[*]} for AppKit/UIKit imports"

# Match only REAL import statements: `import` must be the first non-whitespace
# token on the line (optionally preceded by an attribute like @_exported). This
# anchoring is what prevents false positives on comments that merely mention the
# invariant, e.g. `// MUST NOT import AppKit or UIKit`. The trailing class stops
# `import AppKit`, `import AppKit.NSView`, and `  import UIKit` from leaking by
# while not matching a hypothetical `AppKitShim` identifier.
# grep exits 1 when nothing matches — the PASS case — so guard against pipefail.
matches="$(grep -rnE --include='*.swift' \
  '^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+(AppKit|UIKit)([[:space:]]|\.|$)' \
  "${SCAN_DIRS[@]}" || true)"

if [[ -n "${matches}" ]]; then
  echo ""
  echo "FAIL: PlayerCore and AIConnectorKit must not import AppKit or UIKit."
  echo "      Move platform-UI code into the macOS / iOS / Widget shells instead."
  echo ""
  echo "Offending occurrences:"
  printf '%s\n' "${matches}"
  exit 1
fi

echo "PASS: no AppKit/UIKit imports in ${SCAN_DIRS[*]}."
exit 0
