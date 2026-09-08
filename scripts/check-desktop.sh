#!/bin/bash
# check-desktop.sh — Compile (default), --run, or --self-check the desktop smoke runner.
# Works from any cwd. No Python/ctypes/grep prechecks, no private API keys.
# --run accepts [--project-root ROOT] [--app-path ABSOLUTE_APP_PATH]; defaults
# target this checkout's build/Verso.app. Arguments are forwarded without eval.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$PROJECT_DIR/scripts"
BUILD_DIR="$PROJECT_DIR/.build/desktop-smoke"
APP_BUNDLE="$BUILD_DIR/VersoDesktopSmoke.app"
SWIFT_FILE="$SCRIPT_DIR/desktop-smoke.swift"
BINARY="$APP_BUNDLE/Contents/MacOS/VersoDesktopSmoke"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

usage() {
    echo "Usage: $0 [--run [--project-root ROOT] [--app-path ABSOLUTE_APP_PATH] | --self-check]" >&2
}

# Validate arguments before compiling (exit 64, no GUI, no build side effects on error).
MODE=""
USER_ROOT=""
USER_APP=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --run|--self-check)
            if [ -n "$MODE" ]; then echo "[check-desktop] ERROR: duplicate mode: $1" >&2; usage; exit 64; fi
            if [ "$1" = "--run" ]; then MODE="run"; else MODE="selfcheck"; fi
            shift
            ;;
        --project-root)
            if [ -n "$USER_ROOT" ]; then echo "[check-desktop] ERROR: duplicate --project-root" >&2; usage; exit 64; fi
            if [ "$#" -lt 2 ]; then echo "[check-desktop] ERROR: missing value for --project-root" >&2; usage; exit 64; fi
            case "$2" in /*) ;; *) echo "[check-desktop] ERROR: --project-root must be absolute: $2" >&2; exit 64 ;; esac
            USER_ROOT="$2"
            shift 2
            ;;
        --app-path)
            if [ -n "$USER_APP" ]; then echo "[check-desktop] ERROR: duplicate --app-path" >&2; usage; exit 64; fi
            if [ "$#" -lt 2 ]; then echo "[check-desktop] ERROR: missing value for --app-path" >&2; usage; exit 64; fi
            case "$2" in /*) ;; *) echo "[check-desktop] ERROR: --app-path must be absolute: $2" >&2; exit 64 ;; esac
            case "$2" in *.app) ;; *) echo "[check-desktop] ERROR: --app-path must be an .app bundle: $2" >&2; exit 64 ;; esac
            USER_APP="$2"
            shift 2
            ;;
        *) echo "[check-desktop] ERROR: unknown argument: $1" >&2; usage; exit 64 ;;
    esac
done
if { [ -n "$USER_ROOT" ] || [ -n "$USER_APP" ]; } && [ "$MODE" != "run" ]; then
    echo "[check-desktop] ERROR: --project-root/--app-path require --run" >&2; usage; exit 64
fi

# Create .app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$BUILD_DIR/ModuleCache"
cat > "$INFO_PLIST" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>VersoDesktopSmoke</string>
	<key>CFBundleIdentifier</key><string>local.verso.desktop-smoke</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>VersoDesktopSmoke</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Compile with xcrun swiftc targeting macOS 14
echo "[check-desktop] Compiling with xcrun swiftc -> $BINARY" >&2
xcrun swiftc \
    -O \
    -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    -o "$BINARY" \
    "$SWIFT_FILE" 2>&1

# Ad-hoc sign
codesign --force --sign - "$APP_BUNDLE" 2>&1
echo "[check-desktop] Compiled and signed: $BINARY" >&2

echo "BINARY=$BINARY"
echo "APP_BUNDLE=$APP_BUNDLE"

# --self-check: pure self-check, no GUI, no project root needed
if [ "$MODE" = "selfcheck" ]; then
    echo "[check-desktop] Running --self-check" >&2
    exec "$BINARY" --self-check
fi

# --run: execute checked binary, forwarding explicit roots without eval
if [ "$MODE" = "run" ]; then
    if [ -n "$USER_ROOT" ]; then RUN_ROOT="$USER_ROOT"; else RUN_ROOT="$PROJECT_DIR"; fi
    echo "[check-desktop] Running --run with project-root=$RUN_ROOT" >&2
    if [ -n "$USER_APP" ]; then
        exec "$BINARY" --run --project-root "$RUN_ROOT" --app-path "$USER_APP"
    else
        exec "$BINARY" --run --project-root "$RUN_ROOT"
    fi
fi

# Default: compile only (already done)
echo "[check-desktop] Compiled only. Use --self-check or --run." >&2
