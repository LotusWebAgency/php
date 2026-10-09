#!/usr/bin/env bash
# Minimal ImageMagick, built from the source pinned in deps/versions.lock.
#
# No X11, OpenMP, OpenCL, Ghostscript library, graphviz/pango/rsvg/wmf/djvu/
# openexr/raw: those are size, thread-safety and CVE-surface liabilities that
# don't belong in an FPM worker (OpenMP spawns a thread per core per request).
# No XML either: imagick is compiled statically into the PHP binary, which
# already links its own libxml2, and a second libxml2 build in one process is a
# conflict; none of the kept delegates need it. Delegates kept: PNG/JPEG/WEBP/
# TIFF/HEIC (HEIC covers AVIF via libheif), from whatever -dev packages the
# calling deps stage installed.
#
# The GitHub release tarball ships a pre-generated `configure` (autoconf 2.72),
# so no autogen.sh/autoreconf step is needed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PREFIX="${1:-/opt/imagemagick}"

row=$(grep -E '^both[[:space:]]+imagemagick[[:space:]]' "$HERE/versions.lock")
version=$(echo "$row" | awk '{print $3}')
sha=$(echo "$row" | awk '{print $5}')
url=$(echo "$row" | awk '{print $6}')

# fetch-verified.sh retries (GitHub archive endpoints drop connections for
# minutes at a time) and verifies the sha256, so a retried download is as
# trusted as a first one.
bash "$HERE/fetch-verified.sh" "$url" "$sha" /tmp/im.tar.gz
mkdir -p /tmp/im && tar xf /tmp/im.tar.gz -C /tmp/im --strip-components=1
cd /tmp/im

# ImageMagick is not part of the microarchitecture-variant matrix (one build is
# shared by every uarch variant), so it always uses baseline flags: PHP's
# hardening without the -v3 tuning.
export CFLAGS
CFLAGS="$(bash "$ROOT/php/cflags.sh" baseline)"
export CXXFLAGS="$CFLAGS -std=c++17"
# Self-referencing rpath: MagickWand.so and friends find each other in
# $PREFIX/lib without a global LD_LIBRARY_PATH (which would shadow system
# libraries for other binaries). Also applies the project's hardening ld flags
# (full relro, noexecstack) to libraries with a heavy CVE history.
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

# Static archives and .la files are dead weight: the runtime image links the
# .so via rpath, and .la files embed this build's throwaway /tmp paths.
find "$PREFIX/lib" -name '*.la' -delete
find "$PREFIX/lib" -name '*.a' -delete
find "$PREFIX/lib" -type f -name '*.so*' -exec strip --strip-unneeded {} +

cd / && rm -rf /tmp/im /tmp/im.tar.gz
echo "imagemagick $version installed to $PREFIX"
