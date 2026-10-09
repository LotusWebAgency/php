#!/usr/bin/env bash
# Assert the hardening flags actually landed in a produced binary.
#
#   assert-elf-hardening.sh [--main] <label> <file> [<file>...]
#
# scripts/test_flags.py checks that php/cflags.sh and php/ldflags.sh *emit*
# -fstack-protector-strong, -D_FORTIFY_SOURCE=3, -fcf-protection=full,
# -z relro/now/noexecstack and so on. That is a test of our intent. It cannot
# see a flag dropped by configure, overridden by a later flag on the same
# command line, or silently ignored by the target. This asserts the properties
# on the ELF files that ship.
#
# Every check below is a *positive* assertion ("the binary HAS this"), which is
# the shape that cannot pass by accident. What can still go wrong is the
# measurement itself, so that is guarded explicitly: a file that readelf cannot
# parse, a file with no program headers, or an empty file list is a failure, not
# a silent pass. (tests/smoke.sh feeds this script a deliberately non-ELF
# file to prove that guard fires.)
set -euo pipefail

MAIN=0
if [ "${1:-}" = "--main" ]; then MAIN=1; shift; fi
LABEL="${1:?usage: assert-elf-hardening.sh [--main] <label> <file>...}"
shift
[ "$#" -gt 0 ] || { echo "FAIL[$LABEL]: no files given -- nothing was measured"; exit 1; }

for tool in readelf objdump; do
  command -v "$tool" >/dev/null || { echo "FAIL[$LABEL]: $tool not found; cannot verify hardening"; exit 1; }
done

checked=0
for f in "$@"; do
  [ -f "$f" ] || { echo "FAIL[$LABEL]: $f does not exist"; exit 1; }
  name="$(basename "$f")"

  # Parse once, up front, with nothing to swallow a failure: a file readelf
  # cannot read must fail here rather than produce empty output that every grep
  # below reads as "property absent" -- or worse, as "no bad thing found".
  hdr="$(readelf -hW "$f")"   || { echo "FAIL[$LABEL]: readelf could not read the ELF header of $name"; exit 1; }
  phdr="$(readelf -lW "$f")"  || { echo "FAIL[$LABEL]: readelf could not read the program headers of $name"; exit 1; }
  dyn="$(readelf -dW "$f")"   || { echo "FAIL[$LABEL]: readelf could not read the dynamic section of $name"; exit 1; }
  grep -q 'Program Headers:' <<<"$phdr" || { echo "FAIL[$LABEL]: $name has no program headers -- not a linked ELF, nothing was measured"; exit 1; }

  # PIE / position independent. -pie for the executable (EXTRA_LDFLAGS_PROGRAM),
  # -fPIC for everything else; either way the result is ET_DYN. An ET_EXEC here
  # means the binary is loaded at a fixed address and ASLR does not apply to it.
  grep -qE '^[[:space:]]*Type:[[:space:]]+DYN' <<<"$hdr" \
    || { echo "FAIL[$LABEL]: $name is not ET_DYN (no PIE/ASLR): $(grep -E '^[[:space:]]*Type:' <<<"$hdr" | tr -s ' ')"; exit 1; }

  # Full RELRO is two properties and needs both: the GNU_RELRO segment that
  # marks the region, and BIND_NOW so the GOT is resolved and mapped read-only
  # before main() runs. RELRO without BIND_NOW ("partial RELRO") leaves the GOT
  # writable, which is the thing worth preventing.
  grep -q 'GNU_RELRO' <<<"$phdr" \
    || { echo "FAIL[$LABEL]: $name has no GNU_RELRO segment (-z relro did not take)"; exit 1; }
  grep -qE 'BIND_NOW|FLAGS_1.*\bNOW\b' <<<"$dyn" \
    || { echo "FAIL[$LABEL]: $name has RELRO but not BIND_NOW (-z now did not take; partial RELRO leaves the GOT writable)"; exit 1; }

  # Non-executable stack. The segment must exist -- its *absence* means the
  # kernel falls back to an executable stack, so "no GNU_STACK line" is the
  # dangerous case, not a passing one.
  stack="$(grep -E 'GNU_STACK' <<<"$phdr" || true)"
  [ -n "$stack" ] \
    || { echo "FAIL[$LABEL]: $name has no GNU_STACK segment -- the kernel will map the stack executable"; exit 1; }
  # Flags are the RWE field at the end of the line.
  grep -qE 'GNU_STACK.*[[:space:]]RW[[:space:]]' <<<"$stack" \
    || { echo "FAIL[$LABEL]: $name has an executable stack: $(tr -s ' ' <<<"$stack")"; exit 1; }

  checked=$((checked + 1))
done

echo "ok[$LABEL]: $checked file(s) are PIE, full-RELRO (BIND_NOW) and non-exec-stack"

if [ "$MAIN" -eq 1 ]; then
  f="$1"; name="$(basename "$f")"
  syms="$(readelf -sW --dyn-syms "$f")" \
    || { echo "FAIL[$LABEL]: could not read the dynamic symbols of $name"; exit 1; }
  grep -q 'Symbol table' <<<"$syms" \
    || { echo "FAIL[$LABEL]: $name has no dynamic symbol table -- nothing was measured"; exit 1; }

  # -fstack-protector-strong: a binary this size with the canary on always
  # references the failure handler.
  grep -q '__stack_chk_fail' <<<"$syms" \
    || { echo "FAIL[$LABEL]: $name has no __stack_chk_fail (-fstack-protector-strong did not take)"; exit 1; }

  # -D_FORTIFY_SOURCE=3: glibc redirects the fortifiable calls to __*_chk.
  #
  # What this can and cannot prove: these are *undefined* references resolved
  # from glibc, so any code in the binary that calls a fortifiable function
  # contributes them -- including, on the legacy era, the statically linked
  # OpenSSL/ICU/curl. It is a whole-binary fact, not a php-src one. The
  # attributed version, which reads php-src's own call sites by symbol before
  # the binary is stripped, is assert_php_src_hardening in php/build.sh and it
  # fails the build; this stays as the cheap end-to-end smoke check.
  n_chk="$(grep -cE '__[a-z_]+_chk' <<<"$syms" || true)"
  [ "${n_chk:-0}" -gt 0 ] \
    || { echo "FAIL[$LABEL]: $name references no __*_chk symbols (_FORTIFY_SOURCE did not take)"; exit 1; }

  # -fcf-protection=full: assert the half that is actually observable here --
  # the codegen. Every function entry gets an endbr64 landing pad.
  #
  # Same caveat as the __*_chk count above: on 7.4 the vendored static archives
  # carry 6,881 endbr64 of the shipped binary's 17,654, so php-src could lose
  # the flag entirely and this would still be far above zero.
  # php/build.sh's assert_php_src_hardening is the attributed one.
  #
  # Deliberately NOT asserted: the .note.gnu.property IBT/SHSTK marking that
  # makes the loader *enforce* CET. It is absent from these binaries -- and from
  # Debian trixie's own /bin/ls -- so it is a property of the base
  # distribution's toolchain defaults, not of this build. Asserting it would
  # fail on a correctly built image.
  #
  # The arch is the binary's own (ELF Machine), not the host's: an arm64 image
  # smoke-tested under emulation on an amd64 host carries aarch64 code, and
  # asking it for endbr64 would fail a correct build.
  machine="$(sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' <<<"$(readelf -hW "$f")")"
  case "$machine" in
    *X86-64*)
      n_endbr="$(objdump -d "$f" 2>/dev/null | grep -c 'endbr64' || true)"
      [ "${n_endbr:-0}" -gt 0 ] \
        || { echo "FAIL[$LABEL]: $name contains no endbr64 landing pads (-fcf-protection=full did not take)"; exit 1; }
      echo "ok[$LABEL]: $name has __stack_chk_fail, $n_chk __*_chk symbols and $n_endbr endbr64 landing pads (whole-binary; php-src's own share is attributed at build time)"
      ;;
    AArch64)
      # -mbranch-protection=standard: BTI landing pads ("bti c"/"bti jc") and
      # PAC (paciasp, which also serves as a landing pad on functions that save
      # LR). Same whole-binary caveat as endbr64; php/build.sh attributes it.
      # GNU objdump on an amd64 host is usually built for x86 alone and prints
      # no instructions for an aarch64 file, so fall back to llvm-objdump, and
      # require that the disassembly produced *some* instructions -- an empty
      # one is a broken measurement, not a missing feature.
      dis=""
      for od in objdump llvm-objdump; do
        command -v "$od" >/dev/null || continue
        dis="$("$od" -d "$f" 2>/dev/null || true)"
        grep -qE '[[:space:]](ret|bl|ldr)[[:space:]]' <<<"$dis" && break
        dis=""
      done
      [ -n "$dis" ] \
        || { echo "FAIL[$LABEL]: neither objdump nor llvm-objdump could disassemble aarch64 $name -- the BTI/PAC check measures nothing"; exit 1; }
      n_bti="$(grep -cE '[[:space:]]bti([[:space:]]|$)' <<<"$dis" || true)"
      n_pac="$(grep -cE '[[:space:]]paci[ab]sp([[:space:]]|$)' <<<"$dis" || true)"
      [ "${n_bti:-0}" -gt 0 ] \
        || { echo "FAIL[$LABEL]: $name contains no bti landing pads (-mbranch-protection=standard did not take)"; exit 1; }
      [ "${n_pac:-0}" -gt 0 ] \
        || { echo "FAIL[$LABEL]: $name contains no paciasp/pacibsp (-mbranch-protection=standard's pac-ret did not take)"; exit 1; }
      echo "ok[$LABEL]: $name has __stack_chk_fail, $n_chk __*_chk symbols, $n_bti bti landing pads and $n_pac paciasp (whole-binary; php-src's own share is attributed at build time)"
      ;;
    *)
      echo "FAIL[$LABEL]: $name is a '$machine' ELF -- no landing-pad check is defined for it"; exit 1
      ;;
  esac
fi
