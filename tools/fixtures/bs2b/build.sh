#!/bin/bash
# Builds and runs the libbs2b reference-vector generator, then verifies the
# vendored source digests. Run ONCE per libbs2b version bump — the produced
# CSVs under vectors/ are committed and the Swift tests read only those.
# The test suite must NEVER invoke this script.
set -euo pipefail

cd "$(dirname "$0")"

echo "[1/3] verifying vendored source digests"
(cd vendor && shasum -a 256 --check SHA256SUMS)

echo "[2/3] compiling generator"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
cc -O2 -std=c99 -Ivendor -o "$BUILD_DIR/gen_fixtures" gen_fixtures.c vendor/bs2b.c -lm

echo "[3/3] generating vectors"
mkdir -p vectors
"$BUILD_DIR/gen_fixtures"

echo "done — review the diff before committing"
