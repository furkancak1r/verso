#!/bin/bash
# One certificate pin is shared by Xcode and both packaging entry points.
set -euo pipefail
SIGNING_BUNDLE_ID="com.verso.app"
SIGNING_XCCONFIG_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Resources/Signing.xcconfig"

signing_pin() {
    local cfg="${1:-$SIGNING_XCCONFIG_DEFAULT}" line
    [ -f "$cfg" ] || { echo "[signing] Missing Signing.xcconfig" >&2; return 1; }
    line="$(/usr/bin/grep -E '^[[:space:]]*VERSO_SIGNING_IDENTITY[[:space:]]*=' "$cfg" || true)"
    [[ "$line" =~ ^[[:space:]]*VERSO_SIGNING_IDENTITY[[:space:]]*=[[:space:]]*([[:xdigit:]]{40})[[:space:]]*$ ]] \
        || { echo "[signing] Expected exactly one 40-hex certificate fingerprint" >&2; return 1; }
    printf '%s\n' "${BASH_REMATCH[1]}" | /usr/bin/tr 'a-f' 'A-F'
}

signing_require_available() {
    local identities
    identities="$(/usr/bin/security find-identity -v -p codesigning)" || return 1
    printf '%s\n' "$identities" | /usr/bin/awk -v pin="$1" '$2 == pin {found=1} END {exit !found}' \
        || { echo "[signing] Pinned signing identity unavailable; restore its private key in Keychain. No ad-hoc fallback." >&2; return 1; }
}

signing_sign() {
    /usr/bin/codesign --force --sign "$1" "$2"
}

signing_verify() {
    local pin="$1" app="$2" bid archs arch
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" || return 1
    bid="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" || return 1
    [ "$bid" = "$SIGNING_BUNDLE_ID" ] || { echo "[signing] Wrong bundle identifier" >&2; return 1; }
    archs="$(/usr/bin/lipo -archs "$app/Contents/MacOS/Verso")" || return 1
    [ -n "$archs" ] || return 1
    for arch in $archs; do
        /usr/bin/codesign --verify --deep --strict --arch "$arch" \
            -R "=identifier \"$SIGNING_BUNDLE_ID\" and certificate leaf = H\"$pin\"" "$app" || return 1
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        pin) signing_pin "${2:-}" ;;
        require-available) signing_require_available "${2:?certificate fingerprint required}" ;;
        verify) signing_verify "${2:?certificate fingerprint required}" "${3:?app required}" ;;
        *) echo "Usage: $0 {pin [XCCONFIG]|require-available PIN|verify PIN APP}" >&2; exit 64 ;;
    esac
fi
