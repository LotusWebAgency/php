#!/usr/bin/env bash
# Print the names of php-src's own target-attributed SIMD functions, one per
# line, read out of the source tree that is about to be compiled. Prints
# nothing, successfully, for a branch that has none.
#
#   simd-symbols.sh <php-src-dir>
#
# WHY THIS EXISTS
#
# php/build.sh asserts that the binary really contains php-src's vector
# implementations, because a build where ./configure decided
# __attribute__((target(...))) is unavailable compiles every one of them out and
# is otherwise indistinguishable from a good build. The first version of that
# assertion counted `pshufb` in the whole binary, and on the legacy era that
# number is not php-src's:
#
#   libcrypto.a (vendored OpenSSL 1.1.1w)  pshufb 432  vpshufb 225  pclmul 196
#   shipped php 7.2 binary                 pshufb 432  vpshufb 225  pclmul 196
#
# Identical. Every vector instruction in that binary comes from OpenSSL, so the
# check could not have failed on 7.0-8.0 no matter what happened to php-src.
#
# Matching symbol *names* by ISA suffix does not fix it either: libcrypto.a
# defines 25 symbols that match the same convention (ChaCha20_ssse3,
# RSAZ_1024_mod_exp_avx2, K256_shaext, aesni_*). The only reliable anchor is the
# set of names php-src itself declares, which is what this reads.
#
# Two declaration forms, because php-src uses both:
#
#   7.4-8.0   zend_string *php_base64_encode_ssse3(...) __attribute__((target("ssse3")));
#   8.1+      ZEND_INTRIN_SSSE3_FUNC_DECL(zend_string *php_base64_encode_ssse3(...));
#
# Both are grepped out of the tree being built, so a branch that renames or adds
# an implementation is picked up without an edit here, and a branch that has
# none at all prints nothing. Measured across the matrix: 7.0-7.3 declare none
# and their ./configure does not probe for the attribute; 7.4 (12 names), 8.0
# (14), 8.1 (14) and 8.5 (25) declare them and do probe. The caller cross-checks
# emptiness against that probe, so "printed nothing" can never quietly mean "the
# grep stopped matching".
set -euo pipefail
SRC="${1:?usage: simd-symbols.sh <php-src-dir>}"
[ -d "$SRC" ] || { echo "simd-symbols.sh: $SRC is not a directory" >&2; exit 1; }

# grep exits 1 when it selects nothing, and selecting nothing is the correct
# answer on 7.0-7.3 -- so a bare pipeline under `set -o pipefail` turns "this
# branch has no SIMD" into a silent non-zero exit, which is exactly what it did
# the first time and what failed the 7.0 and 7.1 builds. This forgives "no
# lines" and only that: grep's exit 2, a real error such as an unreadable tree,
# still propagates.
no_match_ok() { "$@" || [ "$?" -eq 1 ]; }

# Zend/zend_portability.h only *defines* the ZEND_INTRIN_* macros and discusses
# the attribute in comments; it declares no implementation, so `define` lines
# are dropped or they would contribute macro parameter names.
raw="$(
  # Form A: name(args) __attribute__((target(...))) -- the identifier that opens
  # the parameter list is the last one before the attribute.
  no_match_ok grep -rhE '__attribute__[[:space:]]*\(\([[:space:]]*target[[:space:]]*\(' \
       "$SRC" --include='*.c' --include='*.h' 2>/dev/null \
    | no_match_ok grep -v 'define[[:space:]]' \
    | sed 's/__attribute__.*//' \
    | no_match_ok grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' \
    | tr -d ' ('

  # Form B: ZEND_INTRIN_<ISA>_FUNC_DECL(rettype name(args));
  no_match_ok grep -rhE 'ZEND_INTRIN_[A-Z0-9_]+_FUNC_DECL[[:space:]]*\(' \
       "$SRC" --include='*.c' --include='*.h' 2>/dev/null \
    | no_match_ok grep -v 'define[[:space:]]' \
    | sed 's/.*ZEND_INTRIN_[A-Z0-9_]*_FUNC_DECL[[:space:]]*(//' \
    | no_match_ok grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' \
    | tr -d ' ('
)"

[ -n "$raw" ] || exit 0

# Keywords and type names that precede a '(' in the same declarations, plus the
# two stray parses the 8.5 tree produces (push/pop from an inline-asm comment).
# A stray name costs nothing -- it simply will not be found in the binary, and
# the assertion requires *some* of the list to be present, not all of it.
printf '%s\n' "$raw" \
  | no_match_ok grep -vE '^(if|for|while|switch|return|sizeof|defined|static|inline|const|void|int|char|unsigned|size_t|bool|zend_string|zend_long|uint32_t|uint8_t|__m128i|__m256i|__m512i|ZEND_INTRIN_[A-Z0-9_]*|__attribute__|target|push|pop)$' \
  | sort -u
