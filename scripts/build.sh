#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
# Respect the installed Xcode toolchain.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# SwiftPM's nested sandbox cannot run inside the host's existing build sandbox.
BUILD_FLAGS=(--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)
# When VERSO_BUILD_IN_SANDBOX=1, add -Xfrontend -disable-sandbox to Swift
# compiler flags so SwiftData macros can run within the existing sandbox.
if [ "${VERSO_BUILD_IN_SANDBOX:-0}" = "1" ]; then
    BUILD_FLAGS+=(-Xswiftc -Xfrontend -Xswiftc -disable-sandbox)
fi
swift build "${BUILD_FLAGS[@]}" -c release
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/build/Verso.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/Verso" "$APP_DIR/Contents/MacOS/Verso"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
mkdir -p "$APP_DIR/Contents/Resources"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
for loc in en tr; do
  mkdir -p "$APP_DIR/Contents/Resources/$loc.lproj"
  cp "Sources/VersoCore/Resources/$loc.lproj/Localizable.strings" "$APP_DIR/Contents/Resources/$loc.lproj/Localizable.strings"
done
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
codesign --force --sign - "$APP_DIR"
echo "Built $APP_DIR"
