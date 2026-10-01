#!/usr/bin/env bash
# Minimal ImageMagick, built from the source pinned in deps/versions.lock.
#
# No X11, no OpenMP, no OpenCL, no Ghostscript library, no graphviz/pango/
# rsvg/wmf/djvu/openexr/raw -- those are size, thread-safety and CVE-surface
# liabilities that don't belong in an FPM worker. OpenMP in particular spawns
# a thread per core per request if left on. No XML either: the legacy era
# (task 15) links a vendored libxml2 2.9.14 into the PHP binary, and imagick
# is compiled statically into that same binary -- linking Debian's libxml2
# here too would put two libxml2 builds in one process. None of the required
# delegates need it. The delegate set this keeps is PNG/JPEG/WEBP/TIFF/HEIC
# (HEIC covers AVIF too, via libheif) -- whatever -dev packages the calling
# deps stage installed before this script runs.
#
# The GitHub release tarball ships a pre-generated `configure` (autoconf 2.72,
# checked in by upstream for tagged releases -- confirmed by running it
# directly), so no autogen.sh/autoreconf step is needed here.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PREFIX="${1:-/opt/imagemagick}"

row=$(grep -E '^both[[:space:]]+imagemagick[[:space:]]' "$HERE/versions.lock")
version=$(echo "$row" | awk '{print $3}')
sha=$(echo "$row" | awk '{print $5}')
url=$(echo "$row" | awk '{print $6}')

# Retried: GitHub archive endpoints drop connections for minutes at a time, and
# the sha256 check below (inside fetch-verified.sh) makes a retried download
# exactly as trusted as a first one, cached or not.
bash "$HERE/fetch-verified.sh" "$url" "$sha" /tmp/im.tar.gz
mkdir -p /tmp/im && tar xf /tmp/im.tar.gz -C /tmp/im --strip-components=1
cd /tmp/im

# ImageMagick isn't part of the microarchitecture-variant matrix (it's built
# once per era, shared by every uarch build), so this always uses baseline
# flags -- same hardening posture as PHP itself, just not the -v3 tuning.
export CFLAGS
CFLAGS="$(bash "$ROOT/php/cflags.sh" baseline)"
export CXXFLAGS="$CFLAGS -std=c++17"
# Self-referencing rpath: MagickWand.so and friends need to find each other
# in $PREFIX/lib at runtime without a global LD_LIBRARY_PATH (task 1 broke
# the host curl binary that way). Also carries the project's hardening
# ld flags (full relro, noexecstack) onto libraries with a heavy CVE history.
export LDFLAGS
LDFLAGS="$(bash "$ROOT/php/ldflags.sh" "$PREFIX")"

./configure \
  --prefix="$PREFIX" \
  --without-x \
  --disable-openmp \
  --disable-opencl \
  --without-gslib \
  --without-gvc \
  --without-fftw \
  --without-pango \
  --without-rsvg \
  --without-djvu \
  --without-wmf \
  --without-openexr \
  --without-raw \
  --without-xml \
  --with-jpeg --with-png --with-webp --with-tiff --with-heic \
  --with-freetype \
  --disable-docs \
  --enable-shared --disable-static

make -j"$(nproc)"
make install

# Static archives and .la files are dead weight: the runtime image links
# against the .so via rpath, never against a .a, and .la files embed this
# build's throwaway /tmp paths.
find "$PREFIX/lib" -name '*.la' -delete
find "$PREFIX/lib" -name '*.a' -delete
find "$PREFIX/lib" -type f -name '*.so*' -exec strip --strip-unneeded {} +

cd / && rm -rf /tmp/im /tmp/im.tar.gz
echo "imagemagick $version installed to $PREFIX"
