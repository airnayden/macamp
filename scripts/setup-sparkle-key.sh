#!/usr/bin/env bash
#
# setup-sparkle-key.sh
#
# One-time (idempotent) setup of the EdDSA signing key Sparkle uses to sign
# MacAMP's update archives. This is a BUILD-TIME PREREQUISITE: the PUBLIC half
# is committed into the app's Info.plist (`SUPublicEDKey` — that exact spelling,
# see `macOS/Project.swift`), and `scripts/make-appcast.sh` needs the PRIVATE
# half in the login Keychain before it can sign anything. Run this BEFORE a
# release, never in the middle of one.
#
#   scripts/setup-sparkle-key.sh                # create-if-absent + export backup
#   scripts/setup-sparkle-key.sh --print-public # just print the public key
#   scripts/setup-sparkle-key.sh --dry-run      # print the plan, touch nothing
#
# Key handling rules (enforced here, not just documented):
#   * The private key lives ONLY in the login Keychain. It is never printed,
#     never passed on a command line, and never written inside this repo.
#     (Sparkle's deprecated `-s <private-key>` CLI flag is NOT used anywhere.)
#   * The backup export defaults to `~/MacAMP-sparkle-key-backup.txt` — OUTSIDE
#     the repository — and is created 0600. A path inside the repo is REFUSED.
#   * The backup is your only recovery path. Losing the key means every existing
#     install stops accepting updates (they verify against the embedded public
#     key). Move the backup into a password manager / escrow and delete the file.
#
# Usage:
#   scripts/setup-sparkle-key.sh [--dry-run] [--print-public] [--force-backup]
#                                [--no-backup] [--backup <path>] [--account <name>]
#
# Options:
#   --dry-run        Print exactly what would happen. ZERO Keychain access, no
#                    key generated, no file written.
#   --print-public   Print ONLY the base64 public key (safe to commit/paste into
#                    Info.plist) and exit. Nonzero if no key exists yet.
#   --backup <path>  Where to export the private-key backup
#                    (default: $HOME/MacAMP-sparkle-key-backup.txt).
#   --force-backup   Overwrite an existing backup file (default: keep it).
#   --no-backup      Skip the backup export entirely (NOT recommended).
#   --account <name> Keychain account for the key (default: Sparkle's own
#                    default, `ed25519`). Pass-through to generate_keys.
#
# Env:
#   SPARKLE_KEYS_BIN  Explicit path to Sparkle's `generate_keys` tool. Otherwise
#                     PATH and the usual SPM/Tuist artifact locations are searched.
#
# Exit codes:
#   0  success
#   1  bad arguments / refused unsafe backup path
#   2  generate_keys not found
#   3  generate_keys failed (key generation or lookup)
#   4  backup export failed
#   5  --print-public with no key in the Keychain
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DRY_RUN=0
PRINT_PUBLIC=0
DO_BACKUP=1
FORCE_BACKUP=0
BACKUP_PATH="${HOME}/MacAMP-sparkle-key-backup.txt"
ACCOUNT=""

die() { echo "error: $1" >&2; exit "${2:-1}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --print-public) PRINT_PUBLIC=1; shift ;;
    --no-backup) DO_BACKUP=0; shift ;;
    --force-backup) FORCE_BACKUP=1; shift ;;
    --backup) [[ $# -ge 2 ]] || die "--backup needs a path"; BACKUP_PATH="$2"; shift 2 ;;
    --account) [[ $# -ge 2 ]] || die "--account needs a name"; ACCOUNT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; s/^#$//'
      exit 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) die "unexpected argument: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# The backup must never land inside the repository (it is private key material
# and a stray `git add` would publish it). Compare canonical absolute paths, so
# `--backup ./x`, `--backup ../macamp/x` and symlinked temp dirs are all caught.
# ---------------------------------------------------------------------------
canonical_dir() {
  # `cd -P` resolves symlinks; the dir must already exist to be canonicalized.
  local dir="$1"
  if [[ -d "${dir}" ]]; then (cd -P "${dir}" && pwd); else echo "${dir}"; fi
}

assert_backup_outside_repo() {
  local dir base abs canon_repo
  dir="$(dirname "${BACKUP_PATH}")"
  base="$(basename "${BACKUP_PATH}")"
  [[ "${dir}" == /* ]] || dir="$(pwd)/${dir}"
  abs="$(canonical_dir "${dir}")/${base}"
  canon_repo="$(canonical_dir "${REPO_ROOT}")"
  case "${abs}" in
    "${canon_repo}"/*|"${canon_repo}")
      die "refusing to write the private-key backup inside the repo: ${abs}
       Choose a path outside ${canon_repo} (default: \$HOME/MacAMP-sparkle-key-backup.txt)." 1 ;;
  esac
  RESOLVED_BACKUP="${abs}"
}
assert_backup_outside_repo

# ---------------------------------------------------------------------------
# Locate Sparkle's `generate_keys`. Mirrors make-appcast.sh's search for
# `generate_appcast` (SPM vends both inside the resolved binary artifacts).
# ---------------------------------------------------------------------------
find_generate_keys() {
  local tool="${SPARKLE_KEYS_BIN:-}"
  if [[ -z "${tool}" ]] && command -v generate_keys >/dev/null 2>&1; then
    tool="$(command -v generate_keys)"
  fi
  if [[ -z "${tool}" ]]; then
    local root found
    for root in \
      "${REPO_ROOT}/Tuist/.build/artifacts" \
      "${REPO_ROOT}/Tuist/.build" \
      "${REPO_ROOT}/.build" \
      "${HOME}/Library/Developer/Xcode/DerivedData" \
      "${HOME}/Library/Caches/org.swift.swiftpm"; do
      [[ -d "${root}" ]] || continue
      found="$(find "${root}" -type f -name generate_keys -perm -111 2>/dev/null | head -n 1)"
      if [[ -n "${found}" ]]; then tool="${found}"; break; fi
    done
  fi
  echo "${tool}"
}

GENERATE_KEYS="$(find_generate_keys)"

ACCOUNT_ARGS=()
[[ -n "${ACCOUNT}" ]] && ACCOUNT_ARGS=(--account "${ACCOUNT}")

# Every generate_keys invocation goes through here. The `[@]+` guard is not
# decoration: macOS ships bash 3.2, where `"${arr[@]}"` on an EMPTY array is an
# "unbound variable" error under `set -u` — which is exactly the default case
# (no --account given).
run_generate_keys() {
  "${GENERATE_KEYS}" ${ACCOUNT_ARGS[@]+"${ACCOUNT_ARGS[@]}"} "$@"
}

# ---------------------------------------------------------------------------
# --dry-run: describe the plan. Nothing is read from or written to the Keychain,
# so this is safe in CI and safe to run repeatedly.
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "==> setup-sparkle-key DRY-RUN — no Keychain access, no files written"
  echo "    generate_keys:  ${GENERATE_KEYS:-<NOT FOUND — run 'tuist install' or 'brew install --cask sparkle'>}"
  echo "    keychain account: ${ACCOUNT:-ed25519 (Sparkle default)}"
  echo "    backup path:    ${RESOLVED_BACKUP}$([[ "${DO_BACKUP}" -eq 0 ]] && echo '  (skipped: --no-backup)')"
  echo "    repo root:      ${REPO_ROOT}  (backup is OUTSIDE it — verified)"
  echo ""
  echo "    Plan:"
  echo "      1. generate_keys -p            → does a signing key already exist?"
  echo "      2. if absent: generate_keys    → create it in the login Keychain"
  echo "         (the private key never leaves the Keychain; no -s flag is used)"
  if [[ "${DO_BACKUP}" -eq 1 ]]; then
    echo "      3. generate_keys -x '${RESOLVED_BACKUP}'  → private-key backup, chmod 0600"
    echo "         (skipped if that file already exists; --force-backup overwrites)"
  else
    echo "      3. (backup export skipped)"
  fi
  echo "      4. print the PUBLIC key for macOS/Project.swift → SUPublicEDKey"
  echo ""
  echo "DRY-RUN: nothing changed. Re-run without --dry-run to apply."
  exit 0
fi

[[ -n "${GENERATE_KEYS}" ]] || die "generate_keys not found. Set SPARKLE_KEYS_BIN=/path/to/generate_keys
       (Sparkle ships it; run 'tuist install' to resolve the package first,
        or 'brew install --cask sparkle'.) See docs/Distribution.md." 2

# Reads the existing public key, or returns nonzero when no key exists yet.
# Two independent checks, because `generate_keys -p` reports "No existing signing
# key found!" on STDOUT (not stderr): trust its exit status, and additionally
# reject anything that is not pure base64 so an error string can never be
# mistaken for a key and committed into Info.plist.
read_public_key() {
  local out
  out="$(run_generate_keys -p 2>/dev/null)" || return 1
  out="$(printf '%s' "${out}" | tr -d '[:space:]')"
  case "${out}" in
    ""|*[!A-Za-z0-9+/=]*) return 1 ;;
  esac
  printf '%s' "${out}"
}

# ---------------------------------------------------------------------------
# --print-public: machine-readable single-value output for scripts (release.sh)
# and for pasting into the Info.plist. Never touches the private key.
# ---------------------------------------------------------------------------
if [[ "${PRINT_PUBLIC}" -eq 1 ]]; then
  PUBLIC_KEY="$(read_public_key || true)"
  [[ -n "${PUBLIC_KEY}" ]] || die "no Sparkle signing key in the Keychain yet — run: scripts/setup-sparkle-key.sh" 5
  echo "${PUBLIC_KEY}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Idempotent setup.
# ---------------------------------------------------------------------------
echo "==> setup-sparkle-key — EdDSA signing key for Sparkle updates"
echo "    tool: ${GENERATE_KEYS}"

PUBLIC_KEY="$(read_public_key || true)"

if [[ -n "${PUBLIC_KEY}" ]]; then
  echo "    key:  already present in the login Keychain — nothing to generate"
else
  echo "    key:  none found — generating one (the Keychain may ask for permission)"
  if ! run_generate_keys >/dev/null; then
    die "generate_keys failed to create a signing key" 3
  fi
  PUBLIC_KEY="$(read_public_key || true)"
  [[ -n "${PUBLIC_KEY}" ]] || die "generate_keys reported success but no public key can be read back" 3
  echo "    key:  created"
fi

# ---------------------------------------------------------------------------
# Backup export. The exported file IS the private key — hence 0600, outside the
# repo, and an explicit escrow instruction.
# ---------------------------------------------------------------------------
BACKUP_STATE="skipped (--no-backup)"
if [[ "${DO_BACKUP}" -eq 1 ]]; then
  if [[ -e "${RESOLVED_BACKUP}" && "${FORCE_BACKUP}" -eq 0 ]]; then
    BACKUP_STATE="kept existing ${RESOLVED_BACKUP} (use --force-backup to overwrite)"
  else
    mkdir -p "$(dirname "${RESOLVED_BACKUP}")"
    # Staged through a 0700 temp dir, for two reasons: `generate_keys -x` REFUSES
    # to write to a path that already exists (so the file cannot be pre-created
    # 0600), and its own output is 0644 — writing straight to the destination
    # would leave the private key world-readable for the window before chmod.
    STAGE_DIR="$(mktemp -d)"
    if ! run_generate_keys -x "${STAGE_DIR}/key" >/dev/null; then
      rm -rf "${STAGE_DIR}"
      die "generate_keys -x failed to export the private-key backup" 4
    fi
    chmod 600 "${STAGE_DIR}/key"
    rm -f "${RESOLVED_BACKUP}"
    mv "${STAGE_DIR}/key" "${RESOLVED_BACKUP}"
    rm -rf "${STAGE_DIR}"
    BACKUP_STATE="written to ${RESOLVED_BACKUP} (mode 0600)"
  fi
fi

echo ""
echo "-- PUBLIC key (safe to commit — this is what ships in Info.plist):"
echo "   ${PUBLIC_KEY}"
echo ""
echo "-- Info.plist wiring (macOS/Project.swift → appInfoPlist):"
echo "     \"SUPublicEDKey\": \"${PUBLIC_KEY}\","
echo ""
echo "-- private-key backup: ${BACKUP_STATE}"
if [[ "${DO_BACKUP}" -eq 1 ]]; then
  echo ""
  echo "   !! ACTION REQUIRED — ESCROW THE BACKUP !!"
  echo "   That file contains the PRIVATE signing key. Store its contents in your"
  echo "   password manager (or your team's secret escrow) and then delete the file:"
  echo "       rm -P '${RESOLVED_BACKUP}'"
  echo "   If this key is lost, every installed copy of MacAMP stops accepting"
  echo "   updates — they only trust signatures made with this key."
fi
echo ""
echo "PASS: Sparkle signing key ready. scripts/make-appcast.sh can now sign archives."
exit 0
