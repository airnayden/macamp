#!/usr/bin/env bash
#
# check-l10n-render-sites.sh — MacAMP render-site localization gate
#
# `check-hardcoded-strings.sh` asks "is this copy a bare literal?". It cannot ask
# the *next* question: "does the key this surface renders actually REACH the
# String Catalog?" A `LocalizedStringResource` whose key is absent from
# `Localizable.xcstrings` compiles, lints clean, and silently falls back to its
# English `defaultValue` in all seven languages. Presence was being checked;
# coverage never was.
#
# This guard closes that gap for ONE SURFACE AT A TIME (default:
# `macOS/Sources/Downloads`), because a surface is the unit a human can actually
# finish. It works in three passes:
#
#   1. SYMBOLS — parse every `static let|var|func <member>` whose initializer or
#      body constructs `LocalizedStringResource("<key>"…)` out of the whole macOS
#      shell, recorded under its ENCLOSING type (`enum X` / `extension X`). The
#      table is shell-wide on purpose: a Downloads view may legitimately render a
#      symbol declared in `MacAMPStrings.swift` or any other `*Strings.swift`, and
#      a symbol table that stops at the surface boundary silently resolves those
#      to nothing.
#   2. RENDER SITES — scan ONLY the surface's own `*.swift` files for QUALIFIED
#      references `<Type>.<member>`, plus any key literal written inline in the
#      surface itself.
#   3. CATALOG — assert every rendered key exists in the catalog carrying all
#      REQUIRED_LOCALES with a non-empty value.
#
# TWO MEASUREMENT AXES THAT ARE KNOWN-BROKEN AND ARE NOT USED HERE
# (both recorded in `.omo/notepads/youtube-downloader/issues.md`):
#
#   * PREFIX / NAMESPACE FILTERING. A key's namespace is NOT its surface.
#     `app.folder.export.json` is rendered by the folder context menu IN THE
#     SIDEBAR while living in the `app.folder.*` namespace, so an
#     `app.sidebar.*` prefix audit reported "0 missing" over a string that was
#     photographed rendering in English. This guard therefore does NO prefix
#     matching of any kind — the surface is a DIRECTORY, never a key prefix.
#
#   * UNQUALIFIED SYMBOL SCANS. Matching a bare `\b<member>\b` collides with
#     ordinary identifiers (17+ false positives in the recorded prototype), so
#     only the QUALIFIED form `<Type>.<member>` counts. A leading-dot inferred
#     reference (`Text(.someKey)`) is deliberately NOT matched: silence beats a
#     false alarm in a gate that must stay at exit 0.
#
# USAGE
#   scripts/check-l10n-render-sites.sh [surface-dir …]
#
#   With no arguments the default surface is `macOS/Sources/Downloads`.
#   Paths are repo-relative (or absolute); a directory that does not exist is a
#   hard failure, so a renamed surface cannot silently stop being checked.
#
#   exit 0  -> every key this surface renders is in the catalog, fully localized
#   exit 1  -> at least one rendered key is missing (printed as
#              `MISSING <key> (<file:line>)`)
#   exit 2  -> the guard could not run (bad argument, missing catalog, no python3)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

# The surface scanned when the caller names none.
DEFAULT_SURFACE="macOS/Sources/Downloads"

# Roots the SYMBOL TABLE is built from. Deliberately the whole shell, not the
# surface: see pass 1 above.
DECLARATION_ROOTS=(
  "macOS/Sources"
)

# The catalog the macOS shell resolves at runtime.
CATALOG="macOS/Sources/Localizable.xcstrings"

# The seven shipped locales. `pseudo` is a pseudolocalization aid, NOT a shipped
# language, and is deliberately NOT required — demanding it would turn a
# translation-QA tool into a release blocker.
REQUIRED_LOCALES="en bg de es fr it ru"

if [[ $# -gt 0 ]]; then
  SURFACE_DIRS=("$@")
else
  SURFACE_DIRS=("${DEFAULT_SURFACE}")
fi

for dir in "${SURFACE_DIRS[@]}"; do
  if [[ ! -d "${dir}" ]]; then
    echo "FAIL: surface directory not found: ${dir}" >&2
    echo "      Pass repo-relative directories, e.g. macOS/Sources/Downloads" >&2
    exit 2
  fi
done

if [[ ! -f "${CATALOG}" ]]; then
  echo "FAIL: string catalog not found: ${CATALOG}" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is required to read ${CATALOG} (a JSON document)." >&2
  echo "      plutil cannot query it: its keypaths are dot-separated and the" >&2
  echo "      catalog's own keys contain dots." >&2
  exit 2
fi

echo "==> render-site l10n guard: surface ${SURFACE_DIRS[*]}"
echo "    symbols from ${DECLARATION_ROOTS[*]} · catalog ${CATALOG}"
echo "    required locales: ${REQUIRED_LOCALES}"

# The three passes live in one python program because pass 3 has to read JSON,
# and a hand-rolled JSON reader in awk is a worse dependency than python3 (which
# this repo already prescribes for .xcstrings work — see SKILL.md, "xcstrings
# Validation"). Configuration crosses the boundary through the environment so no
# path needs shell quoting.
CATALOG="${CATALOG}" \
REQUIRED_LOCALES="${REQUIRED_LOCALES}" \
DECLARATION_ROOTS="$(printf '%s\n' "${DECLARATION_ROOTS[@]}")" \
SURFACE_DIRS="$(printf '%s\n' "${SURFACE_DIRS[@]}")" \
python3 - <<'PYTHON'
import json
import os
import re
import sys

CATALOG = os.environ["CATALOG"]
REQUIRED = os.environ["REQUIRED_LOCALES"].split()
DECL_ROOTS = [p for p in os.environ["DECLARATION_ROOTS"].splitlines() if p]
SURFACE_DIRS = [p for p in os.environ["SURFACE_DIRS"].splitlines() if p]

TYPE_RE = re.compile(
    r"^\s*(?:(?:public|internal|private|fileprivate|final|indirect)\s+)*"
    r"(?:enum|struct|extension|class|actor)\s+([A-Z][A-Za-z0-9_]*)"
)
MEMBER_RE = re.compile(
    r"^\s*(?:(?:public|internal|private|fileprivate|nonisolated)\s+)*"
    r"static\s+(?:let|var|func)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
# A qualified render site: `SomeType.someMember`. The uppercase-initial receiver
# is what separates a namespace from an instance (`error.message`), and the
# member is matched whole so `X.abc` never matches a declaration of `X.abcdef`.
QUALIFIED_RE = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\b")
# The constructors that take a catalog key as their first argument.
KEYED_INIT_RE = re.compile(
    r"(?:LocalizedStringResource|LocalizedStringKey)\s*\(|String\s*\(\s*localized:"
)
LEADING_STRING_RE = re.compile(r'^\s*"([^"\\]+)"')
# A catalog key: dotted, no whitespace. Rejects prose default values that happen
# to sit in first position.
KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$")


def code_only(line):
    """`line` with string literals and the trailing line comment removed.

    Brace counting, type matching and qualified-reference matching all run on
    this so a brace or a dotted phrase inside an English `defaultValue:` cannot
    move the type stack or invent a render site.
    """
    out = []
    i = 0
    n = len(line)
    in_string = False
    while i < n:
        ch = line[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            i += 1
            continue
        if ch == "/" and i + 1 < n and line[i + 1] == "/":
            break
        out.append(ch)
        i += 1
    return "".join(out)


def swift_files(roots):
    seen = set()
    for root in roots:
        for base, dirs, names in os.walk(root):
            dirs.sort()
            for name in sorted(names):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(base, name)
                if path not in seen:
                    seen.add(path)
                    yield path


def key_at(lines, index, after):
    """The catalog key a keyed initializer opens, same line or the next one."""
    tail = lines[index][after:]
    match = LEADING_STRING_RE.match(tail)
    if match is None:
        probe = index + 1
        while probe < len(lines) and not lines[probe].strip():
            probe += 1
        if probe >= len(lines):
            return None, None
        match = LEADING_STRING_RE.match(lines[probe])
        if match is None:
            return None, None
        index = probe
    key = match.group(1)
    return (key, index + 1) if KEY_RE.match(key) else (None, None)


# ---------------------------------------------------------------------------
# Pass 1 — the symbol table: (Type, member) -> {catalog key, …}
# ---------------------------------------------------------------------------
symbols = {}
# (path, 1-based line) of every key literal that IS a declaration, so pass 2 does
# not re-count a `*Strings.swift` declaration as though the file rendered it.
declaration_sites = set()

for path in swift_files(DECL_ROOTS):
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    depth = 0
    stack = []  # (type name, depth at its opening brace)
    member = None

    for index, raw in enumerate(lines):
        code = code_only(raw)

        type_match = TYPE_RE.match(code)
        pending_type = type_match.group(1) if type_match else None

        member_match = MEMBER_RE.match(code)
        if member_match and stack:
            member = member_match.group(1)

        for hit in KEYED_INIT_RE.finditer(raw):
            key, key_line = key_at(lines, index, hit.end())
            if key is None:
                continue
            if stack and member is not None:
                symbols.setdefault((stack[-1][0], member), set()).add(key)
                declaration_sites.add((path, key_line))

        for ch in code:
            if ch == "{":
                depth += 1
                if pending_type is not None:
                    stack.append((pending_type, depth))
                    pending_type = None
                    member = None
            elif ch == "}":
                while stack and stack[-1][1] == depth:
                    stack.pop()
                    member = None
                depth -= 1

# ---------------------------------------------------------------------------
# Pass 2 — render sites inside the surface only
# ---------------------------------------------------------------------------
rendered = {}  # key -> "file:line" of its FIRST render site (stable output)
scanned_files = 0

for path in swift_files(SURFACE_DIRS):
    scanned_files += 1
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    for index, raw in enumerate(lines):
        site = "%s:%d" % (path, index + 1)

        for owner, name in QUALIFIED_RE.findall(code_only(raw)):
            for key in symbols.get((owner, name), ()):
                rendered.setdefault(key, site)

        for hit in KEYED_INIT_RE.finditer(raw):
            key, key_line = key_at(lines, index, hit.end())
            if key is None:
                continue
            if (path, key_line) in declaration_sites:
                continue
            rendered.setdefault(key, "%s:%d" % (path, key_line))

# ---------------------------------------------------------------------------
# Pass 3 — the catalog assertion
# ---------------------------------------------------------------------------
try:
    with open(CATALOG, "r", encoding="utf-8") as handle:
        catalog = json.load(handle)
except (OSError, ValueError) as error:
    sys.stderr.write("FAIL: could not read %s: %s\n" % (CATALOG, error))
    raise SystemExit(2)

entries = catalog.get("strings", {})


def unlocalized(entry):
    """Required locales this entry does not carry with real text."""
    if entry.get("shouldTranslate") is False:
        return []
    localizations = entry.get("localizations") or {}
    gaps = []
    for locale in REQUIRED:
        unit = localizations.get(locale)
        if not isinstance(unit, dict):
            gaps.append(locale)
            continue
        # A plural/device-varied entry carries its text under `variations`
        # instead of a flat `stringUnit`; both are real localizations.
        if unit.get("variations"):
            continue
        value = (unit.get("stringUnit") or {}).get("value")
        if not value:
            gaps.append(locale)
    return gaps


violations = []
for key in sorted(rendered):
    entry = entries.get(key)
    if entry is None:
        violations.append("MISSING %s (%s)" % (key, rendered[key]))
        continue
    gaps = unlocalized(entry)
    if gaps:
        violations.append(
            "MISSING %s (%s) [locales: %s]" % (key, rendered[key], ",".join(gaps))
        )

print(
    "    %d symbol(s) declared · %d file(s) scanned · %d key(s) rendered"
    % (len(symbols), scanned_files, len(rendered))
)

if violations:
    print("")
    for line in violations:
        print(line)
    # stdout is block-buffered through a pipe while stderr is not, so without
    # this the FAIL banner lands ABOVE the list it is summarizing in a CI log.
    sys.stdout.flush()
    sys.stderr.write("\nFAIL: %d rendered key(s) missing from %s.\n" % (len(violations), CATALOG))
    sys.stderr.write(
        "      Add each key to the catalog with all required locales "
        "(%s).\n" % ", ".join(REQUIRED)
    )
    sys.stderr.write(
        "      A key absent from the catalog renders its English defaultValue "
        "in every language.\n"
    )
    raise SystemExit(1)

print("PASS: every key this surface renders is in the catalog, fully localized.")
PYTHON
