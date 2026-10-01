#!/usr/bin/env bash
# Prove, on this toolchain and with this build's own flags, that a .text.hot
# section in a linked binary means a profile reached the compiler -- and that
# no such section appears without one.
#
#   discriminator-control.sh <cflags> <ldflags>
#
# php/build.sh's assert_profile_reached_the_link() is an assertion about the
# shipped php binary, and it is only as good as the discriminator it rests on.
# Left unmeasured, two things could quietly break it in opposite directions:
#
#   * a clang that stops emitting section prefixes (a default change, a
#     packaging change) would make every PGO build look like it dropped its
#     profile -- a loud failure, but for the wrong reason;
#   * a clang or a flag set that emits .text.hot for some other reason would
#     make the PGO assertion pass on a build that never read a profile, which
#     is the failure that ships.
#
# So both directions are measured here, on every build, in about three seconds,
# with the same CFLAGS and LDFLAGS the real compile uses -- not with a
# hand-written minimal flag set that could differ in exactly the way that
# matters. The cost is two compiles of a 40-line file.
#
# .text.hot rather than .text.unlikely on purpose: php-src marks whole files'
# worth of functions with ZEND_COLD -> __attribute__((cold)), so the cold
# section exists with or without a profile. ZEND_HOT is defined but used
# nowhere in 7.0.33 or 8.5.0 (grepped, both), so nothing in php-src can produce
# a hot section on its own.
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
  # Same positive control the real assertion uses: an empty listing would make
  # both answers below "no" and the control would report a dead discriminator.
  grep -q '\.text' <<<"$sections" \
    || { echo "FATAL[control]: readelf printed no sections for $1" >&2; exit 1; }
  if grep -q '\.text\.hot' <<<"$sections"; then echo yes; else echo no; fi
}

if [ "$COMPILER" = gcc ]; then
  # gcc has no raw-profile format to merge: -fprofile-generate=DIR writes
  # .gcda straight into DIR and -fprofile-use=DIR reads it back directly, so
  # there is no llvm-profdata-equivalent step here at all.
  #
  # Two compiles (-c) into the SAME object path, not one source-to-binary
  # compile per probe binary: gcc names each .gcda after the *object file*
  # -fprofile-generate compiled (its -o path when called with -c, the link
  # output's basename otherwise) -- measured, not assumed, against this exact
  # toolchain (gcc 16 / binutils 2.47) -- so probe-gen.o and probe-pgo.o
  # compiled to two different names would each look for their own .gcda and
  # silently find neither, and -Wno-missing-profile would hide exactly that.
  # php-src's own Makefiles never hit this: pass 1 and pass 2 compile the same
  # sources to the same .o paths, which is what this reproduces.
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
