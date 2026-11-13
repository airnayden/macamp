#!/bin/bash
# Offline checks against disposable plists and a stubbed release pipeline.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${1:-${TEST_DIR}/..}"
FIXTURE_ROOT="$(mktemp -d /tmp/macamp-identity-test.XXXXXX)"
trap 'rm -rf "${FIXTURE_ROOT}"' EXIT
mkdir -p "${FIXTURE_ROOT}/repo/scripts" "${FIXTURE_ROOT}/bin" "${FIXTURE_ROOT}/tmp"
cp "${SCRIPTS_DIR}/release.sh" "${FIXTURE_ROOT}/repo/scripts/release.sh"
if [[ -f "${SCRIPTS_DIR}/check-release-identity.sh" ]]; then
    cp "${SCRIPTS_DIR}/check-release-identity.sh" "${FIXTURE_ROOT}/repo/scripts/check-release-identity.sh"
fi
export RELEASE_TEST_TRACE="${FIXTURE_ROOT}/trace"
export RELEASE_TEST_PLIST="${FIXTURE_ROOT}/Info.plist"
export PATH="${FIXTURE_ROOT}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export TMPDIR="${FIXTURE_ROOT}/tmp/"

for tool in xcodebuild tuist hdiutil codesign spctl ditto security curl xcrun; do
    cat > "${FIXTURE_ROOT}/bin/${tool}" <<'STUB'
#!/bin/bash
printf '%s\n' "${0##*/}" >> "${RELEASE_TEST_TRACE}"
echo "STUB: refused ${0##*/}"
exit 99
STUB
done
cat > "${FIXTURE_ROOT}/bin/git" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "${FIXTURE_ROOT}"/bin/*
cat > "${FIXTURE_ROOT}/repo/scripts/build-macamp.sh" <<'STUB'
#!/bin/bash
set -eu
echo build >> "${RELEASE_TEST_TRACE}"
mkdir -p build/MacAMP.app/Contents
cp "${RELEASE_TEST_PLIST}" build/MacAMP.app/Contents/Info.plist
STUB
mkdir -p "${FIXTURE_ROOT}/repo/tools/downloader"
cat > "${FIXTURE_ROOT}/repo/tools/downloader/fetch-download-tools.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "${FIXTURE_ROOT}/repo/scripts/build-macamp.sh" "${FIXTURE_ROOT}/repo/tools/downloader/fetch-download-tools.sh"
TOOLS="${FIXTURE_ROOT}/repo/macOS/Resources/DownloaderTools"
mkdir -p "${TOOLS}/yt-dlp/_internal"
for artifact in ffmpeg ffprobe LICENSE-yt-dlp.txt LICENSE-ffmpeg.txt SOURCE-OFFER.txt yt-dlp/yt-dlp_macos yt-dlp/_internal/fixture; do
    touch "${TOOLS}/${artifact}"
done

make_plist() {
    rm -f "${RELEASE_TEST_PLIST}"
    plutil -create xml1 "${RELEASE_TEST_PLIST}"
    [[ "$1" == MISSING ]] || plutil -insert CFBundleIdentifier -string "$1" "${RELEASE_TEST_PLIST}"
    [[ "$2" == MISSING ]] || plutil -insert SUFeedURL -string "$2" "${RELEASE_TEST_PLIST}"
    plutil -insert CFBundleShortVersionString -string 1.2.3 "${RELEASE_TEST_PLIST}"
    plutil -insert CFBundleVersion -string 123 "${RELEASE_TEST_PLIST}"
}

pipeline_case() {
    local name="$1" identifier="$2" feed="$3" expected_status="$4" expected_trace="$5" status=0
    make_plist "${identifier}" "${feed}"
    : > "${RELEASE_TEST_TRACE}"
    DEVELOPER_ID_APPLICATION="" /bin/bash "${FIXTURE_ROOT}/repo/scripts/release.sh" \
        --version 1.2.3 --no-model --skip-appcast > "${FIXTURE_ROOT}/pipeline.log" 2>&1 || status=$?
    if [[ "${status}" -ne "${expected_status}" || "$(cat "${RELEASE_TEST_TRACE}")" != "${expected_trace}" ]]; then
        cat "${FIXTURE_ROOT}/pipeline.log"
        echo "FAIL ${name}: expected exit=${expected_status}, trace='${expected_trace}'; got exit=${status}, trace='$(cat "${RELEASE_TEST_TRACE}")'" >&2
        exit 1
    fi
    echo "PASS ${name}: exit=${status}, trace='$(tr '\n' ',' < "${RELEASE_TEST_TRACE}")'"
}

# This fails on the original pipeline because codesign is attempted (exit4).
pipeline_case placeholder-before-sign com.example.macamp https://downloads.example.com/appcast.xml 3 build
pipeline_case invalid-feed-before-sign org.macamp.tests http://updates.macamp-test.test/appcast.xml 3 build
pipeline_case valid-reaches-sign org.macamp.tests https://updates.macamp-test.test/appcast.xml 4 $'build\ncodesign'

check_case() {
    local name="$1" expected_status="$2" identifier="$3" feed="$4" status=0
    make_plist "${identifier}" "${feed}"
    /bin/bash "${SCRIPTS_DIR}/check-release-identity.sh" "${RELEASE_TEST_PLIST}" > "${FIXTURE_ROOT}/check.log" 2>&1 || status=$?
    [[ "${status}" -eq "${expected_status}" ]] || {
        cat "${FIXTURE_ROOT}/check.log"
        echo "FAIL ${name}: expected exit=${expected_status}, got ${status}" >&2
        exit 1
    }
    echo "PASS ${name}: exit=${status}; $(cat "${FIXTURE_ROOT}/check.log")"
}

check_case valid 0 org.macamp.tests https://updates.macamp-test.test/appcast.xml
check_case newline-id 1 $'org.macamp.tests\n' https://updates.macamp-test.test/appcast.xml
check_case newline-feed 1 org.macamp.tests $'https://updates.macamp-test.test/appcast.xml\n'
check_case valid-port-query 0 org.macamp.tests 'https://updates.macamp-test.test:8443/feed?channel=stable&format=xml'
check_case missing-id 1 MISSING https://updates.macamp-test.test/appcast.xml
check_case empty-id 1 '' https://updates.macamp-test.test/appcast.xml
check_case malformed-id 1 'org..macamp' https://updates.macamp-test.test/appcast.xml
check_case example-id 1 COM.EXAMPLE.macamp https://updates.macamp-test.test/appcast.xml
check_case todo-id 1 org.TODO.macamp https://updates.macamp-test.test/appcast.xml
check_case missing-feed 1 org.macamp.tests MISSING
check_case empty-feed 1 org.macamp.tests ''
check_case example-feed 1 org.macamp.tests https://downloads.example.com/appcast.xml
check_case invalid-domain 1 org.macamp.tests https://updates.invalid/appcast.xml
check_case todo-feed 1 org.macamp.tests https://TODO.test/appcast.xml
check_case insecure-feed 1 org.macamp.tests http://updates.macamp-test.test/appcast.xml
check_case malformed-feed 1 org.macamp.tests https:///appcast.xml
check_case credentials-feed 1 org.macamp.tests https://user:pass@updates.macamp-test.test/appcast.xml
check_case whitespace-feed 1 org.macamp.tests 'https://updates.macamp-test.test/app cast.xml'
check_case backslash-feed 1 org.macamp.tests 'https://updates.macamp-test.test/feed\oops'
check_case invalid-port 1 org.macamp.tests https://updates.macamp-test.test:99999/appcast.xml
check_case invalid-escape 1 org.macamp.tests https://updates.macamp-test.test/%ZZ
make_plist org.macamp.tests https://updates.macamp-test.test/appcast.xml
plutil -replace SUFeedURL -integer 123 "${RELEASE_TEST_PLIST}"
if /bin/bash "${SCRIPTS_DIR}/check-release-identity.sh" "${RELEASE_TEST_PLIST}"; then
    echo 'FAIL non-string feed accepted' >&2; exit 1
fi
echo 'PASS non-string feed rejected'

rm -rf "${FIXTURE_ROOT}/repo/build"
: > "${RELEASE_TEST_TRACE}"
DEVELOPER_ID_APPLICATION="" /bin/bash "${FIXTURE_ROOT}/repo/scripts/release.sh" \
    --version 1.2.3 --no-model --skip-appcast --dry-run > "${FIXTURE_ROOT}/dry.log" 2>&1
[[ ! -s "${RELEASE_TEST_TRACE}" ]] || { cat "${RELEASE_TEST_TRACE}"; echo 'FAIL dry run invoked a guarded command' >&2; exit 1; }
grep -q 'release identity: pending' "${FIXTURE_ROOT}/dry.log"
[[ ! -e "${FIXTURE_ROOT}/repo/dist" ]] || { echo 'FAIL dry run wrote output directory' >&2; exit 1; }
echo 'PASS dry-run: identity pending; no build, signing, keychain or network command; no output directory'
echo 'PASS release identity regression'
