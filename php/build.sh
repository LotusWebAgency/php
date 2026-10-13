#!/usr/bin/env bash
# Configure, compile and install PHP. Run from the unpacked source tree by the
# Dockerfile's php-build stage, which exposes its build args as environment.
#
# php_make() is the single place that drives a compile. The PGO passes go through
# it as PROF_FLAGS=... on the make command line, which php-src's CFLAGS_CLEAN
# carries to every compile rule.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PHP_VERSION="${PHP_VERSION:?php/build.sh needs PHP_VERSION}"
PHP_ERA="${PHP_ERA:-modern}"
UARCH="${UARCH:-baseline}"

# Empty for the modern era, which links against what Debian ships. The legacy era
# points this at the vendored prefix; ldflags.sh turns it into an rpath on the
# binary rather than a global LD_LIBRARY_PATH, which let a vendored libcurl
# shadow Debian's for every process in the image.
PHP_DEPS_PREFIX="${PHP_DEPS_PREFIX:-}"

# configure-args.sh renders literal text that no shell re-expands, so a flag that
# must carry the prefix as its value (7.x: --with-openssl=DIR, --with-curl=DIR,
# --with-libxml-dir=DIR ...) cannot be expressed in the registry. List those flag
# names here and the value is spliced in below; empty leaves every flag as
# rendered.
PREFIXED_CONFIGURE_FLAGS="${PREFIXED_CONFIGURE_FLAGS:-}"

# The pecl sources are unpacked into ext/ (php/fetch-pecl.sh) before this script
# runs, so every era builds core and pecl configure flags.
EXT_SOURCES="${EXT_SOURCES:-all}"

if [ -n "$PREFIXED_CONFIGURE_FLAGS" ] && [ -z "$PHP_DEPS_PREFIX" ]; then
  echo "PREFIXED_CONFIGURE_FLAGS is set but PHP_DEPS_PREFIX is empty" >&2
  exit 1
fi

# The flags reaching ./configure and the flags reaching the compiler are separate
# knobs. php/flag-split.sh holds the rationale and the controls; it is shared
# with php/build-shared-ext.sh so the two do not carry drifting copies.
# shellcheck source=php/flag-split.sh
. "$HERE/flag-split.sh"
php_docker_flag_split "$PHP_ERA"

BASE_CFLAGS="$(bash "$HERE/cflags.sh" "$UARCH")"
# The legacy era's opcache optimizer detects integer overflow in its range
# inference (zend_inference.c) by testing the result of a signed add, which is
# undefined behavior. GCC 16 folds those checks away and SCCP then proves a loop
# bound that is not true: PrestaShop 8.2.8 on PHP 7.2 spun forever in Symfony's
# XmlFileLoader::validateSchema() on a cold cache. -fwrapv makes the overflow
# defined.
if [ "$PHP_ERA" = legacy ]; then
  BASE_CFLAGS="$BASE_CFLAGS -fwrapv"
fi
# -std=gnu17 is part of BASE_CFLAGS for every version and compiler; see
# php/cflags.sh.

# CFLAGS/CXXFLAGS/LDFLAGS are exported per pass by php_set_pass_flags() below,
# from these BASE_* values.
# C++17 removed the `register` storage class, and clang rejects it outright in
# that mode. PHP 7.0's main/php.h, main/snprintf.h and Zend/zend_string.h still
# use it and ext/intl's C++ units include all three, so 7.0 cannot be compiled as
# C++17; 7.1 removed the last uses. C++11 is also what ICU 67.1
# (deps/versions.lock) requires of its consumers.
case "$PHP_VERSION" in
  7.0) CXX_STD="-std=c++11" ;;
  *)   CXX_STD="-std=c++17" ;;
esac
BASE_CXXFLAGS="$BASE_CFLAGS $CXX_STD"
# ImageMagick lives at /opt/imagemagick in every era, not under PHP_DEPS_PREFIX.
# imagick needs an rpath to it or the php binary cannot resolve libMagickWand; a
# global LD_LIBRARY_PATH would break host binaries such as curl.
BASE_LDFLAGS="$(bash "$HERE/ldflags.sh" "$PHP_DEPS_PREFIX" /opt/imagemagick)"
export EXTRA_LDFLAGS_PROGRAM="-pie"

# amd64 v3 on the clang era: make ld.so refuse the SAPI executables on a CPU
# without x86-64-v3 by linking in a hand-made GNU_PROPERTY_X86_ISA_1_NEEDED note
# (php/isa-note-x86-64-v3.S; the gcc era gets the same from -mneeded in
# php/cflags.sh). clang has no -mneeded, lld ignores -z x86-64-v3 and drops input
# .note.gnu.property sections, so the note lives in a differently named section
# of its own object. It goes through EXTRA_LDFLAGS_PROGRAM, the program-only
# path, so shared modules are not marked; libtool passes a plain object on the
# link line through untouched, and assert_isa_note below proves it reached the
# final executables.
#
# Neither lld (for this section) nor gold emits a PT_GNU_PROPERTY program header,
# so the refusal depends on glibc's ld.so reading the property out of the legacy
# PT_NOTE segment. trixie's glibc 2.41 does; glibc 2.44 does not. The runtime
# proof in tests/test-uarch.sh guards that, not readelf.
#
# Linking this object (it has no GNU_PROPERTY_X86_FEATURE_1_AND) makes lld drop
# any IBT/SHSTK marking; the shipped binaries carry none
# (tests/assert-elf-hardening.sh).
if [ "$UARCH" = v3 ] && [ "$(dpkg --print-architecture)" = amd64 ] && [ "${COMPILER:-clang}" = clang ]; then
  ISA_NOTE_DIR="$(mktemp -d)"
  trap 'rm -rf "$ISA_NOTE_DIR"' EXIT
  ISA_NOTE_OBJ="$ISA_NOTE_DIR/isa-note-x86-64-v3.o"
  "${CC:-clang}" -c "$HERE/isa-note-x86-64-v3.S" -o "$ISA_NOTE_OBJ"
  EXTRA_LDFLAGS_PROGRAM="$EXTRA_LDFLAGS_PROGRAM $ISA_NOTE_OBJ"
fi

if [ -n "$PHP_DEPS_PREFIX" ]; then
  export CPPFLAGS="-I${PHP_DEPS_PREFIX}/include ${CPPFLAGS:-}"
fi
# ext/intl on 7.0-7.3 refers to Locale/Calendar/TimeZone/UnicodeString/...
# unqualified. ICU 68 stopped injecting `using namespace icu;` and dropped the
# TRUE/FALSE macros ext/intl needs, which is why deps/versions.lock caps ICU at
# 67.1 for this range. 8.0's ICU 70.1 and its ext/intl already qualify
# everything with `icu::`.
case "$PHP_VERSION" in
  7.0|7.1|7.2|7.3)
    export CPPFLAGS="-DU_USING_ICU_NAMESPACE=1 ${CPPFLAGS:-}"
    BASE_CXXFLAGS="$BASE_CXXFLAGS -DU_USING_ICU_NAMESPACE=1"
    ;;
esac
# imagick's --with-imagick=/opt/imagemagick (php/ext.json) finds MagickWand via
# the staged MagickWand-config script, not pkg-config; this is set anyway so
# anything else that uses pkg-config finds ImageMagick's .pc files.
export PKG_CONFIG_PATH="${PHP_DEPS_PREFIX:+${PHP_DEPS_PREFIX}/lib/pkgconfig:}/opt/imagemagick/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
# PKG_CONFIG_PATH does not survive to the legacy era's ICU/openssl checks: PECL
# imagick's imagemagick.m4 (upstream, fetched fresh by fetch-pecl.sh) exports
# PKG_CONFIG_PATH="$IM_IMAGEMAGICK_PREFIX/lib/pkgconfig" unconditionally, and
# that runs before intl's PHP_SETUP_ICU, so the ICU check sees only ImageMagick's
# directory. PKG_CONFIG_LIBDIR is never touched by that m4, so the vendored
# prefix and the compiler's real default search path go there instead. The
# default path has to be listed explicitly because PKG_CONFIG_LIBDIR replaces
# pkg-config's built-in one, and the legacy era's system libcurl .pc (8.0, not
# vendored) depends on it.
if [ -n "$PHP_DEPS_PREFIX" ]; then
  PKG_CONFIG_DEFAULT_PATH="$(pkg-config --variable pc_path pkg-config)"
  export PKG_CONFIG_LIBDIR="${PHP_DEPS_PREFIX}/lib/pkgconfig:/opt/imagemagick/lib/pkgconfig:${PKG_CONFIG_DEFAULT_PATH}"
fi

# --with-curl carries the vendored prefix only on versions that vendor curl
# (7.0-7.2 per deps/versions.lock; 7.3-8.0 link trixie's libcurl). On 7.0/7.1,
# ext/curl/config.m4 is pure CURL_DIR + $CURL_DIR/bin/curl-config, so splicing
# the prefix onto a version that did not vendor curl fails configure. The
# decision is derived from the artifact build-deps.sh produced, not from a
# second copy of the version range.
#
# Per-version detection in each release's ext/curl/config.m4: 7.0/7.1 use
# curl-config only; 7.2/7.3 try pkg-config first (a DIR resolves to
# $DIR/lib/pkgconfig/libcurl.pc) with curl-config as fallback; 7.4+ use pure
# PKG_CHECK_MODULES(libcurl), where a DIR value is accepted and never read. The
# prefix therefore has to be spliced for 7.0-7.2, and curl-config exists in
# exactly those builds.
if [ -n "$PHP_DEPS_PREFIX" ] && [ -x "${PHP_DEPS_PREFIX}/bin/curl-config" ]; then
  PREFIXED_CONFIGURE_FLAGS="${PREFIXED_CONFIGURE_FLAGS} --with-curl"
fi

# --with-icu-dir, for the one version that needs it. 7.1+ try pkg-config first in
# PHP_SETUP_ICU (acinclude.m4), and only when --with-icu-dir was not passed, so
# they find the vendored ICU through PKG_CONFIG_LIBDIR and must NOT be given a
# DIR -- that would route them into the legacy icu-config branch. 7.0's
# PHP_SETUP_ICU has no pkg-config branch (zero occurrences of PKG_CONFIG in
# 7.0.33, seven in 7.1.33): it shells out to icu-config, found at
# $PHP_ICU_DIR/bin or on $PATH, and errors with "Unable to detect ICU prefix"
# otherwise. Trixie has no system icu-config, so 7.0 has to be told.
#
# php/ext.json carries the flag as a 7.0 override on intl; only the value is
# derived here, from the artifact deps/build-deps.sh left behind. Putting
# ${PHP_DEPS_PREFIX}/bin on PATH would also work but would let the vendored
# `curl` binary (7.0-7.2) shadow /usr/bin/curl for the rest of the build.
case " $(bash "$HERE/configure-args.sh" "$PHP_VERSION" "$EXT_SOURCES" | tr '\n' ' ') " in
  *" --with-icu-dir "*)
    if [ -n "$PHP_DEPS_PREFIX" ] && [ -x "${PHP_DEPS_PREFIX}/bin/icu-config" ]; then
      PREFIXED_CONFIGURE_FLAGS="${PREFIXED_CONFIGURE_FLAGS} --with-icu-dir"
    else
      # A bare --with-icu-dir sets PHP_ICU_DIR=yes and PHP_SETUP_ICU then looks
      # for "yes/bin/icu-config", failing late in configure. Fail here, where
      # the reason is legible.
      echo "php/ext.json asks for --with-icu-dir on PHP ${PHP_VERSION} but there is no" \
           "icu-config at '${PHP_DEPS_PREFIX:-<unset PHP_DEPS_PREFIX>}/bin' to point it at" >&2
      exit 1
    fi
    ;;
esac

render_configure_args() {
  local args flag
  args="$(bash "$HERE/configure-args.sh" "$PHP_VERSION" "$EXT_SOURCES")"
  for flag in $PREFIXED_CONFIGURE_FLAGS; do
    args="$(printf '%s\n' "$args" | sed "s|^${flag}\$|${flag}=${PHP_DEPS_PREFIX}|")"
    # `sed` exits 0 whether or not it substituted anything, so a flag that is no
    # longer rendered (renamed in ext.json, moved behind a version gate, dropped)
    # would silently stop carrying the vendored prefix -- for --with-openssl, a
    # legacy build quietly linking trixie's OpenSSL 3 instead of the vendored
    # 1.1.1w. Assert the substitution happened.
    printf '%s\n' "$args" | grep -qx -- "${flag}=${PHP_DEPS_PREFIX}" || {
      echo "PREFIXED_CONFIGURE_FLAGS names ${flag}, but php/configure-args.sh does not" \
           "render it for PHP ${PHP_VERSION} -- nothing was substituted, so the vendored" \
           "prefix would not be used" >&2
      exit 1
    }
  done
  printf '%s\n' "$args" | tr '\n' ' '
}

# Probe-answer canaries and the configure/make split control (php/build-canaries.sh).
# shellcheck source=php/build-canaries.sh
. "$HERE/build-canaries.sh"

php_configure() {
  # Not `./configure $(render_configure_args)`: a command substitution used as an
  # argument discards its exit status, so the guard inside that function would
  # print its diagnostic and exit the subshell while ./configure ran anyway. A
  # plain assignment is the form `set -e` acts on.
  local args
  args="$(render_configure_args)"
  # shellcheck disable=SC2086  # the rendered flags and cache overrides are meant to word-split
  ./configure $args $CONFIGURE_CACHE_OVERRIDES
  # The VM this build gets, from the header's own ZEND_VM_KIND (read_zend_vm_kind).
  # The messages below name it instead of assuming gcc means HYBRID: 7.0/7.1 are
  # CALL on every arch even though they pin the same registers, and 7.2/7.3 on
  # aarch64 have no register probe at all.
  ZEND_VM_KIND_CONFIG="$(read_zend_vm_kind)" || exit 1
  local vm_name="${ZEND_VM_KIND_CONFIG^^}"
  # COMPILER=gcc exists for PHP's HYBRID VM, which pins execute_data/opline into
  # %r14/%r15 via GCC global register variables (Zend/zend_execute.c) when
  # ./configure's probe accepts them. clang defines __GNUC__ but does not
  # implement that extension reliably enough for the probe, so a clang build
  # never gets HAVE_GCC_GLOBAL_REGS. Both directions are asserted.
  #
  # %r14/%r15 is the x86_64 pair. On aarch64 the answer depends on the branch:
  # Zend/Zend.m4's probe knows __aarch64__ (x27/x28) only from 7.4 on, while
  # 7.0-7.3 list i386/x86_64 alone, so those builds get the plain CALL VM under
  # any gcc. Which case applies is read from the probe block itself rather than
  # a version list, and asserted both ways.
  if [ "${COMPILER:-clang}" = gcc ] && [ "$(uname -m)" = aarch64 ]; then
    # From the --enable-gcc-global-regs option to the probe's #error: the
    # probe program and nothing else. Every branch's block names __x86_64__,
    # so a range that does not is a stale extraction, not an answer.
    local regs_probe
    regs_probe="$(sed -n '/gcc-global-regs/,/global register variables are not supported/p' Zend/Zend.m4)"
    grep -q '__x86_64__' <<<"$regs_probe" \
      || { echo "FATAL: could not find the global-register probe in Zend/Zend.m4 (no __x86_64__ in the" \
                "extracted block) -- the aarch64 expectation below would be guessed, not derived" >&2; exit 1; }
    if grep -q '__aarch64__' <<<"$regs_probe"; then
      grep -q '^#define HAVE_GCC_GLOBAL_REGS 1' main/php_config.h \
        || { echo "FATAL: COMPILER=gcc on aarch64 but HAVE_GCC_GLOBAL_REGS did not take, though this" \
                  "branch's Zend/Zend.m4 probe knows __aarch64__ -- check main/php_config.h" >&2; exit 1; }
      echo "ok: HAVE_GCC_GLOBAL_REGS=1 -- the ${vm_name} VM will pin execute_data/opline in x27/x28 (aarch64)"
    else
      if grep -q '^#define HAVE_GCC_GLOBAL_REGS 1' main/php_config.h; then
        echo "FATAL: HAVE_GCC_GLOBAL_REGS=1 on aarch64, but this branch's Zend/Zend.m4 probe only" \
             "knows i386/x86_64 -- the derivation above is stale" >&2
        exit 1
      fi
      echo "ok: HAVE_GCC_GLOBAL_REGS is not defined on aarch64, as expected -- PHP ${PHP_VERSION}'s" \
           "Zend/Zend.m4 probe predates aarch64 global registers (added in 7.4), so this build runs the CALL VM"
    fi
  elif [ "${COMPILER:-clang}" = gcc ]; then
    grep -q '^#define HAVE_GCC_GLOBAL_REGS 1' main/php_config.h \
      || { echo "FATAL: COMPILER=gcc but HAVE_GCC_GLOBAL_REGS did not take -- check main/php_config.h" >&2; exit 1; }
    echo "ok: HAVE_GCC_GLOBAL_REGS=1 -- the ${vm_name} VM will pin execute_data/opline in %r14/%r15"
  elif grep -q '^#define HAVE_GCC_GLOBAL_REGS 1' main/php_config.h; then
    echo "FATAL: COMPILER=clang but HAVE_GCC_GLOBAL_REGS=1 was defined -- this build no longer" \
         "demonstrates that clang rejects the global-register probe" >&2
    exit 1
  else
    echo "ok: HAVE_GCC_GLOBAL_REGS is not defined under clang, as expected"
  fi
  assert_sprintf_canary
  assert_readdir_r_canary
  assert_ifunc_canary
  # ifunc is the only attribute this build forces off; everything else php-src
  # probes has to have come back yes.
  assert_attribute_canary "ifunc"
  assert_preserve_none_canary
  assert_configure_make_split

  # tests/smoke.sh's VM-kind expectation needs a build-time answer for versions
  # it cannot ask at runtime: 7.0-7.3 have no FFI (ext.json's floor is >=7.4), so
  # a shipped image has no zend_vm_kind() to call. ZEND_VM_KIND_CONFIG was read
  # from the generated header right after configure; write_build_record ships
  # it.
  echo "ok: vm_kind_config=$ZEND_VM_KIND_CONFIG (ZEND_VM_KIND from Zend/zend_vm_opcodes.h and main/php_config.h)"
}

# The only place a compile is driven; the PGO passes go through it
# (`php_make PROF_FLAGS=...`).
# shellcheck disable=SC2120  # the non-PGO path calls it with no goals
php_make() {
  # CCACHE_DISABLE when a profile flag is in play, as php-src's own
  # prof-gen/prof-use targets do (Makefile.global). ccache's -fprofile-use
  # handling relies on hashing the profile *file*, and a stale hit would serve
  # objects built without the profile while every other check still passed.
  # An empty string, not "0": ${var:+word} expands whenever var is non-empty.
  local ccache_off="" arg
  for arg in "$@"; do case "$arg" in PROF_FLAGS=*) ccache_off="CCACHE_DISABLE=1" ;; esac; done
  if make -j"$(nproc)" ${ccache_off:+"$ccache_off"} EXTRA_CFLAGS="$MAKE_ONLY_CFLAGS" "$@"; then
    return 0
  fi
  # A parallel make interleaves the output of sixteen compilers, which shreds a
  # linker's long stack trace. Re-run serially so the failing command and
  # everything it printed are legible. The return is unconditional, so this never
  # turns a failure into a pass; if the serial run succeeds, that is reported as
  # a race in the build.
  echo "=== make failed; re-running serially so the failing command is legible" >&2
  if make -j1 ${ccache_off:+"$ccache_off"} EXTRA_CFLAGS="$MAKE_ONLY_CFLAGS" "$@"; then
    echo "=== NOTE: the serial re-run SUCCEEDED where -j$(nproc) failed -- that is a race in the build, not a compiler problem. Failing anyway." >&2
  fi
  return 1
}

php_install() {
  # Not parallel: PHP's install targets share mkinstalldirs and race under -j.
  make install EXTRA_CFLAGS="$MAKE_ONLY_CFLAGS"
  mkdir -p /usr/local/etc/php/conf.d
  # make install only writes php-fpm.conf.default and www.conf.default
  # (sapi/fpm/Makefile.frag); copy them into place so the files exist.
  [ -f /usr/local/etc/php-fpm.conf ] \
    || cp /usr/local/etc/php-fpm.conf.default /usr/local/etc/php-fpm.conf
  [ -f /usr/local/etc/php-fpm.d/www.conf ] \
    || cp /usr/local/etc/php-fpm.d/www.conf.default /usr/local/etc/php-fpm.d/www.conf
  strip --strip-unneeded /usr/local/bin/php /usr/local/sbin/php-fpm
  find /usr/local/lib/php -name '*.a' -delete
}

# Vendored libraries have to reach the runtime image at exactly the path their
# binaries' rpath names. Staging them under /deps-stage lets the runtime stage do
# one unconditional COPY; the PHP_DEPS_PREFIX tree is empty in the modern era.
stage_runtime_deps() {
  mkdir -p /deps-stage
  if [ -n "$PHP_DEPS_PREFIX" ]; then
    mkdir -p "/deps-stage${PHP_DEPS_PREFIX}"
    cp -a "${PHP_DEPS_PREFIX}/lib" "/deps-stage${PHP_DEPS_PREFIX}/"
    # php has already linked (php_install ran above); .a/.la are build-time
    # artifacts only (openssl's and icu's static archives, curl's libtool
    # metadata) that nothing at runtime reads.
    find "/deps-stage${PHP_DEPS_PREFIX}/lib" \( -name '*.a' -o -name '*.la' \) -delete
  fi
  # ImageMagick has its own fixed prefix in every era; stage it unconditionally.
  if [ -d /opt/imagemagick/lib ]; then
    mkdir -p /deps-stage/opt/imagemagick
    cp -a /opt/imagemagick/lib /deps-stage/opt/imagemagick/
  fi
  # net-snmp's client library and MIB files only: bin, include and pkgconfig are
  # build-time inputs for ext-snmp, which php/build-shared-ext.sh compiles after
  # this runs, against the prefix still present in this stage. share/snmp/mibs is
  # where the library's compiled-in MIB directory points.
  if [ -d /opt/net-snmp/lib ]; then
    mkdir -p /deps-stage/opt/net-snmp/lib /deps-stage/opt/net-snmp/share/snmp
    cp -a /opt/net-snmp/lib/libnetsnmp.so.* /deps-stage/opt/net-snmp/lib/
    cp -a /opt/net-snmp/share/snmp/mibs /deps-stage/opt/net-snmp/share/snmp/
  fi
}

# --------------------------------------------------------------- ThinLTO, PGO
#
# ThinLTO is unconditional on the clang path: cross-module inlining needs no
# corpus and cannot be trained wrong. PGO is matrix.json's `pgo` flag, passed
# through by bake; a version that cannot complete two passes sets it to false
# with a pgo_disabled_reason, which scripts/pgo_tiers.py check enforces. Plain
# ThinLTO is the documented fallback, not a failure.
#
# PGO has no default on purpose: an unset build arg must not silently produce an
# unoptimized binary.
PGO="${PGO:?php/build.sh needs PGO=true or PGO=false (bake passes it from matrix.json)}"
case "$PGO" in
  true|false) ;;
  *) echo "PGO must be 'true' or 'false', got '$PGO'" >&2; exit 1 ;;
esac

PGO_CORPUS="${PGO_CORPUS:-/corpus}"
PGO_CORPUS_SRC="${PGO_CORPUS_SRC:-/corpus-src}"
PROFRAW_DIR="${PGO_PROFRAW_DIR:-/tmp/php-profraw}"
PROFDATA="${PGO_PROFDATA:-/tmp/php.profdata}"
BUILD_RECORD_DIR="${PHP_BUILD_RECORD_DIR:-/usr/local/share/php-build}"
TRAIN_SUMMARY=/tmp/pgo-train.summary

# ./configure cache overrides. Autoconf reads a preset ax_cv_*/ac_cv_* value
# instead of running the probe; php-src's own configure.ac does the same to ifunc
# on FreeBSD below 12, so "no ifunc resolvers" is a configuration upstream ships.
#
# Why ifunc is off: ld.lld 19.1.7 segfaults linking php-src with -flto=thin, in
# llvm::computeDeadSymbolsAndUpdateIndirectCalls (and, with that pass disabled
# via -mllvm -compute-dead=false, in llvm::ModuleSummaryIndex::
# propagateAttributes). Both walk the summary index's alias edges, which is where
# a GlobalIFunc lands. Answering the ifunc probe "no" makes the link succeed. It
# reproduces with and without a profile, so it is ThinLTO, not PGO.
#
# Cost: php-src resolves its SIMD implementations through a function pointer set
# in MINIT instead of the dynamic linker (the ZEND_INTRIN_*_RESOLVER /
# *_FUNC_PTR path every toolchain without ifunc takes). On 8.5 that is
# php_base64_encode_ex, php_base64_decode_ex and php_addslashes, plus mbstring's
# utf-8/utf-16 checks on the branches that have them: a per-call indirection
# that PGO's indirect-call promotion can partly recover, against cross-module
# inlining over all of php-src and the static PECL extensions. 7.0 has no ifunc
# resolvers, so the override is a no-op there; assert_ifunc_canary derives which
# branches ask.
CONFIGURE_CACHE_OVERRIDES="ax_cv_have_func_attribute_ifunc=no"

# -ffunction-sections and -z keep-text-section-prefix apply to both PGO passes
# and to the non-PGO fallback, and that symmetry is the point. Clang gives a
# function a .text.hot/.text.unlikely prefix only when it has hotness data, which
# llvm's PGOInstrumentation pass sets from an IR profile. With these flags
# constant across every build, a `.text.hot` section in the linked binary can
# only come from a build that consumed a profile; assert_profile_reached_the_link
# and tests/test-pgo.sh assert that in both directions.
#
# .text.unlikely is NOT that signal: php-src marks functions ZEND_COLD
# (__attribute__((cold))) in 19 (7.0) to 45 (8.5) files, so that section exists
# with or without a profile. ZEND_HOT is defined but used nowhere in either
# release, which is why only the hot side discriminates.
#
# GCC's LTO is off for the gcc path, permanently. Its whole-program LTRANS pass
# rejects ext/opcache/jit/zend_jit_vm_helpers.c, which declares a global register
# variable after a function definition in the same translation unit; that is
# only checked when LTO re-elaborates the merged program, and per-TU compilation
# accepts it. Fedora disables LTO for php-src for the same class of conflict. So
# the gcc branch uses no -flto and plain ar/ranlib/nm (the gcc-ar wrappers exist
# only to handle LTO bytecode in archives). The LTO_CFLAGS/LTO_LDFLAGS names stay
# because both branches feed the same php_set_pass_flags call.
# -freorder-functions/-freorder-blocks-and-partition are per-TU codegen flags and
# still give a profile-guided gcc build a .text.hot section to discriminate on
# (php/pgo/discriminator-control.sh). -fuse-ld is unset because the Dockerfile's
# ld-shim already puts the right linker (gcc: gold, for the .text.hot fold) on
# PATH.
case "${COMPILER:-clang}" in
  clang)
    LTO_CFLAGS="-flto=thin -ffunction-sections"
    LTO_LDFLAGS="-flto=thin -fuse-ld=lld -Wl,-z,keep-text-section-prefix"
    ;;
  gcc)
    # -freorder-blocks-and-partition, not just -freorder-functions: with gcc 16 /
    # binutils 2.47, -freorder-functions alone never emits a .text.hot.* input
    # section (php/pgo/discriminator-probe.c); the partition flag is what makes
    # gcc split a profiled-hot function's blocks into .text.hot.NAME /
    # .text.unlikely.NAME. keep-text-section-prefix is a linker option (see the
    # Dockerfile's ld-shim for why it needs gold), so it is not repeated here.
    LTO_CFLAGS="-ffunction-sections -freorder-functions -freorder-blocks-and-partition"
    # Not on arm64: aarch64 gcc keeps block partitioning off by default because
    # its compact jump tables are label differences that cannot span .text and
    # .text.unlikely, and forcing it on fails in the assembler
    # (ext/standard/var_unserializer.c, 8.1/8.2). There -freorder-functions alone
    # already puts profiled-hot functions in .text.hot.* (gcc 16.2, gold).
    if [ "$(dpkg --print-architecture)" = arm64 ]; then
      LTO_CFLAGS="-ffunction-sections -freorder-functions"
    fi
    LTO_LDFLAGS="-Wl,-z,keep-text-section-prefix"
    ;;
  *) echo "php/build.sh: unsupported COMPILER=${COMPILER:-<unset>}" >&2; exit 1 ;;
esac

# php_set_pass_flags <extra-cflags> <extra-ldflags>
#
# The one place CFLAGS/CXXFLAGS/LDFLAGS are exported, so both passes differ only
# by their arguments. CONFIGURE_ONLY_CFLAGS stays out of CXXFLAGS: the demotions
# are C-only.
php_set_pass_flags() {
  export CFLAGS="$BASE_CFLAGS $CONFIGURE_ONLY_CFLAGS${1:+ $1}"
  export CXXFLAGS="$BASE_CXXFLAGS${1:+ $1}"
  export LDFLAGS="$BASE_LDFLAGS${2:+ $2}"
}

# assert_profile_reached_the_link <yes|no> <binary> [<binary>...]
#
# "The build printed no errors" cannot tell a profile-guided link apart from one
# where the profile was generated, merged, and never consumed (ccache serving
# objects from a non-PGO build, say). This check cannot pass that way.
#
# The floor is a share of the binary's own text, so it needs no retuning per
# version or architecture. Profile-guided builds measure 17.7% (7.0), 35.0%
# (8.5), 36.1% (8.2); a ThinLTO-only build measures 0. Five percent sits a factor
# of three below the lowest real build and far above what a stray
# __attribute__((hot)) on one function could produce, since `hot` puts a
# function in that section with no profile involved.
#
# Not env-overridable, so the floor cannot be lowered when inconvenient; it is
# recorded into the image so what the build asserted is legible from the
# artifact.
PGO_TEXT_HOT_MIN_PERCENT=5

# section_size <readelf -SW output> <section name> -> size in bytes, 0 if absent
#
# Not `awk strtonum()`: it is a gawk extension and the build image has mawk,
# where it silently evaluates to 0. The leading "[NN]" is stripped first because
# readelf pads single-digit indices as "[ 4]", which splits into two fields and
# shifts every column.
section_size() {
  local hex
  hex="$(awk -v want="$2" '{ sub(/^ *\[ *[0-9]+\] */, ""); if ($1 == want) { print $5; exit } }' <<<"$1")"
  printf '%d' "$((16#${hex:-0}))"
}

assert_profile_reached_the_link() {
  local want="$1"; shift
  local bin sections hot text unlikely total pct
  for bin in "$@"; do
    sections="$(readelf -SW "$bin")" \
      || { echo "FATAL: readelf could not read the sections of $bin" >&2; exit 1; }
    # Positive control: an empty or unparsed listing would make every "no
    # .text.hot" answer below true for the wrong reason.
    grep -q '\.dynamic' <<<"$sections" \
      || { echo "FATAL: readelf printed no .dynamic section for $bin -- the .text.hot check measures nothing" >&2; exit 1; }
    text="$(section_size "$sections" .text)"
    hot="$(section_size "$sections" .text.hot)"
    unlikely="$(section_size "$sections" .text.unlikely)"
    total=$((text + hot + unlikely))
    [ "$total" -gt 0 ] \
      || { echo "FATAL: $bin has no executable text at all -- nothing was measured" >&2; exit 1; }
    pct=$((100 * hot / total))
    if [ "$want" = yes ]; then
      [ "$pct" -ge "$PGO_TEXT_HOT_MIN_PERCENT" ] || {
        echo "FATAL: $bin has ${hot} bytes of .text.hot, ${pct}% of its text, below the" \
             "${PGO_TEXT_HOT_MIN_PERCENT}% a profile-guided build produces. The profile was merged" \
             "but did not reach the compiler -- this is a plain ThinLTO build wearing a PGO label." >&2
        exit 1; }
      echo "ok: $(basename "$bin") has ${hot} bytes of .text.hot (${pct}% of text) -- the profile reached the compiler"
    else
      [ "$hot" -eq 0 ] || {
        echo "FATAL: $bin has ${hot} bytes of .text.hot on a PGO=false build. Either a profile" \
             "leaked into this build, or something in the sources now marks functions hot by" \
             "attribute and .text.hot has stopped discriminating -- fix the assertion before" \
             "trusting either answer." >&2
        exit 1; }
      echo "ok: $(basename "$bin") has no .text.hot, as a PGO=false build requires"
    fi
  done
}

# assert_isa_note <v3|baseline> <binary> [<binary>...]
#
# On amd64 a v3 image must refuse to start on a CPU without x86-64-v3 (glibc
# ld.so, exit 127), and a baseline image must not claim to need it. Both come
# from the GNU_PROPERTY_X86_ISA_1_NEEDED note, which no linker here records
# from -march alone, so a flag that was silently ignored would ship an image
# that dies with SIGILL instead -- read the note off the shipped binaries.
# This proves the note is there, not that ld.so acts on it: gold and lld emit
# no PT_GNU_PROPERTY here, so the refusal relies on glibc reading the property
# from PT_NOTE (trixie's 2.41 does, newer glibc may not). tests/test-uarch.sh
# proves the enforcement at runtime on the shipped image.
assert_isa_note() {
  local want="$1"; shift
  local bin notes needed
  for bin in "$@"; do
    notes="$(readelf -n "$bin")" \
      || { echo "FATAL: readelf could not read the notes of $bin" >&2; exit 1; }
    # Positive control: --build-id=sha1 is always linked, so an empty or
    # unparsed listing means the answers below are true for the wrong reason.
    grep -q 'Build ID' <<<"$notes" \
      || { echo "FATAL: readelf printed no build-id note for $bin -- the ISA note check measures nothing" >&2; exit 1; }
    needed="$(grep -i 'x86 ISA needed' <<<"$notes" || true)"
    if [ "$want" = v3 ]; then
      grep -qi 'x86-64-v3' <<<"$needed" || {
        echo "FATAL: $bin does not declare x86-64-v3 in its GNU property note ('${needed:-no ISA note}')." \
             "Its v3 codegen would die with SIGILL on an older CPU instead of being refused at load time." \
             "gcc era: -mneeded (php/cflags.sh) did not reach the link; clang era: php/isa-note-x86-64-v3.S did not." >&2
        exit 1; }
      echo "ok: $(basename "$bin") declares x86-64-v3 ($(tr -s ' ' <<<"$needed" | sed 's/^ *Properties: //'))"
    else
      ! grep -qi 'x86-64-v3' <<<"$needed" || {
        echo "FATAL: baseline $bin declares x86-64-v3 in its GNU property note ('$needed') -- it would be" \
             "refused on a CPU it is meant to run on." >&2
        exit 1; }
      echo "ok: $(basename "$bin") does not claim x86-64-v3, as a baseline build requires"
    fi
  done
}

# assert_simd_dispatch_present <php-src-dir> <unstripped-binary> [<binary>...]
#
# The artifact-level half of assert_attribute_canary. php-src puts every vector
# implementation behind __attribute__((target(...))), so if that attribute is
# unavailable the functions do not exist at all.
#
# It runs on the build-tree binary, before php_install strips it, and matches
# php-src's own function names:
#
#   * Counting vector instructions in the whole binary cannot work on the legacy
#     era. Vendored OpenSSL 1.1.1w is linked statically there, and libcrypto.a
#     alone carries pshufb 432 / vpshufb 225 / pclmul 196 -- exactly what the
#     shipped php 7.2 binary measures -- so php-src contributes nothing to the
#     count.
#   * Matching symbols by ISA suffix does not work either: libcrypto.a defines 25
#     symbols that match that convention (ChaCha20_ssse3,
#     RSAZ_1024_mod_exp_avx2, K256_shaext ...). Only php-src's own names,
#     derived from the tree being compiled by php/simd-symbols.sh, are a clean
#     anchor -- and `strip --strip-unneeded` removes them, so this cannot be
#     deferred to a test against the shipped image.
assert_simd_dispatch_present() {
  local src="$1"; shift
  local names found=0 with_simd=0 sym syms dis probes_target=0

  case "$(uname -m)" in
    x86_64) ;;
    aarch64) assert_neon_base64_present "$src" "$@"; return 0 ;;
    *) echo "FATAL: no SIMD assertion is defined for $(uname -m) -- add one before building here" >&2
       exit 1 ;;
  esac

  names="$(bash "$HERE/simd-symbols.sh" "$src")"
  if grep -q 'ax_cv_have_func_attribute_target' configure 2>/dev/null; then probes_target=1; fi

  # The two derivations are each other's control. A branch that carries
  # target-attributed code must also probe for the attribute, and one that does
  # not must not -- so an extractor that quietly stopped matching, or a branch
  # that grew SIMD without this noticing, is a hard failure rather than a
  # cheerful "nothing to check".
  if [ -z "$names" ]; then
    [ "$probes_target" -eq 0 ] || {
      echo "FATAL: ./configure probes for __attribute__((target)) but php/simd-symbols.sh found no" \
           "target-attributed function in this source tree. The extractor has gone stale, and the" \
           "SIMD assertion would silently check nothing." >&2; exit 1; }
    SIMD_CHECK_RESULT="none-in-this-branch"
    echo "note: php ${PHP_VERSION} declares no target-attributed SIMD (7.0-7.3 predate it) and its configure does not probe for the attribute"
    return 0
  fi
  [ "$probes_target" -eq 1 ] || {
    echo "FATAL: this source tree declares target-attributed functions but its ./configure never" \
         "probes for the attribute -- one of the two derivations is wrong." >&2; exit 1; }

  for bin in "$@"; do
    syms="$(nm "$bin" 2>/dev/null)" \
      || { echo "FATAL: nm could not read $bin" >&2; exit 1; }
    # Positive control: this has to be an unstripped binary with a real symbol
    # table, or every name below is "absent" for the wrong reason.
    [ "$(wc -l <<<"$syms")" -gt 100 ] \
      || { echo "FATAL: $bin has almost no symbols -- it is stripped, and the check below would" \
                "report every php-src implementation missing regardless of the truth" >&2; exit 1; }
    found=0; with_simd=0
    for sym in $names; do
      grep -qE "[[:space:]]${sym}\$" <<<"$syms" || continue
      found=$((found + 1))
      dis="$(objdump -d --disassemble="$sym" "$bin" 2>/dev/null || true)"
      if grep -qE 'pshufb|vpshufb|pclmul|pcmpistri|vpermi2b|sha256rnds2' <<<"$dis"; then
        with_simd=$((with_simd + 1))
      fi
    done
    [ "$found" -gt 0 ] || {
      echo "FATAL: $bin contains none of php-src's $(wc -w <<<"$names") target-attributed" \
           "implementations. ./configure decided __attribute__((target)) is unavailable and every" \
           "one of them was preprocessed out -- check ax_cv_have_func_attribute_target in" \
           "config.log; a warning from any flag on configure's command line is enough to do it." >&2
      exit 1; }
    [ "$with_simd" -gt 0 ] || {
      echo "FATAL: $bin defines $found of php-src's target-attributed implementations but not one of" \
           "them contains a vector instruction -- they compiled as scalar code." >&2
      exit 1; }
    echo "ok: $(basename "$bin") defines $found of $(wc -w <<<"$names") php-src SIMD implementations, $with_simd of them carrying vector instructions"
  done
  SIMD_CHECK_RESULT="${with_simd}/${found} php-src implementations carry vector instructions"
  SIMD_FOUND="$found"
}

# assert_neon_base64_present <php-src-dir> <unstripped-binary> [<binary>...]
#
# The aarch64 counterpart of the x86 check above. php-src has no
# target-attributed code for aarch64 and nothing a configure probe can switch
# off: from 7.4 on, ext/standard/base64.c carries NEON encode/decode loops
# (neon_base64_encode/neon_base64_decode, plus strrev/addslashes in string.c)
# behind a plain #if __aarch64__, always_inline'd into the exported
# php_base64_encode[_ex]/php_base64_decode_ex. So the failure mode the x86
# check guards cannot happen here, but the result is still asserted rather
# than assumed: the NEON loops are the only code in those functions that uses
# de-interleaving structure loads/stores (vld3q_u8/vst4q_u8 to encode,
# vld4q_u8/vst3q_u8 to decode), and they must be there.
#
# Per symbol, never whole-binary -- vendored OpenSSL carries NEON of its own on
# the legacy era, the same attribution problem as on x86. A function's
# ".cold"/".part" pieces are read with it, since -freorder-blocks-and-partition
# under a profile that never ran base64 is free to move the vector loop there.
assert_neon_base64_present() {
  local src="$1"; shift
  local bin base syms parts dis enc_ok dec_ok

  if ! grep -q 'neon_base64_decode' "$src/ext/standard/base64.c" 2>/dev/null; then
    SIMD_CHECK_RESULT="none-in-this-branch"
    echo "note: php ${PHP_VERSION} has no aarch64 NEON code in ext/standard/base64.c (added in 7.4) and no target-attributed SIMD on this arch -- nothing to check"
    return 0
  fi

  for bin in "$@"; do
    syms="$(nm "$bin" 2>/dev/null)" \
      || { echo "FATAL: nm could not read $bin" >&2; exit 1; }
    [ "$(wc -l <<<"$syms")" -gt 100 ] \
      || { echo "FATAL: $bin has almost no symbols -- it is stripped, and the check below would" \
                "report the NEON loops missing regardless of the truth" >&2; exit 1; }

    enc_ok=0; dec_ok=0
    for base in php_base64_encode php_base64_encode_ex; do
      parts="$(awk -v b="$base" '$3 == b || index($3, b ".") == 1 { print $3 }' <<<"$syms" | sort -u)"
      [ -n "$parts" ] || continue
      dis="$(for p in $parts; do objdump -d --disassemble="$p" "$bin" 2>/dev/null || true; done)"
      if grep -qE '[[:space:]]ld3[[:space:]]+\{v' <<<"$dis" && grep -qE '[[:space:]]st4[[:space:]]+\{v' <<<"$dis"; then
        enc_ok=1
      fi
    done
    parts="$(awk '$3 == "php_base64_decode_ex" || index($3, "php_base64_decode_ex.") == 1 { print $3 }' <<<"$syms" | sort -u)"
    [ -n "$parts" ] || {
      echo "FATAL: $bin defines no php_base64_decode_ex -- the anchor this check reads is gone, so" \
           "it would measure nothing" >&2; exit 1; }
    dis="$(for p in $parts; do objdump -d --disassemble="$p" "$bin" 2>/dev/null || true; done)"
    if grep -qE '[[:space:]]ld4[[:space:]]+\{v' <<<"$dis" && grep -qE '[[:space:]]st3[[:space:]]+\{v' <<<"$dis"; then
      dec_ok=1
    fi

    [ "$enc_ok" -eq 1 ] || {
      echo "FATAL: no php_base64_encode[_ex] in $bin carries the ld3/st4 of neon_base64_encode --" \
           "ext/standard/base64.c's aarch64 NEON loop did not reach the binary" >&2; exit 1; }
    [ "$dec_ok" -eq 1 ] || {
      echo "FATAL: php_base64_decode_ex in $bin does not carry the ld4/st3 of neon_base64_decode --" \
           "ext/standard/base64.c's aarch64 NEON loop did not reach the binary" >&2; exit 1; }
    echo "ok: $(basename "$bin") -- php_base64_encode/decode carry php-src's NEON loops (ld3/st4, ld4/st3)"
  done
  SIMD_CHECK_RESULT="neon: 2/2 php-src base64 functions carry NEON structure loads/stores"
  SIMD_FOUND=2
}

# assert_php_src_hardening <unstripped-binary> [<binary>...]
#
# tests/assert-elf-hardening.sh asserts PIE, full RELRO and a non-executable
# stack, which are link properties and therefore whole-binary facts. Two further
# checks are code properties that a whole-binary count cannot establish on the
# legacy era:
#
#   __*_chk symbols  (proof that -D_FORTIFY_SOURCE=3 took) are undefined
#     references resolved from glibc, contributed by any code that calls a
#     fortifiable function.
#   endbr64 landing pads (proof that -fcf-protection took) are emitted per
#     compiled function by whoever compiled it.
#
# On 7.0-8.0 most of the binary is not php-src: on 7.4 the vendored static
# archives carry 6,881 of the shipped binary's 17,654 endbr64 (libcrypto.a 5,728,
# libssl.a 1,124, libicutest.a 29), so php-src could lose -fcf-protection and the
# count would stay far above zero. The flags are set globally, so php-src and the
# vendored deps share them today; attributing the property to code we built keeps
# the check valid if a change ever scopes them differently.
#
# The anchor is php-src's own symbol prefixes: across every vendored static
# archive and ImageMagick's shared libraries, the number of defined symbols
# starting zend_/php_/_php_/zif_/zm_ is zero.
#
# One objdump pass, attributed by enclosing symbol, because thirty
# --disassemble= invocations each re-parse the whole binary.
# --disassemble= invocations each re-parse the whole binary.
assert_php_src_hardening() {
  local bin out total endbr chk bti pct

  for bin in "$@"; do
    out="$(objdump -d "$bin" 2>/dev/null | awk '
      /^[0-9a-f]+ <.*>:$/ {
        sym = $2; gsub(/[<>:]/, "", sym);
        php = (sym ~ /^(zend_|php_|_php_|zif_|zm_)/);
        first = 1;
        next
      }
      # aarch64 (-mbranch-protection=standard): a function entry is a BTI
      # landing pad when it starts with "bti c"/"bti jc", or with paciasp/
      # pacibsp, which BTI also accepts as one -- gcc and clang emit the PAC
      # form instead of a separate bti on every function that saves LR
      # (checked on the trixie gcc 14 and clang 19 under this cflags.sh output).
      # Neither mnemonic exists on x86_64, so this counter stays 0 there.
      php && first && /\t/ { total++; if ($0 ~ /endbr64/) endbr++; if ($0 ~ /\t(bti|paciasp|pacibsp)(\t|$)/) bti++; first = 0 }
      # The call target has to *end* at _chk. Unanchored, this also matched
      # __stack_chk_fail, which -fstack-protector-strong emits in most functions,
      # so the counter stayed non-zero with _FORTIFY_SOURCE=0.
      # "call" is x86_64; aarch64 spells a direct call "bl".
      php && /call/ && /__[a-z0-9_]+_chk(@plt)?>/ { chk++ }
      php && /\tbl\t/ && /__[a-z0-9_]+_chk(@plt)?>/ { chk++ }
      END { printf "%d %d %d %d", total+0, endbr+0, chk+0, bti+0 }')" \
      || { echo "FATAL: objdump could not disassemble $bin" >&2; exit 1; }
    read -r total endbr chk bti <<<"$out"

    # Positive control for both assertions below: if no php-src function was
    # found at all -- a stripped binary, a changed objdump format, a prefix that
    # stopped matching -- then "0 of 0 lack endbr64" and "0 __*_chk call sites"
    # would both be reported as absences of a problem rather than as a broken
    # measurement.
    [ "$total" -gt 100 ] || {
      echo "FATAL: found only $total php-src functions in $bin (expected thousands). The binary is" \
           "stripped or the symbol prefixes no longer identify php-src -- the hardening attribution" \
           "below measures nothing." >&2; exit 1; }

    case "$(uname -m)" in
      x86_64)
        pct=$((100 * endbr / total))
        # -fcf-protection=full puts an endbr64 at every function entry, but a
        # handful of entries legitimately lack one and the share moves with
        # unrelated flags (7.4: 89% with _FORTIFY_SOURCE off, ~95% on). The
        # discriminating gap is 89-vs-0: with -fcf-protection dropped the ratio
        # was exactly 0 of 5065. 50 sits in the middle of that gap.
        # move with flags that are none of this check's business.
        [ "$pct" -ge 50 ] || {
          echo "FATAL: only $endbr of $total php-src functions in $bin start with endbr64 (${pct}%)." \
               "-fcf-protection did not reach php-src's own compiles. The whole-binary count cannot" \
               "see this on the legacy era -- the vendored static archives supply thousands." >&2
          exit 1; }
        ;;
      aarch64)
        # The same assertion for -mbranch-protection=standard, with the same 50%:
        # the gap that matters is "most entries" against "none", since neither
        # trixie's gcc nor the gcc:16 image enables branch protection by default.
        # Like CET's IBT/SHSTK note on x86, the GNU_PROPERTY_AARCH64_FEATURE_1
        # BTI/PAC note is not asserted: it is the AND over every input object,
        # gold (the gcc path's linker) does not emit it, and its absence is not a
        # property of php-src.
        pct=$((100 * bti / total))
        [ "$pct" -ge 50 ] || {
          echo "FATAL: only $bti of $total php-src functions in $bin start with a BTI landing pad" \
               "(bti/paciasp, ${pct}%). -mbranch-protection did not reach php-src's own compiles." >&2
          exit 1; }
        ;;
      *) pct=-1 ;;
    esac

    [ "$chk" -gt 0 ] || {
      echo "FATAL: no php-src function in $bin calls a __*_chk entry point. -D_FORTIFY_SOURCE did not" \
           "reach php-src's own compiles; the undefined __*_chk references in the binary are the" \
           "vendored dependencies'." >&2
      exit 1; }

    if [ "$(uname -m)" = aarch64 ]; then
      echo "ok: $(basename "$bin") -- $bti/$total php-src functions start with bti/paciasp (${pct}%), $chk php-src __*_chk call sites"
    elif [ "$pct" -ge 0 ]; then
      echo "ok: $(basename "$bin") -- $endbr/$total php-src functions carry endbr64 (${pct}%), $chk php-src __*_chk call sites"
    else
      echo "ok: $(basename "$bin") -- $chk php-src __*_chk call sites (endbr64 is x86_64-only, skipped on $(uname -m))"
    fi
  done
  HARDENING_PHP_SRC="endbr64 ${endbr}/${total} php-src functions, ${chk} __*_chk call sites"
  [ "$(uname -m)" != aarch64 ] || HARDENING_PHP_SRC="bti/paciasp ${bti}/${total} php-src functions, ${chk} __*_chk call sites"
  [ "$pct" -ge 0 ] || HARDENING_PHP_SRC="${chk} __*_chk call sites (endbr64 skipped on $(uname -m))"
}

# assert_no_ifunc_symbols <binary> [<binary>...]
#
# The configure-time canary proves the ifunc probe was answered "no". This
# proves the answer reached the binaries, which is the property ThinLTO
# actually needs: one ifunc that survives is one alias edge in the summary
# index, and ld.lld segfaults on the next build rather than here.
assert_no_ifunc_symbols() {
  local bin syms n control
  # Positive control on the same instrument, taken once: libc is full of defined
  # IFUNC symbols, so if this matcher cannot find any there it cannot have found
  # any in php either and every "0" below would mean nothing.
  control="$(readelf -sW --dyn-syms /lib/*/libc.so.6 2>/dev/null | awk '$4=="IFUNC" && $7!="UND"' | wc -l)"
  [ "$control" -gt 0 ] \
    || { echo "FATAL: the IFUNC matcher found none in libc -- it cannot measure anything, so the counts below prove nothing" >&2; exit 1; }
  for bin in "$@"; do
    syms="$(readelf -sW --dyn-syms "$bin")" \
      || { echo "FATAL: readelf could not read the dynamic symbols of $bin" >&2; exit 1; }
    # Defined only: an undefined IFUNC reference is glibc's business (memcpy
    # and friends), not php's, and nothing here can or should remove those.
    n="$(awk '$4=="IFUNC" && $7!="UND"' <<<"$syms" | wc -l)"
    [ "$n" -eq 0 ] \
      || { echo "FATAL: $bin still defines $n ifunc symbol(s) despite ax_cv_have_func_attribute_ifunc=no; ThinLTO will segfault ld.lld" >&2
           awk '$4=="IFUNC" && $7!="UND" {print "  " $8}' <<<"$syms" >&2; exit 1; }
  done
  echo "ok: all $# shipped binaries define no ifunc symbols (control: libc defines $control)"
}

# The image-visible record of what this build did. tests/test-pgo.sh reads it
# and cross-checks the pgo= line against matrix.json, so a version that
# silently stopped taking PGO fails a test instead of shipping quietly slower.
write_build_record() {  # write_build_record <key=value>...
  mkdir -p "$BUILD_RECORD_DIR"
  {
    printf 'php_version=%s\n' "$PHP_VERSION"
    printf 'php_era=%s\n' "$PHP_ERA"
    printf 'uarch=%s\n' "$UARCH"
    printf 'pgo=%s\n' "$PGO"
    printf 'compiler=%s\n' "${COMPILER:-clang}"
    printf 'lto=%s\n' "$([ "${COMPILER:-clang}" = gcc ] && echo none || echo thin)"
    printf 'cflags=%s\n' "$CFLAGS"
    printf 'ldflags=%s\n' "$LDFLAGS"
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "${BUILD_RECORD_DIR}/pgo.txt"
  echo "=== ${BUILD_RECORD_DIR}/pgo.txt"
  cat "${BUILD_RECORD_DIR}/pgo.txt"
}

# Before either path and before the long compile: does the thing both paths are
# asserted with actually discriminate on this toolchain? It runs for PGO=false
# builds too, whose fallback asserts .text.hot is *absent* -- which an equally
# dead discriminator would also satisfy.
bash "$HERE/pgo/discriminator-control.sh" "$BASE_CFLAGS $LTO_CFLAGS" "$BASE_LDFLAGS $LTO_LDFLAGS"

# Why the profile flag is not in CFLAGS
#
# php-src probes __attribute__((target(...))) with AX_GCC_FUNC_ATTRIBUTE, which
# compiles and links a probe and accepts the attribute only if stderr came back
# *empty*. Under -fprofile-use clang emits a -Wbackend-plugin
# profile-hash-mismatch warning on the probe's own main(), so the answer is
# "no", HAVE_FUNC_ATTRIBUTE_TARGET is never defined and every ZEND_INTRIN_*
# dispatch function in php-src is preprocessed out. Two builds identical but for
# this measured pshufb 0 vs 48, pclmul 0 vs 84, sha256rnds2 0 vs 32, and
# base64_decode ~134x slower. The probe links, so LDFLAGS reaches it too and the
# profile flag cannot hide there either.
#
# It is the third compiler diagnostic that made an autoconf probe answer wrongly
# (ZEND_BROKEN_SPRINTF, PHP_READDIR_R_TYPE, func_attribute_target); flags that
# change what the compiler *says* stay out of ./configure.
#
# So ./configure sees one flag set with no profile flag in it, and both passes
# are driven by php-src's own PROF_FLAGS knob on the make command line.
# configure.ac bakes CFLAGS_CLEAN="$CFLAGS $(PROF_FLAGS)" and CXXFLAGS="...
# $(PROF_FLAGS)", and every compile rule, both program links (BUILD_CLI,
# BUILD_FPM) and the shared-module link_cmd expand $(CFLAGS_CLEAN) -- checked in
# 8.5.0's configure.ac/build/php.m4/sapi config.m4 and in 7.0.33's
# acinclude.m4 -- so the flag reaches the link that has to pull in
# libclang_rt.profile as well as the compiles.
php_set_pass_flags "$LTO_CFLAGS" "$LTO_LDFLAGS"
php_configure

record=()
if [ "$PGO" = true ]; then
  echo "=== pass 1: instrumented"
  rm -rf "$PROFRAW_DIR"; mkdir -p "$PROFRAW_DIR"
  php_make PROF_FLAGS="-fprofile-generate=$PROFRAW_DIR"

  # The corpus's prestashop app needs a real MySQL/MariaDB server to train
  # against; the corpus image ships only its app tree and a pre-populated datadir
  # (see php/pgo/corpus/prestashop/db-up.sh). Every PGO tier's corpus carries
  # prestashop and no PGO=false build trains, so the server is installed here,
  # only when training is about to run. Fatal on failure: a run that silently
  # skipped PrestaShop would ship a profile that looks complete and is not.
  apt-get update && apt-get install -y --no-install-recommends mariadb-server \
    || { echo "FATAL: apt-get install mariadb-server failed -- cannot train the prestashop corpus app" >&2; exit 1; }
  command -v mariadbd >/dev/null 2>&1 || command -v mysqld >/dev/null 2>&1 \
    || { echo "FATAL: mariadb-server installed but neither mariadbd nor mysqld is on PATH" >&2; exit 1; }
  echo "ok: mariadb-server installed for training"

  echo "=== training"
  PGO_TRAIN_SUMMARY="$TRAIN_SUMMARY" \
    bash "$HERE/pgo/train.sh" "$PWD/sapi/cli/php" "$PGO_CORPUS" "$PGO_CORPUS_SRC" "$PROFRAW_DIR"
  [ -f "$TRAIN_SUMMARY" ] || { echo "FATAL: train.sh wrote no summary" >&2; exit 1; }
  # Parsed, not sourced: `apps=laravel=12.66.0 symfony=7.4.16 ...` sourced by
  # bash is three assignments, so apps would come out as just the laravel pair
  # and the corpus cross-check in tests/test-pgo.sh would compare a truncated
  # string against the full manifest.
  summary_field() { sed -n "s/^${1}=//p" "$TRAIN_SUMMARY" | head -1; }
  requests="$(summary_field requests)"
  profraw_files="$(summary_field profraw_files)"
  iterations_per_path="$(summary_field iterations_per_path)"
  apps="$(summary_field apps)"

  # A flat merge is the wrong merge. llvm-profdata sums counters, so a
  # workload's share of the profile is its raw instruction count, and those
  # differ by two orders of magnitude here: WordPress is the slowest app and
  # dominates, while Symfony, twenty times faster per request, came out at about
  # 3% of the profile mass. Flat-merged, the image measured laravel +7..14% and
  # wordpress +2..7% against a plain ThinLTO build, but symfony -6..-13%,
  # reproducibly.
  #
  # So each workload is merged on its own and weighted so the parts carry
  # comparable mass. The weight is derived from the profiles themselves, so no
  # fixed ratio goes stale when a corpus app is added or a framework gets faster;
  # llvm-profdata's -weighted-input multiplies a whole input's counters.
  #
  # The statistic is `Total count` from --detailed-summary, not the busiest
  # single function: which function tops the list can flip between two builds of
  # the same source (the tracing JIT compiles a hot loop at a slightly different
  # point), which made the weights jump 6x between adjacent versions. A total
  # over every counter cannot flip that way.
  weights=""
  case "${COMPILER:-clang}" in
  clang)
    echo "=== merging profile (one part per workload, balanced)"
    labels="$(summary_field labels)"
    [ -n "$labels" ] || { echo "FATAL: the training summary names no profile labels" >&2; exit 1; }
    mass_of() { llvm-profdata show --detailed-summary "$1" | awk '/^Total count:/ {print $3}'; }

    parts=(); masses=(); max_mass=0
    for label in $labels; do
      part="/tmp/pgo-part-${label}.profdata"
      # No glob-expands-to-nothing: a label with no .profraw means a workload
      # train.sh reported as run left nothing behind.
      files=("$PROFRAW_DIR"/"${label}"-*.profraw)
      [ -e "${files[0]}" ] || { echo "FATAL: workload '$label' produced no .profraw files" >&2; exit 1; }
      llvm-profdata merge -output="$part" "${files[@]}"
      mass="$(mass_of "$part")"
      [ -n "$mass" ] && [ "$mass" -gt 0 ] 2>/dev/null \
        || { echo "FATAL: workload '$label' merged to a profile whose total count is '$mass'" >&2; exit 1; }
      parts+=("$part"); masses+=("$mass")
      [ "$mass" -le "$max_mass" ] || max_mass="$mass"
      echo "  $label: total count $mass"
    done

    weighted=(); i=0
    for part in "${parts[@]}"; do
      # Rounded, not truncated: integer truncation turns a 1.9x gap into x1 and
      # makes the weight jump on a rounding boundary for no real change.
      w=$(( (max_mass + masses[i] / 2) / masses[i] ))
      [ "$w" -ge 1 ] || w=1
      weighted+=("-weighted-input=${w},${part}")
      label="$(basename "$part" .profdata)"; label="${label#pgo-part-}"
      weights="${weights:+${weights} }${label}=x${w}"
      echo "  weight x${w} for ${label} (total count ${masses[i]})"
      i=$((i + 1))
    done
    llvm-profdata merge -output="$PROFDATA" "${weighted[@]}"
    show="$(llvm-profdata show "$PROFDATA")"
    printf '%s\n' "$show" | tail -6
    total_functions="$(awk '/^Total functions:/ {print $3}' <<<"$show")"
    max_count="$(awk '/^Maximum function count:/ {print $4}' <<<"$show")"
    [ -n "$total_functions" ] && [ "$total_functions" -gt 0 ] 2>/dev/null \
      || { echo "FATAL: the merged profile describes $total_functions functions" >&2; exit 1; }
    # Derived, not a magic threshold: every HTTP request train.sh made runs the
    # engine's hottest function far more than once, so a profile whose busiest
    # function ran fewer times than there were requests did not record the
    # workload -- it recorded startup, or an error path that returned early.
    [ -n "$max_count" ] && [ "$max_count" -gt "${requests:?train summary has no request count}" ] 2>/dev/null \
      || { echo "FATAL: the profile's busiest function ran $max_count times for $requests requests -- the workload was not recorded" >&2; exit 1; }
    echo "ok: profile covers $total_functions functions, busiest ran $max_count times over $requests requests"
    PROF_FLAGS_USED="-fprofile-use=$PROFDATA"
    profdata_sha256="$(sha256sum "$PROFDATA" | awk '{print $1}')"
    profile_merge="balanced-by-total-count"
    ;;
  gcc)
    # gcc has no separate raw-profile format to merge: -fprofile-generate=DIR
    # writes .gcda straight into DIR, one file per compiled object, and every
    # process run against the same instrumented tree accumulates into the same
    # files (libgcov reads the existing .gcda at exit and adds to it). train.sh's
    # cli-then-per-app sequence is therefore the merge, with no llvm-profdata
    # step and no per-workload weighting.
    echo "=== gcc profile: accumulated in place under $PROFRAW_DIR (no separate merge step)"
    gcda_count="$(find "$PROFRAW_DIR" -name '*.gcda' | wc -l)"
    [ "$gcda_count" -gt 0 ] || { echo "FATAL: no .gcda files under $PROFRAW_DIR after training -- pass 2 would build unguided" >&2; exit 1; }
    echo "ok: $gcda_count .gcda file(s) present under $PROFRAW_DIR"
    total_functions="n/a-gcc"
    max_count="n/a-gcc"
    # -fprofile-partial-training: most PECL extensions' code is not on any
    # corpus request path, and without this flag gcc treats an unexercised
    # function as *guaranteed cold* rather than merely unmeasured, which can
    # demote code the training workload simply never reached. -Wno-coverage-mismatch
    # tolerates a source line-map drift between pass 1 and pass 2 objects (LTO
    # can reorder inlining decisions between passes); both are gcc >=12 flags,
    # present in trixie's default gcc.
    PROF_FLAGS_USED="-fprofile-use=$PROFRAW_DIR -fprofile-partial-training -Wno-coverage-mismatch -Wno-missing-profile"
    profdata_sha256="n/a-gcc"
    profile_merge="flat-accumulated-in-place"
    ;;
  esac

  echo "=== pass 2: profile-guided$([ "${COMPILER:-clang}" = gcc ] && echo '' || echo ' + lto')"
  make clean
  php_make PROF_FLAGS="$PROF_FLAGS_USED"

  record=(
    "prof_flags=$PROF_FLAGS_USED"
    "profdata_sha256=$profdata_sha256"
    "profile_functions=$total_functions"
    "profile_max_function_count=$max_count"
    "training_requests=$requests"
    "training_profraw_files=${profraw_files:-}"
    "training_iterations_per_path=${iterations_per_path:-}"
    "training_corpus=${apps:-}"
    "profile_merge=$profile_merge"
    "profile_weights=${weights}"
  )
else
  echo "=== single pass: thinlto only, no profile (PGO=false for php ${PHP_VERSION})"
  php_make
  record=("prof_flags=")
fi

# Before php_install, which strips: php-src's implementations are static symbols
# and the names this needs are gone afterwards.
assert_simd_dispatch_present "$PWD" "$PWD/sapi/cli/php" "$PWD/sapi/fpm/php-fpm"
assert_php_src_hardening "$PWD/sapi/cli/php" "$PWD/sapi/fpm/php-fpm"

php_install
# After php_install, so this measures the stripped binaries that actually ship.
# --strip-unneeded keeps allocated sections, .text.hot among them (verified).
assert_profile_reached_the_link "$([ "$PGO" = true ] && echo yes || echo no)" \
  /usr/local/bin/php /usr/local/sbin/php-fpm
assert_no_ifunc_symbols /usr/local/bin/php /usr/local/sbin/php-fpm
# amd64 only: arm64 has no glibc check of this kind, its v3 (armv9-a) images
# simply fault on an older core.
if [ "$(dpkg --print-architecture)" = amd64 ]; then
  assert_isa_note "$([ "$UARCH" = v3 ] && echo v3 || echo baseline)" \
    /usr/local/bin/php /usr/local/sbin/php-fpm
fi
write_build_record "discriminator_control=ok" "ifunc_resolvers=disabled" \
  "text_hot_min_percent=${PGO_TEXT_HOT_MIN_PERCENT}" \
  "simd_php_src=${SIMD_CHECK_RESULT:-unchecked}" \
  "simd_php_src_functions=${SIMD_FOUND:-0}" \
  "hardening_php_src=${HARDENING_PHP_SRC:-unchecked}" \
  "vm_kind_config=${ZEND_VM_KIND_CONFIG:?php_configure did not set ZEND_VM_KIND_CONFIG}" \
  "${record[@]+"${record[@]}"}"
stage_runtime_deps

/usr/local/bin/php -v
