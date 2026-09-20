# drtagger for Mac

Native macOS app that splits SACD ISOs and CD images (+CUE) into tracks,
identifies the exact release and writes accurate, player-friendly metadata.
Scope, decisions and delivery phases live in [DESIGN.md](DESIGN.md).

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI app target (macOS 15+, Swift 6) |
| `Packages/FLACKit` | FLAC / DSF / WAV readers and writers, ID3v2, Vorbis comments |
| `Packages/Chromaprint` | Vendored chromaprint 1.5.1 (LGPL) + `ChromaprintKit` Swift wrapper |
| `Packages/ProviderKit` | MusicBrainz, AcoustID, Discogs clients and the `Candidate` model |
| `Packages/LibraryKit` | Album discovery: folder scanner, CUE parser with encoding detection, SACD probe |
| `Vendor/ffmpeg` | Minimal LGPL ffmpeg/ffprobe embedded in the app (built, not committed) |
| `scripts/build-ffmpeg.sh` | Reproducible ffmpeg build (arm64 + x86_64) |
| `scripts/embed-ffmpeg.sh` | Xcode run-script phase that copies and signs the helpers |
| `Tests/` | App unit tests (Swift Testing) |

## Building

```sh
brew install xcodegen          # once
scripts/build-ffmpeg.sh        # once, ~10 min; produces Vendor/ffmpeg/{ffmpeg,ffprobe}
xcodegen generate              # regenerates drtagger.xcodeproj from project.yml
open drtagger.xcodeproj
```

Command line:

```sh
xcodebuild -project drtagger.xcodeproj -scheme drtagger -configuration Debug build
xcodebuild -project drtagger.xcodeproj -scheme drtagger test
```

Package tests run with `swift test` inside each `Packages/*` folder.

To load a library at launch without the open panel:

```sh
open .build/DerivedData/Build/Products/Debug/drtagger.app --args --add ~/mactagger-samples
```

Without `Vendor/ffmpeg` the app still builds and falls back to a Homebrew
ffmpeg for development (Settings > Advanced shows which one is in use).
Homebrew's ffmpeg is a GPL build and must never be redistributed.

## Distribution

Developer ID + notarization (no App Sandbox). Set your team and a
"Developer ID Application" identity in Xcode; `scripts/embed-ffmpeg.sh` signs
the embedded helpers with the same identity so the hardened runtime and
notarization accept them.

## Licenses

- chromaprint: LGPL 2.1+ (source shipped unmodified in `Packages/Chromaprint`)
- ffmpeg: LGPL 2.1+; the exact tarball, checksum and configure line are in
  `Vendor/ffmpeg/BUILD-INFO.txt`
