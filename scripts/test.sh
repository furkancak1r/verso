#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
# Respect the installed Xcode toolchain.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEST_FLAGS=(--disable-sandbox --disable-xctest --enable-swift-testing --cache-path .build/cache --config-path .build/config --security-path .build/security)
# Respect DEVELOPER_DIR for Testing framework discovery.
TEST_FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
# Command Line Tools includes Swift Testing outside the SDK's framework search path.
if [ -d "$TEST_FRAMEWORKS/Testing.framework" ]; then
    TEST_FLAGS+=(-Xswiftc "-F$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS/../usr/lib")
fi
# When VERSO_BUILD_IN_SANDBOX=1, add -Xfrontend -disable-sandbox to Swift
# compiler flags so SwiftData macros can run within the existing sandbox.
if [ "${VERSO_BUILD_IN_SANDBOX:-0}" = "1" ]; then
    TEST_FLAGS+=(-Xswiftc -Xfrontend -Xswiftc -disable-sandbox)
fi
swift test "${TEST_FLAGS[@]}" "$@"
