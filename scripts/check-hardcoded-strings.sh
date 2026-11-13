#!/usr/bin/env bash
#
# check-hardcoded-strings.sh — MacAMP no-hardcoded-text guard
#
# MacAMP ships ZERO hardcoded user-facing text: every user-visible string is
# resolved through a String Catalog (.xcstrings) via String(localized:) /
# LocalizedStringKey. This guard fails the build when user-facing SwiftUI copy is
# hardcoded as a plain Swift string literal instead.
#
# HEURISTIC LINT (intentionally conservative to avoid false positives):
#   A quoted argument to a user-facing initializer/modifier is a VIOLATION when it
#   "looks user-visible" — i.e. it contains a space OR starts with an uppercase
#   letter. Catalog keys ("library.playAll"), SF Symbol names ("play.fill"), the
#   "MacAMP" brand, verbatim text (Text(verbatim:)) and String(format:) are allowed.
#
# SCANNED initializers / modifiers (Swift sources under the app/widget shells):
#   Text  Button  Label  Toggle  TextField  SecureField  Picker  Menu  Link
#   Section  Stepper  .navigationTitle  .navigationSubtitle  .accessibilityLabel
#   .accessibilityHint  .accessibilityValue  .help  .alert  .confirmationDialog
#   title:  message:  prompt:
#
# This scanner is a CONSERVATIVE FLOOR, not an exhaustive ceiling: the rule
# ("every user-facing string is translatable") applies to EVERY surface a user
# can read — tooltips, form controls, toolbar/menu items, AppKit strings, and any
# custom view that renders a passed-in String — even where this heuristic is
# silent. See ".opencode/skills/macamp/SKILL.md" (Localization) for the full rule.
#
# ALLOWED (never flagged):
#   Text(verbatim: "…")        — non-translatable tokens
#   Text(String(format: …))    — composed/formatted strings
#   "MacAMP"                    — non-localized brand (allowlist)
#   "library.playAll" etc.     — dotted catalog keys (lowercase, dotted, no spaces)
#   "play.fill" etc.           — SF Symbol names (allowlist + dotted heuristic)
#
#   exit 0  -> clean (no hardcoded user-facing literals)
#   exit 1  -> hardcoded user-facing string literal(s) found (file:line printed)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

# Directories that contain shippable app / widget UI source, plus the
# AIConnectorKit package: connector copy must be key-based
# LocalizedStringResource only, since the package ships no String Catalog of its
# own and the shells resolve every key it returns.
SCAN_DIRS=(
  "macOS/Sources"
  "iOS/Sources"
  "Widget/Sources"
  "AIConnectorKit/Sources"
)

# Non-localized brand — always allowed as a bare literal.
BRAND="MacAMP"

# Common SF Symbol names. SF Symbols are lowercase + dotted so the key heuristic
# already passes them, but an explicit allowlist documents intent and covers edges.
SF_SYMBOLS=(
  "play" "play.fill" "pause" "pause.fill" "stop" "stop.fill"
  "forward.fill" "backward.fill" "forward.end.fill" "backward.end.fill"
  "shuffle" "repeat" "repeat.1" "speaker.fill" "speaker.slash.fill"
  "speaker.wave.1.fill" "speaker.wave.2.fill" "speaker.wave.3.fill"
  "list.bullet" "music.note" "music.note.list" "music.mic"
  "plus" "plus.circle" "plus.circle.fill" "minus" "minus.circle"
  "trash" "trash.fill" "xmark" "xmark.circle.fill" "checkmark"
  "magnifyingglass" "ellipsis" "ellipsis.circle" "gearshape" "gearshape.fill"
  "slider.horizontal.3" "heart" "heart.fill" "star" "star.fill"
  "folder" "folder.fill" "chevron.right" "chevron.left" "chevron.down" "chevron.up"
  "arrow.clockwise" "arrow.up" "arrow.down" "info.circle" "exclamationmark.triangle"
)

# grep candidate pattern  |||  bash extraction regex (LAST capture group = literal).
# The "|||" delimiter is safe: no ERE pattern below uses alternation as a payload.
# Word-initial constructs (Text/Button/Label/title:/message:) carry a leading
# non-word boundary in the EXTRACTION regex so e.g. `accessibilityLabel("…")` is
# NOT mis-captured by the bare `Label(` handler, and `subtitle:` is not captured
# by the `title:` handler. The grep pass stays loose; extraction is the validator.
HANDLERS=(
  'Text\("|||(^|[^A-Za-z0-9_])Text\("([^"]*)"'
  'Button\("|||(^|[^A-Za-z0-9_])Button\("([^"]*)"'
  'Label\("|||(^|[^A-Za-z0-9_])Label\("([^"]*)"'
  'Toggle\("|||(^|[^A-Za-z0-9_])Toggle\("([^"]*)"'
  'TextField\("|||(^|[^A-Za-z0-9_])TextField\("([^"]*)"'
  'SecureField\("|||(^|[^A-Za-z0-9_])SecureField\("([^"]*)"'
  'Picker\("|||(^|[^A-Za-z0-9_])Picker\("([^"]*)"'
  'Menu\("|||(^|[^A-Za-z0-9_])Menu\("([^"]*)"'
  'Link\("|||(^|[^A-Za-z0-9_])Link\("([^"]*)"'
  'Section\("|||(^|[^A-Za-z0-9_])Section\("([^"]*)"'
  'Stepper\("|||(^|[^A-Za-z0-9_])Stepper\("([^"]*)"'
  '\.navigationTitle\("|||\.navigationTitle\("([^"]*)"'
  '\.navigationSubtitle\("|||\.navigationSubtitle\("([^"]*)"'
  '\.accessibilityLabel\("|||\.accessibilityLabel\("([^"]*)"'
  '\.accessibilityHint\("|||\.accessibilityHint\("([^"]*)"'
  '\.accessibilityValue\("|||\.accessibilityValue\("([^"]*)"'
  '\.help\("|||\.help\("([^"]*)"'
  '\.alert\("|||\.alert\("([^"]*)"'
  '\.confirmationDialog\("|||\.confirmationDialog\("([^"]*)"'
  'title:[[:space:]]*"|||(^|[^A-Za-z0-9_])title:[[:space:]]*"([^"]*)"'
  'message:[[:space:]]*"|||(^|[^A-Za-z0-9_])message:[[:space:]]*"([^"]*)"'
  'prompt:[[:space:]]*"|||(^|[^A-Za-z0-9_])prompt:[[:space:]]*"([^"]*)"'
)

VIOL_FILE="$(mktemp)"
trap 'rm -f "${VIOL_FILE}"' EXIT

is_allowlisted() {
  local s="$1"
  [[ "${s}" == "${BRAND}" ]] && return 0
  local sym
  for sym in "${SF_SYMBOLS[@]}"; do
    [[ "${s}" == "${sym}" ]] && return 0
  done
  return 1
}

looks_like_key() {
  # lowercase first char, >=1 dotted segment, no spaces, only [A-Za-z0-9._]
  local key_re='^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)+$'
  [[ "$1" =~ ${key_re} ]]
}

looks_user_visible() {
  local s="$1"
  local upper_re='^[A-Z]'
  [[ "${s}" == *" "* ]] && return 0       # contains a space
  [[ "${s}" =~ ${upper_re} ]] && return 0  # starts uppercase
  return 1
}

echo "==> no-hardcoded-text guard: scanning ${SCAN_DIRS[*]}"

for dir in "${SCAN_DIRS[@]}"; do
  [[ -d "${dir}" ]] || continue
  for handler in "${HANDLERS[@]}"; do
    grep_pat="${handler%%|||*}"
    extract_re="${handler##*|||}"
    while IFS= read -r match; do
      [[ -z "${match}" ]] && continue
      file="${match%%:*}"
      rest="${match#*:}"
      line="${rest%%:*}"
      content="${rest#*:}"
      if [[ "${content}" =~ ${extract_re} ]]; then
        nmatch="${#BASH_REMATCH[@]}"
        literal="${BASH_REMATCH[$((nmatch - 1))]}"
      else
        continue
      fi
      [[ -z "${literal}" ]] && continue
      if is_allowlisted "${literal}"; then continue; fi
      if looks_like_key "${literal}"; then continue; fi
      if looks_user_visible "${literal}"; then
        printf '%s:%s: hardcoded user-facing string: "%s"\n' \
          "${file}" "${line}" "${literal}" >>"${VIOL_FILE}"
      fi
    done < <(grep -rnE --include='*.swift' "${grep_pat}" "${dir}" 2>/dev/null || true)
  done
done

if [[ -s "${VIOL_FILE}" ]]; then
  sort -u "${VIOL_FILE}"
  count="$(sort -u "${VIOL_FILE}" | wc -l | tr -d '[:space:]')"
  echo ""
  echo "FAIL: ${count} hardcoded user-facing string literal(s) found." >&2
  echo "      Route copy through a String Catalog: use String(localized:) /" >&2
  echo "      LocalizedStringKey, or Text(verbatim: ...) for non-translatable" >&2
  echo "      tokens (e.g. the \"MacAMP\" brand)." >&2
  exit 1
fi

echo "PASS: no hardcoded user-facing string literals found."
exit 0
