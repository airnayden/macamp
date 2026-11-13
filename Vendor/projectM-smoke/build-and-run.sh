#!/usr/bin/env bash
# Build + run the headless projectM smoke harness (Task 31 proof).
# Compiles the REAL ObjC++ bridge (macOS/ProjectM/MacAMPProjectMBridge.mm) with
# -DMACAMP_PROJECTM, links the built libprojectM-4 dylib, renders presets fed by
# a synthesized sine PCM into an offscreen FBO, and asserts non-black output.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/macOS/Vendor/projectM/lib"
INC="${ROOT}/macOS/Vendor/projectM/include"
BR="${ROOT}/macOS/ProjectM"
HERE="${ROOT}/Vendor/projectM-smoke"
OUT="${HERE}/smoke"

echo "==> compiling smoke harness"
clang++ -std=c++17 -fobjc-arc -DMACAMP_PROJECTM -Wno-deprecated-declarations \
  -I"${INC}" -I"${BR}" \
  "${HERE}/main.mm" "${BR}/MacAMPProjectMBridge.mm" \
  -L"${LIB}" -lprojectM-4 -Wl,-rpath,"${LIB}" \
  -framework OpenGL -framework Foundation \
  -o "${OUT}"

TEX="${ROOT}/macOS/Vendor/projectM/textures"
echo "==> RUN idle preset"
"${OUT}" "" "${TEX}" "/tmp/projectm-idle.ppm"

PRESET="$(find "${ROOT}/macOS/Vendor/projectM/presets" -name 'Waveform__*.milk' | head -1)"
echo "==> RUN bundled preset: ${PRESET}"
"${OUT}" "${PRESET}" "${TEX}" "/tmp/projectm-preset.ppm"
