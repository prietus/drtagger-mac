#!/bin/bash
set -euo pipefail

# drtagger for Mac release script (modelled on BorgMac's).
# Usage: scripts/release.sh 0.1.0
#        NOTARIZE=0 scripts/release.sh 0.1.0   # sign only, no notarization (dev)
#        PUBLISH=0  scripts/release.sh 0.1.0   # notarize, but no tag / GitHub release / tap bump
#
# Builds a Release .app signed with Developer ID (app and the embedded
# ffmpeg/ffprobe helpers, hardened runtime, secure timestamps), notarizes
# and staples it, and leaves the artifacts in ./dist. With PUBLISH=1
# (default) it tags v<VERSION>, pushes, creates the GitHub release with the
# zip attached and bumps version + sha256 in the cask at
# $TAP_DIR/Casks/drtagger.rb (clone of prietus/homebrew-tap).

VERSION="${1:?Usage: scripts/release.sh VERSION}"
NOTARIZE="${NOTARIZE:-1}"
PUBLISH="${PUBLISH:-1}"

GH_REPO="prietus/drtagger-mac"
TAP_DIR="${TAP_DIR:-$HOME/homebrew-tap}"
CASK_FILE="Casks/drtagger.rb"

TEAM_ID="LFTD9T269J"
SIGN_ID="Developer ID Application: carlos prieto ortiz ($TEAM_ID)"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="/tmp/drtagger-release-build"
OUT_DIR="$PROJECT_DIR/dist"
# Unversioned .app so copying to /Applications overwrites the previous one;
# the zip carries the version.
APP_OUT="$OUT_DIR/drtagger.app"
ZIP_OUT="$OUT_DIR/drtagger-${VERSION}.zip"

cd "$PROJECT_DIR"

if [ ! -x Vendor/ffmpeg/ffmpeg ] || [ ! -x Vendor/ffmpeg/ffprobe ]; then
    echo "ERROR: Vendor/ffmpeg/{ffmpeg,ffprobe} missing — run scripts/build-ffmpeg.sh first." >&2
    exit 1
fi

if [ "$PUBLISH" = "1" ]; then
    echo "==> Pre-flight checks for publishing..."
    if [ "$NOTARIZE" != "1" ]; then
        echo "ERROR: PUBLISH=1 requires NOTARIZE=1 (never ship an un-notarized build)." >&2
        exit 1
    fi
    if [ -n "$(git status --porcelain)" ]; then
        echo "ERROR: working tree is dirty — commit or stash before publishing." >&2
        exit 1
    fi
    if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
        echo "ERROR: releases are cut from main." >&2
        exit 1
    fi
    if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
        echo "ERROR: tag v${VERSION} already exists." >&2
        exit 1
    fi
    if [ ! -f "$TAP_DIR/$CASK_FILE" ]; then
        echo "ERROR: cask not found at $TAP_DIR/$CASK_FILE (clone prietus/homebrew-tap there, or set TAP_DIR)." >&2
        exit 1
    fi
    gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not authenticated." >&2; exit 1; }
fi

echo "==> Generating Xcode project from project.yml..."
xcodegen generate >/dev/null

echo "==> Cleaning previous build artifacts..."
rm -rf "$DERIVED" "$APP_OUT" "$ZIP_OUT"
mkdir -p "$OUT_DIR"

echo "==> Building Release v${VERSION}..."
xcodebuild \
    -project drtagger.xcodeproj \
    -scheme drtagger \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_ID" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    build \
    | grep -E "^(warning:|error:|\*\*)" || true

BUILT_APP="$DERIVED/Build/Products/Release/drtagger.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "ERROR: build did not produce $BUILT_APP" >&2
    exit 1
fi

echo "==> Copying to $APP_OUT..."
cp -R "$BUILT_APP" "$APP_OUT"

echo "==> Re-signing inside-out (helpers first, then the app)..."
for helper in "$APP_OUT"/Contents/Helpers/*; do
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$helper"
done
codesign --force --options runtime --timestamp \
    --entitlements "$PROJECT_DIR/App/drtagger.entitlements" \
    --sign "$SIGN_ID" "$APP_OUT"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_OUT"
for helper in "$APP_OUT"/Contents/Helpers/*; do
    codesign --verify --strict "$helper"
done
codesign -dv --verbose=4 "$APP_OUT" 2>&1 \
    | grep -E "(Identifier|TeamIdentifier|Authority|Timestamp|Runtime)" || true

if [ "$NOTARIZE" != "1" ]; then
    echo
    echo "==> Notarization skipped (NOTARIZE=$NOTARIZE)."
    echo "    App: $APP_OUT (signed but NOT notarized)"
    exit 0
fi

echo "==> Wrapping into zip for notarization..."
ditto -c -k --keepParent "$APP_OUT" "$ZIP_OUT"

echo "==> Submitting to Apple notarization service (this can take 1-5 min)..."
xcrun notarytool submit "$ZIP_OUT" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> Stapling notarization ticket to the .app..."
xcrun stapler staple "$APP_OUT"

echo "==> Re-zipping the stapled .app for distribution..."
rm -f "$ZIP_OUT"
ditto -c -k --keepParent "$APP_OUT" "$ZIP_OUT"

echo "==> Final Gatekeeper assessment (should now pass):"
spctl --assess --type exec --verbose=4 "$APP_OUT"

SHA256="$(shasum -a 256 "$ZIP_OUT" | awk '{print $1}')"
echo "==> sha256: $SHA256"

if [ "$PUBLISH" != "1" ]; then
    echo
    echo "==> Publish skipped (PUBLISH=$PUBLISH)."
    echo "    App: $APP_OUT (notarized + stapled)"
    echo "    Zip: $ZIP_OUT"
    exit 0
fi

echo "==> Tagging v${VERSION} and pushing to origin..."
git tag -a "v${VERSION}" -m "drtagger for Mac ${VERSION}"
git push origin main "v${VERSION}"

echo "==> Creating GitHub release v${VERSION} with $(basename "$ZIP_OUT") attached..."
gh release create "v${VERSION}" "$ZIP_OUT" \
    --repo "$GH_REPO" \
    --title "drtagger for Mac ${VERSION}" \
    --notes "Signed and notarized build for macOS 15 or later (Apple silicon and Intel). Install with \`brew install --cask prietus/tap/drtagger\`, or unzip and move drtagger.app to /Applications.

sha256 \`${SHA256}\`" \
    --generate-notes

echo "==> Bumping cask to ${VERSION} in ${TAP_DIR}..."
(
    cd "$TAP_DIR"
    git pull -q --ff-only
    sed -i '' -E \
        -e "s|^(  version \").*(\")$|\1${VERSION}\2|" \
        -e "s|^(  sha256 \").*(\")$|\1${SHA256}\2|" \
        "$CASK_FILE"
    git add "$CASK_FILE"
    git commit -q -m "drtagger ${VERSION}"
    git push -q
)

echo
echo "==> Done."
echo "    App:     $APP_OUT"
echo "    Zip:     $ZIP_OUT"
echo "    Release: https://github.com/${GH_REPO}/releases/tag/v${VERSION}"
echo "    Install: brew install --cask prietus/tap/drtagger"
