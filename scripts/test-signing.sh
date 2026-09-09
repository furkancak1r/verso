#!/bin/bash
# test-signing.sh — deterministic regression for pinned signing (no keychain/keys).
# Uses fixture copies of the actual scripts with ONLY the absolute
# security/codesign/lipo paths redirected to synthetic stubs; everything else
# (grep/tr/awk/plutil logic, entry-point flow) is the real code. Never touches
# real keychains, certificates, TCC, notes, .build, or system settings.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

GOOD_PIN="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
WRONG_PIN="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
F="$T/proj"; mkdir -p "$F/scripts" "$F/Resources" "$T/stubbin"
export FAKE_STATE_DIR="$T/state"; mkdir -p "$FAKE_STATE_DIR"

# --- synthetic stubs (no keychain/TCC/builds) ---
cat > "$T/stubbin/security" <<'STUB'
#!/bin/bash
# Synthetic `find-identity -v` output only. A bare cert hash line proves a
# find-certificate-style entry never counts as a valid identity ($2 match).
if [ -n "${FAKE_HAVE_PIN:-}" ]; then
    printf 'Policy: Code Signing\n  Matching identities\n  1) %s "Fake Identity"\n     1 valid identities found\n' "$FAKE_HAVE_PIN"
else
    if [ -n "${FAKE_CERT_PIN:-}" ]; then
        printf 'SHA-1 hash: %s\n     0 valid identities found\n' "$FAKE_CERT_PIN"
    else
        printf '     0 valid identities found\n'
    fi
fi
STUB
cat > "$T/stubbin/codesign" <<'STUB'
#!/bin/bash
# Synthetic codesign: --sign records the pin; --verify checks stored signer,
# per-arch failure injection, and global verify failure.
FIX="${FAKE_STATE_DIR:-/tmp}/signer"
SIGN=""; ARCH=""; HAVE_R=0; PREV=""
for a in "$@"; do
  if [ "$PREV" = "-R" ]; then [[ "$a" == =* ]] || exit 1; fi
    [ "$PREV" = "--sign" ] && SIGN="$a"
    [ "$PREV" = "--arch" ] && ARCH="$a"
    [ "$a" = "-R" ] && HAVE_R=1
    PREV="$a"
done
if [ -n "$SIGN" ]; then printf '%s' "$SIGN" > "$FIX"; exit 0; fi
[ "${FAKE_VERIFY_FAIL:-0}" = "1" ] && exit 1
[ -f "$FIX" ] || exit 1
stored="$(cat "$FIX")"; [ -n "$stored" ] || exit 1
if [ "$HAVE_R" = "1" ]; then
    want="$(printf '%s' "$*" | sed -n 's/.*H"\([0-9A-Fa-f]*\)".*/\1/p')"
    [ -n "$want" ] || exit 1
    [ "$stored" = "$want" ] || exit 1
fi
if [ -n "$ARCH" ] && [ "${FAKE_FAIL_ARCH:-}" = "$ARCH" ]; then exit 1; fi
exit 0
STUB
cat > "$T/stubbin/lipo" <<'STUB'
#!/bin/bash
[ "${FAKE_LIPO_FAIL:-0}" = "1" ] && exit 1
if [ "${1:-}" = "-archs" ]; then printf '%s\n' "${FAKE_ARCHS:-arm64 x86_64}"; exit 0; fi
exit 0
STUB
cat > "$T/stubbin/swift" <<'STUB'
#!/bin/bash
touch "${FAKE_STATE_DIR}/swift-ran"
if [[ "$*" == *--show-bin-path* ]]; then printf '%s\n' "$FAKE_BIN_DIR"; exit 0; fi
mkdir -p "$FAKE_BIN_DIR"; printf 'fakebin' > "$FAKE_BIN_DIR/Verso"; exit 0
STUB
cat > "$T/stubbin/xcodebuild" <<'STUB'
#!/bin/bash
touch "${FAKE_STATE_DIR}/xcodebuild-ran"; exit 1
STUB
chmod +x "$T/stubbin"/security "$T/stubbin"/codesign "$T/stubbin"/lipo "$T/stubbin"/swift "$T/stubbin"/xcodebuild

# --- fixture copies of actual scripts; redirect ONLY absolute stub paths ---
cp "$PROJECT_DIR/scripts/signing.sh" "$F/scripts/signing.sh"
cp "$PROJECT_DIR/scripts/build.sh" "$F/scripts/build.sh"
cp "$PROJECT_DIR/scripts/release.sh" "$F/scripts/release.sh"
sed -e "s|/usr/bin/security|$T/stubbin/security|g" -e "s|/usr/bin/codesign|$T/stubbin/codesign|g" -e "s|/usr/bin/lipo|$T/stubbin/lipo|g" \
    "$F/scripts/signing.sh" > "$T/signing.patched" && mv "$T/signing.patched" "$F/scripts/signing.sh"
# plutil/grep/tr/awk stay real (ponytail: smallest interception).
export PATH="$T/stubbin:$PATH" # covers bare lipo/codesign/swift/xcodebuild in entry points
# shellcheck disable=SC1091
. "$F/scripts/signing.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
reset_state() { rm -f "$FAKE_STATE_DIR/signer" "$FAKE_STATE_DIR/swift-ran" "$FAKE_STATE_DIR/xcodebuild-ran"; }
mkapp() { # minimal bundle fixture with real-plutil-readable plist
    mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
    printf 'x' > "$1/Contents/MacOS/Verso"
    cat > "$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.verso.app</string></dict></plist>
PLIST
}

# 1. missing pin rejected (absent file + empty file)
reset_state
if signing_pin "$T/no-such.xcconfig" >/dev/null 2>&1; then bad "missing pin file accepted"; else ok "missing pin file rejected"; fi
printf '# empty\n' > "$T/pin-empty.xcconfig"
if signing_pin "$T/pin-empty.xcconfig" >/dev/null 2>&1; then bad "empty pin accepted"; else ok "empty pin rejected"; fi
# 2. malformed pin rejected
printf 'VERSO_SIGNING_IDENTITY = NOT-A-FINGERPRINT\n' > "$T/pin-bad.xcconfig"
if signing_pin "$T/pin-bad.xcconfig" >/dev/null 2>&1; then bad "malformed pin accepted"; else ok "malformed pin rejected"; fi
# 3. duplicate pin rejected (exactly-one-pin rule)
printf 'VERSO_SIGNING_IDENTITY = %s\nVERSO_SIGNING_IDENTITY = %s\n' "$GOOD_PIN" "$GOOD_PIN" > "$T/pin-dup.xcconfig"
if signing_pin "$T/pin-dup.xcconfig" >/dev/null 2>&1; then bad "duplicate pin accepted"; else ok "duplicate pin rejected"; fi
# 4. valid pin loads (uppercased)
printf 'VERSO_SIGNING_IDENTITY = %s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" > "$T/pin-good.xcconfig"
pin="$(signing_pin "$T/pin-good.xcconfig")" || { bad "valid pin rejected"; pin=""; }
[ "$pin" = "$GOOD_PIN" ] && ok "valid pin loads" || bad "valid pin mismatch"
# 5. cert-without-private-key rejected: cert hash present, no valid identity
reset_state; export FAKE_HAVE_PIN="" FAKE_CERT_PIN="$GOOD_PIN"
if signing_require_available "$GOOD_PIN" >/dev/null 2>&1; then bad "cert-without-key accepted"; else ok "cert-without-key rejected"; fi
# 6. unavailable identity rejected
export FAKE_HAVE_PIN="$WRONG_PIN" FAKE_CERT_PIN=""
if signing_require_available "$GOOD_PIN" >/dev/null 2>&1; then bad "unavailable identity accepted"; else ok "unavailable identity rejected"; fi
export FAKE_HAVE_PIN="$GOOD_PIN" FAKE_ARCHS="arm64 x86_64" FAKE_FAIL_ARCH="" FAKE_LIPO_FAIL="0" FAKE_VERIFY_FAIL="0"
if signing_require_available "$GOOD_PIN" >/dev/null 2>&1; then ok "available identity accepted"; else bad "available identity rejected"; fi
# 7. wrong signer rejected
reset_state
mkapp "$T/New.app"
signing_sign "$WRONG_PIN" "$T/New.app" >/dev/null 2>&1
if signing_verify "$GOOD_PIN" "$T/New.app" >/dev/null 2>&1; then bad "wrong signer accepted"; else ok "wrong signer rejected"; fi
# 8. one failing universal slice rejected
reset_state
mkapp "$T/Uni.app"
signing_sign "$GOOD_PIN" "$T/Uni.app" >/dev/null 2>&1
export FAKE_FAIL_ARCH="x86_64"
if signing_verify "$GOOD_PIN" "$T/Uni.app" >/dev/null 2>&1; then bad "failing slice accepted"; else ok "failing slice rejected"; fi
export FAKE_FAIL_ARCH=""
# 9. lipo failure rejected (fail-on-error, no silent skip)
export FAKE_LIPO_FAIL="1"
if signing_verify "$GOOD_PIN" "$T/Uni.app" >/dev/null 2>&1; then bad "lipo failure accepted"; else ok "lipo failure rejected"; fi
export FAKE_LIPO_FAIL="0"
# 10. happy path sign+verify passes
reset_state; mkapp "$T/Good.app"
signing_sign "$GOOD_PIN" "$T/Good.app" >/dev/null 2>&1 \
  && signing_verify "$GOOD_PIN" "$T/Good.app" >/dev/null 2>&1 \
  && ok "sign+verify pass (universal slices)" || bad "sign+verify failed"
# 11. build.sh with missing identity: old app preserved, swift never runs
reset_state
printf 'VERSO_SIGNING_IDENTITY = %s\n' "$GOOD_PIN" > "$F/Resources/Signing.xcconfig"
mkdir -p "$F/build/Verso.app/Contents/MacOS"
printf 'old-app-sentinel' > "$F/build/Verso.app/Contents/MacOS/Verso"
export FAKE_HAVE_PIN=""
if "$F/scripts/build.sh" >/dev/null 2>&1; then bad "build.sh succeeded without identity"; else ok "build.sh fails without identity"; fi
[ "$(cat "$F/build/Verso.app/Contents/MacOS/Verso")" = "old-app-sentinel" ] && ok "build.sh preserves old app" || bad "build.sh clobbered old app"
[ ! -e "$FAKE_STATE_DIR/swift-ran" ] && ok "build.sh never runs swift" || bad "build.sh ran swift without identity"
# 12. release.sh with missing identity: old release preserved, xcodebuild never runs
reset_state
mkdir -p "$F/build/releases/1.1.4"
printf 'old-release-sentinel' > "$F/build/releases/1.1.4/keep.txt"
if "$F/scripts/release.sh" >/dev/null 2>&1; then bad "release.sh succeeded without identity"; else ok "release.sh fails without identity"; fi
[ "$(cat "$F/build/releases/1.1.4/keep.txt")" = "old-release-sentinel" ] && ok "release.sh preserves old release" || bad "release.sh clobbered old release"
[ ! -e "$FAKE_STATE_DIR/xcodebuild-ran" ] && ok "release.sh never runs xcodebuild" || bad "release.sh ran xcodebuild without identity"
# 13. injected failure after host signing preserves old app (fake swift + minimal resources)
reset_state
export FAKE_HAVE_PIN="$GOOD_PIN" FAKE_VERIFY_FAIL="1" FAKE_BIN_DIR="$T/fakebin"
cp "$PROJECT_DIR/Resources/Info.plist" "$F/Resources/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$F/Resources/AppIcon.icns" 2>/dev/null || printf 'x' > "$F/Resources/AppIcon.icns"
mkdir -p "$F/Sources/VersoCore/Resources/en.lproj" "$F/Sources/VersoCore/Resources/tr.lproj"
cp "$PROJECT_DIR/Sources/VersoCore/Resources/en.lproj/Localizable.strings" "$F/Sources/VersoCore/Resources/en.lproj/Localizable.strings"
cp "$PROJECT_DIR/Sources/VersoCore/Resources/tr.lproj/Localizable.strings" "$F/Sources/VersoCore/Resources/tr.lproj/Localizable.strings"
printf 'old-app-sentinel' > "$F/build/Verso.app/Contents/MacOS/Verso"
if "$F/scripts/build.sh" >/dev/null 2>&1; then bad "build.sh succeeded despite verify failure"; else ok "build.sh fails on injected verify failure"; fi
[ "$(cat "$F/build/Verso.app/Contents/MacOS/Verso")" = "old-app-sentinel" ] && ok "old app preserved after signing failure" || bad "old app clobbered after signing failure"
export FAKE_VERIFY_FAIL="0"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
