#!/usr/bin/env bash
# The configure/make suppression split, and the controls that prove it holds.
#
# Sourced by php/build.sh (core PHP) and php/build-shared-ext.sh (the 18-odd
# phpize'd extensions). It lives in one file because both callers assert the
# same security-relevant property, and two copies of an assertion like this
# drift -- which is the failure mode this project has been bitten by more than
# once.
#
# WHY THE SPLIT EXISTS
#
# autoconf compiles tiny probe programs and reads a *compile failure* as a
# feature answer rather than as an error. PHP 7.x's probes are pre-C99 programs
# -- bare `main()`, functions called with no header in scope, a DIR* passed to
# close() -- and clang 16 and newer reject all three by default. So on the
# legacy branches a probe that the compiler rejects does not fail the build; it
# silently produces the *wrong answer*, which configure then bakes into
# config.h.
#
# Two of these were found the loud way (the build broke): ZEND_BROKEN_SPRINTF
# and PHP_READDIR_R_TYPE, both in core PHP. One was found the quiet way, and it
# is the reason this file exists rather than a second copy of the logic in
# build-shared-ext.sh: PECL uuid's PHP_CHECK_LIBRARY probes use a bare `main()`,
# so without the demotions clang rejects them, configure concludes the library
# and its functions are absent, and seven feature defines -- HAVE_LIBUUID,
# HAVE_UUID_GENERATE_MD5, HAVE_UUID_GENERATE_SHA1, HAVE_UUID_TIME,
# HAVE_UUID_TIME64, HAVE_UUID_TYPE, HAVE_UUID_VARIANT -- quietly vanish from a
# uuid.so that still builds, still loads, and still passes every check this
# project has. Nothing anywhere would have said so.
#
# The demotions therefore have to reach ./configure, and must NOT reach the
# compile: a blanket -Wno- surviving into `make` would hide exactly the class of
# bug (implicit int-vs-pointer returns on LP64) this project cannot afford in a
# security-relevant binary. `make` gets the diagnostics re-promoted to hard
# errors instead. EXTRA_CFLAGS is where the re-promotion goes because every
# compile rule places it *after* CFLAGS_CLEAN -- verified in the source for both
# build systems: acinclude.m4's php_c_meta on 7.0-7.3, build/php.m4's on 7.4+,
# and the same string in the installed build system a phpize build uses.

# The flag set for an era. Sets CONFIGURE_ONLY_CFLAGS and MAKE_ONLY_CFLAGS.
#
# Exactly three demotions, and no more. Each is load-bearing at ./configure
# time and none is needed to compile php-src -- where a real diagnostic turns
# up in the sources, it is fixed at the source (deps/patches/) rather than
# silenced tree-wide. A wider set would carry its own risk in the other
# direction: a probe that *should* fail because a feature is genuinely absent
# can be made to succeed.
# shellcheck disable=SC2034  # both are read by the sourcing script, not here
php_docker_flag_split() {
  case "${1:?php_docker_flag_split needs an era}" in
    legacy)
      CONFIGURE_ONLY_CFLAGS="-Wno-implicit-function-declaration -Wno-implicit-int -Wno-int-conversion"
      MAKE_ONLY_CFLAGS="-Werror=implicit-function-declaration -Werror=implicit-int -Werror=int-conversion"
      ;;
    *)
      # Modern PHP's probes are clean, so nothing is demoted and nothing needs
      # re-promoting: clang's defaults already make all three errors.
      CONFIGURE_ONLY_CFLAGS=""
      MAKE_ONLY_CFLAGS=""
      ;;
  esac
}

# A probe program per diagnostic, whose acceptance *is* the property being
# demoted -- rejected by exactly that diagnostic and by nothing else, so an
# unexpected result cannot be blamed on something unrelated.
php_docker_probe_source_for() {
  case "$1" in
    implicit-function-declaration)
      printf 'int main(void) { return probe_undeclared_function(); }\n' ;;
    implicit-int)
      printf 'static probe_missing_type(void) { return 0; }\nint main(void) { return probe_missing_type(); }\n' ;;
    int-conversion)
      printf 'extern int probe_takes_int(int);\nint main(void) { char *p = "x"; return probe_takes_int(p); }\n' ;;
    *) return 1 ;;
  esac
}

# The two-sided control.
#
#   php_docker_assert_flag_split <label> <configure-time cflags> <make-time cflags>
#
# where <make-time cflags> is the full sequence the compile rules will really
# use -- the baked CFLAGS_CLEAN followed by EXTRA_CFLAGS.
#
#   arm B (always, both eras): the make-time set must REJECT all three probes.
#     A suppression that leaked into the compile fails the build here.
#   arm A (only for diagnostics this build asked configure to demote): the
#     configure-time set must ACCEPT the matching probe, and the demotion must
#     be present in the make-time set's leading half. Without arm A, arm B
#     passes vacuously on a build where the demotion never reached ./configure
#     at all -- which is the same false green the canaries in build.sh exist to
#     prevent.
#
# A demotion with no probe to exercise it is a hard error, not an unverified
# flag: adding one to CONFIGURE_ONLY_CFLAGS means adding its probe above too.
php_docker_assert_flag_split() {
  local label="$1" configure_cflags="$2" make_cflags="$3"
  local tmp d src

  if [ -z "$make_cflags" ]; then
    echo "FATAL[$label]: no make-time flag set to test -- the configure/make split is unverified" >&2
    return 1
  fi
  case "$make_cflags" in
    *'$('*)
      echo "FATAL[$label]: the make-time flag set still contains unexpanded make" \
           "variables ($make_cflags) -- cannot test what the compiler will really see" >&2
      return 1 ;;
  esac

  tmp="$(mktemp -d)"

  for d in implicit-function-declaration implicit-int int-conversion; do
    src="$tmp/b-${d}.c"
    php_docker_probe_source_for "$d" > "$src"
    # shellcheck disable=SC2086  # both flag sets are meant to word-split
    if "${CC:-cc}" $make_cflags -c "$src" -o "$tmp/out.o" 2>/dev/null; then
      echo "FATAL[$label]: -W${d} is not an error during make. A ./configure-only" \
           "suppression has leaked into the compile: '$make_cflags'" >&2
      rm -rf "$tmp"; return 1
    fi
  done
  echo "ok[$label]: make rejects implicit-function-declaration, implicit-int and int-conversion (no suppression leaked past ./configure)"

  for d in $(printf '%s\n' $configure_cflags | sed -n 's/^-Wno-//p'); do
    src="$tmp/a-${d}.c"
    if ! php_docker_probe_source_for "$d" > "$src"; then
      echo "FATAL[$label]: -Wno-${d} is demoted for ./configure but there is no probe" \
           "for it, so the demotion is unverified" >&2
      rm -rf "$tmp"; return 1
    fi
    case " $make_cflags " in
      *" -Wno-${d} "*) ;;
      *)
        echo "FATAL[$label]: -Wno-${d} was given to ./configure but did not survive into" \
             "the flags the compile will use ('$make_cflags') -- ./configure did not use" \
             "the flags it was given, so its probe answers are unreliable" >&2
        rm -rf "$tmp"; return 1 ;;
    esac
    # shellcheck disable=SC2086
    if ! "${CC:-cc}" $configure_cflags -c "$src" -o "$tmp/out.o" 2>/dev/null; then
      echo "FATAL[$label]: -Wno-${d} is in CONFIGURE_ONLY_CFLAGS but the configure-time" \
           "flag set still rejects the matching probe -- the demotion never took effect," \
           "so autoconf's answers were computed by a compiler that cannot build its" \
           "probes. CFLAGS='$configure_cflags'" >&2
      rm -rf "$tmp"; return 1
    fi
    echo "ok[$label]: ./configure ran with -W${d} demoted (probe accepted there, rejected by make)"
  done

  rm -rf "$tmp"
}
