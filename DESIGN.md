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
6. **SACD disc text** or folder name as a free-text fallback query. The
   folder name is parsed properly (`FolderNameParser`): "Artist - Year -
   Title", trailing edition words ("20th Anniversary Edition", "2011
   Remaster"), the medium ("XRCD", "Vinyl Rip", "MQA", "SACD"), the country
   ("Japan", "W. Germany", "US") and bracketed notes, which are mined for
   catalog numbers and barcodes. The edition triggers a second, more precise
   text search; medium, country, edition and pressing year are soft scoring
   signals. Picard tags feed the same hints (ALBUM edition, ORIGINALDATE vs
   DATE, RELEASECOUNTRY, MEDIA).

Every candidate is validated against track count and per-track durations.
When two independent signals agree the candidate is marked *confident*.

Each candidate also gets a format tier — *fits*, *unknown* or *unlikely* —
from its media against what the local files allow (a SACD ISO can only be a
SACD; a 16/44 rip can be a CD, a hybrid's CD layer or a download; hi-res PCM
can be a download, vinyl, SACD or DVD-A) and the medium named in the folder,
which always wins. The UI folds *unlikely* releases into a disclosure (on by
default only for SACD images) and never hides them: MusicBrainz often lacks
or mislabels formats, and the right edition may simply not exist there.

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
  CTDB CRCs are plain CRC32 of 16-bit PCM with the first 5880 samples after
  track 1's INDEX 01 and the last 5880 samples of the disc excluded
  (established empirically on 2026-09-20; matches CUETools' "stride").
- Not in scope for now: DR meter, lyrics, genre/mood providers, reorganising
  already-tagged loose albums.

### Backups
Before any write, the original metadata blocks (tags + pictures) and the
audio stream hash are stored in the app database. Restore rewrites those
blocks. Audio is never rewritten; stream MD5 is verified after each write.

## 3. Architecture

- **App**: SwiftUI, macOS 15+, Swift 6 strict concurrency, Observation.
  String Catalog with English base and Spanish localisation.
- **Workflow**: album queue with states (pending → scanning → scanned →
  identifying → confident / needs review → applying → done, error from any
  step), an inspector per album (candidates, tag diff, artwork, log),
  background jobs with progress. `drtagger --add <path>…` scans paths at
  launch (used by tests and scripts).
- **Persistence**: SwiftData store in Application Support/drtagger
  (`AlbumRecord`: scalar columns for the sidebar plus the scanner's
  `DetectedAlbum` as JSON). All writes happen on the main context; the
  scanner runs detached and hands back Sendable values. Jobs, backups and
  provider caches join the same store in later phases.
- **Distribution**: Developer ID, hardened runtime, notarised DMG. The design
  stays App Store compatible (sandbox + bookmarks) but that is not a goal.

### Packages (copied from `~/drtagger/Packages`, evolved independently)
- `FLACKit` — FLAC / DSF / WAV readers and writers. To add: APEv2, MP4 atoms,
  ID3v2 in WAV/AIFF, AIFF reader, DFF reader.
- `ChromaprintKit` — vendored chromaprint 1.5.1 (vDSP backend, LGPL 2.1).
- `DrtaggerNetwork` — MusicBrainz, AcoustID, Discogs clients and `Candidate`.
  Added: `CUEToolsDBClient` (TOC lookup, XML parsing, CRC verification; CTDB
  also returns MusicBrainz release candidates for the TOC, an extra
  identification signal). To add: Cover Art Archive, fanart.tv, iTunes
  Search, Deezer, rate limiting per provider, on-disk response cache.
  WebDAV code dropped.

### New modules
- `LibraryKit` (phase 1, done) — album discovery. `LibraryScanner` walks
  folders and yields `DetectedAlbum`s of kind `sacdISO`, `cueImage`,
  `cueMultiFile` or `trackFolder`, with multi-disc grouping (`CD1`, `Disc 2`…),
  orphan CUEs kept as hints, artwork and log collection, junk filtering.
  `CueSheet` parses CUE files with encoding detection (UTF-8/BOM, Shift-JIS by
  double-byte runs, CP1251 by Cyrillic words, else CP1252/Latin-1) and
  exposes barcode / catalog / DiscID hints from CATALOG and REM lines.
  `SACDProbe` reads the Scarletbook master TOC, master text and area TOCs.
  `DiscTOC` rebuilds the CD TOC from a CUE plus file lengths and yields the
  MusicBrainz Disc ID, FreeDB ID (checked against real REM DISCIDs) and the
  CUETools DB TOC string; `CueSplitPlan` gives sample-accurate track ranges
  (gaps appended to the previous track, HTOA as track 00 above a threshold).
- `SACDKit` (phase 3, DSD part done) — Scarletbook (SACD ISO) reader and
  extractor. `SACDDiscReader` parses the master TOC / text and, per area, the
  TOC, `SACDTRL1` (track start sectors and lengths), `SACDTRL2` (track start
  time codes and durations), `SACD_IGL` (12-char ISRCs, then genre codes) and
  `SACDTTxt` (u16 position per track; item count + items of {type, reserved,
  NUL text} padded to 4; types 1 title, 2 performer, 3 songwriter, 4 composer,
  5 arranger, 6 message). `SACDFrameReader` walks the audio sectors: header
  byte = packet_info_count:3, frame_info_count:3, reserved:1, dst:1; packet
  entries of 2 bytes (frame_start:1, reserved:1, data_type:3 with 2 = audio,
  length:11); frame infos of 3 bytes (min, sec, frame) for DSD or 4 for DST;
  payloads follow. A frame is the bytes from one frame_start to the next; a
  stereo DSD frame is 9408 bytes, interleaved per channel, MSB-first bits.
  Tracks have TOC durations shorter than the gap to the next track (a pause,
  like a CD pregap) and a 2 s lead-in before track 1. `DSFWriter` de-
  interleaves into 4096-byte channel blocks with bit reversal and appends an
  ID3v2.3 tag (via FLACKit's bridge). `SACDExtractor` cuts by frame time code
  with a pause policy (append to previous, the default, or drop as
  sacd_extract does). Verified 2026-09-21: extracting "A Love Supreme" with
  the drop policy reproduces sacd_extract's three DSF files byte for byte.
  DST areas go through `DSTKit` in parallel batches (one decoder per slot,
  `DispatchQueue.concurrentPerform`), frames stay in order.
- `DSTKit` (phase 3, done) — DST (ISO/IEC 14496-3 subpart 10) decoder that
  emits the DSD bitstream, a Swift port of FFmpeg's LGPL `dstdec.c` stopped
  before its DSD→PCM stage: MSB-first bit reader, JPEG-LS Rice-Golomb codes,
  filter/probability tables with prediction, 12-bit arithmetic decoder,
  128-bit per-channel history with 16 table lookups per sample. Output is
  interleaved per channel MSB first, the same layout as uncompressed frames,
  so the DSF writer is shared. Handles the "uncompressed DST frame" case and
  reports multi-segment frames as unsupported (no SACD uses them). The
  package is LGPL 2.1+ (see Packages/DSTKit/LICENSE). Verified 2026-09-21:
  a 1.8 GB DST disc (14 tracks) extracted with the drop policy matches
  sacd_extract's DSF output byte for byte; Release throughput ~24x realtime
  per core (33 s for the disc with parallel batches), Debug ~1.5x per core.
- `SplitKit` (phase 2, done) — `FFmpegTool` drives the bundled ffmpeg
  (ffprobe JSON, decode to raw PCM, FLAC encode from a stdin pipe with a
  running MD5/CRC of the bytes fed). `ImageSplitter` decodes the image (or
  the run of per-track files) once, cuts sample-accurate ranges from
  `CueSplitPlan`, verifies every track's STREAMINFO MD5 against the fed
  PCM (falls back to a decode + CRC compare), writes provisional Vorbis
  tags from the CUE, and computes CUETools DB CRCs. `PathTemplate` renders
  `{albumartist}/{album} ({year})/{track} {title}` safely. Verified on a
  real XRCD rip: all five track CRCs and the disc CRC equal the CTDB entry.
  `PathTemplate` renders the templates with an optional ASCII
  transliteration (`asciiSafe`: Latin transform, diacritics stripped,
  typographic punctuation normalised).
- `LoudnessKit` (phase 6, done) — ITU-R BS.1770-4 / EBU R128 in Swift:
  K-weighting biquads derived for any sample rate (libebur128 constants),
  400 ms blocks every 100 ms, absolute and relative gates, sample peak and
  true peak by 4×/2× polyphase sinc interpolation. Album loudness gates the
  union of every track's blocks. Audio is decoded by the bundled ffmpeg to
  32-bit PCM (DSD and >192 kHz resampled to 88.2 kHz); the meter agrees
  with ffmpeg's `ebur128` within 0.15 LU / 0.2 dB and reads the EBU Tech
  3341 calibration tone at -23.0 LUFS. `ReplayGain` writes RG2 tags
  (reference -18 LUFS, true-peak factor) and, for DSD, R128_TRACK/ALBUM_GAIN
  in Q7.8 relative to -23 LUFS.
- `IdentifyKit` (phase 4, done) — `SignalCollector` gathers barcodes and
  catalog numbers from artwork (Vision barcodes in three orientations, OCR
  with `ja`, glued codes like PD83889 recognised), existing tags via ffprobe
  (BARCODE, CATALOGNUMBER, MUSICBRAINZ_ALBUMID…), CUE hints, SACD disc text,
  folder name (artist, title, year, edition, medium, country, catalog
  numbers in brackets), the disc TOC and CUETools DB MBIDs, plus per-track
  durations.
  `FingerprintService` fingerprints 120 s of every track (Chromaprint via
  ffmpeg PCM snippets, image ranges for CUE images), asks AcoustID and votes
  per release with the consensus filter from drtagger. `Identifier` pools
  MusicBrainz candidates from MBIDs, TOC lookup (fuzzy `toc=` works even when
  the disc ID is unregistered), barcode, catalog number, fingerprints (plus
  sibling editions of the top release groups) and text search, fetches
  details, and `MatchScorer` ranks them with explainable reasons: track and
  disc count, mean duration error, barcode / catalog / disc ID / MBID /
  fingerprint coverage as strong signals, artist, title, year, edition,
  pressing year, country and medium named in the folder as soft ones. Confident = two strong signals agreeing with fitting durations and a
  clear lead over the runner-up. Discogs candidates (barcode / catalog) are
  kept for the credits merge. Verified live: XRCD image identified from TOC +
  fingerprints in 14 s, a split folder from scans + tags + fingerprints in
  29 s.
- `TagKit` (phase 5, done) — the Picard schema as a flat `TagSet`;
  `PicardMapper` fills it from a candidate (release and track artist credits
  with MBIDs and sort names, dates and original date, labels and catalog
  numbers, media, country, status, types, ISRCs, works, performers and
  production credits from MusicBrainz relationships plus Discogs extra
  artists, GENRE/STYLE from Discogs, disc IDs); `TagMerge` applies the
  overwrite policy (candidate fields replace, identity fields the candidate
  lacks are cleared, everything else preserved, locks win) and yields the
  per-field diff. Containers: FLAC (VORBIS_COMMENT + PICTURE), DSF (ID3v2.3
  trailer), WAV/AIFF/DSDIFF (ID3 chunk, one IFF walker with 32/64-bit sizes),
  APEv2 for APE/WavPack/TTA (stray ID3v1 dropped), MP4/ALAC (ilst rebuilt;
  a moov in front of mdat becomes a `free` atom and the new moov is
  appended so chunk offsets never move). ID3 follows Picard's conventions
  (TXXX descriptions, UFID recording id, IPLS people, TYER+TDAT/TORY dates,
  NUL-separated multi-values). Every write streams the audio payload to a
  temp file while hashing it, compares the SHA-256 with the original and
  only then replaces the file. `TagBackup` keeps the raw metadata region
  (the whole moov for MP4) so Restore is byte-exact; verified by tests on
  every container. `ArtworkProcessor` resizes the front cover (JPEG 90 %,
  small PNGs kept); `CoverArtFetcher` (IdentifyKit) lists sources in order:
  Cover Art Archive release, release group, Discogs, iTunes, Deezer, folder
  scans, fanart.tv (release-group covers by likes, with a key). ACOUSTID_ID
  is written from the AcoustID result id kept per track. `LibraryOrganizer`
  moves the written files into root / album template / "Disc N" (multi-disc)
  / "Multichannel" / track template, carries sidecars (scans, cue, logs)
  along when a folder empties and removes it; the app records every move
  so backups, reports and later re-tagging follow the files.

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
   script, settings + Keychain, empty queue UI. **Done 2026-09-20.**
1. Library scan and album detection (ISO / image+CUE / track folder), queue
   with states, SwiftData store. **Done 2026-09-20.**
2. CUE parsing, image splitting with verification, DiscID, CTDB check.
   **Done 2026-09-20** (inspector "Disc" section, `--split-into <folder>`).
3. SACD ISO reader, DSF extraction, disc text, DST decoding. **Done 2026-09-21.**
4. Identification pipeline: artwork barcode/OCR, DiscID, tags, fingerprints,
   voting, confidence; providers MB / Discogs / CAA / iTunes / Deezer.
   **Done 2026-09-21** (fanart.tv client still to add; artwork download and
   embedding belong to phase 5).
5. Tag mapping and writers for every container, artwork policy, preview with
   diff and field locks, backups and restore. **Done 2026-09-21** (inspector
   "Tags" section: Preview / Apply / Restore Originals, cover picker,
   album-level and per-track diff with locks; `--tag` launch argument).
6. ReplayGain, path templates, localisation, signing and notarisation.
   **Done 2026-09-21**: loudness measured on Apply (setting), templates
   editable in Settings with a live preview and ASCII-only names, files
   organised into the library after Apply, originals moved to the Trash
   after a verified split/extract (setting), Spanish localisation of every
   string, `scripts/release.sh` (Developer ID archive, export, notarytool,
   staple; needs a `drtagger-notary` keychain profile) with secure
   timestamps on the app and the ffmpeg helpers.

7. Multi-disc release sets. **Done 2026-09-22.** Several images with
   "(Disc N)" names in one folder scan as one multi-disc album; separate
   albums that are one release (SACD ISOs whose master TOC says "disc N of
   M" with the same album title, sibling folders "CD1"/"Disc 2"…) are
   grouped automatically into a *release set* after a scan, and can be
   grouped, ungrouped and reordered by hand (sidebar context menu, inspector
   "Release set" section). A set is identified once: every disc's signals
   merged, one TOC lookup per disc, candidates matched medium by medium
   (`MatchScorer.pairedMedia`), so a lone "disc 2 of 3" matches medium 2 of
   the box without a track-count penalty, incomplete sets are allowed with a
   warning, and the box release wins over single-disc releases (which stay
   visible). Tags come from the medium at each disc's position (ALBUM is
   the release title, DISCNUMBER/DISCTOTAL from the release, DISCSUBTITLE the
   medium title); Apply writes every disc, backups and reports stay with the
   record that owns each file. Split and extract process every disc into
   `Artist/Album (year)/Disc N/`; "Split/Extract All Discs" runs the whole
   set.

Small things added on request (2026-09-22): a "Test" button next to every
API key in Settings (AcoustID answers error code 4 for a bad key, Discogs
`/oauth/identity` names the account, fanart.tv refuses a bad key on any
request), a "Providers:" line under the identification signals saying what
ran, and an image viewer sheet for any cover or scan (inspector header,
artwork strip, chosen cover in Tags), decoded at screen size.

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
