#!/usr/bin/env bash
# Link flags. Applied to both libraries and programs; -pie is added separately
# via EXTRA_LDFLAGS_PROGRAM because shared modules must stay PIC, not PIE.
#
# Zero or more deps-prefixes bind vendored lib dirs to the binary via rpath
# instead of a global LD_LIBRARY_PATH: a global env var made a vendored
# libcurl.so.4 shadow debian's for every process in the image, which broke
# the host curl binary. rpath is scoped to the linked binary, so it doesn't.
# Two prefixes exist as of task 8: /opt/imagemagick (all eras) and
# /opt/php-deps (legacy only, task 14) -- each gets its own rpath pair.
set -euo pipefail
FLAGS="-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,--as-needed -Wl,--build-id=sha1"

HAS_PREFIX=0
for PREFIX in "$@"; do
  [ -n "$PREFIX" ] || continue
  HAS_PREFIX=1
  FLAGS="$FLAGS -Wl,-rpath,${PREFIX}/lib -Wl,-rpath-link,${PREFIX}/lib"
done

# The legacy era statically links vendored OpenSSL (no-shared, on purpose --
# see deps/build-deps.sh) directly into the php executable. Without this, an
# executable's own global symbols take priority over a same-named symbol in
# any shared library loaded later in the process (standard ELF symbol
# interposition) -- confirmed by dumping the linked php binary's dynamic
# symbol table: 1736 openssl symbols (SSL_new, SSL_CTX_new, EVP_EncryptInit,
# ...) exported GLOBAL DEFAULT, all from the statically-linked 1.1.1w archive.
# PHP 8.0's own ext/curl links dynamically against trixie's system libcurl.so.4
# (deps/versions.lock vendors curl only for 7.0-7.2), which itself needs
# libssl.so.3 -- and when libcurl's own internal calls resolve SSL_new/
# SSL_CTX_new, the dynamic linker hands them php's exported 1.1.1w symbols
# instead of libssl.so.3's own, because the executable wins ties. 1.1.1w's and
# 3.x's SSL/SSL_CTX struct layouts are incompatible (3.x made almost
# everything opaque), so every curl_exec() over HTTPS immediately segfaults
# (confirmed: plain HTTP survives, HTTPS does not, reproducibly). Applies to
# ImageMagick and the vendored libs' own builds too, not just php's final
# link -- --exclude-libs=ALL only affects symbols originating in *static*
# archives, so it is a no-op wherever none are linked in (every modern-era
# build, and any legacy build with no PREFIX at all).
if [ "$HAS_PREFIX" -eq 1 ]; then
  FLAGS="$FLAGS -Wl,--exclude-libs=ALL"
fi

echo "$FLAGS"
