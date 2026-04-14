#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

echo "Building MLX Metal shaders via xcodebuild..."
xcodebuild build -scheme EyesOnGlass -destination 'platform=OS X' SYMROOT="$ROOT/.build/xcodebuild" -quiet

METAL_BUNDLE="$ROOT/.build/xcodebuild/Release/mlx-swift_Cmlx.bundle"
if [[ ! -d "$METAL_BUNDLE" ]]; then
  METAL_BUNDLE="$ROOT/.build/xcodebuild/Debug/mlx-swift_Cmlx.bundle"
fi

if [[ ! -f "$METAL_BUNDLE/Contents/Resources/default.metallib" ]]; then
  echo "ERROR: Failed to successfully compile default.metallib via xcodebuild" >&2
  exit 1
fi

echo "Successfully built default.metallib"

# Determine active SwiftPM build directory depending on host architecture
HOST_ARCH=$(uname -m)
if [[ "$HOST_ARCH" == "arm64" || "$HOST_ARCH" == "aarch64" ]]; then
  SWIFT_ARCH_DIR=".build/arm64-apple-macosx"
else
  SWIFT_ARCH_DIR=".build/x86_64-apple-macosx"
fi

# 1. Update Test Resource Directories
echo "Injecting default.metallib into SwiftPM testing environments..."
for CONF in debug release; do
  # Direct folder fallback
  mkdir -p "$ROOT/$SWIFT_ARCH_DIR/$CONF/Resources"
  cp "$METAL_BUNDLE/Contents/Resources/default.metallib" "$ROOT/$SWIFT_ARCH_DIR/$CONF/Resources/default.metallib"
  
  # For xctest test suites running via SPM
  XCTEST_APP="$ROOT/$SWIFT_ARCH_DIR/$CONF/EyesOnGlassPackageTests.xctest"
  if [[ -d "$XCTEST_APP" ]]; then
    mkdir -p "$XCTEST_APP/Contents/MacOS/Resources"
    cp "$METAL_BUNDLE/Contents/Resources/default.metallib" "$XCTEST_APP/Contents/MacOS/Resources/default.metallib"
  fi
done

echo "Metal shaders successfully injected into SPM environments."

