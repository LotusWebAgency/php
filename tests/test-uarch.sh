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
# selects) adds AVX2, BMI1/BMI2 and FMA3 over the "x86-64-v2" baseline, and
# -mtune=generic never emits any of them on its own -- their presence is a
# direct readout of which -march clang actually used, immune to a tag or a
# build arg lying about it.
set -euo pipefail

BASELINE="${1:?usage: test-uarch.sh <baseline-image> <v3-image>}"
V3="${2:?usage: test-uarch.sh <baseline-image> <v3-image>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker-lib.sh
. "$HERE/docker-lib.sh"
ROOT="$(cd "${HERE}/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

for tool in readelf objdump python3 docker; do
  command -v "$tool" >/dev/null || fail "$tool not found on this host; cannot verify uarch"
done

# readelf/objdump don't exist inside the runtime image -- pull the binary out
# with docker cp and inspect it on the host, the same idiom tests/smoke.sh and
# tests/test-pgo.sh use.
extract_bin() {  # extract_bin <image> <path-in-image> <dest-path>; non-zero when the image has no such file
  local image="$1" src="$2" dest="$3" cid rc=0
  cid="$(docker create --pull never "$image")"
  docker cp "$cid:$src" "$dest" >/dev/null 2>&1 || rc=$?
  docker rm -f "$cid" >/dev/null
  return "$rc"
}
extract_php() {  # extract_php <image> <dest-path>
  extract_bin "$1" /usr/local/bin/php "$2" || fail "$1 has no /usr/local/bin/php"
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
# with into /usr/local/share/php-build/pgo.txt (tests/test-pgo.sh reads the same
# file). Cheap and direct: it is what the build was *told* to do -- if the two
# images are byte-identical, the UARCH arg is not reaching cflags.sh -- which
# complements rather than replaces the instruction-mix measurement below, which
# is what the compiler actually *did*. A record can only corroborate; a build
# could in principle record the right flags and still not apply them.
#
# This runs before any arch branch and on every arch: it needs no host-side
# disassembler, and arm64 deserves the same corroboration amd64 gets even
# though the instruction-mix check below stays x86-only.
record_cflags() {  # record_cflags <image> -> its pgo.txt cflags= value
  drun --rm --entrypoint cat "$1" /usr/local/share/php-build/pgo.txt 2>/dev/null \
    | sed -n 's/^cflags=//p' | head -1
}
b_cflags="$(record_cflags "$BASELINE")"
v_cflags="$(record_cflags "$V3")"
[ -n "$v_cflags" ] || fail "$V3 has no /usr/local/share/php-build/pgo.txt cflags= line to read"
[ -n "$b_cflags" ] || fail "$BASELINE has no /usr/local/share/php-build/pgo.txt cflags= line to read"
grep -q -- "-march=${v3_march}" <<<"$v_cflags" \
  || fail "the v3 image's own build record does not carry -march=$v3_march: $v_cflags"
# `if grep ...; then fail; fi`, not `grep ... && fail`: under set -e the &&
# form dies on the correct outcome (grep exits 1 when baseline correctly lacks
# the string), which reads as this script crashing rather than passing.
if grep -q -- "-march=${v3_march}" <<<"$b_cflags"; then
  fail "the baseline image's build record carries the v3 -march=$v3_march: $b_cflags"
fi
# Not just "doesn't carry v3": assert baseline carries what php/cflags.sh emits
# for it (-march=x86-64-v2 on amd64, -march=armv8-a on arm64), or a cflags.sh change
# that stopped emitting a baseline -march would silently pass a "does not carry
# v3" check forever.
grep -q -- "-march=${base_march}" <<<"$b_cflags" \
  || fail "the baseline image's build record does not carry its own expected -march=$base_march: $b_cflags"
echo "ok: build records confirm -march=$v3_march reached configure/make for v3 and -march=$base_march for baseline"

# ------------------------------------------------------------ instruction mix
#
# AVX2/BMI2/FMA3 instruction counting is only meaningful (a) with an x86_64
# disassembler capable of decoding the mnemonics below, and (b) against a
# binary that was actually built for amd64 -- gated on the images' own
# architecture (from matrix.json above), not the host's uname -m, so an
# arm64 image pair is correctly labeled partial even when this script
# happens to run on an amd64 CI host under emulation.
if [ "$base_arch" != amd64 ] || [ "$v3_arch" != amd64 ]; then
  echo "note: skipping the x86-64-v3 instruction-mix check ($BASELINE is $base_arch, $V3 is $v3_arch, not amd64/amd64) -- arm64's v3 level is armv9-a, whose SVE2 gain is not measured by an instruction count against this threshold, so this check stays x86-only"
  partial=1
else
  partial=0

  # WHAT IS BEING COUNTED. This runs whole-binary against the shipped php
  # executable, not attributed to php-src's own symbols the way php/build.sh's
  # assert_simd_dispatch_present is at build time (it cannot be: strip
  # --strip-unneeded removes the local zend_/php_/zif_/zm_ symbols attribution
  # needs). On the legacy era that distinction matters: a whole-binary SIMD
  # count there is dominated by the vendored, statically linked OpenSSL, and
  # php-src's own contribution could be zero without the check noticing.
  #
  # The gap is much narrower on 8.4/8.5. tests/smoke.sh proves the modern era's
  # OpenSSL is linked dynamically rather than vendored, and php/system-libs.lock
  # proves libsqlite3/libzip/libzstd are too, so the only non-php-src code
  # statically compiled into this binary is the small set of "static" PECL
  # extensions tests/smoke.sh enumerates (igbinary, redis, imagick's PHP-level
  # glue, memcached, apcu, zstd's glue) plus opcache. ImageMagick's own
  # libraries, the SIMD-heavy third-party code, ship as separate .so files
  # dlopened at runtime. None of what remains ships a vendored crypto or
  # compression kernel, so a whole-binary count here is overwhelmingly php-src's
  # own codegen -- and cheap enough to run per image.
  #
  # vpermd/vpbroadcast*/vperm* (AVX2 shuffle/broadcast), vfmadd*/vfmsub*/
  # vfnmadd*/vfnmsub* (FMA3) and shlx/sarx/shrx/mulx/pdep/pext/bzhi/andn/
  # blsr/blsi (BMI1+BMI2) are the mnemonics x86-64-v3 adds over baseline;
  # none of them can be emitted by a compile that used -march=x86-64-v2 (or no
  # -march at all). \b-bounded so a call-target symbol name that happens to
  # contain one of these strings (e.g. some `..._andn...` helper) cannot be
  # mistaken for the instruction itself.
  #
  # tzcnt is deliberately NOT in this list, though x86-64-v3 (BMI1) adds it:
  # `rep bsf` is the compiler's standard lowering of ctz-family builtins on
  # *any* -march, and objdump labels the `rep bsf` encoding "tzcnt" whether or
  # not BMI1 was assumed, so it accounts for over half of the v3-mnemonic
  # matches on a binary and says nothing about which -march compiled it. The
  # remaining mnemonics are a discriminating v3-only signal on their own.
  V3_MNEMONICS='\b(vperm[a-z0-9]*|vpbroadcast[bwdq]|vfn?madd[a-z0-9]*|vfn?msub[a-z0-9]*|shlx|sarx|shrx|mulx|pdep|pext|bzhi|andn|blsr|blsi)\b'

  # Disassemble each binary exactly once into a file, with objdump's exit status
  # checked directly (no pipe: a `... | grep -c || true` would swallow an
  # objdump failure that happened before the pipe, letting a broken disassembly
  # pass silently). Everything below reads from these captures.
  disassemble() {  # disassemble <binary> <out-file>
    if ! objdump -d "$1" > "$2" 2>/dev/null; then
      fail "objdump could not disassemble $1"
    fi
  }
  disassemble "$tmp/baseline-php" "$tmp/baseline.dis"
  disassemble "$tmp/v3-php" "$tmp/v3.dis"

  # Positive control for the matcher itself, applied to BOTH captures: if
  # objdump silently produced a near-empty or garbage disassembly of either
  # binary, "substantially higher than baseline" could be satisfied by two
  # near-zero counts -- a fail-open shape. A broken baseline capture
  # (base_count=0) would make the threshold below trivially easy to clear.
  sanity_check() {  # sanity_check <label> <dis-file>
    local n
    n="$(grep -cE '\b(mov|call)\b' "$2" || true)"
    [ "${n:-0}" -gt 1000 ] \
      || fail "objdump found under 1000 mov/call instructions disassembling the $1 binary -- the disassembly is broken, so nothing below was measured"
  }
  sanity_check baseline "$tmp/baseline.dis"
  sanity_check v3 "$tmp/v3.dis"

  # Per-mnemonic breakdown, printed for both binaries on every run, so the
  # evidence behind the instruction-mix count is visible.
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

  # "Substantially higher", not merely non-zero: a baseline build legally carries
  # some of these mnemonics too. php-src wraps a handful of hot functions (the
  # base64 and addslashes dispatch tests/test-pgo.sh exercises, among others) in
  # __attribute__((target("..."))) multiversioning, which compiles that one
  # function at the ISA level named in the attribute regardless of -march, so a
  # baseline build still gets a fast path selected by a runtime cpuid check.
  # Those functions look identical in a v3 build. What differs is everything
  # else -march alone governs -- every loop auto-vectorized with AVX2, every
  # variable shift encoded with shlx once BMI2 is assumed. v3_count > 0 alone
  # would pass on a build that leaked only the shared multiversioned functions
  # and changed nothing else.
  threshold=$(( (base_count + 1) * 5 ))
  [ "$v3_count" -ge "$threshold" ] \
    || fail "v3 image has only $v3_count v3-only instructions against baseline's $base_count -- not substantially higher (wanted >= $threshold), -march=x86-64-v3 may not have reached the compile"
  echo "ok: v3 image carries $v3_count AVX2/BMI2/FMA3 instructions vs baseline's $base_count -- x86-64-v3 codegen confirmed"

  # ------------------------------------------------------------ startup gate
  # A -v3 binary must refuse to start on a CPU without x86-64-v3 instead of
  # dying later with SIGILL, and a baseline binary must not carry the gate.
  # The gate is php/isa-gate-x86-64-v3.c, a priority-101 constructor linked
  # into php and php-fpm (php/build.sh): glibc 2.44 acts on no GNU property
  # note and neither gold nor lld emits PT_GNU_PROPERTY, so there is no loader
  # check to lean on.
  #
  # First half: the gate is in the shipped binaries. Its message is a string in
  # .rodata, which strip keeps.
  gate_marker='this build requires an x86-64-v3 CPU'
  has_gate() { grep -aqF "$gate_marker" "$1"; }
  has_gate "$tmp/v3-php" \
    || fail "v3 image's php does not contain the x86-64-v3 gate -- it would die with SIGILL on an older CPU instead of being refused at startup"
  if has_gate "$tmp/baseline-php"; then
    fail "baseline image's php contains the x86-64-v3 gate -- it would refuse to start on a CPU it is meant to run on"
  fi
  echo "ok: the x86-64-v3 gate is in the v3 php and not in the baseline php"

  # Where the image ships php-fpm (the fpm flavor), it is a separate link.
  if extract_bin "$V3" /usr/local/sbin/php-fpm "$tmp/v3-php-fpm"; then
    has_gate "$tmp/v3-php-fpm" \
      || fail "v3 image's php-fpm does not contain the x86-64-v3 gate"
    if extract_bin "$BASELINE" /usr/local/sbin/php-fpm "$tmp/baseline-php-fpm"; then
      if has_gate "$tmp/baseline-php-fpm"; then
        fail "baseline image's php-fpm contains the x86-64-v3 gate"
      fi
    fi
    echo "ok: the x86-64-v3 gate is in the v3 php-fpm"
  else
    echo "note: $V3 ships no /usr/local/sbin/php-fpm (not an fpm flavor); only php was checked"
  fi

  # Second half: the gate fires. Run the shipped binaries on an emulated CPU
  # below x86-64-v3 -- qemu-user's Nehalem has SSE4.2 (the x86-64-v2 the Wolfi
  # userland needs) and no AVX/AVX2/BMI/FMA -- from inside the image, so the
  # image's own glibc and libraries load. The static qemu binary is bind-mounted
  # in. Controls: Haswell (AVX2, BMI, FMA) must start the same v3 binary, which
  # shows a refusal is about the CPU and not about qemu or the path, and the
  # baseline binary must start on Nehalem. The timeout runs inside the container
  # (PID 1 would ignore a client-side kill).
  qemu_bin=""
  for candidate in qemu-x86_64-static qemu-x86_64; do
    path="$(command -v "$candidate" || true)"
    if [ -n "$path" ] && ! readelf -d "$path" 2>/dev/null | grep -q '(NEEDED)'; then qemu_bin="$path"; break; fi
  done
  if [ -z "$qemu_bin" ]; then
    [ "${UARCH_ALLOW_NO_QEMU:-0}" = 1 ] \
      || fail "no statically linked qemu-x86_64 on this host (qemu-user-static), so the -v3 refusal cannot be tested. Install it, or set UARCH_ALLOW_NO_QEMU=1 to skip this proof knowingly"
    echo "WARNING: UARCH_ALLOW_NO_QEMU=1 -- the -v3 refusal was NOT tested on an emulated CPU" >&2
  else
    run_on_cpu() {  # run_on_cpu <image> <cpu> <binary-in-image> [args...] -> output, exit status of the binary
      local image="$1" cpu="$2" bin="$3"; shift 3
      drun --rm --init --label claude.adhoc=1 -v "$qemu_bin:/qemu:ro" \
        --entrypoint timeout "$image" 60 /qemu -cpu "$cpu" "$bin" "$@" 2>&1
    }
    refusal_proof() {  # refusal_proof <label> <binary-in-image> <version-arg>
      local label="$1" bin="$2" arg="$3" out rc
      rc=0; out="$(run_on_cpu "$V3" Haswell-noTSX "$bin" "$arg")" || rc=$?
      [ "$rc" -eq 0 ] || fail "$label does not start on an emulated Haswell (AVX2) CPU (exit $rc): $out"
      rc=0; out="$(run_on_cpu "$V3" Nehalem "$bin" "$arg")" || rc=$?
      if [ "$rc" -ne 127 ] || ! grep -qF "$gate_marker" <<<"$out"; then
        fail "$label was NOT refused on an emulated Nehalem CPU without AVX2 (exit $rc: $out) -- the -v3 gate is off"
      fi
      echo "ok: $label starts on an emulated Haswell and is refused on a Nehalem (exit 127, '$gate_marker')"
    }
    refusal_proof php /usr/local/bin/php -v
    if [ -s "$tmp/v3-php-fpm" ]; then refusal_proof php-fpm /usr/local/sbin/php-fpm -v; fi
    rc=0; out="$(run_on_cpu "$BASELINE" Nehalem /usr/local/bin/php -v)" || rc=$?
    [ "$rc" -eq 0 ] || fail "the baseline php does not start on an emulated Nehalem CPU (exit $rc): $out"
    echo "ok: the baseline php starts on an emulated Nehalem (x86-64-v2) CPU"
  fi
fi

# ------------------------------------------------------------------- sanity
# Capture, then match -- `docker run ... | grep -q` exits at the first match and
# SIGPIPEs the producer, which pipefail then reports as a pipeline failure.
for img in "$BASELINE" "$V3"; do
  out="$(drun --rm "$img" php -r 'echo "ok";')"
  [ "$out" = "ok" ] || fail "$img does not run (got: '$out')"
done
echo "ok: both variants run"

bv="$(drun --rm "$BASELINE" php -r 'echo PHP_VERSION;')"
vv="$(drun --rm "$V3" php -r 'echo PHP_VERSION;')"
[ "$bv" = "$vv" ] || fail "version mismatch: $bv vs $vv"
echo "ok: same php version ($bv)"

if [ "$partial" -eq 1 ]; then
  echo "UARCH TESTS PASSED (partial -- no x86-64-v3 instruction-mix check for a $base_arch/$v3_arch image pair)"
else
  echo "UARCH TESTS PASSED"
fi
