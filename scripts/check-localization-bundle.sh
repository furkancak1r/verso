#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK="$PROJECT_DIR/.build/localization-bundle-check"
APP="$WORK/LocalizationBundleProbe.app"
BIN="$APP/Contents/MacOS/Probe"
MODULE_CACHE_DIR="$PROJECT_DIR/.build/ModuleCache"
mkdir -p "$MODULE_CACHE_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/tr.lproj"
cp "Sources/VersoCore/Resources/en.lproj/Localizable.strings" "$APP/Contents/Resources/en.lproj/"
cp "Sources/VersoCore/Resources/tr.lproj/Localizable.strings" "$APP/Contents/Resources/tr.lproj/"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict>' '<key>CFBundleExecutable</key><string>Probe</string>' '<key>CFBundleIdentifier</key><string>com.verso.localization-probe</string>' '<key>CFBundlePackageType</key><string>APPL</string>' '</dict></plist>' > "$APP/Contents/Info.plist"
cat > "$WORK/probe.swift" <<'PROBE'
import Foundation
extension Bundle { static var module: Bundle { fatalError("CHECKOUT_BUNDLE_MUST_NOT_BE_EVALUATED") } }
@main struct Probe {
    static func main() {
        AppLocalization.freeze(preference: "tr", appleLanguages: ["en"])
        let value = L("menu.settings")
        print(value)
        precondition(value == "Ayarlar…", "unexpected localization: \(value)")
        AppLocalization.resetForTesting()
        AppLocalization.freeze(preference: "en", appleLanguages: ["tr"])
        let fallback = L("menu.settings")
        precondition(fallback == "Settings…", "unexpected fallback: \(fallback)")
    }
}
PROBE
SWIFTC="$(xcrun --find swiftc)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
"$SWIFTC" -sdk "$SDK" -target "${ARCH}-apple-macosx14.0" -module-cache-path "$MODULE_CACHE_DIR" -D SWIFT_PACKAGE -parse-as-library -o "$BIN" "$PROJECT_DIR/Sources/VersoCore/AppLocalization.swift" "$WORK/probe.swift" -framework Foundation
"$BIN"
echo "localization-bundle-check: OK (app resources used, Bundle.module untouched)"
