#!/usr/bin/env bash
# Link flags. Applied to both libraries and programs; -pie is added separately
# via EXTRA_LDFLAGS_PROGRAM because shared modules must stay PIC, not PIE.
#
# Zero or more deps-prefixes bind vendored lib dirs to the binary via rpath
# instead of a global LD_LIBRARY_PATH: a global env var made a vendored
# libcurl.so.4 shadow debian's for every process in the image, which broke
# the host curl binary. rpath is scoped to the linked binary, so it doesn't.
# Three prefixes are in use: /opt/imagemagick (all eras), /opt/net-snmp (all eras;
# its own build and, via ext-snmp's configure, snmp.so) and /opt/php-deps (legacy
# only) -- each gets its own rpath pair.
set -euo pipefail
FLAGS="-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,--as-needed -Wl,--build-id=sha1"

HAS_PREFIX=0
for PREFIX in "$@"; do
  [ -n "$PREFIX" ] || continue
  HAS_PREFIX=1
  FLAGS="$FLAGS -Wl,-rpath,${PREFIX}/lib -Wl,-rpath-link,${PREFIX}/lib"
done

# The legacy era statically links vendored OpenSSL (no-shared, on purpose -- see
# deps/build-deps.sh) into the php executable. An executable's own global symbols
# win over same-named symbols in shared libraries loaded later (standard ELF
# interposition), and the linked php binary exports 1736 openssl symbols
# (SSL_new, SSL_CTX_new, EVP_EncryptInit, ...) as GLOBAL DEFAULT. PHP 8.0's
# ext/curl links dynamically against trixie's libcurl.so.4 (deps/versions.lock
# vendors curl only for 7.0-7.2), which needs libssl.so.3; libcurl's internal
# calls to SSL_new/SSL_CTX_new then resolve to php's 1.1.1w symbols instead of
# libssl.so.3's. The SSL/SSL_CTX struct layouts of 1.1.1w and 3.x are
# incompatible (3.x made almost everything opaque), so every HTTPS curl_exec()
# segfaults while plain HTTP survives. This applies to ImageMagick's and the
# vendored libs' own builds too, not just php's final link. --exclude-libs=ALL
# only affects symbols originating in *static* archives, so it is a no-op
# wherever none are linked in (every modern-era build, and any legacy build with
# no PREFIX at all).
if [ "$HAS_PREFIX" -eq 1 ]; then
  FLAGS="$FLAGS -Wl,--exclude-libs=ALL"
fi

echo "$FLAGS"
