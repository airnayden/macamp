#!/usr/bin/env bash
#
# check-frozen-track-columns.sh — MacAMP frozen-track-column guard
#
# Migration v12 FROZE four columns on the `track` table:
#
#     playCount   listenedCount   isFavourite   customPosition
#
# They are still physically in the schema (migrations are append-only — a
# shipped column is never dropped) but they are semantically DEAD. Every
# per-profile user-state read/write now goes through the `profileTrackState`
# junction table (ProfileTrackStateRecord, TrackRepository+ProfileState,
# ProfileScopedTrack). The invariant, from the engineering contract
# (".opencode/skills/macamp/SKILL.md", GRDB Migration Discipline):
#
#     "Never read or write the frozen `track` columns through a `TrackRecord`
#      instance again."
#
# This guard fails the build when new code reaches those columns ON THE `track`
# TABLE. It deliberately does NOT flag the identically-named — and entirely
# legitimate — properties of `profileTrackState`, `ProfileScopedTrack`, the
# `ProfileArchive*` payloads, or `folderTrackOrder`.
#
# HEURISTIC LINT (a conservative FLOOR, mirroring check-hardcoded-strings.sh):
# a line is a VIOLATION when, after the exclusions below, it matches any rule:
#
#   R1  TrackRecord.Columns.<frozen>
#       The GRDB column reference — how a query filters/orders on a track column.
#   R2  the line names `TrackRecord` AND performs a `.<frozen>` member access
#       e.g. `try TrackRecord.fetchOne(db, key: id)?.playCount`.
#   R3  a `track.<frozen>` qualified reference on a line carrying a SQL keyword
#       e.g. `WHERE track.isFavourite = 1`. The SQL-keyword requirement is what
#       separates raw SQL from a Swift local that merely happens to be named
#       `track` (those are `ProfileScopedTrack` values — legitimate).
#   R4  a SQL clause against the `track` table (FROM/INTO/UPDATE/JOIN track)
#       on the same line as a frozen column name.
#
# EXCLUSIONS (each is load-bearing, not a convenience):
#   * TrackRecord.swift — the record must keep DECLARING the columns; they still
#     exist in the schema. Freezing is about USE, not about the declaration.
#   * AppDatabase+Migrations.swift and AppDatabase+Migrations+Profiles.swift —
#     shipped migrations are append-only and NEVER edited. v7/v8/v11 created
#     these columns and the v12 `backfillGuestProfileState` SELECT is the one
#     sanctioned read of them (it seeds `profileTrackState` from the old values).
#   * AppDatabase+Migrations+CueTrack.swift — the v20 guarded `track` rebuild
#     must name all four in its rowid-preserving INSERT-SELECT. A rebuild that
#     omitted them would DROP them, destroying the v12 backfill's own source.
#     This is a carry-forward, not a read: nothing interprets the values.
#   * comment-only lines — prose ABOUT the frozen columns is documentation.
#   * PlayerCore/Tests — migration tests must assert on the frozen columns to
#     prove the v8/v12 behaviour; they are verification, not use.
#
# NOT COVERED (deliberate, single-line grep has no way to see it): raw SQL whose
# `FROM track` and frozen column land on DIFFERENT lines of one multi-line
# string. Reviewers still own that case.
#
#   exit 0  -> clean (no frozen-column usage)
#   exit 1  -> frozen-column usage found (file:line printed)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

# Shipping sources only. PlayerCore/Tests is excluded — see EXCLUSIONS above.
SCAN_DIRS=(
  "PlayerCore/Sources"
  "PlayerCore/TestSupport"
  "macOS/Sources"
  "iOS/Sources"
  "Sources"
)

# The four columns v12 froze.
FROZEN='playCount|listenedCount|isFavourite|customPosition'

# Files whose frozen-column references are sanctioned and immutable.
EXCLUDED_FILES=(
  "PlayerCore/Sources/Persistence/Records/TrackRecord.swift"
  "PlayerCore/Sources/Persistence/AppDatabase+Migrations.swift"
  "PlayerCore/Sources/Persistence/AppDatabase+Migrations+Profiles.swift"
  "PlayerCore/Sources/Persistence/AppDatabase+Migrations+CueTrack.swift"
)

VIOL_FILE="$(mktemp)"
trap 'rm -f "${VIOL_FILE}"' EXIT

is_excluded_file() {
  local path="$1" excluded
  for excluded in "${EXCLUDED_FILES[@]}"; do
    [[ "${path}" == "${excluded}" ]] && return 0
  done
  return 1
}

is_comment_line() {
  local comment_re='^[[:space:]]*(///|//|\*|/\*)'
  [[ "$1" =~ ${comment_re} ]]
}

has_sql_keyword() {
  local sql_re='(SELECT|INSERT|UPDATE|DELETE|FROM|WHERE|SET|VALUES|ORDER BY|GROUP BY|JOIN|CONFLICT)'
  [[ "$1" =~ ${sql_re} ]]
}

# Returns the rule name when the line content violates the freeze, else nothing.
classify() {
  local content="$1"
  local columns_re="TrackRecord\.Columns\.(${FROZEN})"
  local member_re="\.(${FROZEN})[^A-Za-z0-9_]"
  local qualified_re="[^A-Za-z0-9_]track\.(${FROZEN})[^A-Za-z0-9_]"
  local table_clause_re='(FROM|INTO|UPDATE|JOIN)[[:space:]]+track[^A-Za-z0-9_]'
  local frozen_re="[^A-Za-z0-9_](${FROZEN})[^A-Za-z0-9_]"

  # Anchor the member/qualified regexes by padding, so a match at either end of
  # the line still sees a delimiter (BSD/bash ERE has no lookaround).
  local padded=" ${content} "

  if [[ "${padded}" =~ ${columns_re} ]]; then
    echo "R1 GRDB column reference to a frozen track column"
    return
  fi
  if [[ "${padded}" == *TrackRecord* ]] && [[ "${padded}" =~ ${member_re} ]]; then
    echo "R2 member access to a frozen column on a TrackRecord"
    return
  fi
  if [[ "${padded}" =~ ${qualified_re} ]] && has_sql_keyword "${padded}"; then
    echo "R3 raw SQL reference to a frozen track.* column"
    return
  fi
  if [[ "${padded}" =~ ${table_clause_re} ]] && [[ "${padded}" =~ ${frozen_re} ]]; then
    echo "R4 SQL clause on the track table naming a frozen column"
    return
  fi
}

echo "==> frozen-track-column guard: scanning ${SCAN_DIRS[*]}"

for dir in "${SCAN_DIRS[@]}"; do
  [[ -d "${dir}" ]] || continue
  while IFS= read -r match; do
    [[ -z "${match}" ]] && continue
    file="${match%%:*}"
    rest="${match#*:}"
    line="${rest%%:*}"
    content="${rest#*:}"
    if is_excluded_file "${file}"; then continue; fi
    if is_comment_line "${content}"; then continue; fi
    rule="$(classify "${content}")"
    [[ -z "${rule}" ]] && continue
    printf '%s:%s: %s\n' "${file}" "${line}" "${rule}" >>"${VIOL_FILE}"
  done < <(grep -rnE --include='*.swift' "(${FROZEN})" "${dir}" 2>/dev/null || true)
done

if [[ -s "${VIOL_FILE}" ]]; then
  sort -u "${VIOL_FILE}"
  count="$(sort -u "${VIOL_FILE}" | wc -l | tr -d '[:space:]')"
  echo ""
  echo "FAIL: ${count} use(s) of a frozen track column found." >&2
  echo "      Migration v12 froze track.playCount / listenedCount /" >&2
  echo "      isFavourite / customPosition. Read and write per-profile state" >&2
  echo "      through profileTrackState instead — see" >&2
  echo "      TrackRepository+ProfileState and ProfileScopedTrack." >&2
  exit 1
fi

echo "PASS: no frozen track column usage found."
exit 0
