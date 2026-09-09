#!/bin/bash
# release.sh — One-command native macOS 14+ universal release for Verso v1.2.0.
# No dependencies beyond stock macOS tools: xcodebuild, ditto, hdiutil,
# codesign, lipo, plutil, shasum. No Finder-layout automation, no uploads,
# no notarization claims. The app is signed with the pinned certificate; its first launch can
# require the normal macOS Open Anyway confirmation.
#
# Output: build/releases/1.2.0/ with Verso.app, Verso-1.2.0-universal.dmg,
# Verso-1.2.0-universal.zip and SHA256SUMS.
#
# Safety: everything builds and validates under .build staging; the complete
# release directory is published only after all checks pass. A previous
# successful release is moved aside (never rm'd) and restored if publishing
# fails; interrupts restore it too. The live build/Verso.app, /Applications,
# user defaults, permissions and notes are never touched. Repeat runs are safe.
# Bash 3.2 compatible (stock macOS /bin/bash): no associative arrays,
# mapfile, ${var,,} or other newer features.
set -euo pipefail

VERSION="1.2.0"
BUILD="14"
BUNDLE_ID="com.verso.app"
DMG_NAME="Verso-${VERSION}-universal.dmg"
ZIP_NAME="Verso-${VERSION}-universal.zip"

usage() {
    echo "Usage: $0 [--help]" >&2
    echo "Builds, verifies and publishes build/releases/${VERSION}/ (Verso.app, DMG, ZIP, SHA256SUMS)." >&2
}
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then usage; exit 0; fi
if [ "$#" -ne 0 ]; then echo "[release] ERROR: unknown argument: $1" >&2; usage; exit 64; fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "[release] ERROR: $1" >&2; exit 1; }
# shellcheck disable=SC1091
. "$PROJECT_DIR/scripts/signing.sh"
# ponytail: single pinned identity, no ad-hoc fallback. Checked before any staging/build mutation.
PIN="$(signing_pin)" || fail "cannot load pinned signing identity"
signing_require_available "$PIN" || fail "signing identity unavailable: $PIN"
RELEASE_DIR="$PROJECT_DIR/build/releases/$VERSION"
mkdir -p "$PROJECT_DIR/.build"
STAGING="$(mktemp -d "$PROJECT_DIR/.build/release-staging.XXXXXX")"
BACKUP=""

# ponytail: trap owns only this run's staging dir; the previous release is
# restored (moved back, never deleted) when publish never completes.
on_exit() {
    local result=$?
    trap - EXIT
    if [ -n "$BACKUP" ] && [ -d "$BACKUP/previous" ] && [ ! -e "$RELEASE_DIR" ]; then
        mv "$BACKUP/previous" "$RELEASE_DIR" || result=1
    fi
    rm -rf "$STAGING"
    exit "$result"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[ ! -L "$RELEASE_DIR" ] || fail "release destination must not be a symlink"
[ ! -e "$RELEASE_DIR" ] || [ -d "$RELEASE_DIR" ] || fail "release destination is not a directory"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

mkdir -p "$STAGING"
DERIVED="$STAGING/DerivedData"
PAYLOAD="$STAGING/payload"
mkdir -p "$PAYLOAD"

echo "[release] Building universal Release (xcodebuild, pinned sign)..." >&2
if [ "${VERSO_BUILD_IN_SANDBOX:-0}" = "1" ]; then
    # Same SwiftData macro compiler flag as scripts/build.sh, in xcodebuild form.
    xcodebuild -project "$PROJECT_DIR/Verso.xcodeproj" -scheme Verso \
        -configuration Release -sdk macosx -destination 'generic/platform=macOS' \
        -derivedDataPath "$DERIVED" \
        ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="$PIN" \
        OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox' \
        build || fail "xcodebuild failed"
else
    xcodebuild -project "$PROJECT_DIR/Verso.xcodeproj" -scheme Verso \
        -configuration Release -sdk macosx -destination 'generic/platform=macOS' \
        -derivedDataPath "$DERIVED" \
        ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="$PIN" \
        build || fail "xcodebuild failed"
fi

BUILT="$DERIVED/Build/Products/Release/Verso.app"
[ -d "$BUILT" ] || fail "built app missing: $BUILT"
# Xcode signed the complete bundle using the canonical Info.plist.
/usr/bin/ditto "$BUILT" "$PAYLOAD/Verso.app" || fail "cannot stage Verso.app"

echo "[release] Verifying staged bundle..." >&2
GOT_BID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$PAYLOAD/Verso.app/Contents/Info.plist")" \
    || fail "cannot read CFBundleIdentifier"
[ "$GOT_BID" = "$BUNDLE_ID" ] || fail "bundle id mismatch: $GOT_BID"
GOT_VER="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$PAYLOAD/Verso.app/Contents/Info.plist")" \
    || fail "cannot read CFBundleShortVersionString"
[ "$GOT_VER" = "$VERSION" ] || fail "version mismatch: $GOT_VER"
GOT_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$PAYLOAD/Verso.app/Contents/Info.plist")" \
    || fail "cannot read CFBundleVersion"
[ "$GOT_BUILD" = "$BUILD" ] || fail "build mismatch: $GOT_BUILD"
GOT_ICON="$(/usr/bin/plutil -extract CFBundleIconFile raw "$PAYLOAD/Verso.app/Contents/Info.plist")" \
    || fail "cannot read CFBundleIconFile"
[ "$GOT_ICON" = "AppIcon.icns" ] || fail "app icon reference mismatch: $GOT_ICON"
cmp -s "$PROJECT_DIR/Resources/AppIcon.icns" "$PAYLOAD/Verso.app/Contents/Resources/AppIcon.icns" \
    || fail "app icon missing or different from source"
iconutil -c iconset "$PAYLOAD/Verso.app/Contents/Resources/AppIcon.icns" -o "$STAGING/icon-check.iconset" \
    || fail "app icon cannot be decoded"
[ -f "$STAGING/icon-check.iconset/icon_512x512@2x.png" ] || fail "1024px app icon missing"
ARCHS="$(lipo -archs "$PAYLOAD/Verso.app/Contents/MacOS/Verso")" || fail "lipo failed"
case "$ARCHS" in *arm64*) ;; *) fail "missing arm64 slice (got: $ARCHS)" ;; esac
case "$ARCHS" in *x86_64*) ;; *) fail "missing x86_64 slice (got: $ARCHS)" ;; esac
[ -f "$PAYLOAD/Verso.app/Contents/Resources/en.lproj/Localizable.strings" ] \
    || fail "missing en.lproj/Localizable.strings"
[ -f "$PAYLOAD/Verso.app/Contents/Resources/tr.lproj/Localizable.strings" ] \
    || fail "missing tr.lproj/Localizable.strings"
codesign --verify --deep --strict --verbose=2 "$PAYLOAD/Verso.app" \
    || fail "strict signature verification failed"
# Reject a bundle signed with anything but the pin before publishing.
signing_verify "$PIN" "$PAYLOAD/Verso.app" || fail "pinned signing verification failed"

echo "[release] Creating DMG (hdiutil UDZO/HFS+)..." >&2
DMG_SRC="$STAGING/dmg-src"
mkdir -p "$DMG_SRC"
/usr/bin/ditto "$PAYLOAD/Verso.app" "$DMG_SRC/Verso.app" || fail "cannot stage DMG source"
ln -s /Applications "$DMG_SRC/Applications" || fail "cannot stage Applications symlink"
cat > "$DMG_SRC/Install-README.txt" <<'DOCEOF'
VERSO — KURULUM / INSTALLATION

TÜRKÇE
1. Verso.app dosyasını Applications (Uygulamalar) klasörüne sürükleyin.
2. Disk görüntüsünü çıkarın ve Verso'yu Uygulamalar klasöründen açın.
3. İlk açılış engellenirse Sistem Ayarları → Gizlilik ve Güvenlik → Yine de Aç yolunu izleyin.
4. Verso → İzinler bölümünden Erişilebilirlik iznini verin. Pencere dönüşümü için Ekran Kaydı iznini de açın.
5. Dil varsayılan olarak sistemi izler. Ayarlar → Dil bölümünden Türkçe veya English seçebilirsiniz; değişiklik sonraki açılışta uygulanır.

Bu ücretsiz sürüm Apple noter onayına sahip değildir; ilk açılışta macOS onayı gerekebilir.
Eski geçici imzadan ilk geçişte izinleri yeniden vermeniz gerekebilir. Sonraki sürümler aynı kalıcı sertifikayı kullanır. Notlarınız korunur.

ENGLISH
1. Drag Verso.app into Applications.
2. Eject the disk image and open Verso from Applications.
3. If the first launch is blocked, use System Settings → Privacy & Security → Open Anyway.
4. In Verso → Permissions, grant Accessibility. Also grant Screen Recording for the window-flip animation.
5. Language follows the system by default. Settings → Language offers Türkçe and English; changes apply on the next launch.

This free build is not notarized by Apple; macOS may require confirmation on first launch.
The first migration from the old ad-hoc signature may require permissions again. Subsequent builds use the same persistent certificate. Your notes are preserved.
DOCEOF
hdiutil create -volname "Verso $VERSION" -srcfolder "$DMG_SRC" \
    -ov -format UDZO -fs HFS+ -o "$PAYLOAD/$DMG_NAME" || fail "hdiutil create failed"
hdiutil verify "$PAYLOAD/$DMG_NAME" || fail "hdiutil verify failed"

echo "[release] Creating ZIP and checksums..." >&2
/usr/bin/ditto -c -k --keepParent "$PAYLOAD/Verso.app" "$PAYLOAD/$ZIP_NAME" \
    || fail "zip (ditto) failed"
(cd "$PAYLOAD" && /usr/bin/shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS) \
    || fail "cannot write SHA256SUMS"
(cd "$PAYLOAD" && /usr/bin/shasum -a 256 -c SHA256SUMS) || fail "checksum self-check failed"

echo "[release] Publishing complete release directory..." >&2
if [ -d "$RELEASE_DIR" ]; then
    BACKUP="$(mktemp -d "$PROJECT_DIR/.build/release-backup-$VERSION.XXXXXX")"
    mv "$RELEASE_DIR" "$BACKUP/previous" || fail "cannot set aside previous release"
fi
mkdir -p "$(dirname "$RELEASE_DIR")"
if mv "$PAYLOAD" "$RELEASE_DIR"; then
    if [ -n "$BACKUP" ]; then echo "[release] Previous release preserved at $BACKUP/previous" >&2; fi
else
    fail "publish failed; previous release restored"
fi

echo "[release] Published $RELEASE_DIR" >&2
echo "[release] Contents:" >&2
ls -l "$RELEASE_DIR" >&2
