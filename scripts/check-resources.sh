#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

BUILD_DIR="$PROJECT_DIR/.build/resource-probe"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"
BUILD_LOG="$BUILD_DIR/build.log"
PROBE_LOG="$BUILD_DIR/result.json"
mkdir -p "$MODULE_CACHE_DIR"

SWIFTC="$(xcrun --find swiftc)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

"$SWIFTC" \
    -sdk "$SDK_PATH" \
    -target "${ARCH}-apple-macosx14.0" \
    -module-cache-path "$MODULE_CACHE_DIR" \
    -parse-as-library \
    -o "$BUILD_DIR/resource-probe" \
    "$PROJECT_DIR/Sources/VersoCore/TemporaryCaptureResource.swift" \
    "$PROJECT_DIR/scripts/resource-probe.swift" \
    -framework CoreGraphics \
    -framework Foundation \
    -framework QuartzCore \
    >"$BUILD_LOG" 2>&1

"$BUILD_DIR/resource-probe" | tee "$PROBE_LOG"
