#!/bin/bash
#
# MacAMP installer for macOS (Apple silicon).
#
#   curl -fsSL https://downloads.macamp.si/install.sh | bash
#
# Downloads the latest release from downloads.macamp.si, checks its SHA-256,
# copies MacAMP.app into /Applications (replacing an older copy) and opens it.
# Nothing else is installed or changed. Read before you run: this file is
# scripts/install.sh in https://github.com/airnayden/macamp.
#
# Options (pass after `bash -s --`):
#   --no-open            don't launch MacAMP afterwards
#   --dir <path>         install somewhere other than /Applications
#
# Copyright (C) 2026 Nayden Panchev. GPL-3.0-or-later, see LICENSE and NOTICE.

set -euo pipefail

main() {
    local base="https://downloads.macamp.si"
    local install_dir="/Applications"
    local open_app=1

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-open) open_app=0; shift ;;
            --dir) [[ $# -ge 2 ]] || fail "--dir needs a path"; install_dir="$2"; shift 2 ;;
            *) fail "unknown option: $1" ;;
        esac
    done

    say "MacAMP installer"

    [[ "$(uname -s)" == "Darwin" ]] || fail "MacAMP runs on macOS only."
    [[ "$(uname -m)" == "arm64" ]] || fail "MacAMP needs a Mac with Apple silicon (M1 or newer)."

    # Globals, not locals: the EXIT trap runs after main has returned.
    MOUNT_POINT=""
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macamp-install.XXXXXX")"
    trap cleanup EXIT
    local tmp="${WORK_DIR}"

    step "Checking the latest version"
    curl -fsSL --retry 3 "${base}/latest.json" -o "${tmp}/latest.json" \
        || fail "couldn't reach ${base}. Check your connection and try again."
    local version url sha256 min_os
    version="$(json version "${tmp}/latest.json")"
    url="$(json url "${tmp}/latest.json")"
    sha256="$(json sha256 "${tmp}/latest.json")"
    min_os="$(json minimumSystemVersion "${tmp}/latest.json")"
    [[ -n "${version}" && -n "${url}" && -n "${sha256}" ]] || fail "the release manifest is incomplete; try again later."
    case "${url}" in "${base}/"*) ;; *) fail "unexpected download location: ${url}" ;; esac

    local os
    os="$(sw_vers -productVersion)"
    if ! version_at_least "${os}" "${min_os:-14.0}"; then
        fail "MacAMP ${version} needs macOS ${min_os} or later; this Mac has ${os}."
    fi
    say "  MacAMP ${version} for macOS ${min_os}+ (you have ${os})"

    step "Downloading"
    curl -fL --retry 3 --progress-bar "${url}" -o "${tmp}/MacAMP.dmg" \
        || fail "download failed; try again."
    local actual
    actual="$(shasum -a 256 "${tmp}/MacAMP.dmg" | awk '{print $1}')"
    [[ "${actual}" == "${sha256}" ]] || fail "checksum mismatch (expected ${sha256}, got ${actual}). Nothing was installed."
    say "  checksum OK"

    step "Installing to ${install_dir}"
    MOUNT_POINT="${tmp}/mnt"
    mkdir -p "${MOUNT_POINT}"
    hdiutil attach "${tmp}/MacAMP.dmg" -nobrowse -readonly -noautoopen -mountpoint "${MOUNT_POINT}" -quiet \
        || fail "couldn't open the disk image."
    [[ -d "${MOUNT_POINT}/MacAMP.app" ]] || fail "the disk image doesn't contain MacAMP.app."

    if pgrep -x MacAMP >/dev/null; then
        say "  quitting the running MacAMP"
        osascript -e 'tell application id "si.macamp.MacAMP" to quit' >/dev/null 2>&1 \
            || osascript -e 'tell application "MacAMP" to quit' >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x MacAMP >/dev/null || break; sleep 1; done
        pgrep -x MacAMP >/dev/null && fail "MacAMP is still running. Quit it and run the installer again."
    fi

    local target="${install_dir%/}/MacAMP.app"
    local sudo=""
    if [[ ! -w "${install_dir}" ]] || { [[ -e "${target}" ]] && [[ ! -w "${target}" ]]; }; then
        say "  ${install_dir} needs administrator rights; macOS will ask for your password."
        sudo="sudo"
    fi
    mkdir -p "${install_dir}" 2>/dev/null || ${sudo} mkdir -p "${install_dir}"
    ${sudo} rm -rf "${target}.installing"
    ${sudo} ditto "${MOUNT_POINT}/MacAMP.app" "${target}.installing"
    ${sudo} rm -rf "${target}"
    ${sudo} mv "${target}.installing" "${target}"
    ${sudo} xattr -dr com.apple.quarantine "${target}" 2>/dev/null || true

    say ""
    say "MacAMP ${version} is installed in ${install_dir}."
    say "Guide: https://docs.macamp.si/docs/ · Updates arrive inside the app."
    if [[ "${open_app}" -eq 1 ]]; then
        open "${target}"
    fi
}

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

# Reads a top-level string from a JSON file with macOS's own plutil.
json() { plutil -extract "$1" raw -o - "$2" 2>/dev/null || true; }

# True when dotted version $1 >= $2.
version_at_least() {
    local -a a b
    local i
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    for i in 0 1 2; do
        local x="${a[i]:-0}" y="${b[i]:-0}"
        ((10#${x} > 10#${y})) && return 0
        ((10#${x} < 10#${y})) && return 1
    done
    return 0
}

cleanup() {
    # Detach before deleting, so rm never walks into the mounted image.
    if [[ -n "${MOUNT_POINT:-}" && -d "${MOUNT_POINT}" ]]; then
        hdiutil detach "${MOUNT_POINT}" -quiet -force >/dev/null 2>&1 || true
    fi
    [[ -n "${WORK_DIR:-}" ]] && rm -rf "${WORK_DIR}"
}

# Everything runs from main, so a partially downloaded script does nothing.
main "$@"
