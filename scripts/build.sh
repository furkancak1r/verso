#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
# shellcheck disable=SC1091
. "$PROJECT_DIR/scripts/signing.sh"

# Fail before any product mutation when the pinned identity is unavailable.
PIN="$(signing_pin)"
signing_require_available "$PIN"

export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BUILD_FLAGS=(--disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)
if [ "${VERSO_BUILD_IN_SANDBOX:-0}" = "1" ]; then
    BUILD_FLAGS+=(-Xswiftc -Xfrontend -Xswiftc -disable-sandbox)
fi
swift build "${BUILD_FLAGS[@]}" -c release
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" -c release --show-bin-path)"

# Stage, sign and verify before touching the previous app.
APP_DIR="$PROJECT_DIR/build/Verso.app"
[ ! -L "$APP_DIR" ] && { [ ! -e "$APP_DIR" ] || [ -d "$APP_DIR" ]; } || { echo "Invalid app destination" >&2; exit 1; }
mkdir -p "$PROJECT_DIR/build"
STAGING="$(mktemp -d "$PROJECT_DIR/.build/host-staging.XXXXXX")"
BACKUP=""
on_exit() {
    local result=$?
    trap - EXIT
    if [ -n "$BACKUP" ] && [ -d "$BACKUP/previous.app" ] && [ ! -e "$APP_DIR" ]; then
        mv "$BACKUP/previous.app" "$APP_DIR" || result=1
    fi
    rm -rf "$STAGING"
    exit "$result"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STAGE_APP="$STAGING/Verso.app"
mkdir -p "$STAGE_APP/Contents/MacOS"
cp "$BIN_DIR/Verso" "$STAGE_APP/Contents/MacOS/Verso"
cp Resources/Info.plist "$STAGE_APP/Contents/Info.plist"
mkdir -p "$STAGE_APP/Contents/Resources"
cp Resources/AppIcon.icns "$STAGE_APP/Contents/Resources/AppIcon.icns"
for loc in en tr; do
  mkdir -p "$STAGE_APP/Contents/Resources/$loc.lproj"
  cp "Sources/VersoCore/Resources/$loc.lproj/Localizable.strings" "$STAGE_APP/Contents/Resources/$loc.lproj/Localizable.strings"
done
printf 'APPL????' > "$STAGE_APP/Contents/PkgInfo"
signing_sign "$PIN" "$STAGE_APP"
signing_verify "$PIN" "$STAGE_APP"

# Atomic publish; the prior app is preserved and restored on failure.
if [ -d "$APP_DIR" ]; then
    BACKUP="$(mktemp -d "$PROJECT_DIR/.build/host-backup.XXXXXX")"
    mv "$APP_DIR" "$BACKUP/previous.app"
fi
if mv "$STAGE_APP" "$APP_DIR"; then
    if [ -n "$BACKUP" ]; then echo "Previous app preserved at $BACKUP/previous.app" >&2; fi
else
    echo "Publish failed; previous app restored" >&2
    exit 1
fi
echo "Built $APP_DIR"
