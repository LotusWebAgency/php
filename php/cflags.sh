#!/usr/bin/env bash
# Print CFLAGS for the current architecture at the requested microarch level.
#
#   cflags.sh [baseline|v3] [c|cxx]
#
# "cxx" prints the C++ variant: the same flags without the C-only -std=gnu17, plus
# the libstdc++ assertions. Callers append their own -std=c++NN.
# The compiler comes from $COMPILER (gcc|clang, set by the Dockerfile) and, when
# that is unset, from what $CC reports; the one flag only gcc has is guarded on it.
set -euo pipefail
UARCH="${1:-baseline}"
LANG_KIND="${2:-c}"
case "$LANG_KIND" in
  c|cxx) ;;
  *) echo "cflags.sh: language must be c or cxx, got $LANG_KIND" >&2; exit 1 ;;
esac

COMPILER_KIND="${COMPILER:-}"
if [ -z "$COMPILER_KIND" ]; then
  case "$("${CC:-cc}" --version 2>/dev/null || true)" in
    *clang*) COMPILER_KIND=clang ;;
    *) COMPILER_KIND=gcc ;;
  esac
fi
case "$COMPILER_KIND" in
  gcc|clang) ;;
  *) echo "cflags.sh: COMPILER must be gcc or clang, got $COMPILER_KIND" >&2; exit 1 ;;
esac

ARCH="$(bash "$(dirname "${BASH_SOURCE[0]}")/arch.sh")"

# -U before -D: the build environment may already define _FORTIFY_SOURCE (Wolfi's
# openssf compiler defaults do), and redefining it without undefining first is a
# warning, not an override.
COMMON="-O2 -fPIC -fstack-protector-strong -fstack-clash-protection"
COMMON="$COMMON -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -fno-semantic-interposition"
# The rest of Wolfi's default hardening set. The Dockerfile switches Wolfi's own
# defaults off (GCC_SPEC_FILE, CLANG_NO_DEFAULT_CONFIG) so that this file decides
# every flag, which means anything it does not name is gone. Wolfi's gcc
# openssf.spec (-fhardened plus extras) and clang common.cfg enable these on top
# of the ones above; the C++-only -D_GLIBCXX_ASSERTIONS is added for "cxx" below.
#  -ftrivial-auto-var-init=zero: uninitialized automatic variables read as zero
#    instead of stack garbage. Same flag on gcc 16 and clang 19.
#  -fno-delete-null-pointer-checks: a null check the compiler can "prove" is
#    redundant after a dereference stays in the binary.
#  -fno-strict-overflow: signed overflow wraps instead of being undefined.
#    Subsumes the -fwrapv that php/build.sh adds on the legacy era.
#  -fno-strict-aliasing: no type-based alias analysis; php-src and PECL code
#    pun types freely.
# None of these conflicts with PGO or ThinLTO: the profile-generate and
# profile-use passes read the same flag set from here, so a profile is always
# matched to the code it was trained on.
COMMON="$COMMON -ftrivial-auto-var-init=zero -fno-delete-null-pointer-checks"
COMMON="$COMMON -fno-strict-overflow -fno-strict-aliasing"
# -fzero-init-padding-bits=all (GCC 15+) also zeroes the padding bytes of
# aggregates and unions that are initialized with = {0} or a partial initializer,
# so padding cannot leak stack contents. Wolfi's clang config does not set it
# and clang 19 has no such option, so it is gcc-only.
if [ "$COMPILER_KIND" = gcc ]; then
  COMMON="$COMMON -fzero-init-padding-bits=all"
fi
# -std=gnu17 is pinned for every PHP version on both compilers, not just where
# gcc's newer default forces the issue. GCC 15+ defaults to -std=gnu23, whose
# stricter K&R semantics (a bare `()` now means "no parameters", not
# "unspecified") break php-src on the legacy era outright (ext/standard/scanf.c,
# ext/date/php_date.c) and risk the same in any PECL extension or vendored dep
# built from source, silently if the K&R code merely changes behavior instead of
# failing to compile. Pinning one dialect removes that class of drift. It costs
# nothing on the clang path: clang 19 already defaults to gnu17
# (__STDC_VERSION__ is 201710L with and without the flag), so this only changes
# anything on the gcc path.
if [ "$LANG_KIND" = c ]; then
  COMMON="$COMMON -std=gnu17"
else
  # libstdc++ bounds checks on operator[], front(), back() and friends, which
  # abort instead of reading out of range. libstdc++ is the C++ library under
  # both compilers here. In a C compile the macro would be inert, so it stays out.
  COMMON="$COMMON -D_GLIBCXX_ASSERTIONS"
fi

case "$ARCH" in
  amd64)
    SEC="-fcf-protection=full"
    if [ "$UARCH" = "v3" ]; then
      MARCH="-march=x86-64-v3 -mtune=generic"
      # A v3 build must refuse to start on a CPU without x86-64-v3. That is a
      # constructor linked into the SAPI executables (php/isa-gate-x86-64-v3.c,
      # php/build.sh), not a compiler or linker flag.
    else MARCH="-march=x86-64-v2 -mtune=generic"; fi
    ;;
  arm64)
    SEC="-mbranch-protection=standard"
    # v3 on arm64 is armv9-a, not a v8.x point release: armv8-a already has NEON,
    # and LSE atomics/crc32/crypto are reached at runtime (outline atomics,
    # OpenSSL's own dispatch), so v8.2 buys next to nothing. v9 is the real step
    # -- SVE2, which gcc 16 and clang 19 both auto-vectorize with. It runs on
    # Neoverse N2/V2 and later (Graviton4, Axion, Cobalt 100, Grace), not on
    # Graviton2/3, Ampere or Apple silicon.
    # Wolfi's aarch64 gcc bakes in -mtune=neoverse-v2 and keeps it when -march is
    # given, while clang would fall back to generic tuning. Both are named here so
    # the two compilers tune identically: neoverse-v2 for v3 (the core v9 targets
    # are built on), generic for the baseline as amd64's is.
    if [ "$UARCH" = "v3" ]; then MARCH="-march=armv9-a -mtune=neoverse-v2"
    else MARCH="-march=armv8-a -mtune=generic"; fi
    ;;
  *)
    echo "unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

echo "$COMMON $SEC $MARCH"
