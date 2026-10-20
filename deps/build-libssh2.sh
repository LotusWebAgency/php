#!/usr/bin/env bash
# libssh2 for ext-ssh2, built from the commit pinned in deps/versions.lock and
# installed as a static PIC archive, so ssh2.so carries it and no libssh2.so or
# distro libssh2 package ships.
#
# Why vendored: the newest release (1.11.1) and Wolfi's package lack upstream's
# fixes for six HIGH CVEs (CVE-2026-58050, CVE-2026-58051, CVE-2026-66032 to
# CVE-2026-66035); they are on libssh2's master only. Move to the next release
# once one ships and contains them.
#
# The crypto backend is the system OpenSSL (openssl-4.0-dev in the build stage),
# the same one every other library in the image links. zlib stays on so SSH
# compression keeps working; ssh2.so links libz and libcrypto dynamically.
#
# Left out: examples, docs, the sshd/docker test suites.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PREFIX="${1:-/opt/libssh2}"

row=$(grep -E '^both[[:space:]]+libssh2[[:space:]]' "$HERE/versions.lock")
version=$(echo "$row" | awk '{print $3}')
sha=$(echo "$row" | awk '{print $5}')
url=$(echo "$row" | awk '{print $6}')

bash "$HERE/fetch-verified.sh" "$url" "$sha" /tmp/libssh2.tar.gz
mkdir -p /tmp/libssh2 && tar xf /tmp/libssh2.tar.gz -C /tmp/libssh2 --strip-components=1
cd /tmp/libssh2

# A git archive ships no configure script.
autoreconf -fi

export CFLAGS
CFLAGS="$(bash "$ROOT/php/cflags.sh" baseline)"
export LDFLAGS
LDFLAGS="$(bash "$ROOT/php/ldflags.sh")"

./configure \
  --prefix="$PREFIX" \
  --disable-shared --enable-static \
  --with-crypto=openssl \
  --with-libz \
  --disable-examples-build --disable-docker-tests --disable-sshd-tests \
  --disable-docs

make -j"$(nproc)"
make install

find "$PREFIX/lib" -name '*.la' -delete

cd / && rm -rf /tmp/libssh2 /tmp/libssh2.tar.gz
echo "libssh2 $version installed to $PREFIX"
