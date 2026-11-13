#!/usr/bin/env bash
# Build libprojectM v4.1.6 (shared) for macOS arm64 into Vendor/projectM/install.
# macOS-only marquee backend (Task 31). NOT for iOS / NOT for App Store builds.
set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="/opt/homebrew/bin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${ROOT}/projectM/src"
BUILD="${ROOT}/projectM/build"
INSTALL="${ROOT}/projectM/install"
TAG="v4.1.6"

echo "==> projectM build start $(date)"

if [[ ! -d "${SRC}/.git" ]]; then
  echo "==> Cloning projectM ${TAG} (shallow + submodules)"
  rm -rf "${SRC}"
  git clone --branch "${TAG}" --depth 1 --recurse-submodules --shallow-submodules \
    https://github.com/projectM-visualizer/projectm "${SRC}"
  echo "==> Applying MacAMP patches (LGPL modifications, documented)"
  for patch in "${ROOT}"/projectM-patches/*.patch; do
    [[ -e "${patch}" ]] || continue
    git -C "${SRC}" apply "${patch}" && echo "    applied $(basename "${patch}")"
  done
else
  echo "==> Source already present, skipping clone"
fi

echo "==> Configuring (CMake, shared, arm64, deploy 14.0)"
cmake -S "${SRC}" -B "${BUILD}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${INSTALL}" \
  -DCMAKE_PREFIX_PATH=/opt/homebrew \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=ON \
  -DENABLE_PLAYLIST=ON \
  -DENABLE_TESTING=OFF \
  -DBUILD_TESTING=OFF \
  -DENABLE_SDL_UI=OFF \
  -DENABLE_EMSCRIPTEN=OFF

echo "==> Building"
cmake --build "${BUILD}" --config Release -j"$(sysctl -n hw.ncpu)"

echo "==> Installing to ${INSTALL}"
cmake --install "${BUILD}" --config Release

echo "==> Built artifacts:"
find "${INSTALL}" -name '*.dylib' -maxdepth 3 -print
echo "==> projectM build DONE $(date)"
