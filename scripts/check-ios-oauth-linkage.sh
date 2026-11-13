#!/usr/bin/env bash
#
# check-ios-oauth-linkage.sh
#
# The iOS shell has NO subscription-OAuth surface: there is no `ExternalOAuth`
# buildable folder in `iOS/`, no sign-in UI, and no `ASWebAuthenticationSession`
# flow. So `macampiOS` must link no OAuth product. Adding one is not a wiring
# detail — it means shipping a login surface that does not exist yet, on a shell
# that is still work-in-progress — and this guard is what forces that to be a
# deliberate, reviewed act rather than a stray `.external(...)` line.
#
# `AIConnectorMCP` is held to the same rule for a sharper reason. The MCP client
# reaches servers the user configures — over HTTP, or by SPAWNING A CHILD
# PROCESS. iOS has no process spawning, no server-management UI, and no way for a
# user to review what they just connected to. Linking it there would compile,
# then fail at runtime or ship an unreviewable surface. See
# `.omo/plans/ai-chat-refinement.md` todo 11.
#
# HISTORY: this is the surviving third of `check-oauth-linkage.sh`, retired when
# the two macOS targets merged. That gate's other two assertions proved the
# App-Store-safe `macampMac` binary carried no OAuth code, with the
# `macampMac-projectM` binary as a negative control. MacAMP is never distributed
# through the App Store, so there is one macOS target and it links
# `AIConnectorKitOAuth` unconditionally — both assertions became meaningless, and
# with them the two full Release builds they required. This assertion did not:
# it is about iOS, and it is a pure source grep, so it lives in the cheap
# `portability-guard` job instead of its own build job.
#
#   exit 0  -> clean (iOS links no macOS-only AI product)
#   exit 1  -> iOS/Project.swift references a forbidden product
#   exit 2  -> iOS/Project.swift not found (run from a MacAMP checkout)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IOS_PROJECT="iOS/Project.swift"

cd "${REPO_ROOT}"

if [[ ! -f "${IOS_PROJECT}" ]]; then
  echo "error: ${IOS_PROJECT} not found (run from a MacAMP checkout)" >&2
  exit 2
fi

FORBIDDEN_PRODUCTS=(
  "AIConnectorKitOAuth"
  "AIConnectorMCP"
)

echo "==> iOS AI link gate: ${IOS_PROJECT} must reference none of: ${FORBIDDEN_PRODUCTS[*]}"

FAILED=0
for product in "${FORBIDDEN_PRODUCTS[@]}"; do
  # grep exits 1 when nothing matches — the PASS case — so guard against pipefail.
  matches="$(grep -Fn "${product}" "${IOS_PROJECT}" || true)"
  [[ -z "${matches}" ]] && continue

  FAILED=1
  echo ""
  echo "FAIL: ${IOS_PROJECT} references ${product}."
  case "${product}" in
  AIConnectorKitOAuth)
    echo "      The iOS shell has no OAuth login surface (no ExternalOAuth folder,"
    echo "      no sign-in UI), so it must link no OAuth product. If iOS is genuinely"
    echo "      gaining subscription sign-in, ship that surface first and update this"
    echo "      guard in the same change."
    ;;
  AIConnectorMCP)
    echo "      The iOS shell has no MCP surface: no server-management UI, no way to"
    echo "      review a configured server, and no process spawning at all. Linking"
    echo "      the MCP client there ships an unreviewable outbound path. If iOS is"
    echo "      genuinely gaining MCP, ship that surface first and update this guard"
    echo "      in the same change."
    ;;
  esac
  echo ""
  printf '%s\n' "${matches}"
done

if [[ "${FAILED}" -eq 1 ]]; then
  exit 1
fi

echo "PASS: ${IOS_PROJECT} links none of: ${FORBIDDEN_PRODUCTS[*]}"
exit 0
