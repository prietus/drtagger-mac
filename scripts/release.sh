#!/bin/bash
#
# Release build: archive with the Developer ID certificate, export, notarize
# with notarytool and staple the ticket. Produces build/release/drtagger-<version>.zip.
#
# One-time setup (stores an app-specific password in the Keychain):
#   xcrun notarytool store-credentials drtagger-notary --apple-id <apple id> --team-id LFTD9T269J
#
# Usage:
#   scripts/release.sh                 # archive + notarize + staple
#   SKIP_NOTARIZE=1 scripts/release.sh # archive and sign only (offline check)
#   NOTARY_PROFILE=other scripts/release.sh

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-drtagger-notary}"
OUT=build/release
ARCHIVE="$OUT/drtagger.xcarchive"
EXPORT="$OUT/export"
rm -rf "$OUT"
mkdir -p "$OUT"

if [ ! -x Vendor/ffmpeg/ffmpeg ]; then
    echo "error: Vendor/ffmpeg/ffmpeg missing; run scripts/build-ffmpeg.sh first" >&2
    exit 1
fi

xcodegen generate >/dev/null
echo "== Archiving (Release, Developer ID)"
xcodebuild -project drtagger.xcodeproj -scheme drtagger -configuration Release \
    -archivePath "$ARCHIVE" archive | grep -E "error:|warning: .*codesign|ARCHIVE (SUCCEEDED|FAILED)" || true
[ -d "$ARCHIVE" ] || { echo "error: archive failed" >&2; exit 1; }

echo "== Exporting"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions.plist \
    -exportPath "$EXPORT" | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" || true
APP="$EXPORT/drtagger.app"
[ -d "$APP" ] || { echo "error: export failed" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
ZIP="$OUT/drtagger-$VERSION-$BUILD.zip"

echo "== Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
for helper in "$APP"/Contents/Helpers/*; do
    codesign --verify --strict "$helper"
done

ditto -c -k --keepParent "$APP" "$ZIP"
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo "== Notarizing with profile $PROFILE"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    spctl --assess --type execute --verbose=2 "$APP"
fi
echo "Ready: $ZIP"
