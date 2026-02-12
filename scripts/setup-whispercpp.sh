#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$ROOT_DIR/whisper.cpp"
BUILD_DIR="$REPO_DIR/build"
LOCAL_BIN="$ROOT_DIR/whisper-cli"
LOCAL_CMAKE_GLOB="$ROOT_DIR/tools/cmake-*-macos-universal/CMake.app/Contents/bin"

echo "Root directory: $ROOT_DIR"

if ! command -v cmake >/dev/null 2>&1; then
  LOCAL_CMAKE_BIN="$(compgen -G "$LOCAL_CMAKE_GLOB/cmake" | head -n 1 || true)"
  if [ -n "${LOCAL_CMAKE_BIN:-}" ]; then
    export PATH="$(dirname "$LOCAL_CMAKE_BIN"):$PATH"
    echo "Using local cmake at: $LOCAL_CMAKE_BIN"
  else
    echo "cmake is required. Install it first or place a local CMake tarball under $ROOT_DIR/tools."
    exit 1
  fi
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required."
  exit 1
fi

if [ ! -d "$REPO_DIR" ]; then
  echo "Cloning whisper.cpp..."
  git clone https://github.com/ggml-org/whisper.cpp "$REPO_DIR"
else
  echo "whisper.cpp already exists at $REPO_DIR"
fi

echo "Configuring build..."
cmake -S "$REPO_DIR" -B "$BUILD_DIR" -UWHISPER_METAL -DGGML_METAL=ON

echo "Building whisper-cli..."
cmake --build "$BUILD_DIR" --config Release -j

if [ -x "$BUILD_DIR/bin/whisper-cli" ]; then
  cp "$BUILD_DIR/bin/whisper-cli" "$LOCAL_BIN"
  chmod +x "$LOCAL_BIN"
  echo "Installed local binary at: $LOCAL_BIN"
  echo "Done."
else
  echo "Build finished but whisper-cli was not found at $BUILD_DIR/bin/whisper-cli"
  exit 1
fi
