#!/bin/bash
#
# Xcode run-script phase: copies the LGPL ffmpeg/ffprobe built by
# scripts/build-ffmpeg.sh into the app bundle (Contents/Helpers) and signs
# them with the same identity as the app so the hardened runtime and
# notarization accept them. When the binaries are missing the build still
# succeeds; the app then falls back to a system ffmpeg (Settings > Advanced).

set -euo pipefail

SRC="$SRCROOT/Vendor/ffmpeg"
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$DEST"

for bin in ffmpeg ffprobe; do
    if [ ! -f "$SRC/$bin" ]; then
        echo "warning: $SRC/$bin not found; run scripts/build-ffmpeg.sh to embed it"
        continue
    fi
    cp -f "$SRC/$bin" "$DEST/$bin"
    chmod 755 "$DEST/$bin"
    if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        # Release archives need a secure timestamp for notarization; Debug
        # builds skip it so an offline machine still builds.
        if [ "${CONFIGURATION:-Debug}" = "Release" ]; then TS="--timestamp"; else TS="--timestamp=none"; fi
        codesign --force --options runtime $TS \
            --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$DEST/$bin"
    fi
done

# License texts and build provenance go under Resources: anything else under
# Contents/ is treated as code by codesign and would have to be signed.
DOCS="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ffmpeg"
mkdir -p "$DOCS"
for doc in BUILD-INFO.txt LICENSE.md COPYING.LGPLv2.1; do
    [ -f "$SRC/$doc" ] && cp -f "$SRC/$doc" "$DOCS/$doc"
done
exit 0
