#!/usr/bin/env bash
# Configure, compile and install PHP. Run from the unpacked source tree by the
# Dockerfile's php-build stage, which exposes its build args as environment.
#
# Split out of the Dockerfile so the compile has seams: task 17 needs to drive
# make more than once for two-pass PGO, and php-src already supports that
# natively -- `make prof-gen` / `make prof-use` re-enter make with
# PROF_FLAGS=-fprofile-generate|-fprofile-use, and CFLAGS_CLEAN carries
# $(PROF_FLAGS) through to every compile rule. php_make() below is the single
# place that drives a compile, so those passes go there rather than into a new
# copy of this file.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PHP_VERSION="${PHP_VERSION:?php/build.sh needs PHP_VERSION}"
PHP_ERA="${PHP_ERA:-modern}"
UARCH="${UARCH:-baseline}"

# Empty for the modern era, which links against what debian ships. The legacy
# era (task 14) points this at the vendored prefix; ldflags.sh turns it into an
# rpath on the binary rather than a global LD_LIBRARY_PATH, which in task 1 made
# a vendored libcurl shadow debian's for every process in the image.
PHP_DEPS_PREFIX="${PHP_DEPS_PREFIX:-}"

# configure-args.sh renders literal text that no shell ever re-expands, so a
# flag that has to carry the prefix as its value (7.x wants --with-openssl=DIR,
# --with-curl=DIR, --with-libxml-dir=DIR ...) cannot be expressed in the
# registry. List those flag names here and the value is spliced in below.
# Task 14/15 populates this; empty leaves every flag exactly as rendered.
PREFIXED_CONFIGURE_FLAGS="${PREFIXED_CONFIGURE_FLAGS:-}"

# The pecl sources are unpacked into ext/ (php/fetch-pecl.sh, task 7) before
# this script runs, so every era can now build core+pecl configure flags.
EXT_SOURCES="${EXT_SOURCES:-all}"

if [ -n "$PREFIXED_CONFIGURE_FLAGS" ] && [ -z "$PHP_DEPS_PREFIX" ]; then
  echo "PREFIXED_CONFIGURE_FLAGS is set but PHP_DEPS_PREFIX is empty" >&2
  exit 1
fi

# The flags reaching ./configure and the flags reaching the compiler are two
# separate knobs on purpose. php/flag-split.sh holds the whole rationale, the
# flag sets themselves, and the two-sided control that proves the split holds --
# it is shared with php/build-shared-ext.sh, which needs exactly the same thing
# for the phpize'd extensions and must not carry a second copy that drifts.
# shellcheck source=php/flag-split.sh
. "$HERE/flag-split.sh"
php_docker_flag_split "$PHP_ERA"

BASE_CFLAGS="$(bash "$HERE/cflags.sh" "$UARCH")"
# The legacy era's opcache optimizer detects integer overflow in its range
# inference (zend_inference.c) by testing the result of a signed add, which is
# undefined behaviour. GCC 16 folds those checks away, and SCCP then proves a
# loop bound that is not true: PrestaShop 8.2.8 on PHP 7.2 spun forever in
# Symfony's XmlFileLoader::validateSchema() on a cold cache, fixed by turning
# off optimizer pass 6 or 8 alone. -fwrapv makes the overflow defined.
if [ "$PHP_ERA" = legacy ]; then
  BASE_CFLAGS="$BASE_CFLAGS -fwrapv"
fi
# -std=gnu17 is in there unconditionally (task 37a, owner ruling) -- see
# php/cflags.sh for why it's pinned on both compilers and every version
# rather than gated to the gcc+legacy combination the compile probes alone
# would have justified.

# CFLAGS/CXXFLAGS/LDFLAGS are no longer exported here. Task 17 drives
# ./configure twice with different flag sets (instrumented, then
# profile-guided), and a flag baked into the Makefile by the first configure is
# not something the second can take back -- so the exports happen in
# php_set_pass_flags() below, once per pass, from these BASE_* values.
# C++17 removed the `register` storage class, and clang rejects it outright in
# that mode (-Wregister is an error there, not a warning). PHP 7.0's
# main/php.h, main/snprintf.h and Zend/zend_string.h still use it, and
# ext/intl's C++ translation units include all three -- so 7.0 cannot be
# compiled with a C++17 front end at all. 7.1 removed the last of them
# (measured: zero occurrences in those three headers from 7.1 on), which is
# why this is a 7.0-only step down and not an era-wide one.
#
# C++11 is the right floor rather than an arbitrary older standard: it is what
# ICU 67.1 -- the ICU this version links (deps/versions.lock) -- requires of
# its consumers, and what ext/intl on this branch was written against. Nothing
# in the 7.0 build needs a later standard; the 7.1-8.0 builds keep C++17.
case "$PHP_VERSION" in
  7.0) CXX_STD="-std=c++11" ;;
  *)   CXX_STD="-std=c++17" ;;
esac
BASE_CXXFLAGS="$BASE_CFLAGS $CXX_STD"
# ImageMagick (task 8) lives at /opt/imagemagick in every era, not under
# PHP_DEPS_PREFIX -- imagick (task 7) needs an rpath to it or the php binary
# can't resolve libMagickWand at runtime; a global LD_LIBRARY_PATH is what
# broke the host curl binary in task 1.
BASE_LDFLAGS="$(bash "$HERE/ldflags.sh" "$PHP_DEPS_PREFIX" /opt/imagemagick)"
export EXTRA_LDFLAGS_PROGRAM="-pie"

if [ -n "$PHP_DEPS_PREFIX" ]; then
  export CPPFLAGS="-I${PHP_DEPS_PREFIX}/include ${CPPFLAGS:-}"
fi
# ext/intl on 7.0-7.3 refers to Locale/Calendar/TimeZone/UnicodeString/...
# unqualified (no `icu::` prefix anywhere in the extension) -- ICU stopped
# injecting `using namespace icu;` by default at ICU 68, which is exactly
# the ceiling deps/versions.lock already pins 67.1 to for that range
# (ICU 68 also dropped the TRUE/FALSE macros ext/intl needs, a harder wall
# with no flag workaround). Task 15 seam (task 14 review) -- unused on 8.0,
# whose ICU 70.1 / newer ext/intl sources already qualify everything with
# `icu::` and needed no such flag (confirmed by task 14's own build).
case "$PHP_VERSION" in
  7.0|7.1|7.2|7.3)
    export CPPFLAGS="-DU_USING_ICU_NAMESPACE=1 ${CPPFLAGS:-}"
    BASE_CXXFLAGS="$BASE_CXXFLAGS -DU_USING_ICU_NAMESPACE=1"
    ;;
esac
# imagick's --with-imagick=/opt/imagemagick (php/ext.json) resolves MagickWand
# via the MagickWand-config script staged alongside it, not pkg-config -- but
# set this unconditionally anyway so anything else that does go through
# pkg-config (present or future) finds ImageMagick's .pc files too.
export PKG_CONFIG_PATH="${PHP_DEPS_PREFIX:+${PHP_DEPS_PREFIX}/lib/pkgconfig:}/opt/imagemagick/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
# PKG_CONFIG_PATH above does not survive to the legacy era's ICU/openssl
# checks: PECL imagick's own ext/imagick/imagemagick.m4 (IM_FIND_
# IMAGEMAGICK, upstream, not ours to patch -- it's fetched fresh by
# fetch-pecl.sh every build) does `export PKG_CONFIG_PATH="$IM_IMAGEMAGICK_
# PREFIX/lib/pkgconfig"` unconditionally, even when --with-imagick=DIR finds
# MagickWand-config directly and never touches pkg-config itself. That runs
# well before intl's PHP_SETUP_ICU in configure.ac's macro order, so by the
# time the ICU check runs, PKG_CONFIG_PATH has been silently reduced to just
# ImageMagick's own pkgconfig dir -- confirmed by tracing config.log's
# ac_cv_env_PKG_CONFIG_PATH_value (the vendored prefix, as exported above)
# against its PKG_CONFIG_PATH cache dump (ImageMagick's alone) in the same
# run. PKG_CONFIG_LIBDIR is a different variable that imagick's m4 never
# touches, and pkg-config consults it alongside whatever PKG_CONFIG_PATH
# ends up as -- so the vendored prefix and the compiler's real default
# search path (queried once, since PKG_CONFIG_LIBDIR *replaces* pkg-config's
# built-in default rather than adding to it) both go there instead, immune
# to the clobber. libcurl's system .pc (legacy era, 8.0 -- not vendored,
# deps/versions.lock caps the vendored copy at 7.0-7.2) depends on that
# default path surviving too, which is exactly why it isn't just the
# vendored prefix on its own here.
if [ -n "$PHP_DEPS_PREFIX" ]; then
  PKG_CONFIG_DEFAULT_PATH="$(pkg-config --variable pc_path pkg-config)"
  export PKG_CONFIG_LIBDIR="${PHP_DEPS_PREFIX}/lib/pkgconfig:/opt/imagemagick/lib/pkgconfig:${PKG_CONFIG_DEFAULT_PATH}"
fi

# --with-curl is the one remaining flag that has to carry the vendored prefix,
# and only on the versions that actually vendor curl. deps/versions.lock caps
# the vendored copy at 7.0-7.2; 7.3-8.0 link trixie's own libcurl. Splicing
# =${PHP_DEPS_PREFIX} onto a version that did not vendor curl is a real
# configure failure on 7.0/7.1 (their ext/curl/config.m4 is pure
# CURL_DIR+curl-config: it would look for ${PHP_DEPS_PREFIX}/bin/curl-config,
# find nothing, and error out) -- so this is derived from the artifact
# build-deps.sh actually produced rather than from a second copy of the version
# range that would then have to be kept in sync with versions.lock by hand.
#
# Detection mechanism per version, read out of each release's own
# ext/curl/config.m4 (not inferred): 7.0/7.1 CURL_DIR + $CURL_DIR/bin/curl-config
# only; 7.2/7.3 pkg-config first (a DIR resolves to
# $DIR/lib/pkgconfig/libcurl.pc) with the curl-config path as fallback;
# 7.4+ pure PKG_CHECK_MODULES(libcurl), where a DIR value is accepted
# syntactically and never read. The vendored prefix therefore has to be
# spliced for 7.0-7.2, and curl-config is present in exactly those builds.
if [ -n "$PHP_DEPS_PREFIX" ] && [ -x "${PHP_DEPS_PREFIX}/bin/curl-config" ]; then
  PREFIXED_CONFIGURE_FLAGS="${PREFIXED_CONFIGURE_FLAGS} --with-curl"
fi

# --with-icu-dir, for the one version that needs it. 7.1 and up try pkg-config
# first in PHP_SETUP_ICU (acinclude.m4) and only when --with-icu-dir was not
# passed at all, so they find the vendored ICU through PKG_CONFIG_LIBDIR and
# must NOT be given a DIR -- passing one there routes them into the legacy
# icu-config branch instead. 7.0's PHP_SETUP_ICU has no pkg-config branch at
# all (measured: zero occurrences of PKG_CONFIG in that macro in 7.0.33, seven
# in 7.1.33): it shells out to icu-config, found either at $PHP_ICU_DIR/bin or
# on $PATH, and errors out with "Unable to detect ICU prefix" when neither
# resolves. Trixie has no system icu-config at all (Debian dropped it, and the
# legacy era does not install libicu-dev anyway), so 7.0 has to be told.
#
# php/ext.json carries the flag itself as a 7.0 override on intl; what is
# derived here is only the *value*, from the artifact deps/build-deps.sh left
# behind. Putting ${PHP_DEPS_PREFIX}/bin on PATH would also work and is not
# done on purpose: it is the LD_LIBRARY_PATH mistake from task 1's spike in a
# different suit -- the same directory holds the vendored `curl` binary for
# 7.0-7.2, which would then shadow /usr/bin/curl for the rest of the build.
case " $(bash "$HERE/configure-args.sh" "$PHP_VERSION" "$EXT_SOURCES" | tr '\n' ' ') " in
  *" --with-icu-dir "*)
    if [ -n "$PHP_DEPS_PREFIX" ] && [ -x "${PHP_DEPS_PREFIX}/bin/icu-config" ]; then
      PREFIXED_CONFIGURE_FLAGS="${PREFIXED_CONFIGURE_FLAGS} --with-icu-dir"
    else
      # A bare --with-icu-dir sets PHP_ICU_DIR=yes, and PHP_SETUP_ICU then
      # looks for "yes/bin/icu-config" -- so this would fail anyway, thirty
      # seconds into configure, with "Unable to detect ICU prefix". Fail here
      # instead, where the reason is legible.
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
    # `sed` exits 0 whether or not it substituted anything, so a flag that is
    # no longer rendered (renamed in ext.json, moved behind a version gate,
    # dropped) silently stops carrying the vendored prefix -- and for
    # --with-openssl that means a legacy build quietly links trixie's OpenSSL
    # 3 instead of the vendored 1.1.1w, which is the exact outcome the legacy
    # era exists to prevent. Nothing downstream would say so: configure would
    # succeed, the compile would succeed, and only smoke.sh's CF-5
    # readelf assertion might notice, after twenty minutes. Assert the
    # substitution happened.
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
  # Not `./configure $(render_configure_args)`: a command substitution used as
  # an argument has its exit status discarded, so the guard inside that
  # function would print its diagnostic, exit the subshell, and ./configure
  # would run anyway with whatever had been printed before the failure. A plain
  # assignment is the form `set -e` actually acts on.
  local args
  args="$(render_configure_args)"
  # shellcheck disable=SC2086  # the rendered flags and cache overrides are meant to word-split
  ./configure $args $CONFIGURE_CACHE_OVERRIDES
  # Task 33: the whole point of COMPILER=gcc. PHP's HYBRID VM pins
  # execute_data/opline into %r14/%r15 via GCC global register variables
  # (Zend/zend_execute.c) when ./configure's own probe decides the compiler
  # supports them -- clang defines __GNUC__ for compatibility but does not
  # implement that GNU extension reliably enough for the probe to accept it,
  # so a clang build always gets HAVE_GCC_GLOBAL_REGS undefined. Both
  # directions are asserted: gcc must get it, and clang -- the control this
  # whole experiment is measured against -- must not, or the premise this
  # task tests no longer holds.
  #
  # %r14/%r15 is the x86_64 pair. On aarch64 the gcc answer depends on the
  # branch, not the compiler: Zend/Zend.m4's global-register probe only knows
  # __aarch64__ (x27/x28, Zend/zend_execute.c) from 7.4 on -- 7.0-7.3 list
  # i386/x86_64 alone, so their probe answers no on arm64 under any gcc and
  # those builds get the plain CALL VM. Which case applies is read out of the
  # probe block itself rather than keyed off a version list, and it is still
  # asserted both ways: a branch whose probe knows aarch64 must get the
  # registers, one whose probe does not must not have them by some other route.
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
      echo "ok: HAVE_GCC_GLOBAL_REGS=1 -- the HYBRID VM will pin execute_data/opline in x27/x28 (aarch64)"
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
    echo "ok: HAVE_GCC_GLOBAL_REGS=1 -- the HYBRID VM will pin execute_data/opline in %r14/%r15"
  elif grep -q '^#define HAVE_GCC_GLOBAL_REGS 1' main/php_config.h; then
    echo "FATAL: COMPILER=clang but HAVE_GCC_GLOBAL_REGS=1 was defined -- this build no longer" \
         "demonstrates the finding task 33 exists to test" >&2
    exit 1
  else
    echo "ok: HAVE_GCC_GLOBAL_REGS is not defined under clang, as task-29h found"
  fi
  assert_sprintf_canary
  assert_readdir_r_canary
  assert_ifunc_canary
  # ifunc is the only attribute this build forces off; everything else php-src
  # probes has to have come back yes.
  assert_attribute_canary "ifunc"
  assert_preserve_none_canary
  assert_configure_make_split

  # Task 37b: tests/smoke.sh's VM-kind expectation needs a build-time answer
  # for the versions it cannot ask at runtime -- 7.0-7.3 have no FFI (ext.json's
  # floor is >=7.4), so there is no `zend_vm_kind()` to call from a shipped
  # image. What decided the VM was already computed two probes up
  # (HAVE_GCC_GLOBAL_REGS -> HYBRID, HAVE_PRESERVE_NONE -> TAILCALL, neither ->
  # the plain CALL VM); this just names the answer so write_build_record can
  # ship it. The two defines are mutually exclusive on every toolchain this
  # project builds (gcc has no preserve_none calling convention; clang has no
  # global register variables), so exactly one of the first two branches can
  # ever be true here -- this does not re-decide anything, only records what
  # the canaries above already asserted.
  if grep -q '^#define HAVE_GCC_GLOBAL_REGS 1' main/php_config.h; then
    ZEND_VM_KIND_CONFIG=hybrid
  elif grep -Eq '^[[:space:]]*#[[:space:]]*define[[:space:]]+HAVE_PRESERVE_NONE[[:space:]]+1' main/php_config.h; then
    ZEND_VM_KIND_CONFIG=tailcall
  else
    ZEND_VM_KIND_CONFIG=call
  fi
  echo "ok: vm_kind_config=$ZEND_VM_KIND_CONFIG (from main/php_config.h)"
}

# The only place a compile is driven. Task 17's PGO passes belong here, which is
# what the pass-through arguments are for (`php_make prof-gen`).
# shellcheck disable=SC2120  # no caller passes goals yet; task 17 will
php_make() {
  # CCACHE_DISABLE when a profile flag is in play, which is what php-src's own
  # prof-gen/prof-use targets do (Makefile.global, 7.0.33:134,143). ccache's
  # -fprofile-use handling depends on it hashing the profile *file*, and a
  # stale hit here would serve objects built without the profile while every
  # other check still passed -- the exact silent degradation this task exists
  # to remove. The passes recompile from scratch either way, since pass 2's
  # flags differ from pass 1's.
  # An empty string, not "0": ${var:+word} expands whenever var is non-empty,
  # and "0" is non-empty -- so the first version of this disabled ccache on
  # every make, including the non-PGO path it was never meant to touch.
  local ccache_off="" arg
  for arg in "$@"; do case "$arg" in PROF_FLAGS=*) ccache_off="CCACHE_DISABLE=1" ;; esac; done
  if make -j"$(nproc)" ${ccache_off:+"$ccache_off"} EXTRA_CFLAGS="$MAKE_ONLY_CFLAGS" "$@"; then
    return 0
  fi
  # A parallel make interleaves the output of sixteen compilers, and when the
  # thing that failed is a linker printing a forty-frame stack trace, the trace
  # arrives shredded across two other jobs' output -- which is exactly what
  # happened while diagnosing the ThinLTO ifunc crash below. Re-run serially so
  # the failing command and everything it printed are legible.
  #
  # This can never turn a failure into a pass: the return is unconditional. If
  # the serial run succeeds, that is a real finding (a race in the parallel
  # build) and it is reported rather than acted on.
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
  # make install only ever writes php-fpm.conf.default and www.conf.default
  # (sapi/fpm/Makefile.frag); task 10 replaces both with real config.
  [ -f /usr/local/etc/php-fpm.conf ] \
    || cp /usr/local/etc/php-fpm.conf.default /usr/local/etc/php-fpm.conf
  [ -f /usr/local/etc/php-fpm.d/www.conf ] \
    || cp /usr/local/etc/php-fpm.d/www.conf.default /usr/local/etc/php-fpm.d/www.conf
  strip --strip-unneeded /usr/local/bin/php /usr/local/sbin/php-fpm
  find /usr/local/lib/php -name '*.a' -delete
}

# Vendored libraries have to reach the runtime image at exactly the path their
# binaries' rpath names. Staging them under /deps-stage lets the runtime stage
# do one unconditional COPY: for PHP_DEPS_PREFIX that directory is simply
# empty in the modern era, which needs nothing; ImageMagick stages in every
# era, since it never depended on PHP_DEPS_PREFIX in the first place.
stage_runtime_deps() {
  mkdir -p /deps-stage
  if [ -n "$PHP_DEPS_PREFIX" ]; then
    mkdir -p "/deps-stage${PHP_DEPS_PREFIX}"
    cp -a "${PHP_DEPS_PREFIX}/lib" "/deps-stage${PHP_DEPS_PREFIX}/"
    # PHP has already linked (php_install ran above); .a/.la are build-time
    # artifacts only -- openssl's and icu's static archives, curl's libtool
    # metadata. Shipping them cost the task 1 spike 16 MB for nothing
    # a running container ever reads (FINDINGS.md, "Measured size").
    find "/deps-stage${PHP_DEPS_PREFIX}/lib" \( -name '*.a' -o -name '*.la' \) -delete
  fi
  # ImageMagick (task 8) lives at its own fixed prefix in every era, not
  # under PHP_DEPS_PREFIX -- stage it unconditionally rather than only when
  # the legacy vendored tree is present.
  if [ -d /opt/imagemagick/lib ]; then
    mkdir -p /deps-stage/opt/imagemagick
    cp -a /opt/imagemagick/lib /deps-stage/opt/imagemagick/
  fi
}

# --------------------------------------------------------------- ThinLTO, PGO
#
# Two knobs, one of them per-version. ThinLTO is unconditional: cross-module
# inlining is the half of this that needs no corpus and cannot be trained
# wrong. PGO is matrix.json's `pgo` flag, passed through by bake, and a version
# that cannot complete two passes sets it to false with a
# pgo_disabled_reason -- scripts/pgo_tiers.py check enforces that the reason
# exists. Plain ThinLTO is the documented fallback, not a failure.
#
# No default for PGO on purpose: an unset build arg silently producing an
# unoptimised binary is exactly the class of quiet degradation this task is
# meant to remove.
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
# instead of running the probe, which is the supported way to answer a probe
# for it -- php-src's own configure.ac does the same thing to ifunc on FreeBSD
# below 12, so "no ifunc resolvers" is a configuration upstream ships, not one
# invented here.
#
# WHY IFUNC IS TURNED OFF: ld.lld 19.1.7 segfaults linking this project's
# php-src with -flto=thin. Measured, not inferred -- the crash is in
# llvm::computeDeadSymbolsAndUpdateIndirectCalls, and with that pass disabled
# (-mllvm -compute-dead=false) it moves to llvm::ModuleSummaryIndex::
# propagateAttributes: both walk the summary index's alias edges, which is
# where a GlobalIFunc lands. Answering the ifunc probe "no" makes the link
# succeed on the first try, with nothing else changed. It reproduces with and
# without a profile, so it is ThinLTO, not PGO.
#
# What it costs: php-src resolves its SIMD implementations through a function
# pointer set in MINIT instead of through the dynamic linker at load time --
# the ZEND_INTRIN_*_RESOLVER / *_FUNC_PTR path, which is the branch every
# toolchain without the ifunc attribute already takes. On 8.5 that is three
# symbols (php_base64_encode_ex, php_base64_decode_ex, php_addslashes; counted
# on a pre-LTO build of this image), plus mbstring's utf-8/utf-16 checks on the
# branches that have them. That is a per-call indirection on a handful of
# functions, against cross-module inlining over the whole of php-src plus the
# static PECL extensions -- and PGO's indirect-call promotion can recover part
# of the indirection. 7.0 has no ifunc resolvers at all (grepped), so the
# override is a no-op there; assert_ifunc_canary derives which branches ask.
CONFIGURE_CACHE_OVERRIDES="ax_cv_have_func_attribute_ifunc=no"

# -ffunction-sections and -z keep-text-section-prefix are applied to BOTH
# passes and to the non-PGO fallback, and that symmetry is the point. Clang
# only gives a function a .text.hot/.text.unlikely section prefix when it has
# something to base hotness on, and llvm's PGOInstrumentation pass is what sets
# it from an IR profile. So with these two flags constant across every build
# this file produces, a `.text.hot` section in the linked binary is a property
# only a build that consumed a profile can have -- which is what
# assert_profile_reached_the_link() below and tests/test-pgo.sh assert, in both
# directions.
#
# .text.unlikely is deliberately NOT that signal: php-src marks 19 (7.0) to 45
# (8.5) files' worth of functions with ZEND_COLD -> __attribute__((cold)), so
# that section exists with or without a profile. ZEND_HOT is defined but used
# nowhere in either release (grepped, both branches), which is why the hot side
# discriminates and the cold side does not.
# Task 33b: gcc's LTO is off, permanently, for this compiler path -- not a
# flag tuning problem. Task 33 found that GCC's whole-program LTRANS pass
# rejects ext/opcache/jit/zend_jit_vm_helpers.c: it declares a global register
# variable after a function definition in the same translation unit, which is
# only checked (and only fails) when LTO re-elaborates the merged program;
# under plain per-TU compilation (what this branch now does, and what
# dementev/php-fpm-with-ext's stock GCC -O2 image has always done) the same
# file compiles cleanly. Fedora disables LTO for php-src for the same class of
# conflict. So: no -flto anywhere in the gcc branch, plain ar/ranlib/nm (the
# gcc-ar/gcc-ranlib/gcc-nm wrappers exist only to read/write LTO bytecode in
# .a archives -- nothing here produces any), variable name kept as LTO_CFLAGS/
# LTO_LDFLAGS because both branches still plug into the same
# php_set_pass_flags call below. -freorder-functions/-freorder-blocks-and-
# partition survive the LTO removal: they are per-TU codegen flags, not LTO,
# and are still what gives a profile-guided gcc build a .text.hot section to
# discriminate on (confirmed against php/pgo/discriminator-control.sh's gcc
# branch, unchanged by this task). -fuse-ld is left unset because the ld-shim
# in the Dockerfile already put the right linker (gcc: gold, for the
# .text.hot fold -- see the Dockerfile comment; that reason is independent of
# LTO) on PATH.
# A revisit of GCC LTO itself -- patching or excluding the one JIT file --
# is future work, not this task's; see task-33-report.md.
case "${COMPILER:-clang}" in
  clang)
    LTO_CFLAGS="-flto=thin -ffunction-sections"
    LTO_LDFLAGS="-flto=thin -fuse-ld=lld -Wl,-z,keep-text-section-prefix"
    ;;
  gcc)
    # -freorder-blocks-and-partition, not just -freorder-functions: measured
    # against php/pgo/discriminator-probe.c on this exact toolchain (gcc 16 /
    # binutils 2.47) -- -freorder-functions alone never emits a .text.hot.*
    # input section at all (every function stays plain .text.NAME regardless
    # of its profile count); adding -freorder-blocks-and-partition is what
    # makes gcc split a profiled-hot function's own hot/cold blocks into
    # .text.hot.NAME / .text.unlikely.NAME. keep-text-section-prefix is a
    # linker option (see the Dockerfile's ld-shim for why it needs gold, not
    # the CFLAGS/LDFLAGS here) so it is not repeated on this line.
    LTO_CFLAGS="-ffunction-sections -freorder-functions -freorder-blocks-and-partition"
    LTO_LDFLAGS="-Wl,-z,keep-text-section-prefix"
    ;;
  *) echo "php/build.sh: unsupported COMPILER=${COMPILER:-<unset>}" >&2; exit 1 ;;
esac

# php_set_pass_flags <extra-cflags> <extra-ldflags>
#
# The one place CFLAGS/CXXFLAGS/LDFLAGS are exported, so both passes are
# guaranteed to differ only by their arguments here. CONFIGURE_ONLY_CFLAGS
# stays out of CXXFLAGS exactly as before -- those three demotions are C-only.
php_set_pass_flags() {
  export CFLAGS="$BASE_CFLAGS $CONFIGURE_ONLY_CFLAGS${1:+ $1}"
  export CXXFLAGS="$BASE_CXXFLAGS${1:+ $1}"
  export LDFLAGS="$BASE_LDFLAGS${2:+ $2}"
}

# assert_profile_reached_the_link <yes|no> <binary> [<binary>...]
#
# "The build printed no errors" cannot tell a profile-guided link apart from
# one where the profile was generated, merged, and then never consumed -- the
# ccache case is real, not hypothetical: if a cached object from an earlier
# non-PGO build were served for every translation unit, everything above would
# still succeed. This is the check that cannot pass that way.
# The floor is a share of the binary's own text, not a byte count, so it does
# not have to be retuned per version or per architecture. Measured on real
# profile-guided builds of this project: 17.7% (7.0), 35.0% (8.5), 36.1% (8.2).
# A ThinLTO-only build measures 0. Five percent sits a factor of three below
# the lowest real build and orders of magnitude above what a stray
# __attribute__((hot)) on one function could produce -- which is the fail-open
# the bare presence check had, since `hot` puts a function in that section with
# no profile involved at all.
# Not env-overridable: a floor a caller can lower is a floor that will be
# lowered the first time it is inconvenient, and it is recorded into the image
# so what the build asserted is legible from the artifact.
PGO_TEXT_HOT_MIN_PERCENT=5

# section_size <readelf -SW output> <section name> -> size in bytes, 0 if absent
#
# Not `awk strtonum()`: that is a gawk extension and the build image has mawk,
# where it silently evaluates to 0 -- which made every section look empty and
# the assertion below fire on a perfectly good binary. The leading "[NN]" is
# stripped first because readelf pads single-digit indices as "[ 4]", which
# splits into two fields and shifts every column.
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

# assert_simd_dispatch_present <php-src-dir> <unstripped-binary> [<binary>...]
#
# The artifact-level half of assert_attribute_canary, and the check that would
# have caught the shipped defect whichever probe misfired: php-src puts every
# vector implementation behind __attribute__((target(...))), so if that
# attribute is unavailable the functions are not merely slow, they do not exist.
#
# It runs on the *build tree* binary, before php_install strips it, and it
# matches php-src's own function names -- both of which are the point:
#
#   * Counting vector instructions in the whole shipped binary cannot work on
#     the legacy era. Vendored OpenSSL 1.1.1w is linked statically there, and
#     libcrypto.a alone carries pshufb 432 / vpshufb 225 / pclmul 196 -- exactly
#     the numbers the shipped php 7.2 binary measures. Every one of them is
#     OpenSSL's; php-src contributed nothing to the count, so the check could
#     not have failed on six of eleven versions.
#   * Matching symbols by ISA suffix does not fix it either: libcrypto.a defines
#     25 symbols that match that convention (ChaCha20_ssse3,
#     RSAZ_1024_mod_exp_avx2, K256_shaext ...). Only php-src's own names,
#     derived from the tree being compiled by php/simd-symbols.sh, are a clean
#     anchor -- and after `strip --strip-unneeded` those names are gone, which
#     is why this cannot be deferred to a test against the shipped image.
assert_simd_dispatch_present() {
  local src="$1"; shift
  local names found=0 with_simd=0 sym syms dis probes_target=0

  case "$(uname -m)" in
    x86_64) ;;
    *) SIMD_CHECK_RESULT="skipped-non-x86_64"
       echo "note: php-src's target-attributed implementations are x86-only; nothing to check on $(uname -m)"
       return 0 ;;
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

# assert_php_src_hardening <unstripped-binary> [<binary>...]
#
# tests/assert-elf-hardening.sh asserts PIE, full RELRO and a non-executable
# stack, which are properties of the *link* and are therefore whole-binary
# facts -- correct as they stand. Two of its checks are not link properties but
# code properties, and those cannot be established from a whole-binary count on
# the legacy era:
#
#   __*_chk symbols  (proof that -D_FORTIFY_SOURCE=3 took) are undefined
#     references resolved from glibc, contributed by any code that calls a
#     fortifiable function.
#   endbr64 landing pads (proof that -fcf-protection took) are emitted per
#     compiled function by whoever compiled it.
#
# On 7.0-8.0 most of the binary is not php-src: measured on 7.4, the vendored
# static archives alone carry 6,881 endbr64 (libcrypto.a 5,728, libssl.a 1,124,
# libicutest.a 29) of the shipped binary's 17,654. php-src could lose
# -fcf-protection entirely and the count would stay comfortably above zero.
#
# It is not a live defect -- php/build.sh sets those flags globally, so php-src
# and the vendored deps share them -- but it is the same hole the SIMD check
# had, and the same thing that would open it: a future change that scopes the
# flags differently. So it is closed the same way, by attributing the property
# to code we built.
#
# The anchor is php-src's own symbol prefixes. Verified rather than assumed:
# across every vendored static archive and ImageMagick's shared libraries, the
# number of defined symbols starting zend_/php_/_php_/zif_/zm_ is zero.
#
# One objdump pass, attributed by enclosing symbol, because thirty
# --disassemble= invocations each re-parse the whole binary.
assert_php_src_hardening() {
  local bin out total endbr chk pct

  for bin in "$@"; do
    out="$(objdump -d "$bin" 2>/dev/null | awk '
      /^[0-9a-f]+ <.*>:$/ {
        sym = $2; gsub(/[<>:]/, "", sym);
        php = (sym ~ /^(zend_|php_|_php_|zif_|zm_)/);
        first = 1;
        next
      }
      php && first && /\t/ { total++; if ($0 ~ /endbr64/) endbr++; first = 0 }
      # The call target has to *end* at _chk. Unanchored, this matched inside
      # __stack_chk_fail, which -fstack-protector-strong emits in most
      # functions -- so the counter was measuring the stack protector and
      # stayed non-zero with _FORTIFY_SOURCE=0. Caught by the negative control,
      # which is the only reason it is not still wrong.
      php && /call/ && /__[a-z0-9_]+_chk(@plt)?>/ { chk++ }
      END { printf "%d %d %d", total+0, endbr+0, chk+0 }')" \
      || { echo "FATAL: objdump could not disassemble $bin" >&2; exit 1; }
    read -r total endbr chk <<<"$out"

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
        # handful of entries legitimately lack one and the exact share moves
        # with unrelated flags -- measured on 7.4: 89% with _FORTIFY_SOURCE
        # turned off against ~95% with it on, which is why an initial 90%
        # threshold fired on the wrong control. The discriminating gap is not
        # 89-vs-95, it is 89-vs-0: with -fcf-protection dropped the ratio was
        # exactly 0 of 5065. 50 sits in the middle of that gap and does not
        # move with flags that are none of this check's business.
        [ "$pct" -ge 50 ] || {
          echo "FATAL: only $endbr of $total php-src functions in $bin start with endbr64 (${pct}%)." \
               "-fcf-protection did not reach php-src's own compiles. The whole-binary count cannot" \
               "see this on the legacy era -- the vendored static archives supply thousands." >&2
          exit 1; }
        ;;
      *) pct=-1 ;;
    esac

    [ "$chk" -gt 0 ] || {
      echo "FATAL: no php-src function in $bin calls a __*_chk entry point. -D_FORTIFY_SOURCE did not" \
           "reach php-src's own compiles; the undefined __*_chk references in the binary are the" \
           "vendored dependencies'." >&2
      exit 1; }

    if [ "$pct" -ge 0 ]; then
      echo "ok: $(basename "$bin") -- $endbr/$total php-src functions carry endbr64 (${pct}%), $chk php-src __*_chk call sites"
    else
      echo "ok: $(basename "$bin") -- $chk php-src __*_chk call sites (endbr64 is x86_64-only, skipped on $(uname -m))"
    fi
  done
  HARDENING_PHP_SRC="endbr64 ${endbr}/${total} php-src functions, ${chk} __*_chk call sites"
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
  # Positive control on the same instrument, taken once: libc is full of
  # defined IFUNC symbols, so if this matcher cannot find any there it cannot
  # have found any in php either and every "0" below would mean nothing.
  # (Measured for the other direction too: a pre-LTO build of this image
  # defines exactly 3.)
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

# Before either path, and before the twenty minutes of compiling: does the
# thing both paths are asserted with actually discriminate on this toolchain?
# Three seconds, and it runs for PGO=false builds too -- the fallback path
# asserts .text.hot is *absent*, which an equally dead discriminator would also
# satisfy.
bash "$HERE/pgo/discriminator-control.sh" "$BASE_CFLAGS $LTO_CFLAGS" "$BASE_LDFLAGS $LTO_LDFLAGS"

# WHY THE PROFILE FLAG IS NOT IN CFLAGS
#
# It used to be, and it cost every PGO image all of php-src's SIMD.
#
# php-src probes __attribute__((target(...))) with AX_GCC_FUNC_ATTRIBUTE, which
# compiles-and-links a probe and then accepts the attribute only if stderr came
# back *empty* (`if test -s conftest.err then ax_cv_have_func_attribute_target=
# no`). Under -fprofile-use clang emits a -Wbackend-plugin profile-hash-mismatch
# warning on the probe's own main(), stderr is non-empty, the answer is "no",
# HAVE_FUNC_ATTRIBUTE_TARGET never gets defined, and every ZEND_INTRIN_*
# dispatch function in php-src is preprocessed out. Measured on two builds
# identical but for this: pshufb 0 vs 48, pclmul 0 vs 84, sha256rnds2 0 vs 32,
# and base64_decode ~134x slower.
#
# This is the third time in this project that a compiler diagnostic has made an
# autoconf probe answer wrongly (ZEND_BROKEN_SPRINTF, PHP_READDIR_R_TYPE, now
# func_attribute_target), and the seam that exists to prevent it was built in
# task 15 and documented at the top of this file: flags that change what the
# compiler *says* stay out of ./configure. That the probe LINKS rather than
# only compiles matters too -- LDFLAGS reaches it, so the profile flag cannot
# be hidden there either.
#
# So: ./configure sees one flag set with no profile flag anywhere in it, and
# both passes are driven by php-src's own PROF_FLAGS knob on the make command
# line. configure.ac bakes CFLAGS_CLEAN="$CFLAGS $(PROF_FLAGS)" and
# CXXFLAGS="... $(PROF_FLAGS)", and every compile rule, both program links
# (BUILD_CLI, BUILD_FPM) and the shared-module link_cmd expand $(CFLAGS_CLEAN)
# -- checked in 8.5.0's configure.ac/build/php.m4/sapi config.m4 and in
# 7.0.33's acinclude.m4, so the flag reaches the link that has to pull in
# libclang_rt.profile as well as the compiles.
#
# One ./configure now instead of two, which is the other half of the same
# point: two configures were only ever needed because the flags differed.
php_set_pass_flags "$LTO_CFLAGS" "$LTO_LDFLAGS"
php_configure

record=()
if [ "$PGO" = true ]; then
  echo "=== pass 1: instrumented"
  rm -rf "$PROFRAW_DIR"; mkdir -p "$PROFRAW_DIR"
  php_make PROF_FLAGS="-fprofile-generate=$PROFRAW_DIR"

  # mariadb-server (task 29b): the corpus's prestashop app (task 29a) needs a
  # real MySQL/MariaDB server to train against -- the corpus image ships only
  # its app tree and a pre-populated datadir, never the server binary itself
  # (php/pgo/corpus/prestashop/db-up.sh's own header explains why). Installed
  # here, in this stage, only when training is about to run: every PGO tier's
  # corpus now carries prestashop (no per-app opt-out, task 29b brief), so
  # every PGO=true build needs it, and no PGO=false build ever does. Fatal on
  # failure like every other apt-get in this Dockerfile -- a training run that
  # silently skipped PrestaShop because the server never came up would ship a
  # profile that looks complete and is not.
  apt-get update && apt-get install -y --no-install-recommends mariadb-server \
    || { echo "FATAL: apt-get install mariadb-server failed -- cannot train the prestashop corpus app" >&2; exit 1; }
  command -v mariadbd >/dev/null 2>&1 || command -v mysqld >/dev/null 2>&1 \
    || { echo "FATAL: mariadb-server installed but neither mariadbd nor mysqld is on PATH" >&2; exit 1; }
  echo "ok: mariadb-server installed for training"

  echo "=== training"
  PGO_TRAIN_SUMMARY="$TRAIN_SUMMARY" \
    bash "$HERE/pgo/train.sh" "$PWD/sapi/cli/php" "$PGO_CORPUS" "$PGO_CORPUS_SRC" "$PROFRAW_DIR"
  [ -f "$TRAIN_SUMMARY" ] || { echo "FATAL: train.sh wrote no summary" >&2; exit 1; }
  # Parsed, not sourced. `apps=laravel=12.66.0 symfony=7.4.16 ...` sourced by
  # bash is three variable assignments, not one -- apps would silently come out
  # as just the laravel pair, and the corpus cross-check in tests/test-pgo.sh
  # would then compare a truncated string against the full manifest.
  summary_field() { sed -n "s/^${1}=//p" "$TRAIN_SUMMARY" | head -1; }
  requests="$(summary_field requests)"
  profraw_files="$(summary_field profraw_files)"
  iterations_per_path="$(summary_field iterations_per_path)"
  apps="$(summary_field apps)"

  # A flat merge is the wrong merge, measured rather than assumed. llvm-profdata
  # sums counters, so a workload's share of the profile is its raw instruction
  # count -- and those differ by two orders of magnitude here. WordPress is the
  # slowest app and dominates; Symfony, twenty times faster per request, came
  # out at about 3% of the profile mass. Flat-merged, the resulting image
  # measured laravel +7..14% and wordpress +2..7% against a plain ThinLTO
  # build, but symfony -6..-13%, reproducibly, across three runs.
  #
  # So each workload is merged on its own and then weighted so the parts carry
  # comparable mass. The weight is derived from the profiles themselves -- no
  # fixed ratio to go stale when a corpus app is added or a framework gets
  # faster -- and llvm-profdata's -weighted-input multiplies a whole input's
  # counters, which is exactly the knob for this.
  #
  # The statistic is `Total count` from --detailed-summary, not the busiest
  # single function. A maximum is one sample: which function happens to top the
  # list can flip between two builds of the same source (the tracing JIT
  # compiles a hot loop at a slightly different point and the interpreter
  # counters stop where it took over), and that made the weights jump by 6x
  # between adjacent versions on the same corpus. A total over every counter in
  # the profile cannot flip that way, which is what makes the weights
  # reproducible.
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
      # train.sh reported as run left nothing behind, which is the silent-failure
      # case this whole task exists to remove.
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
    # process that runs against the same instrumented tree accumulates its
    # counts into the *same* files (libgcov reads the existing .gcda at exit
    # and adds to it) -- train.sh's cli-then-per-app sequence already is the
    # merge, with no llvm-profdata step and, unlike the clang side, no
    # per-workload weighting: this is the simplification the brief allows
    # ("whatever this GCC needs") rather than reimplementing -weighted-input
    # against gcov-tool merge in the same build cycle.
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
write_build_record "discriminator_control=ok" "ifunc_resolvers=disabled" \
  "text_hot_min_percent=${PGO_TEXT_HOT_MIN_PERCENT}" \
  "simd_php_src=${SIMD_CHECK_RESULT:-unchecked}" \
  "simd_php_src_functions=${SIMD_FOUND:-0}" \
  "hardening_php_src=${HARDENING_PHP_SRC:-unchecked}" \
  "vm_kind_config=${ZEND_VM_KIND_CONFIG:?php_configure did not set ZEND_VM_KIND_CONFIG}" \
  "${record[@]+"${record[@]}"}"
stage_runtime_deps

/usr/local/bin/php -v
