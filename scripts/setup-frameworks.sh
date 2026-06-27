#!/usr/bin/env bash
# Download + extract sherpa-onnx + onnxruntime XCFrameworks for local dev.
# These are git-ignored (200MB+, way above GitHub's 100MB file limit) so
# every fresh clone on a Mac needs this once. CI runs the same logic
# inline in .github/workflows/{ci,testflight}.yml — when bumping the
# version here, bump it there too.
set -euo pipefail

VERSION="1.13.2"
TARBALL="sherpa-onnx-v${VERSION}-ios.tar.bz2"
CACHE_DIR="$HOME/sherpa-onnx-cache"
CACHE_PATH="$CACHE_DIR/$TARBALL"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${TARBALL}"

cd "$(dirname "$0")/.."

if [ -d "frameworks/sherpa-onnx.xcframework" ] && [ -d "frameworks/onnxruntime.xcframework" ]; then
  echo "frameworks/ already populated — skipping download. rm -rf frameworks/ to force redownload."
  exit 0
fi

mkdir -p "$CACHE_DIR"
if [ ! -f "$CACHE_PATH" ]; then
  echo "Downloading ${TARBALL} (~200MB, one-time per version)…"
  curl -fL -o "$CACHE_PATH" "$URL"
else
  echo "Using cached ${TARBALL}"
fi

mkdir -p frameworks
# Tarball layout (verified from CI):
#   <top>/build-ios/sherpa-onnx.xcframework               (depth 2)
#   <top>/build-ios/ios-onnxruntime/onnxruntime.xcframework -> 1.17.1/onnxruntime.xcframework (symlink)
#   <top>/build-ios/ios-onnxruntime/1.17.1/onnxruntime.xcframework/ (the real bundle)
# Strip 2 levels so sherpa-onnx lands directly, then locate the REAL
# onnxruntime.xcframework directory (not the symlink) and flatten it up.
tar -xjf "$CACHE_PATH" -C frameworks --strip-components=2
REAL_ONNX=$(find frameworks/ -mindepth 2 -name "onnxruntime.xcframework" -type d | head -1)
if [ -n "$REAL_ONNX" ]; then
  rm -f frameworks/onnxruntime.xcframework
  mv "$REAL_ONNX" frameworks/onnxruntime.xcframework
  rm -rf frameworks/ios-onnxruntime
fi

test -d frameworks/sherpa-onnx.xcframework || { echo "ERROR: sherpa-onnx.xcframework missing after extract"; exit 1; }
test -d frameworks/onnxruntime.xcframework || { echo "ERROR: onnxruntime.xcframework missing after extract"; exit 1; }

echo
echo "Done. frameworks/:"
ls -lh frameworks/
