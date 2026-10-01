#!/usr/bin/env bash
# Probe-answer canaries: assert what ./configure *decided*, not that it ran.
#
# Sourced by php/build.sh and called from the configured source tree, so every
# function here expects config.log, main/php_config.h and the generated
# Makefile to be present in $PWD.
#
# These are separate from build.sh for the same reason php/flag-split.sh is:
# driving configure/make/install and interrogating the build environment are
# two different jobs, and the second one is the part a reviewer needs to read
# closely. Nothing here changes what is built -- every function either passes
# or aborts the build.
#
# The general principle they all follow: autoconf reads a *compile failure* as
# a feature answer, so on the legacy branches a probe the compiler rejects
# produces a wrong answer rather than an error. Two of those are known by name
# and get a canary each below; php/flag-split.sh carries the general two-sided
# control over the flags that keep the probes compilable in the first place.

# autoconf's answer to "is sprintf broken" is only as good as its ability to
# compile the probe. PHP 7.x asks with a pre-C99 program that a modern compiler
# rejects outright; autoconf reads that compile failure as "yes, broken", and
# ZEND_BROKEN_SPRINTF=1 then makes Zend/zend.h declare zend_sprintf, which
# ext/intl pulls in under two linkages and the build dies.
# docs/legacy-era-rationale.md has the whole chain.
#
# The assertion is on the generated header, not on config.log, and it is
# value-sensitive:
#   - config.log records the question and the answer on separate lines
#     ("configure:NNN: checking whether sprintf is broken" then
#     "configure:NNN: result: no"), so no grep for "...broken... no" can match.
#   - 7.x emits `#define ZEND_BROKEN_SPRINTF 0` on a *healthy* build --
#     AC_DEFINE_UNQUOTED with the computed value, Zend/acinclude.m4:68-84 -- so
#     the healthy value is 0, not "absent".
#
# Whether a branch asks the question at all is read out of the source tree
# rather than assumed: 7.0-7.3 carry AC_ZEND_BROKEN_SPRINTF in
# Zend/acinclude.m4, 7.4 dropped it and nothing since has it. Without that
# derivation this check answers "note: no probe on this branch" for a branch
# that does have one and never ran it -- a canary that reports ok on a build
# where the measurement never happened. Both directions are asserted: a branch
# with the macro must have run the probe and recorded 0, and a branch without
# it must not have a probe result in config.log at all (so a future branch that
# reintroduces the probe is not silently skipped).
assert_sprintf_canary() {
  local has_probe=0
  if grep -q 'ZEND_BROKEN_SPRINTF' Zend/acinclude.m4 2>/dev/null; then has_probe=1; fi

  if [ "$has_probe" -eq 1 ]; then
    if ! grep -q 'checking whether sprintf is broken' config.log; then
      echo "FATAL: Zend/acinclude.m4 defines the ZEND_BROKEN_SPRINTF probe but" \
           "config.log has no record of configure ever running it -- the canary" \
           "measured nothing" >&2
      exit 1
    fi
    grep -m1 -A2 'checking whether sprintf is broken' config.log || true
    if ! grep -Eq '^[[:space:]]*#[[:space:]]*define[[:space:]]+ZEND_BROKEN_SPRINTF[[:space:]]+0([[:space:]]|$)' \
        main/php_config.h; then
      echo "FATAL: configure did not decide sprintf is healthy" \
           "(expected '#define ZEND_BROKEN_SPRINTF 0' in main/php_config.h);" \
           "the probe did not compile, it did not fail at runtime" >&2
      grep -n 'ZEND_BROKEN_SPRINTF' main/php_config.h >&2 || true
      exit 1
    fi
    echo "ok: ZEND_BROKEN_SPRINTF probe ran and answered 'not broken'"
  else
    if grep -q 'checking whether sprintf is broken' config.log; then
      echo "FATAL: config.log shows a sprintf probe this branch's" \
           "Zend/acinclude.m4 does not define -- the derivation above is stale" >&2
      exit 1
    fi
    echo "note: no ZEND_BROKEN_SPRINTF probe in this branch (7.4 dropped it)"
  fi
}

# The second known false-negative probe on these branches, and the one that
# actually fired during task 15. PHP_READDIR_R_TYPE (acinclude.m4, 7.0-7.3;
# 7.4 dropped it, same boundary as the sprintf probe) decides between POSIX
# 3-argument readdir_r and the "old-style" 2-argument form by *running* a
# program -- one that calls close(dir) on a DIR*, which clang rejects outright
# as -Wint-conversion. When it fails to compile, autoconf falls through to a
# preprocess-only fallback that succeeds on any platform, and the answer comes
# out "old-style" on glibc, where readdir_r has never been anything but POSIX.
#
# On Linux/glibc -- the only platform this image targets -- POSIX is the only
# correct answer, so this asserts it rather than merely reporting it. Both
# directions again: a branch that has the probe must have answered POSIX, and
# a branch that does not have it must not have HAVE_OLD_READDIR_R defined by
# some other route.
assert_readdir_r_canary() {
  local has_probe=0 m4
  for m4 in acinclude.m4 build/php.m4; do
    if [ -f "$m4" ] && grep -q 'PHP_READDIR_R_TYPE' "$m4"; then has_probe=1; fi
  done

  if grep -Eq '^[[:space:]]*#[[:space:]]*define[[:space:]]+HAVE_OLD_READDIR_R[[:space:]]+1([[:space:]]|$)' \
      main/php_config.h; then
    echo "FATAL: configure decided readdir_r is the old 2-argument form" \
         "(HAVE_OLD_READDIR_R=1). On glibc it is POSIX 3-argument; the probe" \
         "did not compile, it did not fail at runtime -- see CONFIGURE_ONLY_CFLAGS" >&2
    grep -n 'READDIR_R' config.log | tail -5 >&2 || true
    exit 1
  fi

  if [ "$has_probe" -eq 1 ]; then
    if ! grep -q 'checking for type of readdir_r' config.log; then
      echo "FATAL: this branch defines PHP_READDIR_R_TYPE but config.log has no" \
           "record of the probe running -- the canary measured nothing" >&2
      exit 1
    fi
    if ! grep -Eq '^[[:space:]]*#[[:space:]]*define[[:space:]]+HAVE_POSIX_READDIR_R[[:space:]]+1([[:space:]]|$)' \
        main/php_config.h; then
      echo "FATAL: the readdir_r probe ran but did not define HAVE_POSIX_READDIR_R;" \
           "main/reentrancy.c will compile the wrong arity" >&2
      grep -m1 -A2 'checking for type of readdir_r' config.log >&2 || true
      exit 1
    fi
    echo "ok: readdir_r probe ran and answered POSIX"
  else
    echo "note: no PHP_READDIR_R_TYPE probe in this branch (7.4 dropped it)"
  fi
}

# The general control for the same concern, and the one that makes the
# configure/make split verifiable instead of merely intended.
#
# CONFIGURE_ONLY_CFLAGS demotes a diagnostic so autoconf's pre-C99 probes
# compile; MAKE_ONLY_CFLAGS re-promotes it so the real compile stays strict. A
# green build cannot tell a correctly-scoped demotion from one that leaked into
# `make` and is now hiding real bugs, so assert both halves directly, with
# probe programs whose acceptance *is* the property in question:
#
#   arm B (always, both eras): the flag set `make` will really use --
#     CFLAGS_CLEAN exactly as configure baked it, followed by EXTRA_CFLAGS,
#     which every compile rule places after it (acinclude.m4's php_c_meta on
#     7.0-7.3, build/php.m4's on 7.4+) -- must REJECT both probes.
#   arm A (only for diagnostics this build asked configure to demote): the
#     configure-time flag set must ACCEPT the matching probe. Without this,
#     arm B passes vacuously on a build where the demotion never reached
#     ./configure at all, which is the same false green the canary above
#     exists to prevent.
#
# A demotion with no probe to exercise it is a hard error rather than a
# silently unverified flag: adding one to CONFIGURE_ONLY_CFLAGS means adding
# its probe here too.
assert_configure_make_split() {
  local cflags_clean mk

  # CFLAGS_CLEAN is what configure baked our CFLAGS into and what every compile
  # rule expands; reading it back is the only way to test the real make-time
  # flag set rather than a reconstruction of it.
  #
  # It has to be expanded *by make*, not read out of the file: the value
  # legitimately ends in $(PROF_FLAGS), which is empty in a normal build and is
  # what task 17's `make prof-gen`/`prof-use` passes set. A literal
  # "$(PROF_FLAGS)" handed to the compiler is an unknown argument, and the
  # probes would then fail for a reason that has nothing to do with the property
  # being measured. php-src's generated Makefile has no rule that regenerates
  # itself, so `include`ing it from a scratch makefile is side-effect free.
  mk="$(mktemp)"
  printf 'include Makefile\n_php_docker_print_cflags_clean:\n\t@echo $(CFLAGS_CLEAN)\n' > "$mk"
  cflags_clean="$(make -s -f "$mk" _php_docker_print_cflags_clean)" || cflags_clean=""
  rm -f "$mk"
  if [ -z "$cflags_clean" ]; then
    echo "FATAL: could not get the expanded CFLAGS_CLEAN out of the generated" \
         "Makefile -- the configure/make split is unverified" >&2
    exit 1
  fi

  # The make-time set is CFLAGS_CLEAN followed by EXTRA_CFLAGS, in that order,
  # because that is the order every compile rule expands them in.
  php_docker_assert_flag_split "core" "$CFLAGS" "$cflags_clean $MAKE_ONLY_CFLAGS" || exit 1
}


# The third probe answer this build depends on, and the only one it *forces*.
# php/build.sh passes ax_cv_have_func_attribute_ifunc=no on the ./configure
# line so php-src takes its function-pointer dispatch path instead of emitting
# __attribute__((ifunc)) symbols -- ld.lld 19.1.7 segfaults on the ThinLTO
# summary index when those are present (the whole chain is in build.sh, next to
# CONFIGURE_CACHE_OVERRIDES).
#
# A forced cache value fails quietly in exactly one way: the variable name
# changes upstream, autoconf ignores the assignment, the probe runs, the answer
# comes back "yes", and the next build segfaults in the linker with no hint
# that a deliberate override stopped working. So both directions are asserted:
# a branch whose configure has the probe must show the forced value in
# config.log's cache dump AND must not have defined the macro, and a branch
# with no probe must not have the macro either (7.0 has no ifunc resolvers at
# all -- grepped across the release, zero occurrences).
assert_ifunc_canary() {
  local has_probe=0
  if grep -q 'ax_cv_have_func_attribute_ifunc' configure 2>/dev/null; then has_probe=1; fi

  if grep -Eq '^[[:space:]]*#[[:space:]]*define[[:space:]]+HAVE_FUNC_ATTRIBUTE_IFUNC' main/php_config.h; then
    echo "FATAL: configure defined HAVE_FUNC_ATTRIBUTE_IFUNC despite" \
         "ax_cv_have_func_attribute_ifunc=no on its command line. The cache" \
         "override did not take -- check whether php-src renamed the variable." >&2
    grep -n 'HAVE_FUNC_ATTRIBUTE_IFUNC' main/php_config.h >&2 || true
    exit 1
  fi

  if [ "$has_probe" -eq 1 ]; then
    # autoconf dumps its cache into config.log; the forced value has to be
    # visible there, or the assignment never reached configure at all and the
    # macro is absent for some other reason entirely.
    if ! grep -q 'ax_cv_have_func_attribute_ifunc=no' config.log; then
      echo "FATAL: this branch's configure has the ifunc probe, but config.log" \
           "has no record of ax_cv_have_func_attribute_ifunc=no -- the override" \
           "was not applied and the macro's absence means something else" >&2
      grep -n 'ax_cv_have_func_attribute_ifunc' config.log >&2 || true
      exit 1
    fi
    echo "ok: ifunc resolvers disabled by cache override (ThinLTO cannot link php-src with them)"
  else
    echo "note: this branch's configure has no ifunc probe; nothing to disable"
  fi
}

# The general form of the bug the ifunc canary above only covers one case of,
# and the one that shipped: an autoconf probe that reads a compiler *warning*
# as a feature answer.
#
# AX_GCC_FUNC_ATTRIBUTE compiles and links a probe and then accepts the
# attribute only if stderr came back empty:
#
#     if ac_fn_c_try_link ...; then
#       if test -s conftest.err; then ax_cv_have_func_attribute_$1=no
#       else                          ax_cv_have_func_attribute_$1=yes
#
# So *any* warning on *any* flag ./configure is given turns every probed
# attribute off at once. Passing -fprofile-use to ./configure did exactly that
# (clang emits -Wbackend-plugin on the probe's own main), which turned off
# __attribute__((target)) and preprocessed every SIMD implementation out of
# php-src -- shipped on all eleven versions, measured at pshufb 0 vs 48 and
# base64_decode ~134x slower, with every other check in this repo still green.
#
# This asserts the whole class rather than that one flag: every attribute this
# branch probes must have come back yes, except the ones this build
# deliberately forces off. A new attribute answering no fails the build with
# its name, which is a one-line decision (real limitation -> allowlist it, or
# a flag is leaking diagnostics into ./configure -> take the flag out).
#
#   assert_attribute_canary <space-separated attributes allowed to be "no">
assert_attribute_canary() {
  local allowed=" ${1:-} " probed answers name value bad=""

  probed="$(grep -oE 'ax_cv_have_func_attribute_[a-z0-9_]+' configure 2>/dev/null | sort -u || true)"
  if [ -z "$probed" ]; then
    echo "note: this branch's configure probes no function attributes (7.0-7.2 predate AX_GCC_FUNC_ATTRIBUTE)"
    return 0
  fi

  # autoconf dumps its cache into config.log; that dump is the record of what
  # each probe decided.
  answers="$(grep -oE 'ax_cv_have_func_attribute_[a-z0-9_]+=(yes|no)' config.log 2>/dev/null | sort -u || true)"
  if [ -z "$answers" ]; then
    echo "FATAL: configure probes $(wc -w <<<"$probed") function attribute(s) but config.log's" \
         "cache dump records no answer for any of them -- this canary measured nothing" >&2
    exit 1
  fi
  # php-src's target probe is x86-only: AX_GCC_FUNC_ATTRIBUTE([target]) compiles
  # __attribute__((target("sse2"))), which aarch64 gcc and clang reject, so "no"
  # is the correct answer there -- and nothing it guards exists on that arch
  # anyway (the ZEND_INTRIN_* SSE/AVX paths; php-src's NEON code is plain
  # #ifdef __aarch64__, see assert_simd_dispatch_present). The allowance is
  # derived from the probe body in this configure, not from the arch alone: a
  # future generic target probe that aarch64 could pass is not excused.
  local arch target_x86_only=0 excused=""
  arch="$(uname -m)"
  if grep -q '__attribute__((target("sse2")))' configure 2>/dev/null; then target_x86_only=1; fi
  case "$arch" in
    x86_64|i?86) ;;
    *)
      if grep -qx 'ax_cv_have_func_attribute_target' <<<"$probed" && [ "$target_x86_only" -eq 1 ]; then
        allowed="${allowed}target "
        excused="target"
        echo "note: __attribute__((target)) is probed with target(\"sse2\") -- an x86-only body, so 'no' is the correct answer on $arch"
      fi
      ;;
  esac

  # Positive control: at least one attribute has to have come back yes. If they
  # were all no -- which is what the shipped bug looked like -- the loop below
  # would be reporting a real failure, but a matcher that silently matched
  # nothing would look identical, and "no bad answers" would be vacuous.
  #
  # On aarch64, 7.3-8.3 probe only ifunc (forced off) and target (x86-only
  # body), so no probed attribute can legitimately say yes and the control has
  # nothing in the answers to stand on. It is then run directly instead, on the
  # property the answers would have been evidence of: the probe harness under
  # configure's real flags. assert_attribute_probe_harness reproduces
  # AX_GCC_FUNC_ATTRIBUTE's link-and-empty-stderr rule with an attribute every
  # target supports (visibility, the body 8.4+'s own probe uses), and proves the
  # same harness can still answer no.
  local can_be_yes=""
  for name in $probed; do
    name="${name#ax_cv_have_func_attribute_}"
    case " $allowed " in *" $name "*) ;; *) can_be_yes="${can_be_yes:+${can_be_yes} }${name}" ;; esac
  done
  if [ -n "$can_be_yes" ]; then
    grep -q '=yes$' <<<"$answers" \
      || { echo "FATAL: not one probed function attribute came back yes. ./configure is being given a flag whose diagnostics it reads as feature answers." >&2
           printf '  %s\n' $answers >&2; exit 1; }
  else
    echo "note: on $arch every attribute this configure probes is allowed to be 'no' ($(tr -s ' ' <<<"$allowed")) --" \
         "no answer can serve as the positive control, so the probe harness is checked directly"
    assert_attribute_probe_harness
  fi

  # Every attribute configure probes has to appear in the answers. Without this
  # the loop below only ever inspects what the cache dump happened to contain:
  # a probe that ran but whose answer never reached config.log would be
  # inspected by nobody and reported as fine -- an absence passing for a pass,
  # which is the shape of defect this file exists to stop.
  local missing=""
  for name in $probed; do
    grep -q "^${name}=" <<<"$answers" || missing="${missing:+${missing} }${name}"
  done
  [ -z "$missing" ] || {
    echo "FATAL: ./configure probes $missing but config.log's cache dump has no answer for" \
         "$(wc -w <<<"$missing") of them -- those probes were never checked by anything." >&2
    exit 1; }

  for line in $answers; do
    name="${line%%=*}"; name="${name#ax_cv_have_func_attribute_}"
    value="${line##*=}"
    case " $allowed " in *" $name "*) continue ;; esac
    [ "$value" = yes ] || bad="${bad:+${bad} }${name}"
  done
  if [ -n "$bad" ]; then
    echo "FATAL: ./configure decided php-src cannot use __attribute__(($bad)). Either clang really" \
         "cannot, or a flag on configure's command line emitted a diagnostic and" \
         "AX_GCC_FUNC_ATTRIBUTE read the non-empty stderr as 'no' -- which silently removes every" \
         "feature guarded by that attribute (SIMD, for target)." >&2
    printf '  %s\n' $answers >&2
    exit 1
  fi
  if [ -n "$excused" ]; then
    echo "ok: every probed function attribute answered yes except the forced ones (${1:-}) and the x86-only ones on $arch ($excused)"
  else
    echo "ok: every probed function attribute answered yes except the forced ones ($(tr -s " " <<<"$allowed"))"
  fi
}

# The positive control assert_attribute_canary falls back to when no probed
# attribute can say yes on this arch. Same compile-and-link, same exported
# $CC/$CFLAGS/$CPPFLAGS/$LDFLAGS configure ran with, same verdict rule
# (AX_GCC_FUNC_ATTRIBUTE: link succeeded AND stderr empty -> yes):
#   yes arm: visibility, which every ELF target supports -- a flag on
#     configure's command line that emits any diagnostic turns this into no,
#     which is exactly the defect the canary exists to catch.
#   no arm:  target("sse2"), configure's own target probe body -- the harness
#     has to reproduce the "no" configure recorded, or it is a check that
#     cannot fail.
assert_attribute_probe_harness() {
  local tmp rc_yes=0 rc_no=0
  tmp="$(mktemp -d)"
  cat > "$tmp/yes.c" <<'EOF'
int foo_def( void ) __attribute__((visibility("default")));
int foo_hid( void ) __attribute__((visibility("hidden")));
int foo_int( void ) __attribute__((visibility("internal")));
int foo_pro( void ) __attribute__((visibility("protected")));
int main (void) { return 0; }
EOF
  cat > "$tmp/no.c" <<'EOF'
static int bar( void ) __attribute__((target("sse2")));
int main (void) { return 0; }
EOF
  # shellcheck disable=SC2086  # the flag sets are meant to word-split, as configure splits them
  "${CC:-cc}" -o "$tmp/yes" $CFLAGS ${CPPFLAGS:-} ${LDFLAGS:-} "$tmp/yes.c" 2>"$tmp/yes.err" || rc_yes=$?
  # shellcheck disable=SC2086
  "${CC:-cc}" -o "$tmp/no" $CFLAGS ${CPPFLAGS:-} ${LDFLAGS:-} "$tmp/no.c" 2>"$tmp/no.err" || rc_no=$?
  if [ "$rc_yes" -ne 0 ] || [ -s "$tmp/yes.err" ]; then
    echo "FATAL: a visibility-attribute probe built the way AX_GCC_FUNC_ATTRIBUTE builds its own" \
         "(exit $rc_yes) was not clean under configure's flags -- every attribute probe on this" \
         "branch would read the same diagnostics as 'no':" >&2
    sed 's/^/  /' "$tmp/yes.err" >&2
    rm -rf "$tmp"; exit 1
  fi
  if [ "$rc_no" -eq 0 ] && [ ! -s "$tmp/no.err" ]; then
    echo "FATAL: target(\"sse2\") built cleanly on $(uname -m) under configure's flags, so the harness" \
         "cannot tell yes from no here -- or configure's 'no' for target is wrong" >&2
    rm -rf "$tmp"; exit 1
  fi
  rm -rf "$tmp"
  echo "ok: attribute probe harness under configure's flags -- visibility links with empty stderr (yes)," \
       "target(\"sse2\") does not (no, matching configure's answer)"
}

# The interpreter's dispatch model, which on this toolchain hangs on a single
# probe. GCC builds get the HYBRID VM through global register variables; clang
# has none, so every clang build up to 8.4 runs the plain CALL VM with
# execute_data and opline kept in memory. 8.5 added the TAILCALL VM for exactly
# this case (Zend/zend_vm_opcodes.h: HAVE_MUSTTAIL + HAVE_PRESERVE_NONE + clang
# + x86_64/aarch64), and HAVE_PRESERVE_NONE comes from an AC_RUN_IFELSE probe
# whose inline asm calls a preserve_none function `fun` by name.
#
# It was lost that way once already, silently, on every 8.5.0 image. 8.5.0's
# probe declared `fun` without `used`, so the only reference to it -- inside
# the asm string -- was invisible to the optimiser: under -flto=thin (even at
# -O0) LTO internalised and dropped `fun`, the probe failed to link ("ld.lld:
# undefined hidden symbol: fun"), and configure read the link failure as "no
# preserve_none". Upstream later added `noinline,used` to `fun` on the 8.5
# branch, which is why 8.5.11 answers yes under the exact flags that made 8.5.0
# answer no. Nothing is forced from here: the probe also checks the
# argument/return register contract the JIT relies on, so it has to really run
# and pass.
#
# Whether a branch asks is read from its configure (7.0-8.4 have no probe). A
# branch that asks must have defined HAVE_PRESERVE_NONE, or the build is about
# to ship the CALL VM looking exactly like a TAILCALL one.
assert_preserve_none_canary() {
  if ! grep -q 'HAVE_PRESERVE_NONE' configure 2>/dev/null; then
    echo "note: this branch's configure has no preserve_none probe (the TAILCALL VM is 8.5+)"
    return 0
  fi
  if ! grep -Eq '^[[:space:]]*#[[:space:]]*define[[:space:]]+HAVE_PRESERVE_NONE[[:space:]]+1' main/php_config.h; then
    echo "FATAL: ./configure decided clang has no preserve_none calling convention, so this" \
         "build gets the CALL VM instead of TAILCALL. The probe compiles, links and runs a" \
         "program -- the error is under 'checking for preserve_none calling convention' in" \
         "config.log (8.5.0 failed to link it under -flto=thin)." >&2
    awk '/checking for preserve_none calling convention/{p=1} p{print} p&&/result:/{exit}' config.log \
      | grep -v '^| ' | head -20 >&2 || true
    exit 1
  fi
  echo "ok: HAVE_PRESERVE_NONE defined -- clang builds the TAILCALL VM on this branch"
}

# read_zend_vm_kind
#
# Prints the dispatch model this build actually gets, as call|switch|goto|
# hybrid|tailcall, by running Zend/zend_vm_opcodes.h and the freshly generated
# main/php_config.h through the same $CC/$CFLAGS/$CPPFLAGS configure ran with and
# reading what ZEND_VM_KIND expands to. The header is the authority: 7.0 and 7.1
# define it as ZEND_VM_KIND_CALL unconditionally, so HAVE_GCC_GLOBAL_REGS being
# set there (the CALL VM still pins registers) says nothing about the kind, and
# 7.2+ choose HYBRID/TAILCALL/CALL from compiler and HAVE_* conditions that only
# the preprocessor evaluates correctly. Run from the PHP source root, after
# ./configure.
read_zend_vm_kind() {
  local n
  [ -f Zend/zend_vm_opcodes.h ] && [ -f main/php_config.h ] \
    || { echo "FATAL: read_zend_vm_kind needs Zend/zend_vm_opcodes.h and main/php_config.h in $PWD" >&2; return 1; }
  # shellcheck disable=SC2086  # CFLAGS/CPPFLAGS are flag lists meant to word-split
  n="$(printf '#include "main/php_config.h"\n#include "Zend/zend_vm_opcodes.h"\nZEND_VM_KIND_IS ZEND_VM_KIND\n' \
        | "${CC:-cc}" -E -P -x c -I. -IZend -Imain ${CFLAGS:-} ${CPPFLAGS:-} - \
        | sed -n 's/^ZEND_VM_KIND_IS[[:space:]]*//p' | tail -1 | tr -d '[:space:]')"
  case "$n" in
    1) echo call ;;
    2) echo switch ;;
    3) echo goto ;;
    4) echo hybrid ;;
    5) echo tailcall ;;
    *) echo "FATAL: ZEND_VM_KIND did not preprocess to 1-5 (got '${n}') -- Zend/zend_vm_opcodes.h" \
            "changed shape, so the recorded VM kind would be a guess" >&2
       return 1 ;;
  esac
}
