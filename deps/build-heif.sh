#!/usr/bin/env bash
# Minimal static HEIC/AVIF decoding stack for ImageMagick, built from the sources
# pinned in deps/versions.lock: dav1d (AV1) and libde265 (HEVC) under libheif.
#
# Why vendored: the distro libheif drags SDL2, gdk-pixbuf, glib and every
# encoder codec (x265, aom, SVT-AV1, rav1e, openh264) into the runtime image, and
# its dev package has no static dav1d. These archives are linked into
# libMagickCore.so by deps/build-imagemagick.sh and ship nowhere else, so the runtime
# needs none of those packages.
#
# Decoders only: encoders are the bulk of the closure, and an FPM image reads
# user uploads rather than producing HEIC/AVIF. Plugin loading is off, so libheif
# never dlopens a codec from disk. No examples, tools, tests, gdk-pixbuf or SDL.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PREFIX="${1:-/opt/heif-static}"

lock_field() {  # lock_field <name> <field-number>
  grep -E "^both[[:space:]]+$1[[:space:]]" "$HERE/versions.lock" | awk -v f="$2" '{print $f}'
}

# Position-independent archives with the project's hardening and arch flags,
# same posture as ImageMagick itself (baseline, shared by every uarch variant).
export CFLAGS
CFLAGS="$(bash "$ROOT/php/cflags.sh" baseline)"
# -std=gnu17 is C-only; the C++ projects choose their own standard.
export CXXFLAGS
CXXFLAGS="$(printf '%s' "$CFLAGS" | sed -E 's/(^| )-std=[^ ]+//g')"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

fetch_and_unpack() {  # fetch_and_unpack <name> -> unpacked into /tmp/<name>-src
  local name="$1" sha url archive src
  sha=$(lock_field "$name" 5)
  url=$(lock_field "$name" 6)
  archive="/tmp/$name.tar"
  src="/tmp/$name-src"
  bash "$HERE/fetch-verified.sh" "$url" "$sha" "$archive"
  rm -rf "$src" && mkdir -p "$src" && tar xf "$archive" -C "$src" --strip-components=1
  rm -f "$archive"
}

fetch_and_unpack dav1d
# Tools, tests and examples off; both bit depths stay on (10-bit HEIC/AVIF). The
# plain buildtype leaves optimization and hardening to CFLAGS.
(
  cd /tmp/dav1d-src
  meson setup build \
    --prefix="$PREFIX" --libdir=lib --buildtype=plain \
    -Ddefault_library=static -Db_staticpic=true \
    -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false
  meson compile -C build
  meson install -C build
)
rm -rf /tmp/dav1d-src

fetch_and_unpack libde265
(
  cd /tmp/libde265-src
  cmake -S . -B build \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=None \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_SDL=OFF -DENABLE_ENCODER=OFF -DENABLE_SHERLOCK265=OFF
  cmake --build build -j"$(nproc)"
  cmake --install build
)
rm -rf /tmp/libde265-src

fetch_and_unpack libheif
(
  cd /tmp/libheif-src
  cmake -S . -B build \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=None \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_PLUGIN_LOADING=OFF \
    -DWITH_LIBDE265=ON -DWITH_LIBDE265_PLUGIN=OFF \
    -DWITH_DAV1D=ON -DWITH_DAV1D_PLUGIN=OFF \
    -DWITH_X265=OFF -DWITH_X264=OFF -DWITH_OpenH264_DECODER=OFF \
    -DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF -DWITH_SvtEnc=OFF -DWITH_RAV1E=OFF \
    -DWITH_OpenJPEG_ENCODER=OFF -DWITH_OpenJPEG_DECODER=OFF -DWITH_OPENJPH_ENCODER=OFF \
    -DWITH_JPEG_DECODER=OFF -DWITH_JPEG_ENCODER=OFF -DWITH_FFMPEG_DECODER=OFF \
    -DWITH_UNCOMPRESSED_CODEC=OFF -DWITH_LIBSHARPYUV=OFF \
    -DWITH_EXAMPLES=OFF -DWITH_GDK_PIXBUF=OFF -DBUILD_TESTING=OFF -DBUILD_DOCUMENTATION=OFF
  cmake --build build -j"$(nproc)"
  cmake --install build
)
rm -rf /tmp/libheif-src

# ImageMagick's configure queries pkg-config without --static, which would leave a static
# libheif's private requirements (libde265, dav1d, libstdc++) off the link line. Fold the
# --static answer into Libs.
heif_pc="$PREFIX/lib/pkgconfig/libheif.pc"
static_libs="$(pkg-config --static --libs libheif)"
sed -i "s|^Libs:.*|Libs: $static_libs|" "$heif_pc"

echo "heif stack ($(lock_field dav1d 3), $(lock_field libde265 3), $(lock_field libheif 3)) installed to $PREFIX"
