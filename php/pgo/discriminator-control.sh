#!/usr/bin/env bash
# Prove, on this toolchain and with this build's own flags, that a .text.hot
# section in a linked binary means a profile reached the compiler -- and that no
# such section appears without one.
#
#   discriminator-control.sh <cflags> <ldflags>
#
# php/build.sh's assert_profile_reached_the_link() rests on that discriminator,
# which could break in either direction: a compiler that stops emitting section
# prefixes makes every PGO build look like it dropped its profile (loud, wrong
# reason); one that emits .text.hot without a profile lets the assertion pass on a
# build that never read one (the failure that ships). Both directions are measured
# on every build with the same CFLAGS and LDFLAGS as the real compile, at the cost
# of a few compiles of a 40-line file.
#
# .text.hot rather than .text.unlikely because php-src marks many functions
# ZEND_COLD (__attribute__((cold))), so the cold section exists with or without a
# profile. ZEND_HOT is defined but unused in php-src, so nothing there produces a
# hot section on its own.
set -euo pipefail

CFLAGS_IN="${1:?usage: discriminator-control.sh <cflags> <ldflags>}"
LDFLAGS_IN="${2:?usage: discriminator-control.sh <cflags> <ldflags>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${HERE}/discriminator-probe.c"
[ -f "$PROBE" ] || { echo "FATAL[control]: no $PROBE" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
CC_BIN="${CC:-clang}"
COMPILER="${COMPILER:-clang}"

has_text_hot() {  # has_text_hot <binary> -> prints yes|no
  local sections
  sections="$(readelf -SW "$1")" || { echo "FATAL[control]: readelf could not read $1" >&2; exit 1; }
  # Same positive control as the real assertion: an empty listing would answer
  # "no" for both binaries and report a dead discriminator.
  grep -q '\.text' <<<"$sections" \
    || { echo "FATAL[control]: readelf printed no sections for $1" >&2; exit 1; }
  if grep -q '\.text\.hot' <<<"$sections"; then echo yes; else echo no; fi
}

if [ "$COMPILER" = gcc ]; then
  # gcc has no raw-profile merge step: -fprofile-generate=DIR writes .gcda into
  # DIR and -fprofile-use=DIR reads it back directly.
  #
  # Compile (-c) to the same object path both times: gcc names each .gcda after
  # the object file (the -o path with -c, the link output's basename otherwise),
  # so two different object names would each look for their own .gcda, find
  # neither, and -Wno-missing-profile would hide it. php-src's Makefiles compile
  # both passes to the same .o paths, which this reproduces.
  # shellcheck disable=SC2086  # CFLAGS_IN/LDFLAGS_IN are meant to word-split
  $CC_BIN $CFLAGS_IN -fprofile-generate="${work}/prof" -c "$PROBE" -o "${work}/probe.o"
  # shellcheck disable=SC2086
  $CC_BIN $CFLAGS_IN -fprofile-generate="${work}/prof" $LDFLAGS_IN -o "${work}/probe-gen" "${work}/probe.o"
  "${work}/probe-gen" 2000000 >/dev/null

  # shellcheck disable=SC2086
  $CC_BIN $CFLAGS_IN -fprofile-use="${work}/prof" -fprofile-partial-training -c "$PROBE" -o "${work}/probe.o"
  # shellcheck disable=SC2086
  $CC_BIN $CFLAGS_IN $LDFLAGS_IN -o "${work}/probe-pgo" "${work}/probe.o"
  # shellcheck disable=SC2086
  $CC_BIN $CFLAGS_IN -c "$PROBE" -o "${work}/probe-plain.o"
  # shellcheck disable=SC2086
  $CC_BIN $CFLAGS_IN $LDFLAGS_IN -o "${work}/probe-plain" "${work}/probe-plain.o"
else
  # shellcheck disable=SC2086  # both flag sets are meant to word-split
  $CC_BIN $CFLAGS_IN -fprofile-generate="${work}/prof" $LDFLAGS_IN -fprofile-generate="${work}/prof" \
    -o "${work}/probe-gen" "$PROBE"
  LLVM_PROFILE_FILE="${work}/prof/probe-%p.profraw" "${work}/probe-gen" 2000000 >/dev/null
  llvm-profdata merge -output="${work}/probe.profdata" "${work}"/prof/*.profraw

  # shellcheck disable=SC2086
  $CC_BIN $CFLAGS_IN -fprofile-use="${work}/probe.profdata" $LDFLAGS_IN -o "${work}/probe-pgo" "$PROBE"
  # shellcheck disable=SC2086
  $CC_BIN $CFLAGS_IN $LDFLAGS_IN -o "${work}/probe-plain" "$PROBE"
fi

with="$(has_text_hot "${work}/probe-pgo")"
without="$(has_text_hot "${work}/probe-plain")"

[ "$with" = yes ] || {
  echo "FATAL[control]: a profile-guided link produced no .text.hot section on this toolchain." \
       "The check php/build.sh uses to prove PGO took effect cannot distinguish anything --" \
       "fix the discriminator before trusting any PGO result." >&2
  exit 1
}
[ "$without" = no ] || {
  echo "FATAL[control]: a link with NO profile produced a .text.hot section on this toolchain." \
       "php/build.sh's PGO assertion would pass on a build that never read a profile." >&2
  exit 1
}
echo "ok: .text.hot appears with a profile and not without it -- the PGO assertion has discriminating power"
