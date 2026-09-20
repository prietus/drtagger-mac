#!/bin/bash
#
# Builds the minimal LGPL ffmpeg + ffprobe that drtagger for Mac embeds in
# Contents/Helpers. Only the audio demuxers, decoders, encoders, muxers and
# filters the app actually drives are compiled in; everything else (video,
# network, GPL and non-free components, external libraries) is off, so the
# result is redistributable under LGPL 2.1+ and weighs a few MB per slice.
#
# Usage:
#   scripts/build-ffmpeg.sh                # arm64 + x86_64 universal binary
#   FFMPEG_ARCHS=arm64 scripts/build-ffmpeg.sh
#   FFMPEG_VERSION=8.0 scripts/build-ffmpeg.sh
#
# Output: Vendor/ffmpeg/{ffmpeg,ffprobe,BUILD-INFO.txt,LICENSE.md,COPYING.LGPLv2.1}
# The exact tarball checksum and configure line are recorded in BUILD-INFO.txt
# so the corresponding source can always be offered, as the LGPL requires.
#
# Requirements: Xcode command line tools (clang, make). nasm is NOT required:
# the x86_64 slice is built with --disable-x86asm (plain C, fine for audio).

set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-8.0}"
# Pinned checksum of the ffmpeg 8.0 tarball. Override FFMPEG_SHA256 when
# changing FFMPEG_VERSION (the actual hash is always printed and recorded).
FFMPEG_SHA256="${FFMPEG_SHA256:-b2751fccb6cc4c77708113cd78b561059b6fa904b24162fa0be2d60273d27b8e}"
MACOS_MIN="${MACOS_MIN:-15.0}"
ARCHS="${FFMPEG_ARCHS:-arm64 x86_64}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${FFMPEG_WORK:-$ROOT/.build/ffmpeg}"
OUT="$ROOT/Vendor/ffmpeg"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$WORK" "$OUT"

# --- fetch -------------------------------------------------------------------
TARBALL="$WORK/ffmpeg-$FFMPEG_VERSION.tar.xz"
if [ ! -f "$TARBALL" ]; then
    echo "==> Downloading ffmpeg $FFMPEG_VERSION"
    curl -fL --retry 3 "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$TARBALL.part"
    mv "$TARBALL.part" "$TARBALL"
fi
ACTUAL_SHA="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
echo "==> ffmpeg-$FFMPEG_VERSION.tar.xz sha256 $ACTUAL_SHA"
if [ -n "$FFMPEG_SHA256" ] && [ "$ACTUAL_SHA" != "$FFMPEG_SHA256" ]; then
    echo "error: checksum mismatch (expected $FFMPEG_SHA256)" >&2
    exit 1
fi

SRC="$WORK/ffmpeg-$FFMPEG_VERSION"
if [ ! -d "$SRC" ]; then
    echo "==> Extracting"
    tar -xJf "$TARBALL" -C "$WORK"
fi

# --- component list -----------------------------------------------------------
# Inputs the app must read: APE, WavPack, TTA, FLAC, WAV, AIFF, ALAC (.m4a),
# DSF, DFF (iff demuxer), raw PCM pipes. DST decoding is included for probing
# only: ffmpeg's dst decoder emits PCM, not the DSD bitstream, so lossless
# DST -> DSF extraction uses the app's own decoder (see DESIGN.md).
DEMUXERS="ape,wv,tta,flac,wav,aiff,mov,dsf,iff,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le"
DECODERS="ape,wavpack,tta,alac,flac,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_u8,pcm_s8,pcm_f32le,pcm_f32be,pcm_f64le,dsd_lsbf,dsd_msbf,dsd_lsbf_planar,dsd_msbf_planar,dst"
ENCODERS="flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le"
MUXERS="flac,wav,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,null,md5,hash,framemd5"
FILTERS="aresample,aformat,anull,atrim,asetnsamples,ebur128,replaygain,volumedetect,astats"
PROTOCOLS="file,pipe"

COMMON_FLAGS=(
    --disable-everything
    --disable-programs --enable-ffmpeg --enable-ffprobe
    --disable-doc --disable-debug
    --disable-network --disable-autodetect
    --disable-shared --enable-static --enable-pic
    --disable-avdevice
    --disable-gpl --disable-nonfree --disable-version3
    --enable-swresample --enable-avfilter
    "--enable-protocol=$PROTOCOLS"
    "--enable-demuxer=$DEMUXERS"
    "--enable-decoder=$DECODERS"
    "--enable-encoder=$ENCODERS"
    "--enable-muxer=$MUXERS"
    "--enable-filter=$FILTERS"
)

# --- build per arch ------------------------------------------------------------
SLICES_FFMPEG=()
SLICES_FFPROBE=()
CONFIGURE_LINES=""
for ARCH in $ARCHS; do
    BUILD="$WORK/build-$ARCH"
    PREFIX="$WORK/install-$ARCH"
    mkdir -p "$BUILD"
    ARCH_FLAGS=(
        "--prefix=$PREFIX"
        "--arch=$ARCH"
        --target-os=darwin
        --cc=clang
        "--extra-cflags=-arch $ARCH -mmacosx-version-min=$MACOS_MIN"
        "--extra-ldflags=-arch $ARCH -mmacosx-version-min=$MACOS_MIN"
    )
    HOST_ARCH="$(uname -m)"
    if [ "$ARCH" != "$HOST_ARCH" ]; then
        ARCH_FLAGS+=(--enable-cross-compile)
    fi
    if [ "$ARCH" = "x86_64" ]; then
        ARCH_FLAGS+=(--disable-x86asm)
    fi

    echo "==> Configuring $ARCH"
    (
        cd "$BUILD"
        "$SRC/configure" "${COMMON_FLAGS[@]}" "${ARCH_FLAGS[@]}" > configure.log 2>&1 \
            || { tail -40 configure.log; tail -40 ffbuild/config.log 2>/dev/null; exit 1; }
    )
    CONFIGURE_LINES+="[$ARCH] configure ${COMMON_FLAGS[*]} ${ARCH_FLAGS[*]}"$'\n'

    echo "==> Building $ARCH with $JOBS jobs"
    make -C "$BUILD" -j"$JOBS" > "$BUILD/make.log" 2>&1 || { tail -60 "$BUILD/make.log"; exit 1; }
    make -C "$BUILD" install > "$BUILD/install.log" 2>&1

    SLICES_FFMPEG+=("$PREFIX/bin/ffmpeg")
    SLICES_FFPROBE+=("$PREFIX/bin/ffprobe")
done

# --- combine -------------------------------------------------------------------
echo "==> Creating universal binaries in $OUT"
if [ "${#SLICES_FFMPEG[@]}" -gt 1 ]; then
    lipo -create "${SLICES_FFMPEG[@]}" -output "$OUT/ffmpeg"
    lipo -create "${SLICES_FFPROBE[@]}" -output "$OUT/ffprobe"
else
    cp -f "${SLICES_FFMPEG[0]}" "$OUT/ffmpeg"
    cp -f "${SLICES_FFPROBE[0]}" "$OUT/ffprobe"
fi
strip -x "$OUT/ffmpeg" "$OUT/ffprobe"
chmod 755 "$OUT/ffmpeg" "$OUT/ffprobe"

cp -f "$SRC/LICENSE.md" "$OUT/LICENSE.md"
cp -f "$SRC/COPYING.LGPLv2.1" "$OUT/COPYING.LGPLv2.1"

# --- sanity checks ---------------------------------------------------------------
if "$OUT/ffmpeg" -version | grep -q -- "--enable-gpl"; then
    echo "error: resulting ffmpeg reports --enable-gpl; refusing to ship it" >&2
    exit 1
fi
MISSING=""
for d in ape wavpack tta alac flac dst; do
    "$OUT/ffmpeg" -hide_banner -decoders 2>/dev/null | awk '{print $2}' | grep -qx "$d" || MISSING+=" decoder:$d"
done
"$OUT/ffmpeg" -hide_banner -encoders 2>/dev/null | awk '{print $2}' | grep -qx flac || MISSING+=" encoder:flac"
"$OUT/ffmpeg" -hide_banner -filters 2>/dev/null | awk '{print $2}' | grep -qx ebur128 || MISSING+=" filter:ebur128"
if [ -n "$MISSING" ]; then
    echo "error: built ffmpeg is missing:$MISSING" >&2
    exit 1
fi

{
    echo "ffmpeg $FFMPEG_VERSION"
    echo "source  https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
    echo "sha256  $ACTUAL_SHA"
    echo "built   $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(sw_vers -productVersion) with $(clang --version | head -1)"
    echo "archs   $ARCHS (macOS >= $MACOS_MIN)"
    echo "license LGPL 2.1 or later (no GPL / non-free components)"
    echo
    echo "$CONFIGURE_LINES"
} > "$OUT/BUILD-INFO.txt"

echo "==> Done"
lipo -info "$OUT/ffmpeg"
ls -lh "$OUT/ffmpeg" "$OUT/ffprobe"
"$OUT/ffmpeg" -version | head -1
