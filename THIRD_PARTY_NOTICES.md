# Third-party notices

drtagger for Mac is MIT licensed (see [LICENSE](LICENSE)) except for the
components below, which keep their own licenses.

| Component | Where | License | Notes |
|---|---|---|---|
| FFmpeg 8.0 (`ffmpeg`, `ffprobe`) | `Vendor/ffmpeg/` at build time, `Contents/Helpers/` in the app | LGPL 2.1 or later | Built from the unmodified tarball by `scripts/build-ffmpeg.sh` with a minimal, GPL-free configuration (`Vendor/ffmpeg/BUILD-INFO.txt` records the checksum and configure line). The binaries are not committed. License texts: `Vendor/ffmpeg/COPYING.LGPLv2.1`, `Vendor/ffmpeg/LICENSE.md`. |
| DSTKit | `Packages/DSTKit/` | LGPL 2.1 or later | A Swift port of FFmpeg's `libavcodec/dstdec.c` (DST decoder), stopped before the DSD-to-PCM stage. See `Packages/DSTKit/LICENSE`. |
| Chromaprint 1.5.1 | `Packages/Chromaprint/Sources/Chromaprint/` | MIT | Copyright (C) 2010-2016 Lukas Lalinsky, vendored unmodified. See `Packages/Chromaprint/LICENSE`. |

The app links DSTKit statically and runs FFmpeg as separate helper
processes. The LGPL is satisfied because the whole application is open
source: anyone can rebuild it with a modified DSTKit or FFmpeg.

Services the app talks to (MusicBrainz, Cover Art Archive, AcoustID,
Discogs, CUETools DB, iTunes Search, Deezer, fanart.tv) have their own terms;
the app identifies itself with a `drtagger-mac` user agent and respects the
published rate limits.
