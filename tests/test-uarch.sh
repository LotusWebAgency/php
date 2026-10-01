#!/usr/bin/env bash
# Verify a -v3 image was genuinely compiled at the x86-64-v3 microarchitecture
# level, not merely tagged as one.
#
#   tests/test-uarch.sh <baseline-image> <v3-image>
#
# "Both images run and report the same PHP_VERSION" cannot catch a build where
# UARCH never reached the compile -- ARG UARCH declared after the wrong FROM,
# a bake arg typo, a cache hit that reused baseline's layer -- because that
# build produces a working image, correctly tagged, with byte-identical
# codegen to baseline. So the primary assertion here is on the compiled
# instructions themselves: x86-64-v3 (the psABI level -march=x86-64-v3
# selects) adds AVX2, BMI1/BMI2 and FMA3 over the plain "x86-64" baseline, and
# -mtune=generic never emits any of them on its own -- their presence is a
# direct readout of which -march clang actually used, immune to a tag or a
# build arg lying about it.
set -euo pipefail

BASELINE="${1:?usage: test-uarch.sh <baseline-image> <v3-image>}"
V3="${2:?usage: test-uarch.sh <baseline-image> <v3-image>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

for tool in readelf objdump python3 docker; do
  command -v "$tool" >/dev/null || fail "$tool not found on this host; cannot verify uarch"
done

# readelf/objdump don't exist inside the runtime image (verified absent on
# 8.5-fpm) -- pull the binary out with docker cp and inspect it on the host,
# the same idiom tests/smoke.sh uses for its CF-5 check and tests/test-pgo.sh
# reuses for its own extraction.
extract_php() {  # extract_php <image> <dest-path>
  local image="$1" dest="$2" cid
  cid="$(docker create "$image")"
  docker cp "$cid:/usr/local/bin/php" "$dest" >/dev/null
  docker rm -f "$cid" >/dev/null
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
extract_php "$BASELINE" "$tmp/baseline-php"
extract_php "$V3" "$tmp/v3-php"
[ -s "$tmp/baseline-php" ] || fail "extracted baseline php binary is empty -- docker cp produced nothing to measure"
[ -s "$tmp/v3-php" ] || fail "extracted v3 php binary is empty -- docker cp produced nothing to measure"

# ---------------------------------------------------------------- image arch
# Which -march= each image is expected to carry depends on what CPU
# architecture it was actually built for, not on the host running this
# script -- a CI runner testing an arm64 image under emulation is still an
# amd64 host by `uname -m`. matrix.json's uarch map is the single source for
# what php/cflags.sh emits per {baseline,v3} x {arch}; read from there so this
# check can never drift from what the build itself uses.
image_arch() {  # image_arch <image> -> amd64|arm64|...
  docker image inspect --format '{{.Architecture}}' "$1"
}
expected_march() {  # expected_march <baseline|v3> <arch> -> e.g. x86-64-v3
  python3 -c '
import json, sys
uarch = json.load(open(sys.argv[1]))["uarch"]
level, arch = sys.argv[2], sys.argv[3]
if arch not in uarch.get(level, {}):
    sys.exit("matrix.json has no uarch.%s.%s entry" % (level, arch))
print(uarch[level][arch])
' "${ROOT}/matrix.json" "$1" "$2"
}

base_arch="$(image_arch "$BASELINE")"
v3_arch="$(image_arch "$V3")"
base_march="$(expected_march baseline "$base_arch")"
v3_march="$(expected_march v3 "$v3_arch")"
echo "ok: $BASELINE is $base_arch (expects -march=$base_march), $V3 is $v3_arch (expects -march=$v3_march)"

# ------------------------------------------------------------- build record
# php/build.sh's write_build_record bakes the exact CFLAGS configure/make ran
# with into /usr/local/share/php-build/pgo.txt (tests/test-pgo.sh already
# reads this file for its own lto/prof_flags assertions). Cheap and direct:
# it is what the build was *told* to do -- the mechanism the task brief's own
# troubleshooting note names ("if the two images are byte-identical, the
# UARCH arg is not reaching cflags.sh") -- which complements rather than
# substitutes for the instruction-mix measurement below, which is what the
# compiler actually *did*. A record can only corroborate; it cannot replace
# the artifact-level check, since a build could in principle record the right
# flags and still not apply them.
#
# This runs before any arch branch and on every arch: it needs no host-side
# disassembler, and arm64 deserves the same corroboration amd64 gets even
# though the instruction-mix check below stays x86-only.
record_cflags() {  # record_cflags <image> -> its pgo.txt cflags= value
  docker run --rm --entrypoint cat "$1" /usr/local/share/php-build/pgo.txt 2>/dev/null \
    | sed -n 's/^cflags=//p' | head -1
}
b_cflags="$(record_cflags "$BASELINE")"
v_cflags="$(record_cflags "$V3")"
[ -n "$v_cflags" ] || fail "$V3 has no /usr/local/share/php-build/pgo.txt cflags= line to read"
[ -n "$b_cflags" ] || fail "$BASELINE has no /usr/local/share/php-build/pgo.txt cflags= line to read"
grep -q -- "-march=${v3_march}" <<<"$v_cflags" \
  || fail "the v3 image's own build record does not carry -march=$v3_march: $v_cflags"
# `if grep ...; then fail; fi`, not `grep ... && fail`: under set -e the &&
# form dies on the correct outcome (grep exits 1 when baseline correctly
# lacks the string), which reads as this script crashing rather than
# passing. tests/smoke.sh already carries this exact fix for the same shape
# of assertion.
if grep -q -- "-march=${v3_march}" <<<"$b_cflags"; then
  fail "the baseline image's build record carries the v3 -march=$v3_march: $b_cflags"
fi
# Not just "doesn't carry v3" -- assert baseline carries what php/cflags.sh
# actually emits for it (verified: -march=x86-64 on amd64, -march=armv8-a on
# arm64; neither is empty, but a future cflags.sh change that stopped
# emitting a baseline -march would silently pass a "does not carry v3" check
# forever).
grep -q -- "-march=${base_march}" <<<"$b_cflags" \
  || fail "the baseline image's build record does not carry its own expected -march=$base_march: $b_cflags"
echo "ok: build records confirm -march=$v3_march reached configure/make for v3 and -march=$base_march for baseline"

# ------------------------------------------------------------ instruction mix
#
# AVX2/BMI2/FMA3 instruction counting is only meaningful (a) with an x86_64
# disassembler capable of decoding the mnemonics below, and (b) against a
# binary that was actually built for amd64 -- gated on the images' own
# architecture (from matrix.json above), not the host's uname -m, so an
# arm64 image pair is correctly labelled partial even when this script
# happens to run on an amd64 CI host under emulation.
if [ "$base_arch" != amd64 ] || [ "$v3_arch" != amd64 ]; then
  echo "note: skipping the x86-64-v3 instruction-mix check ($BASELINE is $base_arch, $V3 is $v3_arch, not amd64/amd64) -- arm64's v3 level adds LSE atomics and similar, which the compiler does not auto-emit the way it does AVX2/BMI2/FMA3, so this check stays x86-only"
  partial=1
else
  partial=0

  # WHAT IS BEING COUNTED. This runs whole-binary against the shipped php
  # executable, not attributed to php-src's own symbols the way
  # php/build.sh's assert_simd_dispatch_present is at build time (it cannot
  # be: strip --strip-unneeded, which runs before this image ships, removes
  # the local zend_/php_/zif_/zm_ symbols that attribution needs). That
  # distinction is exactly what cost this project a Critical on the legacy
  # era, where a whole-binary SIMD count read 432 instructions that were
  # entirely OpenSSL's, vendored and statically linked, and php-src's own
  # contribution could have been zero without the check ever noticing.
  #
  # It is a much narrower gap on 8.4/8.5. tests/smoke.sh's CF-5
  # assertion proves the modern era's OpenSSL is linked dynamically rather
  # than vendored, and php/system-libs.lock proves libsqlite3/libzip/libzstd
  # are too, so the only non-php-src code statically compiled into this
  # binary is the small set of "static" PECL extensions tests/smoke.sh
  # itself enumerates -- igbinary, redis, imagick's PHP-level glue,
  # memcached, apcu, zstd's glue -- plus opcache. ImageMagick's own
  # libraries, which is where this project's real SIMD-heavy third-party
  # code lives, ship as separate .so files dlopened at runtime
  # (tests/smoke.sh's im_libs extraction), not compiled into this
  # binary at all. None of what remains ships a vendored crypto/compression
  # kernel the way legacy's OpenSSL did, so a whole-binary count here is
  # overwhelmingly php-src's own codegen -- and cheap enough to run
  # per-image rather than only once at build time.
  #
  # vpermd/vpbroadcast*/vperm* (AVX2 shuffle/broadcast), vfmadd*/vfmsub*/
  # vfnmadd*/vfnmsub* (FMA3) and shlx/sarx/shrx/mulx/pdep/pext/bzhi/andn/
  # blsr/blsi (BMI1+BMI2) are the mnemonics x86-64-v3 adds over baseline;
  # none of them can be emitted by a compile that used -march=x86-64 (or no
  # -march at all). \b-bounded so a call-target symbol name that happens to
  # contain one of these strings (e.g. some `..._andn...` helper) cannot be
  # mistaken for the instruction itself.
  #
  # tzcnt is deliberately NOT in this list, though it is one of the mnemonics
  # x86-64-v3 (BMI1) adds. Measured on the real lotuswebagency/php:8.5-fpm binary
  # (2026-09-26): tzcnt accounts for 69 of 120 v3-mnemonic matches (57.5%) --
  # `rep bsf` is the compiler's standard lowering of ctz-family builtins on
  # *any* -march, and objdump labels the `rep bsf` encoding "tzcnt" whether or
  # not BMI1 was assumed, so its presence says nothing about which -march
  # compiled this binary. Without tzcnt the same binary measures 51 (13
  # vpbroadcastd, 13 vpbroadcastb, 7 vpbroadcastw, 5 vpermq, 5 vpermb, 3
  # vpermd, 2 vperm2i128, 2 vpbroadcastq, 1 vpermt2b) -- a real, discriminating
  # v3-only signal on its own, so dropping the noisy mnemonic costs nothing.
  V3_MNEMONICS='\b(vperm[a-z0-9]*|vpbroadcast[bwdq]|vfn?madd[a-z0-9]*|vfn?msub[a-z0-9]*|shlx|sarx|shrx|mulx|pdep|pext|bzhi|andn|blsr|blsi)\b'

  # Disassemble each binary exactly once into a file, with objdump's own exit
  # status checked directly (no pipe -- a pipe's `... | grep -c || true`
  # swallows an objdump failure that happened before the pipe, which is what
  # let a broken disassembly of the v3 binary pass silently here before).
  # Everything below reads from these captures instead of re-invoking objdump.
  disassemble() {  # disassemble <binary> <out-file>
    if ! objdump -d "$1" > "$2" 2>/dev/null; then
      fail "objdump could not disassemble $1"
    fi
  }
  disassemble "$tmp/baseline-php" "$tmp/baseline.dis"
  disassemble "$tmp/v3-php" "$tmp/v3.dis"

  # Positive control for the matcher itself, applied to BOTH captures before
  # anything below is trusted: if objdump silently produced a near-empty or
  # garbage disassembly of either binary, "substantially higher than
  # baseline" could be satisfied by two near-zero counts -- the same fail-open
  # shape as the CF-5 defect this project already fixed once
  # (smoke.sh's CF-5 fail-open fix). Checking only the v3 side left baseline's
  # own disassembly unverified, and a broken baseline capture (base_count=0)
  # would have made the threshold below trivially easy to clear.
  sanity_check() {  # sanity_check <label> <dis-file>
    local n
    n="$(grep -cE '\b(mov|call)\b' "$2" || true)"
    [ "${n:-0}" -gt 1000 ] \
      || fail "objdump found under 1000 mov/call instructions disassembling the $1 binary -- the disassembly is broken, so nothing below was measured"
  }
  sanity_check baseline "$tmp/baseline.dis"
  sanity_check v3 "$tmp/v3.dis"

  # Per-mnemonic breakdown, printed for both binaries on every run, so the
  # evidence behind the instruction-mix count is visible without re-running
  # anything by hand.
  mnemonic_breakdown() {  # mnemonic_breakdown <dis-file> -> "mnem=count ..." highest first
    grep -oE "$V3_MNEMONICS" "$1" | sort | uniq -c | sort -rn | awk '{printf "%s=%s ", $2, $1}'
  }
  echo "baseline mnemonic breakdown: $(mnemonic_breakdown "$tmp/baseline.dis")"
  echo "v3 mnemonic breakdown: $(mnemonic_breakdown "$tmp/v3.dis")"

  base_count="$(grep -cE "$V3_MNEMONICS" "$tmp/baseline.dis" || true)"
  v3_count="$(grep -cE "$V3_MNEMONICS" "$tmp/v3.dis" || true)"
  echo "instruction mix: baseline=$base_count v3=$v3_count (AVX2/BMI2/FMA3 mnemonics, whole php binary, tzcnt excluded)"

  [ "$v3_count" -gt 0 ] \
    || fail "the v3 image has zero AVX2/BMI2/FMA3 instructions in its php binary -- -march=x86-64-v3 did not reach the compile"

  # "Substantially higher", not merely non-zero: a baseline build legally
  # carries some of these mnemonics too, and not as noise. php-src wraps a
  # handful of hot functions (the base64 and addslashes dispatch
  # tests/test-pgo.sh exercises, among others) in
  # __attribute__((target("..."))) multiversioning, which compiles that *one*
  # function at the ISA level named in the attribute regardless of the
  # translation unit's own -march, precisely so a baseline build still gets a
  # fast path selected by a runtime cpuid check. Those functions look
  # identical in a v3 build. What differs is everything else in php-src that
  # -march alone governs -- every loop the compiler chose to auto-vectorize
  # with AVX2, every variable shift the compiler chose to encode with shlx
  # now that BMI2 is assumed present. v3_count > 0 alone would pass on a
  # build that leaked only the shared multiversioned functions and changed
  # nothing else -- exactly the silent-fallback failure mode this check
  # exists to catch.
  threshold=$(( (base_count + 1) * 5 ))
  [ "$v3_count" -ge "$threshold" ] \
    || fail "v3 image has only $v3_count v3-only instructions against baseline's $base_count -- not substantially higher (wanted >= $threshold), -march=x86-64-v3 may not have reached the compile"
  echo "ok: v3 image carries $v3_count AVX2/BMI2/FMA3 instructions vs baseline's $base_count -- x86-64-v3 codegen confirmed"

  # ---------------------------------------------------------------- ISA note
  # Best-effort corroboration, not the primary measurement: sufficiently
  # recent binutils/lld record the compiled ISA level in .note.gnu.property
  # (GNU_PROPERTY_X86_ISA_1_NEEDED), and readelf -n decodes it as a "x86 ISA
  # needed" property line. Whether the note is emitted at all is a property
  # of the toolchain this base image ships, not of this build -- the same
  # reason tests/assert-elf-hardening.sh documents a *different*
  # .note.gnu.property marking (CET IBT/SHSTK) as deliberately unasserted,
  # having verified it is absent even from Debian trixie's own /bin/ls. So
  # this only asserts something when at least one binary actually carries the
  # note; if neither does, that is not evidence either way and the
  # instruction-count check above -- which is unconditional -- is what this
  # test relies on.
  isa_note() { readelf -n "$1" 2>/dev/null | grep -i "x86 ISA needed" || true; }
  b_isa="$(isa_note "$tmp/baseline-php")"
  v_isa="$(isa_note "$tmp/v3-php")"
  if [ -n "$b_isa" ] || [ -n "$v_isa" ]; then
    echo "$v_isa" | grep -qi "x86-64-v3" || fail "v3 image's ISA note does not declare x86-64-v3: '$v_isa'"
    if echo "$b_isa" | grep -qi "x86-64-v3"; then
      fail "baseline image's ISA note declares x86-64-v3: '$b_isa'"
    fi
    echo "ok: ISA notes agree with the instruction-count measurement (baseline: '$b_isa', v3: '$v_isa')"
  else
    echo "note: neither binary carries a .note.gnu.property ISA-level note (this toolchain does not emit one) -- relying on the instruction-count measurement above"
  fi
fi

# ------------------------------------------------------------------- sanity
# Capture, then match -- `docker run ... | grep -q` exits at the first match
# and SIGPIPEs the producer, which pipefail then reports as a pipeline
# failure. tests/smoke.sh's header documents the same fix for the same
# reason.
for img in "$BASELINE" "$V3"; do
  out="$(docker run --rm "$img" php -r 'echo "ok";')"
  [ "$out" = "ok" ] || fail "$img does not run (got: '$out')"
done
echo "ok: both variants run"

bv="$(docker run --rm "$BASELINE" php -r 'echo PHP_VERSION;')"
vv="$(docker run --rm "$V3" php -r 'echo PHP_VERSION;')"
[ "$bv" = "$vv" ] || fail "version mismatch: $bv vs $vv"
echo "ok: same php version ($bv)"

if [ "$partial" -eq 1 ]; then
  echo "UARCH TESTS PASSED (partial -- no x86-64-v3 instruction-mix check for a $base_arch/$v3_arch image pair)"
else
  echo "UARCH TESTS PASSED"
fi
