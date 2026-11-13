#!/bin/bash
# Exercises the real build entry point with disposable installs and no real build.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="${1:-${TEST_DIR}/../build-macamp.sh}"
FIXTURE_ROOT="$(mktemp -d /tmp/macamp-cleanup-test.XXXXXX)"
cleanup() {
    rm -rf "${FIXTURE_ROOT}"
}
trap cleanup EXIT

mkdir -p "${FIXTURE_ROOT}/repo/scripts" "${FIXTURE_ROOT}/repo/Tuist/.build" "${FIXTURE_ROOT}/bin"
cp "${BUILD_SCRIPT}" "${FIXTURE_ROOT}/repo/scripts/build-macamp.sh"
cat > "${FIXTURE_ROOT}/bin/tuist" <<'STUB'
#!/bin/bash
printf 'STUB tuist %s\n' "$*"
STUB
cat > "${FIXTURE_ROOT}/bin/xcodebuild" <<'STUB'
#!/bin/bash
printf 'STUB xcodebuild: stopped before building\n'
exit 86
STUB
cat > "${FIXTURE_ROOT}/bin/mdfind" <<'STUB'
#!/bin/bash
printf 'ERROR: discovery must not run in this test\n' >&2
exit 99
STUB
cat > "${FIXTURE_ROOT}/bin/pgrep" <<'STUB'
#!/bin/bash
case "$*" in
    *Running*) echo 424242; exit 0 ;;
    *) exit 1 ;;
esac
STUB
cat > "${FIXTURE_ROOT}/bin/lsof" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "${FIXTURE_ROOT}"/bin/*


MATCHING="${FIXTURE_ROOT}/installs/Matching.app"
FOREIGN="${FIXTURE_ROOT}/installs/Foreign.app"
RUNNING="${FIXTURE_ROOT}/installs/Running.app"
UNLISTED="${FIXTURE_ROOT}/installs/Unlisted.app"
DECOY_ID="org.macamp.tests.cleanup.${$}"
make_bundle() {
    mkdir -p "$1/Contents/MacOS"
    cat > "$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>Decoy</string>
</dict></plist>
PLIST
}
make_bundle "${FOREIGN}" "org.macamp.tests.foreign"
make_bundle "${UNLISTED}" "${DECOY_ID}"
make_bundle "${RUNNING}" "${DECOY_ID}"

run_case() {
    local name="$1" expect_present="$2" expected_status="$3" actual_status
    shift 3
    make_bundle "${MATCHING}" "${DECOY_ID}"
    printf '\nCASE %s: /bin/bash build-macamp.sh --skip-model --skip-tools %s\n' "${name}" "$*"
    set +e
    PATH="${FIXTURE_ROOT}/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        MACAMP_CLEAN_SLATE_PATHS="${MATCHING}:${FOREIGN}:${RUNNING}" \
        MACAMP_CLEAN_SLATE_BUNDLE_ID="${DECOY_ID}" \
        /bin/bash "${FIXTURE_ROOT}/repo/scripts/build-macamp.sh" --skip-model --skip-tools "$@"
    actual_status=$?
    set -e
    [[ "${actual_status}" -eq "${expected_status}" ]] || {
        echo "FAIL ${name}: exit ${actual_status}, expected ${expected_status}" >&2
        exit 1
    }
    if [[ "${expect_present}" -eq 1 ]]; then
        [[ -d "${MATCHING}" ]] || { echo "FAIL ${name}: matching install was deleted" >&2; exit 1; }
    else
        [[ ! -e "${MATCHING}" ]] || { echo "FAIL ${name}: explicit cleanup did not remove matching install" >&2; exit 1; }
    fi
    [[ -d "${FOREIGN}" && -d "${RUNNING}" && -d "${UNLISTED}" ]] || {
        echo "FAIL ${name}: protected or unlisted install was deleted" >&2
        exit 1
    }
    echo "PASS ${name}: matching-present=${expect_present}; foreign, running and unlisted preserved"
}

run_case default 1 86
run_case keep-installs 1 86 --keep-installs
run_case clean-installs 0 86 --clean-installs
run_case clean-only 0 0 --clean-only
run_case clean-then-keep 1 86 --clean-installs --keep-installs
run_case keep-then-clean 0 86 --keep-installs --clean-installs
run_case clean-only-then-keep 1 0 --clean-only --keep-installs
run_case keep-then-clean-only 0 0 --keep-installs --clean-only
echo 'PASS: 8 cleanup authorization cases (Bash 3.2 compatible)'
