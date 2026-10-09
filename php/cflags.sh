#!/usr/bin/env bash
# Print CFLAGS for the current architecture at the requested microarch level.
set -euo pipefail
UARCH="${1:-baseline}"

# dpkg is the authority when present (Debian build stages); fall back to uname so
# the script and its tests run on a non-Debian dev host too. An unmapped uname
# fails loudly below, like an unmapped dpkg arch.
if command -v dpkg >/dev/null 2>&1; then
  ARCH="$(dpkg --print-architecture)"
else
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *)
      echo "unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
fi

# -U before -D: debian's build environment may already define _FORTIFY_SOURCE=2,
# and redefining it without undefining first is a warning, not an override.
COMMON="-O2 -fPIC -fstack-protector-strong -fstack-clash-protection"
COMMON="$COMMON -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -fno-semantic-interposition"
# -std=gnu17 is pinned for every PHP version on both compilers, not just where
# gcc's newer default forces the issue. GCC 15+ defaults to -std=gnu23, whose
# stricter K&R semantics (a bare `()` now means "no parameters", not
# "unspecified") break php-src on the legacy era outright (ext/standard/scanf.c,
# ext/date/php_date.c) and risk the same in any PECL extension or vendored dep
# built from source, silently if the K&R code merely changes behavior instead of
# failing to compile. Pinning one dialect removes that class of drift. It costs
# nothing on the clang path: Debian trixie's clang 19 already defaults to
# gnu17 (__STDC_VERSION__ is 201710L with and without the flag), so this only
# changes anything on the gcc path.
COMMON="$COMMON -std=gnu17"

case "$ARCH" in
  amd64)
    SEC="-fcf-protection=full"
    if [ "$UARCH" = "v3" ]; then
      MARCH="-march=x86-64-v3 -mtune=generic"
      # A v3 build must refuse to load on a CPU without x86-64-v3 -- glibc's
      # ld.so prints "CPU ISA level is lower than required" and exits 127 --
      # instead of dying later with SIGILL. It does that when the ELF carries
      # GNU_PROPERTY_X86_ISA_1_NEEDED naming v3. -Wl,-z,x86-64-v3 is not usable
      # here: gold (the gcc era's linker, see the Dockerfile's ld shim) fails on
      # it with "unknown -z option", and lld (the clang era's) warns and ignores
      # it, emitting no note at all. Only ld.bfd honors it. gcc's -mneeded marks
      # every object it compiles and gold OR-merges that into the output
      # (without it gold only records x86-64-baseline). clang has no such flag;
      # the clang era links a hand-made note object instead
      # (php/isa-note-x86-64-v3.S, php/build.sh).
      # Neither gold nor lld emits a PT_GNU_PROPERTY program header, so ld.so's
      # refusal relies on glibc reading the property from the legacy PT_NOTE
      # segment: trixie's 2.41 does, a newer glibc may not. tests/test-uarch.sh
      # proves the refusal at runtime on the shipped image.
      # arm64 has no glibc equivalent of this check, so nothing is added there.
      if [ "${COMPILER:-clang}" = gcc ]; then MARCH="$MARCH -mneeded"; fi
    else MARCH="-march=x86-64 -mtune=generic"; fi
    ;;
  arm64)
    SEC="-mbranch-protection=standard"
    # v3 on arm64 is armv9-a, not a v8.x point release: armv8-a already has NEON,
    # and LSE atomics/crc32/crypto are reached at runtime (outline atomics,
    # OpenSSL's own dispatch), so v8.2 buys next to nothing. v9 is the real step
    # -- SVE2, which gcc 16 and clang 19 both auto-vectorize with. It runs on
    # Neoverse N2/V2 and later (Graviton4, Axion, Cobalt 100, Grace), not on
    # Graviton2/3, Ampere or Apple silicon.
    if [ "$UARCH" = "v3" ]; then MARCH="-march=armv9-a"
    else MARCH="-march=armv8-a"; fi
    ;;
  *)
    echo "unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

echo "$COMMON $SEC $MARCH"
