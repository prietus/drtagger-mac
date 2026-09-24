# drtagger for Mac

A native macOS app for lossless music collections: it takes **SACD ISOs**,
**CD images with CUE sheets** and **folders of tracks**, splits or extracts
them into per-track files, **identifies the exact release** and writes
accurate, Picard-compatible tags, cover art and ReplayGain, then files
everything into your library.

- **SACD**: reads Scarletbook ISOs directly, extracts the stereo (and
  optionally multichannel) area to DSF, decodes DST losslessly, keeps the
  disc text and catalog number.
- **CD images**: sample-accurate CUE splitting to FLAC (WAV, FLAC, APE,
  WavPack, TTA images), HTOA and pregap handling, verification against the
  CUETools database, MusicBrainz disc IDs.
- **Identification**: every signal available, combined and scored with an
  explanation: barcodes and catalog numbers read from your scans (Vision),
  existing tags, disc TOC, AcoustID fingerprints, folder names, SACD disc
  text; MusicBrainz and Discogs candidates, hybrid-SACD layers, multi-disc
  release sets, format plausibility.
- **Tagging**: the Picard schema written to FLAC, DSF, WAV, AIFF, DSDIFF,
  APE, WavPack, TTA and ALAC, with a per-field diff and locks before writing,
  byte-exact backups and restore, and the audio payload hashed to prove it
  was never touched.
- **Extras**: EBU R128 loudness and ReplayGain 2 / R128 tags, cover art from
  Cover Art Archive, fanart.tv, Discogs, iTunes and Deezer, path templates
  with transliteration, Spanish and English UI.

Requires macOS 15 or later. The design, decisions and delivery phases are
in [DESIGN.md](DESIGN.md).

## Status

All planned phases are implemented and used daily by the author; releases
with signed, notarized builds are coming. Until then, build from source.

## API keys

The app ships without keys. MusicBrainz, Cover Art Archive, iTunes Search,
Deezer and CUETools DB need none. AcoustID (fingerprints), Discogs (credits
and editions) and fanart.tv (covers) take a key you create with your own
account, entered in Settings > Providers and stored in your Keychain, with a
"Test" button next to each.

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI app target (macOS 15+, Swift 6) |
| `Packages/FLACKit` | FLAC / DSF / WAV readers and writers, ID3v2, Vorbis comments |
| `Packages/Chromaprint` | Vendored chromaprint 1.5.1 (MIT) + `ChromaprintKit` Swift wrapper |
| `Packages/ProviderKit` | MusicBrainz, AcoustID, Discogs clients and the `Candidate` model |
| `Packages/LibraryKit` | Album discovery: folder scanner, CUE parser with encoding detection, SACD probe, disc TOC / IDs, split plan |
| `Packages/SplitKit` | ffmpeg driver, verified CUE image splitting to FLAC, CUETools DB CRCs, path templates |
| `Packages/SACDKit` | Scarletbook (SACD ISO) reader, frame reader, DSF writer, per-track extraction with ID3 tags |
| `Packages/DSTKit` | DST decoder emitting DSD bits (Swift port of FFmpeg's dstdec.c, LGPL) |
| `Packages/LoudnessKit` | EBU R128 loudness and true peak in Swift, ReplayGain 2 / R128 tags |
| `Packages/TagKit` | Picard tag schema, mapping from a release, merge with locks, writers for FLAC/DSF/WAV/AIFF/DFF/APE/WV/TTA/ALAC with audio verification, backups and restore, artwork processing |
| `Packages/IdentifyKit` | Release identification: artwork barcodes/OCR, tags, TOC, fingerprints, candidate scoring |
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
# …and split every CUE-based album it found into a folder:
open .build/DerivedData/Build/Products/Debug/drtagger.app --args --add ~/rips --split-into ~/Music/Library
# …or extract every SACD ISO (DSD or DST) to DSF:
open .build/DerivedData/Build/Products/Debug/drtagger.app --args --add ~/isos --extract-into ~/Music/Library
# …or identify everything in the queue (uses the AcoustID / Discogs keys from Settings):
open .build/DerivedData/Build/Products/Debug/drtagger.app --args --add ~/rips --identify
# Several ISOs or CD1/CD2 folders that are one release are grouped into a release set automatically
# (or by hand in the app) and identified, tagged and organised as one multi-disc album.
# …or identify and write tags + cover to every album with a confident match (originals backed up in the store):
open .build/DerivedData/Build/Products/Debug/drtagger.app --args --add ~/rips --identify --tag
```

Slow and network tests are opt-in: `DRTAGGER_SLOW_TESTS=1 swift test` in
`Packages/SplitKit` splits a real rip; `DRTAGGER_NETWORK_TESTS=1 swift test`
in `Packages/ProviderKit` and `Packages/IdentifyKit` queries the real services
(`DRTAGGER_ACOUSTID_KEY=<key>` additionally enables fingerprint tests); `DRTAGGER_SLOW_TESTS=1 swift test` in
`Packages/SACDKit` compares a real SACD extraction with sacd_extract's output.

DST decoding is CPU-bound: about 24x realtime per core in Release builds (a
70-minute DST disc takes 15 to 30 s on Apple silicon) but only ~1.5x per core in
Debug builds, so use a Release build for real extractions.

Without `Vendor/ffmpeg` the app still builds and falls back to a Homebrew
ffmpeg for development (Settings > Advanced shows which one is in use).
Homebrew's ffmpeg is a GPL build and must never be redistributed.

## Distribution

Developer ID + notarization (no App Sandbox). Set your team and a
"Developer ID Application" identity in Xcode; `scripts/embed-ffmpeg.sh` signs
the embedded helpers with the same identity so the hardened runtime and
notarization accept them.

## Licenses

drtagger for Mac is MIT licensed ([LICENSE](LICENSE)). Two components keep
their own licenses, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md):
DSTKit (LGPL 2.1+, a Swift port of FFmpeg's DST decoder) and the FFmpeg
helpers built at release time (LGPL 2.1+, GPL-free configuration).
Chromaprint is MIT.

## Release

`scripts/release.sh <version>` builds Release, signs the app and the ffmpeg
helpers with Developer ID (hardened runtime, secure timestamps), notarizes
and staples, then tags `v<version>`, creates the GitHub release with the zip
and bumps the cask in `prietus/homebrew-tap`. `NOTARIZE=0` only signs,
`PUBLISH=0` stops after notarization. It expects a notarytool keychain
profile (`NOTARY_PROFILE`, default `notarytool-profile`).

Install a release with:

```
brew install --cask prietus/tap/drtagger
```
