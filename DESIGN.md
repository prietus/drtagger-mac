# drtagger for Mac — Design

Working name: **drtagger for Mac**. Bundle id `us.priet.drtagger-mac`. Repo: `mactagger`.
Decisions below were agreed in the kickoff interview on 2026-09-20. Change this
file when a decision changes; it is the source of truth for scope.

## 1. Goal

A native macOS (SwiftUI) app that takes audiophile rips as they circulate
(SACD ISO, CD images + CUE, folders of lossless tracks), splits images into
per-track files, identifies the exact release, and writes metadata that music
players read correctly and consistently. Identification reuses the acoustic
fingerprint stack from the iOS app `drtagger` and the artwork OCR/barcode
scanner from `OBIScanner`.

## 2. Scope

### Inputs
- **SACD ISO** (Scarletbook): stereo area by default, multichannel optional.
  Uncompressed DSD and DST-compressed discs.
- **CD images + CUE**: BIN/ISO/WAV/FLAC/APE/WV/TTA image with a `.cue`, or a
  multi-file CUE (one FILE per track, e.g. JVC XRCD WAV rips). CUE encoding
  sniffed (UTF-8 with/without BOM, CP1252, Latin-1, CP1251, Shift-JIS); the
  NAS survey found ASCII, UTF-8, ISO-8859-1 and CP1252 (smart quotes,
  en-dash). AppleDouble `._*` files and `.dr_done` markers are ignored.
- **Loose tracks**: FLAC, APE, WavPack, TTA, WAV, AIFF, ALAC (.m4a), DSF, DFF.
- No lossy formats. No DVD-Audio / Blu-ray Audio.
- Sources: local folders and mounted volumes (USB, SMB/NFS). No WebDAV.

### Outputs
- SACD → one **DSF** per track, ID3v2.4 tags. Multichannel area, if selected,
  goes to its own subfolder. No DSD→PCM conversion.
- CD image → one **FLAC** per track (level 8, same bit depth / sample rate),
  pregap (INDEX 00) appended to the previous track, HTOA saved as track 00
  when present. Split verified by decoding the image and the tracks and
  comparing sample counts and stream MD5.
- Destination: a configurable library root with a path template, default
  `{albumartist}/{album} ({year})/{track} {title}` and `Disc N/` subfolders
  only for multi-disc releases. Originals are never modified; an optional
  "move original to Trash after verification" toggle exists.

### Identification signals (highest priority first)
1. **Barcode** (EAN-13 / UPC) read from artwork in the folder via Vision →
   MusicBrainz `barcode:` and Discogs barcode search. Exact release.
2. **Catalog number** OCR'd from OBI / back cover (Vision, `ja` enabled,
   three rotations) → MB `catno:` + Discogs, disambiguated by artist/album.
3. **MusicBrainz DiscID** computed from the CUE TOC, plus the CUE's own
   `CATALOG` (UPC/EAN) and `REM COMMENT` / `REM DISCID` lines, which EAC and
   XLD rips often fill with barcode and catalog number.
4. **Existing tags / MBIDs** already in the files.
5. **Acoustic fingerprints** of all tracks (Chromaprint → AcoustID, 3 req/s),
   each track votes for the releases containing its recording; releases are
   ranked by coverage, track count and duration fit.
6. **SACD disc text** or folder name as a free-text fallback query.

Every candidate is validated against track count and per-track durations.
When two independent signals agree the candidate is marked *confident*.

### Automation
Confident candidates are preselected but **never written without a preview**.
The preview shows a per-track tag diff and artwork changes. Batch action
"apply all confident" still shows a summary before writing.

### Metadata providers
| Provider | Key | Used for |
|---|---|---|
| MusicBrainz | none (User-Agent) | canonical identity: titles, artists, dates, MBIDs, ISRC, works, sort names, DiscID |
| AcoustID | app key entered by user | fingerprint lookup |
| Cover Art Archive | none | front/back artwork |
| Discogs | personal token | per-track credits, styles, label/catno detail, edition notes |
| fanart.tv | user key | hi-res album/artist art |
| iTunes Search | none | hi-res front cover (up to 3000 px) |
| Deezer | none | cover 1000 px, genres |

Field priority: MusicBrainz wins identity fields; Discogs fills credits and
detail MB lacks. Conflicts are flagged in the preview with a per-field source
switch. Default priority is a setting. All keys live in the Keychain; the app
ships with no keys and links to each provider's key page.

### Tag schema
Picard/MusicBrainz standard mapping, identical semantics across containers:
- FLAC → Vorbis comments (existing FLACKit)
- DSF, WAV, AIFF → ID3v2.4 (FLACKit ID3v2, extended for WAV/AIFF)
- APE, WavPack, TTA → APEv2 (new in FLACKit)
- ALAC (.m4a) → MP4/iTunes atoms (new in FLACKit)

Core fields: TITLE, ARTIST, ARTISTSORT, ALBUM, ALBUMSORT, ALBUMARTIST,
ALBUMARTISTSORT, DATE, ORIGINALDATE, TRACKNUMBER, TRACKTOTAL, DISCNUMBER,
DISCTOTAL, DISCSUBTITLE, LABEL, CATALOGNUMBER, BARCODE, MEDIA, RELEASECOUNTRY,
RELEASESTATUS, RELEASETYPE, ISRC, GENRE, STYLE, COMPOSER, COMPOSERSORT,
CONDUCTOR, PERFORMER (with instrument), PRODUCER, WORK, MOVEMENT,
MOVEMENTNUMBER, MUSICBRAINZ_ALBUMID / _ALBUMARTISTID / _ARTISTID /
_TRACKID / _RELEASETRACKID / _RELEASEGROUPID / _WORKID / _DISCID,
ACOUSTID_ID, ACOUSTID_FINGERPRINT, REPLAYGAIN_* / R128_*.

Classical: Picard classical layout (composer in COMPOSER, work relations in
WORK/MOVEMENT, performers in ARTIST/PERFORMER). ALBUMARTIST as credited by MB.

Non-Latin releases: write the release's original script in TITLE/ALBUM/ARTIST,
put MB transliterations/aliases in the *SORT fields, and always use an
ASCII-safe transliteration for file names. Global setting to force Latin
script in display fields.

Overwrite policy: fields mapped from the candidate are replaced; every other
field (ReplayGain, comments, custom tags, unknown frames) is preserved
byte-exact. Individual fields can be locked in the preview.

### Artwork
Front cover embedded, resized to max 1500 px JPEG ~90%. Full-resolution
`cover.jpg` plus back / obi / booklet scans kept as files. Existing local art
is not replaced without asking. Size and format are settings.

### Analysis extras
- ReplayGain / EBU R128 per track and album via ffmpeg `ebur128`, written as
  REPLAYGAIN_* (PCM) and R128_* (DSF).
- CD rip verification against **CUETools DB** (TOC + per-track CRC, no key).
- Not in scope for now: DR meter, lyrics, genre/mood providers, reorganising
  already-tagged loose albums.

### Backups
Before any write, the original metadata blocks (tags + pictures) and the
audio stream hash are stored in the app database. Restore rewrites those
blocks. Audio is never rewritten; stream MD5 is verified after each write.

## 3. Architecture

- **App**: SwiftUI, macOS 15+, Swift 6 strict concurrency, Observation.
  String Catalog with English base and Spanish localisation.
- **Workflow**: album queue with states (pending → scanning → identifying →
  confident / needs review → applying → done / error), an inspector per
  album (candidates, tag diff, artwork, log), background jobs with progress.
- **Persistence**: SwiftData store for albums, jobs, backups and provider
  caches. (Swap for GRDB if SwiftData concurrency proves painful.)
- **Distribution**: Developer ID, hardened runtime, notarised DMG. The design
  stays App Store compatible (sandbox + bookmarks) but that is not a goal.

### Packages (copied from `~/drtagger/Packages`, evolved independently)
- `FLACKit` — FLAC / DSF / WAV readers and writers. To add: APEv2, MP4 atoms,
  ID3v2 in WAV/AIFF, AIFF reader, DFF reader.
- `ChromaprintKit` — vendored chromaprint 1.5.1 (vDSP backend, LGPL 2.1).
- `DrtaggerNetwork` — MusicBrainz, AcoustID, Discogs clients and `Candidate`.
  To add: Cover Art Archive, fanart.tv, iTunes Search, Deezer, CUETools DB,
  rate limiting per provider, on-disk response cache. WebDAV code dropped.

### New modules
- `ImageKit` — Scarletbook (SACD ISO) reader: master TOC, area TOCs, disc
  text, track list, DSD/DST frame extraction, DSF writer. Written from the
  Scarletbook specification, no GPL code. Layout verified against 205 real
  ISOs on 2026-09-20 (2048-byte sectors; master TOC at sector 510, `SACDMTOC`;
  area starts at master offsets 64/72; area TOC: frame format at byte 21
  (0 DST, 2/3 DSD), channel count at 32, track offset/count at 68/69,
  track start/end sectors at 72/76, play time at 64). Disc text uses
  per-locale character sets (ISO 646, ISO 8859-1, …) and is often empty or
  wrong, hence a fallback signal only. sacd_extract XML sidecars next to
  the ISOs serve as ground truth for parser tests. CUE parser with encoding sniffing,
  TOC → MusicBrainz DiscID, CTDB TOC id.
- `Transcoder` — wraps the bundled `ffmpeg` (Process, stdin/stdout pipes):
  decode any input to PCM for fingerprinting, split image ranges to FLAC,
  run `ebur128` / `replaygain`.
- `DSTKit` — DST (Direct Stream Transfer) decoder that outputs the DSD
  bitstream. Verified on 2026-09-20: ffmpeg's `dst` decoder always runs its
  DSD→PCM filter and emits float PCM, so it cannot produce lossless DSF from
  a DST disc. Plan: vendor ffmpeg's LGPL `libavcodec/dstdec.c` (plus its
  arithmetic decoder and tables, minus the dsd2pcm stage) as a C target
  like `Chromaprint`, with source shipped for LGPL compliance. Phase 3.
- `Identify` — signal collection, candidate ranking, confidence.
- `TagMap` — Picard schema ↔ container writers, merge with locked fields.
- `ArtworkScan` — Vision OCR + barcode (port of drtagger `ArtworkScanner` to
  CGImage).

### ffmpeg
`scripts/build-ffmpeg.sh` builds a minimal LGPL ffmpeg (no `--enable-gpl`,
no `--enable-nonfree`) for arm64 + x86_64, lipo'd into `Vendor/ffmpeg`, with
only: demuxers ape, wv, tta, flac, wav, aiff, mov, dsf, iff(dff), dst;
decoders ape, wavpack, tta, alac, flac, pcm_*, dsd_*, dst; encoder flac,
pcm; filters ebur128, aresample. The exact source tarball and configure
line are recorded for LGPL compliance. Homebrew's ffmpeg is GPL and is used
only as a dev-time fallback via a settings override.

### Provider etiquette
MusicBrainz 1 req/s with a descriptive User-Agent; AcoustID 3 req/s; Discogs
60 req/min authenticated; Deezer / iTunes / fanart with conservative limits.
Responses cached on disk keyed by URL with provider-specific TTLs.

## 4. Delivery phases

0. Scaffold: XcodeGen project, copied packages made macOS-only, ffmpeg build
   script, settings + Keychain, empty queue UI.
1. Library scan and album detection (ISO / image+CUE / track folder), queue
   with states, SwiftData store.
2. CUE parsing, image splitting with verification, DiscID, CTDB check.
3. SACD ISO reader, DSF extraction, DST via ffmpeg, disc text.
4. Identification pipeline: artwork barcode/OCR, DiscID, tags, fingerprints,
   voting, confidence; providers MB / Discogs / CAA / fanart / iTunes / Deezer.
5. Tag mapping and writers for every container, artwork policy, preview with
   diff and field locks, backups and restore.
6. ReplayGain, path templates, localisation, signing and notarisation.

## 5. Sample files

Source library: NFS mount `~/nfs` (read-only, NAS share):
`isos/` 205 SACD ISOs (71 DST, 48 with multichannel area, many with
sacd_extract `.xml` sidecars), `rips/` 214 CD rips (193 CUEs, 123 of them
single-image, several with HTOA), `dsf/` extracted DSF albums with ID3v2.4.

Curated local copy for development and fixtures: `~/mactagger-samples/`
- `isos/` Goldberg Variations (DSD 2ch, 32 tracks, XML), A Love Supreme (DSD
  2ch, disc text, Japanese catalog), Bach Cantatas Vol. 40 (DST 2ch + 5ch,
  XML), Space Oddity (DST 2ch, 0.7 GB, quick tests).
- `cue-images/` the only two real single-image rips on the NAS: Miles Davis
  "Walkin'" XRCD (FLAC image + CUE with HTOA) and Diana Krall "All For You"
  XRCD (FLAC image + CUE).
- `cue/` already-split albums whose CUE still describes the original image:
  Leno (CUE says APE, tracks are FLAC, Spanish accents), Diamond Dogs (HTOA,
  INDEX 00, EAC log, full scan set with barcode for OCR tests), Ella and
  Oscar (9-file WAV CUE, INDEX 00 on every track, .accurip). Useful for CUE
  parsing, multi-file CUEs and artwork scanning, not for splitting.
- `cue-encodings/` CUEs in ISO-8859-1 and CP1252.
- `dsf/` two sacd_extract DSF tracks with ID3v2.4.
- `loose/` an ALAC .m4a with embedded cover, a DSF track.

Still missing: APE, WavPack and TTA images (none on the NAS; generate from
the Walkin' FLAC with `mac`, `wavpack`, `ttaenc`), a hybrid-flag SACD (none
on the NAS), Shift-JIS and CP1251 CUEs (synthesise from a UTF-8 CUE).
