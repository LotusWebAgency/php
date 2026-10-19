#!/usr/bin/env bash
# Assert the hardening flags actually landed in a produced binary.
#
#   assert-elf-hardening.sh [--main] [--code] <label> <file> [<file>...]
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
#
# --main  also holds the FIRST file (the php binary) to the whole-binary
#         code-level checks: canary, _chk imports, landing pads, stack probes.
# --code  holds EVERY file to the per-file code-level checks, in the form that
#         cannot false-fail a correctly built small module; the rule and its
#         thresholds are documented at check_code below.
set -euo pipefail

MAIN=0
CODE=0
while [ "${1:-}" = "--main" ] || [ "${1:-}" = "--code" ]; do
  case "$1" in --main) MAIN=1 ;; --code) CODE=1 ;; esac
  shift
done
LABEL="${1:?usage: assert-elf-hardening.sh [--main] <label> <file>...}"
shift
[ "$#" -gt 0 ] || { echo "FAIL[$LABEL]: no files given -- nothing was measured"; exit 1; }

for tool in readelf objdump; do
  command -v "$tool" >/dev/null || { echo "FAIL[$LABEL]: $tool not found; cannot verify hardening"; exit 1; }
done

# ---------------------------------------------------------------- code level
# Per-file code-level checks (--code). The link checks above are properties of
# the linker line; these are properties of the code the compiler produced, so
# they catch a flag that never reached a file's compile (a Makefile that ignores
# CFLAGS, a configure that resets them). A tiny module has legitimately little
# to show -- a chmod shim has no stack buffer and no fortifiable call -- so each
# property is demanded only of a file that must show it, never as "this file
# has some":
#
#   landing pads  Every FUNCTION THE FILE EXPORTS must start with one (endbr64
#                 on x86-64; bti c/j/jc or paciasp/pacibsp on aarch64): -fcf-
#                 protection / -mbranch-protection put one on every function
#                 whose address can be taken, and an exported symbol can. This
#                 is a ratio over the file's own exports, so the distro's crt
#                 objects (_init/_fini, always CET) cannot mask a dropped flag
#                 the way a whole-file count does, and hand-written assembly
#                 (dav1d's) cannot fail a file whose C is covered: more than
#                 half of the exports must carry one. A file with no exports
#                 has nothing attributable and is not asked.
#   stack canary  __stack_chk_fail must be imported by any file whose .text is
#                 at least STACK_PROT_MIN_TEXT bytes. -fstack-protector-strong
#                 instruments every function with a local array or an address-
#                 taken local, which C code of that size is not free of; below
#                 it a module may simply have none (PHP's own calendar.so and
#                 bz2.so carry no canary, correctly built).
#   _FORTIFY      Size cannot demand a __*_chk import: fortify leaves a call
#                 plain when the destination size is unknown or provably fine,
#                 so a 66 KB module (memcached.so) or a 7 MB codec (libaom) can
#                 be correctly built and import only plain memcpy. What fortify
#                 never leaves plain is the printf family -- its _chk variant
#                 carries a flag, not just a size, and is called even for an
#                 unknown buffer (verified with gcc and clang at level 3). So a
#                 file that imports a plain printf-family function and not one
#                 __*_chk symbol was certainly compiled without fortify. A file
#                 that shows no such import is not asked; php itself is held to
#                 a whole-binary _chk count by --main.
#
# Not asserted per file, for want of a reliable signature: -fstack-clash-
# protection. Its probes appear only in a function whose frame exceeds a page,
# which a small module need not contain, so it is asserted on the php binary
# alone (--main) and otherwise left to scripts/test_flags.py.
STACK_PROT_MIN_TEXT="${STACK_PROT_MIN_TEXT:-32768}"
FORTIFY_PLAIN='printf|fprintf|vprintf|vfprintf|dprintf|vdprintf|sprintf|snprintf|vsprintf|vsnprintf|asprintf|vasprintf|syslog|vsyslog'

# disassemble <file> <machine>: instructions on stdout; non-zero when the
# disassembler produced none (a broken measurement, not a missing feature).
# GNU objdump on an amd64 host is usually built for x86 alone and prints nothing
# for an aarch64 file, so llvm-objdump is the fallback.
disassemble() {
  local f="$1" od out
  for od in objdump llvm-objdump; do
    command -v "$od" >/dev/null || continue
    out="$("$od" -d "$f" 2>/dev/null || true)"
    if grep -qE '^[[:space:]]*[0-9a-f]+:[[:space:]]' <<<"$out"; then printf '%s\n' "$out"; return 0; fi
  done
  return 1
}

# text_size <file>: size in bytes of .text, from the section headers.
text_size() {
  local hex
  hex="$(readelf -SW "$1" | sed -E 's/\[ *[0-9]+\]//' | awk '$1 == ".text" { print $2 == "PROGBITS" ? $5 : ""; exit }')"
  [ -n "$hex" ] || return 1
  echo $((16#$hex))
}

# export_pads <file> <syms> <dis>: sets n_exp (exported functions) and n_pad (how
# many of them start with a landing pad). Exported means defined, global or
# weak, FUNC or IFUNC, minus the crt's _init/_fini. Matching is by address, not
# name: objdump labels an address with one of its aliases only.
export_pads() {
  local exports pads
  exports="$(awk '$4 ~ /^(FUNC|IFUNC)$/ && $5 ~ /^(GLOBAL|WEAK)$/ && $7 != "UND" && $8 !~ /^_(init|fini)(@|$)/ { a = tolower($2); sub(/^0+/, "", a); print a }' <<<"$2" | sort -u)"
  pads="$(awk '
    /^[0-9a-f]+ <[^>]+>:$/ { addr = tolower($1); sub(/^0+/, "", addr); want = 1; next }
    want && /^[[:space:]]*[0-9a-f]+:/ {
      want = 0
      if ($0 ~ /[[:space:]](endbr64|bti|paciasp|pacibsp)([[:space:]]|$)/) print addr
    }' <<<"$3" | sort -u)"
  n_exp="$(grep -c . <<<"$exports" || true)"
  n_pad=0
  if [ "$n_exp" -gt 0 ]; then
    n_pad="$(comm -12 <(printf '%s\n' "$exports") <(printf '%s\n' "$pads") | grep -c . || true)"
  fi
}

check_code() {  # check_code <label> <file>
  local label="$1" f="$2" name machine tsize dis syms
  name="$(basename "$f")"
  machine="$(readelf -hW "$f" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
  case "$machine" in *X86-64*|AArch64) ;; *) echo "FAIL[$label]: $name is a '$machine' ELF -- no code-level check is defined for it"; return 1 ;; esac

  tsize="$(text_size "$f")" \
    || { echo "FAIL[$label]: $name has no .text section header -- the code-level checks measure nothing"; return 1; }
  # A file with no code (a data-only object) has nothing to harden.
  if [ "$tsize" -eq 0 ]; then echo "ok[$label]: $name has an empty .text; no code to check"; return 0; fi

  syms="$(readelf -sW --dyn-syms "$f")" || { echo "FAIL[$label]: could not read the dynamic symbols of $name"; return 1; }
  dis="$(disassemble "$f")" \
    || { echo "FAIL[$label]: neither objdump nor llvm-objdump could disassemble $machine $name -- the landing-pad check measures nothing"; return 1; }

  export_pads "$f" "$syms" "$dis"
  if [ "$n_exp" -gt 0 ] && [ $((n_pad * 2)) -le "$n_exp" ]; then
    echo "FAIL[$label]: only $n_pad of $name's $n_exp exported functions start with a landing pad ($machine -fcf-protection/-mbranch-protection did not take for this file)"; return 1
  fi

  local canary="n/a" fort n_chk plain
  if [ "$tsize" -ge "$STACK_PROT_MIN_TEXT" ]; then
    grep -qE '[[:space:]]__stack_chk_fail(@|[[:space:]]|$)' <<<"$syms" \
      || { echo "FAIL[$label]: $name has $tsize bytes of code and no __stack_chk_fail (-fstack-protector-strong did not take for this file)"; return 1; }
    canary="yes"
  fi
  n_chk="$(grep -cE '[[:space:]]__[a-z_0-9]+_chk(@|[[:space:]]|$)' <<<"$syms" || true)"
  plain="$(awk -v re="^($FORTIFY_PLAIN)(@|\$)" '$7 == "UND" && $8 ~ re { n = $8; sub(/@.*/, "", n); print n }' <<<"$syms" | sort -u | paste -sd, -)"
  if [ -n "$plain" ] && [ "${n_chk:-0}" -eq 0 ]; then
    echo "FAIL[$label]: $name imports plain $plain and no __*_chk symbol at all (-D_FORTIFY_SOURCE did not take for this file; fortify always redirects the printf family)"; return 1
  fi
  fort="$n_chk"
  [ -z "${ELF_HARDENING_VERBOSE:-}" ] || echo "  $name: text=$tsize exports=$n_exp pads=$n_pad canary=$canary chk=$fort plain=${plain:-none}"
}

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

  [ "$CODE" -eq 0 ] || check_code "$LABEL" "$f" || exit 1

  checked=$((checked + 1))
done

echo "ok[$LABEL]: $checked file(s) are PIE, full-RELRO (BIND_NOW) and non-exec-stack"
[ "$CODE" -eq 0 ] || echo "ok[$LABEL]: $checked file(s) pass the per-file code checks (landing pads on exports; canary from ${STACK_PROT_MIN_TEXT} B of code, no plain printf-family import without _chk)"

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
  # Anchored at the end of the name: unanchored, `__stack_chk_fail` matches too,
  # which made this count non-zero on any binary with the canary and the check
  # vacuous.
  n_chk="$(grep -cE '__[a-z_0-9]+_chk(@|[[:space:]]|$)' <<<"$syms" || true)"
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
  # makes the loader *enforce* CET. It is absent from these binaries, so it is
  # a property of the toolchain defaults, not of this build's flags. Asserting
  # it would fail on a correctly built image.
  #
  # The arch is the binary's own (ELF Machine), not the host's: an arm64 image
  # smoke-tested under emulation on an amd64 host carries aarch64 code, and
  # asking it for endbr64 would fail a correct build.
  machine="$(sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' <<<"$(readelf -hW "$f")")"
  case "$machine" in
    *X86-64*)
      dis="$(objdump -d "$f" 2>/dev/null || true)"
      n_endbr="$(grep -c 'endbr64' <<<"$dis" || true)"
      [ "${n_endbr:-0}" -gt 0 ] \
        || { echo "FAIL[$LABEL]: $name contains no endbr64 landing pads (-fcf-protection=full did not take)"; exit 1; }
      # The count above is satisfied by the distro's own crt objects (_start and
      # friends are CET-marked whatever our flags said), so a build that lost
      # the flag could still pass it. The exports are ours: php exports the Zend
      # API to its extensions, and every one of those functions must begin with
      # a landing pad.
      export_pads "$f" "$syms" "$dis"
      if [ "$n_exp" -gt 0 ] && [ $((n_pad * 2)) -le "$n_exp" ]; then
        echo "FAIL[$LABEL]: only $n_pad of $name's $n_exp exported functions start with endbr64 (-fcf-protection=full did not take for php's own code)"; exit 1
      fi
      # -fstack-clash-protection: a function whose frame exceeds a page touches
      # each page as it grows the stack. gcc probes with `or $0x0,(%rsp)` (orb,
      # orq...), clang with `movq $0x0,(%rsp)` right after `sub $0x1000,%rsp`.
      # Only a function with a big frame shows either, which a small module need
      # not contain -- so this is asked of the php binary alone, where php-src's
      # frames (path buffers, the VM) make a build without the flag show none.
      # aarch64 has no signature checked against real images (the probe sits
      # behind a 64 KiB guard and a `str xzr`), so there it stays with
      # scripts/test_flags.py's check of what cflags.sh emits.
      n_probe="$(awk '
        /[[:space:]]or[bwlq]?[[:space:]]+\$0x0,(0x[0-9a-f]+)?\(%rsp\)/ { n++ }
        /[[:space:]]mov[bwlq]?[[:space:]]+\$0x0,\(%rsp\)/ && prev ~ /[[:space:]]sub[[:space:]]+\$0x1000,%rsp/ { n++ }
        { prev = $0 }
        END { print n + 0 }' <<<"$dis")"
      [ "${n_probe:-0}" -gt 0 ] \
        || { echo "FAIL[$LABEL]: $name contains no stack probes (-fstack-clash-protection did not take)"; exit 1; }
      echo "ok[$LABEL]: $name has __stack_chk_fail, $n_chk __*_chk symbols, $n_endbr endbr64 landing pads and $n_probe stack probes (whole-binary; php-src's own share is attributed at build time)"
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
      export_pads "$f" "$syms" "$dis"
      if [ "$n_exp" -gt 0 ] && [ $((n_pad * 2)) -le "$n_exp" ]; then
        echo "FAIL[$LABEL]: only $n_pad of $name's $n_exp exported functions start with bti/paciasp (-mbranch-protection=standard did not take for php's own code)"; exit 1
      fi
      echo "ok[$LABEL]: $name has __stack_chk_fail, $n_chk __*_chk symbols, $n_bti bti landing pads and $n_pac paciasp (whole-binary; php-src's own share is attributed at build time)"
      ;;
    *)
      echo "FAIL[$LABEL]: $name is a '$machine' ELF -- no landing-pad check is defined for it"; exit 1
      ;;
  esac
fi
