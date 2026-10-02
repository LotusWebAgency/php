# syntax=docker/dockerfile:1.27
# One Dockerfile for every published tag; docker-bake.hcl feeds it the matrix.
# Task 6 wires up the modern era (8.1+, debian packages) and core static
# extensions; task 7 adds the six static PECL extensions and imagemagick's
# libraries (task 8) into the binary. Shared modules arrive in task 9, ini
# files in task 10, the entrypoint in task 11, PGO in task 17.
ARG BASE_IMAGE=debian:trixie-slim
ARG PHP_ERA=modern
# Declared global (before any FROM) so the `FROM toolchain-select-${COMPILER}`
# stage-selector below can see it -- a FROM can only resolve a build arg that
# was declared at this scope, not one declared inside a later stage (the
# toolchain-base stage below redeclares ARG COMPILER too, which is what makes
# it reach the shell/ENV inside that stage; this copy is only for the FROM).
ARG COMPILER=clang

# ------------------------------------------------------------- gcc16-toolchain
# Task 37a (owner decision): the ONLY gcc this project ships is GCC 16.2 --
# there is no more "distro gcc" build path (gcc 14, the task-33/33b benchmark
# baseline, is gone; see the toolchain-select-gcc stage below for why Debian's
# own gcc package still gets installed anyway). GCC 16.2 is not packaged for
# trixie or trixie-backports, so its toolchain comes from the official image
# instead of apt, pinned by digest -- the multi-arch INDEX digest, not a
# single-platform manifest, so an arm64 build of this Dockerfile still
# resolves it -- so a retag upstream can't quietly change what a COMPILER=gcc
# build compiles with. That image is itself debian:13-slim plus a from-source
# GCC build installed wholesale under /usr/local -- copied out below by the
# toolchain-select-gcc stage. buildkit only builds/pulls this stage when
# `toolchain` actually resolves to toolchain-select-gcc (COMPILER=gcc), so a
# COMPILER=clang build never pays for it.
FROM gcc:16.2-trixie@sha256:ef558a40d1f13115293feee01526dbdb9aaad7c9c5a00da05f471ce042e855c1 AS gcc16-toolchain

# ---------------------------------------------------------------- toolchain
FROM ${BASE_IMAGE} AS toolchain-base
ARG COMPILER=clang
# The four real binary names COMPILER implies, derived by docker-bake.hcl from
# item.compiler (defaulted here to the clang set, so a bare `docker build`
# with no bake args still works). Bare names, not paths: PATH is about to put
# /usr/lib/ccache first, and ccache's own masquerade symlinks there
# (/usr/lib/ccache/clang, /usr/lib/ccache/gcc, ...) dispatch to the real
# compiler by argv[0] basename -- a name Dockerfile ENV cannot compute from
# COMPILER by itself (clang -> clang++, gcc -> g++ is not a string transform),
# so bake supplies it instead of this stage guessing.
ARG CXX_COMPILER=clang++
ARG AR_COMPILER=llvm-ar
ARG RANLIB_COMPILER=llvm-ranlib
ARG NM_COMPILER=llvm-nm
ENV DEBIAN_FRONTEND=noninteractive
# gcc/g++ are installed unconditionally alongside clang/lld/llvm, but only as
# a build-essential transitive dependency and for the tools (binutils-gold,
# ar/ranlib/nm) both toolchains share -- this is a build-only stage, nothing
# here reaches a shipped image. Nothing ever compiles PHP or a vendored dep
# with THIS gcc: the toolchain-select-gcc stage below puts GCC 16.2 ahead of
# it on PATH for every COMPILER=gcc build, so apt's gcc/g++ binaries are never
# the ones `gcc`/`cc` resolve to. PHP's HYBRID VM pins execute_data/opline
# into %r14/%r15 via GCC global register variables (HAVE_GCC_GLOBAL_REGS,
# Zend/zend_execute.c) -- a GNU-C extension clang does not implement -- so
# COMPILER=gcc is the opt-in path (7.0-8.4, task 37a) that gets that dispatch
# back; COMPILER=clang (8.5) stays the only other option.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      build-essential clang lld llvm gcc g++ binutils-gold ccache pkg-config ca-certificates curl \
      autoconf automake libtool bison re2c make patch xz-utils file \
      gnupg dirmngr python3 dpkg-dev \
    && case "$COMPILER" in clang|gcc) ;; *) echo "COMPILER must be clang or gcc, got COMPILER=$COMPILER" >&2; exit 1 ;; esac
ENV CC=$COMPILER CXX=$CXX_COMPILER AR=$AR_COMPILER RANLIB=$RANLIB_COMPILER NM=$NM_COMPILER
# Carried as a plain ENV (not just the ARG, which does not survive into a
# child stage unless redeclared there) so php/build.sh, php/pgo/train.sh and
# php/pgo/discriminator-control.sh -- none of which re-declare ARG COMPILER --
# can still branch on it by reading the environment.
ENV COMPILER=$COMPILER
ENV PATH=/usr/lib/ccache:$PATH
# Task 33c: gcc's own package (libgcc-14-dev, pulled in by gcc/g++ above)
# ships omp.h in gcc's private include search path, found by #include <omp.h>
# with no -fopenmp flag needed -- it's just a header gcc always carries.
# PECL imagick's config.m4 (upstream, not ours to patch -- see php/build.sh
# below on IM_FIND_IMAGEMAGICK) probes for that header plus a link against
# -lgomp purely to decide "is the active compiler GCC with an OpenMP runtime
# available", and unconditionally adds -lgomp to the statically-linked
# imagick extension when it is -- entirely independent of ImageMagick's own
# --disable-openmp (deps/build-imagemagick.sh), which this leaves untouched.
# That gave the gcc-toolchain path a libgomp NEEDED entry on php/php-fpm that
# the clang path never gets, not because clang's ImageMagick differs but
# because LLVM's own omp.h lives in libomp-dev, which isn't installed here,
# so clang's #include <omp.h> fails outright and imagick's probe never
# reaches the link step at all. Removing gcc's private omp.h before any
# ./configure runs makes gcc answer that probe the same "no OpenMP" way
# clang already does by accident, and the way this project wants everywhere
# (deps/build-imagemagick.sh's own comment on OpenMP thread explosions) --
# nothing else in php-src or any vendored dep includes <omp.h>.
RUN if [ "$COMPILER" = "gcc" ]; then \
      rm -f "$(dirname "$(gcc -print-libgcc-file-name)")/include/omp.h"; \
    fi

# One gcc, one clang (task 37a): the shipped paths are exactly COMPILER=clang
# (Debian trixie's own clang 19, unchanged, toolchain-select-clang is a plain
# passthrough with no extra layer) and COMPILER=gcc (GCC 16.2, overlaid over
# it by toolchain-select-gcc below). `toolchain` resolves to whichever one
# COMPILER names, so a clang build never builds or pulls gcc16-toolchain.
FROM toolchain-base AS toolchain-select-clang

FROM toolchain-base AS toolchain-select-gcc
COPY --from=gcc16-toolchain /usr/local /opt/gcc16
# GCC installs libstdc++.la (and one .la per runtime library) with libdir
# pointing at its original /usr/local prefix, which does not exist once the
# tree sits at /opt/gcc16. libtool resolves every `-lstdc++` -- php-src puts it
# on the link line for ext/intl and the C++ PECL modules -- to that .la, warns
# "library ... was moved", and hardcodes the .la's own directory as RUNPATH.
# That is how php, php-fpm and swoole.so came to carry /opt/gcc16/lib64, a
# directory the runtime image does not have (php resolves libstdc++ from
# Debian's own libstdc++6). With the .la files gone libtool treats -lstdc++ as
# a plain system library and adds no rpath. Nothing here links through a gcc
# runtime .la on purpose; the compiler driver finds the .so files itself.
RUN find /opt/gcc16 -name '*.la' -delete
# Ahead of ccache's own masquerade dir's target search, not ahead of the
# masquerade dir itself: ccache still intercepts every `gcc`/`g++` call (its
# default compiler_check=mtime hashes the size+mtime of whichever real binary
# it resolves to, so a gcc16 object never collides with apt's gcc14 one in the
# shared /root/.cache/ccache mount even though both answer to the same
# masqueraded name), it just now resolves "gcc" to /opt/gcc16/bin/gcc first --
# which is also what keeps the assertion below honest, and what makes apt's
# own gcc/g++ (installed above) unreachable for anything that compiles PHP or
# a vendored dependency.
ENV PATH=/usr/lib/ccache:/opt/gcc16/bin:$PATH
# Same c6832e2 fix, gcc 16's own private omp.h -- PECL imagick's config.m4
# probe reacts to whichever <omp.h> the active $CC finds first, and gcc16
# ships its own copy at a version-specific path this image's own
# `gcc -print-libgcc-file-name` resolves for us, same as apt gcc's removal
# above.
RUN rm -f "$(dirname "$(gcc -print-libgcc-file-name)")/include/omp.h"
# Assert, don't assume: the whole point of this stage is that `gcc`/`cc`
# resolve to GCC 16.2, not to whatever gcc/g++ apt just installed above. A
# stale PATH override or a masquerade regression would otherwise silently
# build with the wrong compiler and still "work".
RUN v="$(gcc -dumpfullversion)"; case "$v" in \
      16.2*) echo "ok: COMPILER=gcc resolves to GCC $v (/opt/gcc16)" ;; \
      *) echo "FATAL: COMPILER=gcc must resolve to GCC 16.2.x, got $v" >&2; exit 1 ;; \
    esac

FROM toolchain-select-${COMPILER} AS toolchain

# ------------------------------------------------------------- imagemagick
# ImageMagick from source (task 8): distro ImageMagick is a permanent CVE
# source and its default OpenMP support causes thread explosions inside FPM
# workers. Built once here rather than once per era: both eras need the exact
# same library at the exact same prefix, so this stage is what deps-modern
# and deps-legacy both derive FROM, not something either one repeats. That
# also means it builds once per (arch, uarch) instead of twice.
FROM toolchain AS imagemagick
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      libpng-dev libjpeg-dev libwebp-dev libtiff-dev libfreetype-dev \
      libheif-dev libde265-dev
COPY deps/build-imagemagick.sh deps/versions.lock deps/fetch-verified.sh /build/deps/
COPY php/cflags.sh php/ldflags.sh /build/php/
RUN --mount=type=cache,target=/var/cache/src,id=php-src-cache,sharing=locked \
    bash /build/deps/build-imagemagick.sh /opt/imagemagick
# Nothing upstream of this sets PKG_CONFIG_PATH; a flat assignment (rather
# than the ${VAR:-} self-reference pattern) avoids buildkit's UndefinedVar
# lint on a variable this stage never declared as an ARG.
ENV PKG_CONFIG_PATH=/opt/imagemagick/lib/pkgconfig

# ------------------------------------------------------------- net-snmp
# net-snmp's client library, vendored for the same reason as ImageMagick: the
# distro copy (libsnmp40t64) hard-depends on libperl5.40, which puts ~49 MB of
# perl in every runtime image and cannot be purged away. Built once for both
# eras (it links Debian's libssl3 -- libssl-dev is installed here for that --
# never the legacy era's vendored, static-only 1.1.1w), in its own stage so it
# neither invalidates nor waits for ImageMagick. The deps stages below COPY the whole prefix (ext-snmp needs bin/net-snmp-config and
# the headers at build time); php/build.sh's stage_runtime_deps ships only the
# library and the MIB files.
FROM toolchain AS net-snmp
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends libssl-dev
COPY deps/build-netsnmp.sh deps/versions.lock deps/fetch-verified.sh /build/deps/
COPY php/cflags.sh php/ldflags.sh /build/php/
RUN --mount=type=cache,target=/var/cache/src,id=php-src-cache,sharing=locked \
    bash /build/deps/build-netsnmp.sh /opt/net-snmp

# ------------------------------------------------------------- deps: modern
# PHP 8.1+ links against what trixie ships; base rebuilds carry the CVE fixes.
FROM imagemagick AS deps-modern
# libpng/libjpeg/libwebp/libfreetype -dev are already installed by the
# imagemagick stage above (ImageMagick itself needs them); GD (built by
# php-build, which inherits from this stage) needs the same headers plus
# libavif-dev, which nothing upstream of here installs.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      libssl-dev libcurl4-openssl-dev libxml2-dev libxslt1-dev libicu-dev \
      libonig-dev libzip-dev libsqlite3-dev libpq-dev zlib1g-dev libzstd-dev \
      libbrotli-dev libavif-dev \
      libsodium-dev libargon2-dev libgmp-dev libreadline-dev libmemcached-dev \
# Task 9's shared extensions, one apt package per non-empty `libs` entry in
# ext.json for every linkage:"shared" extension -- the registry is the source
# of truth here, not any list hand-copied into this file. libbrotli-dev is
# already above (imagick/gd need it too). libmcrypt-dev is real and installs
# cleanly on trixie, kept staged for task 15's legacy build even though
# mcrypt's php<8.0 constraint means nothing here builds it yet. imap's
# libc-client-dev has no trixie package at all (Debian dropped c-client
# entirely) so it -- and the libkrb5-dev only imap would use -- is not here;
# see the task 9 report. libpcre2-dev (task 12) is snuffleupagus's build
# dependency: its config.m4 shells out to `pcre2-config --libs8` directly,
# and trixie ships the pcre2 runtime lib but not the -dev package/pcre2-config
# binary anywhere else in this image.
      librabbitmq-dev libbz2-dev libffi-dev libldap2-dev liblz4-dev \
      libmcrypt-dev libssh2-1-dev libtidy-dev uuid-dev \
      libyaml-dev libevent-dev libpcre2-dev
# ext-snmp links this instead of libsnmp-dev (see the net-snmp stage above).
COPY --from=net-snmp /opt/net-snmp /opt/net-snmp
ENV PHP_DEPS_PREFIX=""

# ------------------------------------------------------------- deps: legacy
# PHP 7.0-8.0 cannot link against what trixie ships: OpenSSL 3 support only
# became solid in 8.1, and ICU 74+ needs C++17 that ext/intl below 8.1
# doesn't use. So this era vendors pinned copies (deps/versions.lock)
# instead -- task 14 proves PHP 8.0 (the newest, easiest legacy version);
# task 15 does the other ten. libxml2 is NOT vendored (task 14 review, I2):
# trixie's own package is the same 2.9.14 series this project would have
# vendored, but with three security backports upstream's bare tarball
# lacks -- deps-legacy installs libxml2-dev from apt instead, below.
#
# OpenSSL and ICU are built no-shared/static-only by deps/build-deps.sh: no
# EOL libssl.so (or duplicate ICU data blob) exists anywhere in the image for
# anything else to dlopen. Neither ships an rpath entry for that reason --
# there is no .so to find at runtime. rpath (not LD_LIBRARY_PATH, which
# broke the host curl binary in task 1's spike: see php/ldflags.sh) exists
# for whatever *does* end up shared under PHP_DEPS_PREFIX -- curl, below,
# for the 7.0-7.2 versions that vendor it.
#
# curl is vendored only for 7.0-7.2 (deps/versions.lock): PHP's ext/curl
# config.m4 detected a DIR-style --with-curl=DIR through at least 7.3
# (CURL_DIR + curl-config), but switched to pure PKG_CHECK_MODULES(libcurl)
# by 8.0 -- exactly where in 7.4-8.0 that happened is still open (see the
# task 14 report's Concerns). PHP 8.0 (this task) therefore uses trixie's
# own libcurl4-openssl-dev, exactly like the modern era; only the version
# pinned right here on this line -- 8.0 -- has had that claim actually built
# and verified, not the rest of 7.3-8.0.
#
# Two more of the 7.0 spike's build-environment adjustments have no PHP-8.0
# use yet but get their seam here rather than being invented fresh by task 15:
#   - ext/gd's --with-freetype-dir=/usr (ext.json's gd overrides, 7.0-7.3
#     only -- 8.0 uses the pkg-config form and needs none of this) hard-
#     requires a freetype-config script at <dir>/bin, which freetype dropped
#     at 2.9.1. The shim goes in this stage, version-gated, right after the
#     apt install below.
#   - ext/intl's -DU_USING_ICU_NAMESPACE=1 (7.0-7.3 unqualified `icu::` type
#     references; ICU 68 removed the namespace-injection default this
#     papers over) belongs in php/build.sh's CPPFLAGS/CXXFLAGS, version-gated
#     the same way MAKE_ONLY_CFLAGS already is there -- not here, since it's
#     a compile flag, not a dependency-fetching concern.
FROM imagemagick AS deps-legacy
ARG PHP_VERSION
# libpng/libjpeg/libwebp/libfreetype/libheif -dev are already installed by
# the imagemagick stage above, same as deps-modern. No libssl-dev or
# libicu-dev here: both are vendored (see above). No libavif-dev: GD's AVIF
# support doesn't exist before PHP 8.1. libxml2-dev IS here, unlike
# deps-modern's comment used to say (I2) -- it's an ordinary system package
# now, not a vendored one, for every legacy version, not just 8.0.
# Otherwise this mirrors deps-modern's package set 1:1 -- ext.json is still
# the source of truth for which extension needs which package, this stage
# just can't build straight from the registry the way configure-args.sh
# does, so the list has to be kept in sync by hand like deps-modern's is.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      libcurl4-openssl-dev libxslt1-dev libxml2-dev \
      libonig-dev libzip-dev libsqlite3-dev libpq-dev zlib1g-dev libzstd-dev \
      libbrotli-dev \
      libsodium-dev libargon2-dev libgmp-dev libreadline-dev libmemcached-dev \
      librabbitmq-dev libbz2-dev libffi-dev libldap2-dev liblz4-dev \
      libmcrypt-dev libssh2-1-dev libtidy-dev uuid-dev \
      libyaml-dev libevent-dev libpcre2-dev
COPY deps/build-deps.sh deps/versions.lock deps/fetch-verified.sh /build/deps/
COPY php/cflags.sh php/ldflags.sh /build/php/
RUN --mount=type=cache,target=/var/cache/src,id=php-src-cache,sharing=locked \
    bash /build/deps/build-deps.sh "$PHP_VERSION" /opt/php-deps
# Placed after the vendored dependency build above, not before it, for the
# same reason the chmod shim is placed late in php-build: these are
# five-line steps and that RUN is twenty minutes of openssl + ICU + curl.
# Nothing in build-deps.sh consults either shim.
# Two build-environment shims that only 7.0-7.3 need, both of them satisfying
# an autoconf *search* rather than changing what actually gets linked. Guarded
# so they cost 7.4-8.0 nothing. Neither reaches the runtime image -- this stage
# is a build stage; nothing under /usr/include or /usr/bin here is copied out.
#
#  1. freetype-config.
#     ext/gd's config.m4 on these branches iterates $PHP_FREETYPE_DIR
#     /usr/local /usr and tests -f "$i/bin/freetype-config" -- nothing else on
#     PATH is consulted, and freetype dropped that script at 2.9.1 (trixie
#     ships 2.13, pkg-config only). config.m4 then calls exactly --cflags and
#     --libs. 7.4 moved gd to pkg-config and needs none of this.
#
#  2. /usr/include/gmp.h. ext/gmp's config.m4 on these branches searches
#     $i/include/gmp.h and $i/include/$($CC -dumpmachine)/gmp.h, and Debian
#     ships gmp.h only under the multiarch directory because it is
#     arch-dependent. That second test is exactly the multiarch fallback --
#     and it used to miss under **clang**, whose -dumpmachine prints
#     "x86_64-pc-linux-gnu" while Debian's multiarch triple (and gcc's
#     -dumpmachine) is "x86_64-linux-gnu": clang 7.0-7.3 all died at
#     "configure: error: Unable to locate gmp.h" (only the *test* was broken --
#     clang searches the multiarch include dir by default, so once configure
#     was satisfied the compile found the real header on its own). Task 37a
#     moved 7.0-8.4 to COMPILER=gcc, whose -dumpmachine already matches
#     Debian's multiarch triple, so this test now passes on its own for those
#     versions too -- the symlink stays unconditional (cheap, idempotent, keyed
#     off the real found path rather than a hardcoded one) rather than gated on
#     COMPILER, so a future clang run of these versions (or a v3 arm64 triple
#     that does not match) is still covered without this block being revisited.
RUN set -eu; \
    case "$PHP_VERSION" in \
      7.0|7.1|7.2|7.3) \
        printf '%s\n' '#!/bin/sh' 'case "$1" in' \
          '  --cflags) exec pkg-config --cflags freetype2 ;;' \
          '  --libs) exec pkg-config --libs freetype2 ;;' \
          '  --ftversion) exec pkg-config --modversion freetype2 ;;' \
          '  --prefix) exec pkg-config --variable=prefix freetype2 ;;' \
          'esac' 'exit 1' > /usr/bin/freetype-config; \
        chmod +x /usr/bin/freetype-config; \
        gmp_h="$(find /usr/include -maxdepth 2 -name gmp.h -print -quit)"; \
        [ -n "$gmp_h" ] || { echo "libgmp-dev is installed but no gmp.h was found under /usr/include" >&2; exit 1; }; \
        [ -e /usr/include/gmp.h ] || ln -s "$gmp_h" /usr/include/gmp.h; \
        echo "gmp.h: $gmp_h -> /usr/include/gmp.h"; \
        ;; \
      *) : ;; \
    esac
# ext-snmp links this instead of libsnmp-dev (see the net-snmp stage above).
COPY --from=net-snmp /opt/net-snmp /opt/net-snmp
# PKG_CONFIG_PATH/PKG_CONFIG_LIBDIR (the latter set in php/build.sh) is what
# actually makes PHP's ./configure find the vendored openssl/icu -- both
# PHP_SETUP_OPENSSL and PHP_SETUP_ICU are PKG_CHECK_MODULES-based, and
# neither reads a DIR value at all when one is given. For OpenSSL this is a
# PHP 7.4+ change (confirmed against 7.4.33 and 8.0.30: --with-openssl=DIR
# is accepted syntactically -- PHP_ARG_WITH takes any value as truthy -- but
# never read). For ICU it is NOT a version boundary the way an earlier draft
# of this comment claimed: PHP_ARG_WITH(icu-dir,,...,DEFAULT,no) in 7.3's
# own acinclude.m4 defaults $PHP_ICU_DIR to the literal string "DEFAULT"
# whenever --with-icu-dir isn't passed at all, and that DEFAULT value is
# exactly what routes PHP_SETUP_ICU into its pkg-config branch -- so never
# emitting --with-icu-dir is correct on every version back to 7.0, for the
# same reason it's correct on 8.0, not a different one. (--with-icu-dir does
# stop existing as a flag name above 7.3, per an earlier task-14 note, but
# that's not why omitting it here is correct.)
#
# That holds for 7.1 through 8.0. It does NOT hold for 7.0, which task 15
# measured rather than assumed: 7.0.33's PHP_SETUP_ICU contains no reference
# to PKG_CONFIG at all (7.1.33's contains seven). It shells out to icu-config,
# found at $PHP_ICU_DIR/bin or on $PATH, and hard-errors with "Unable to
# detect ICU prefix" when neither resolves -- and trixie ships no icu-config
# anywhere. So 7.0 alone needs --with-icu-dir=${PHP_DEPS_PREFIX}. That flag
# comes from php/ext.json (a 7.0 override on intl) and gets its value spliced
# by php/build.sh, derived from ${PHP_DEPS_PREFIX}/bin/icu-config existing,
# for the same reason --with-curl is: so the version range lives in exactly
# one place. Which is why this ENV still names only --with-openssl.
#
# Both of the derived flags are deliberately not solved by putting
# ${PHP_DEPS_PREFIX}/bin on PATH, which would satisfy icu-config and
# curl-config in one line: that directory also holds the vendored `curl`
# binary for 7.0-7.2, and shadowing /usr/bin/curl for the whole build is the
# LD_LIBRARY_PATH failure from task 1's spike in a different suit.
ENV PHP_DEPS_PREFIX=/opt/php-deps
ENV PREFIXED_CONFIGURE_FLAGS="--with-openssl"

# --------------------------------------------------------------- deps alias
FROM deps-${PHP_ERA} AS deps

# --------------------------------------------------------------- php-build
FROM deps AS php-build
ARG PHP_VERSION
ARG PHP_RELEASE
ARG PHP_ERA
ARG UARCH=baseline
# Consumed by later tasks (17 PGO, 14 vendored ICU); declared so bake can pass
# them without buildkit warning about unused build args.
ARG PGO
ARG ICU_VERSION
WORKDIR /src

# The clang profile runtime. debian's `clang` package does not pull it in, and
# without it PGO pass 1 dies at the link on a missing libclang_rt.profile.a --
# twenty minutes in and nowhere near the cause, so both it and llvm-profdata
# (which merges the .profraw files) are asserted here.
#
# Installed in this stage rather than in `toolchain`, which is where the
# compiler otherwise lives, for one reason a reviewer can check: this is the
# only stage that ever compiles with a profile flag. deps/build-imagemagick.sh
# and deps/build-deps.sh build through php/cflags.sh and php/ldflags.sh,
# neither of which emits one. Putting it upstream would put ImageMagick and the
# legacy era's vendored OpenSSL/ICU/curl -- twenty-odd minutes per version --
# in the invalidation path of every PGO change, for a package they never use.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends libclang-rt-dev \
    && { command -v llvm-profdata >/dev/null || { echo "llvm-profdata is missing; two-pass PGO cannot merge a profile" >&2; exit 1; }; } \
    && { [ -n "$(find /usr/lib/llvm-* -name 'libclang_rt.profile*' -print -quit)" ] \
         || { echo "no libclang_rt.profile under /usr/lib/llvm-*; -fprofile-generate cannot link" >&2; exit 1; }; }

# `ld` means lld in this stage. -fuse-ld=lld in LDFLAGS is not enough, measured:
# libtool sorts link-mode arguments into buckets, and only the ones matching its
# known list (-O*, -flto*, -fstack-protector*, ...) reach $compiler_flags, which
# is the variable its *shared library* archive_cmds template expands. A plain
# -f flag it does not recognise -- -fuse-ld=lld is exactly that -- reaches the
# program link and nothing else. So php and php-fpm linked with lld while
# ext/opcache/opcache.la was handed to /usr/bin/ld, which cannot read the
# bitcode ThinLTO produces:
#
#   /usr/bin/ld: warning: -z keep-text-section-prefix ignored
#   ext/opcache/.libs/ZendAccelerator.o: file not recognized: file format not recognized
#
# It only showed on 7.0-8.4: 8.5 compiles opcache into the binary, so the only
# ThinLTO shared-object link in the tree did not exist there and the first eight
# builds of this task never hit it.
#
# A PATH shim rather than -Wc,-fuse-ld=lld (libtool's "pass to the compiler"
# form, which does reach $compiler_flags): that spelling is a libtool argument,
# and ./configure links its own probes by invoking clang directly, where it is
# an unknown argument -- every probe would fail and autoconf would read the
# failures as feature answers, which is the exact class of silent wrong answer
# php/build-canaries.sh exists to catch.
# GCC needs the same PATH-based shim for a different reason, found the same
# way the lld one was (build it, read the failure): gcc's own -ffunction-
# sections/-freorder-functions/-freorder-blocks-and-partition profile-guided
# hot/cold split DOES put php-src's hot functions in their own .text.hot.*
# input sections, but the *default* /usr/bin/ld (bfd, binutils 2.47 on
# trixie) does not fold them back into a single .text.hot OUTPUT section --
# it warns "-z keep-text-section-prefix ignored" and leaves one big .text, so
# assert_profile_reached_the_link's whole premise (a .text.hot section only a
# profile-guided link produces) would measure nothing. ld.gold does the fold
# with no flag needed at all; confirmed with php/pgo/discriminator-probe.c
# against this exact toolchain before trusting it on a 20-minute build. A
# `-fuse-ld=gold` CFLAGS/LDFLAGS entry was tried and rejected for the same
# reason `-fuse-ld=lld` was: it is an -f flag libtool's shared-module
# archive_cmds template does not forward, so opcache.so would link with
# whatever `ld` happens to default to instead.
RUN set -eux; \
    mkdir -p /usr/local/lib/php-docker-ld; \
    case "$COMPILER" in \
      clang) ln -sf /usr/bin/ld.lld /usr/local/lib/php-docker-ld/ld ;; \
      gcc)   ln -sf /usr/bin/ld.gold /usr/local/lib/php-docker-ld/ld ;; \
    esac; \
    PATH=/usr/local/lib/php-docker-ld:$PATH; \
    v="$(ld --version | head -1)"; \
    case "$COMPILER:$v" in \
      clang:*LLD*) echo "ok: ld on PATH is '$v'" ;; \
      clang:*) echo "FATAL: ld on PATH is '$v', not lld; ThinLTO shared-object links will fail" >&2; exit 1 ;; \
      gcc:*GNU\ gold*) echo "ok: ld on PATH is '$v'" ;; \
      gcc:*) echo "FATAL: ld on PATH is '$v', not gold; profile-guided .text.hot would not survive the link" >&2; exit 1 ;; \
    esac
ENV PATH=/usr/local/lib/php-docker-ld:$PATH

COPY php/ /build/php/
COPY scripts/runtime-libs.sh /build/scripts/
COPY deps/patches/ /build/patches/
# fetch-pecl.sh, build-shared-ext.sh and the php.net tarball fetch below all
# route through the shared cache helper (task 31); it lives under deps/,
# outside the `COPY php/` tree above, so it needs its own line.
COPY deps/fetch-verified.sh /build/deps/fetch-verified.sh
# The opcache settings the runtime image installs. php/pgo/train.sh replays
# them onto the instrumented binary so the profile is taken with the JIT, the
# interned-string buffer and the accelerated-file count the deployments
# actually run -- rather than with opcache's compiled-in defaults, or with a
# second copy of these numbers that would drift from conf/opcache.ini.
COPY conf/opcache.ini /build/conf/opcache.ini

# php.net tarballs are GPG-signed by the release managers. The keys are vendored
# in php/release-keys.asc and imported offline: fetching them from a keyserver
# per build is both flaky in CI and a fresh decision to trust whatever comes back.
# The sha256 pins in php/php-src.lock (task 31) are additive to that GPG check,
# not a replacement for it -- see the lock file's header -- and are what let
# this fetch go through the same content-addressed cache as everything else,
# surviving a php.net or GitHub outage mid-build the same way.
RUN --mount=type=cache,target=/var/cache/src,id=php-src-cache,sharing=locked \
    set -eux; \
    row="$(grep -E "^${PHP_RELEASE}[[:space:]]" /build/php/php-src.lock)"; \
    [ -n "$row" ] || { echo "FATAL: no php/php-src.lock row for PHP_RELEASE=$PHP_RELEASE" >&2; exit 1; }; \
    tar_sha="$(echo "$row" | awk '{print $2}')"; \
    asc_sha="$(echo "$row" | awk '{print $3}')"; \
    bash /build/deps/fetch-verified.sh "https://www.php.net/distributions/php-${PHP_RELEASE}.tar.xz" "$tar_sha" php.tar.xz; \
    bash /build/deps/fetch-verified.sh "https://www.php.net/distributions/php-${PHP_RELEASE}.tar.xz.asc" "$asc_sha" php.tar.xz.asc; \
    GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; \
    gpg --batch --import /build/php/release-keys.asc; \
    gpg --batch --verify php.tar.xz.asc php.tar.xz; \
    gpgconf --kill all; rm -rf "$GNUPGHOME"; \
    tar xf php.tar.xz; rm php.tar.xz php.tar.xz.asc

WORKDIR /src/php-${PHP_RELEASE}

# Applied in filename order -- the NNN- prefix on every patch is what makes
# that deterministic rather than locale-dependent prose ordering.
#
# --fuzz=0 is the point of this step being three flags instead of one: `patch`
# happily applies a hunk whose context only partly matches, prints "Hunk #1
# succeeded at 42 with fuzz 2" on stdout, and exits 0. On a security-relevant
# binary that is a silent behaviour change disguised as a green build, so a
# patch that no longer matches its context exactly must fail the build and be
# rewritten. --forward makes an already-applied patch an error instead of an
# interactive "Reversed (or previously applied) patch detected!" prompt, and
# --batch keeps it non-interactive in every other case too.
#
# A version with no directory here needs no patches. That is 8.1-8.5 now
# (8.1.34/8.2.34/8.3.35 ship the xxhash include fix upstream); every older
# version carries at least one, and 7.0 carries four. deps/patches/README.md records which versions carry what and why. The count is echoed so "applied nothing"
# is visible in the build log rather than being indistinguishable from
# "applied everything" the way a silent loop would be.
RUN set -eux; \
    dir="/build/patches/php-${PHP_VERSION}"; \
    n=0; \
    if [ -d "$dir" ]; then for p in "$dir"/*.patch; do \
      [ -e "$p" ] || continue; echo "applying $p"; \
      patch -p1 --batch --forward --fuzz=0 < "$p"; n=$((n+1)); \
    done; fi; \
    echo "php-${PHP_VERSION}: applied $n patch(es) from deps/patches"

# PECL sources land in ext/ before buildconf so configure treats them as core;
# --force is required because the release tarball ships a pre-generated
# configure and buildconf refuses to run without it.
RUN --mount=type=cache,target=/var/cache/src,id=php-src-cache,sharing=locked \
    set -eux; \
    bash /build/php/fetch-pecl.sh "$PHP_VERSION" "$PWD"; \
    ./buildconf --force

# The corpus is mounted for every build, not only the PGO ones. A conditional
# mount is not expressible here, and the alternative -- a placeholder image for
# the pgo=false case -- would mean the fallback path and the real path stop
# being the same code. scripts/gen_matrix.py derives the tag per version from
# scripts/pgo_tiers.py, so which corpus arrives is a function of matrix.json.
#
# rw on /corpus because Laravel, Symfony and WordPress all write while serving
# (compiled views, sqlite journals). The write layer is scoped to this RUN and
# thrown away with it, so the corpus image itself stays immutable. /corpus-src
# stays read-only: it holds the endpoints files train.sh asserts against, and
# the training run must not be able to rewrite its own success criteria.
#
# apt cache mounts (task 29b): build.sh apt-get installs mariadb-server here,
# in this stage only, to start the database PrestaShop's corpus app needs
# while training (php/pgo/train.sh brackets it around that one app with
# corpus/prestashop/db-up.sh and db-down.sh). Never in `toolchain` or in the
# runtime stages below -- runtime-base only COPYs specific /usr/local/...
# paths out of this stage, none of which an apt package ever touches, so
# mariadb-server cannot reach a shipped image structurally, and
# tests/smoke.sh additionally asserts its binaries are absent from one.
RUN --mount=type=cache,target=/root/.cache/ccache \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,from=corpus,source=/corpus,target=/corpus,rw \
    --mount=type=bind,from=corpus,source=/corpus-src,target=/corpus-src \
    bash /build/php/build.sh

# Task 9's shared extensions: built against the now-installed PHP, dropped
# into extension_dir, never enabled. Must run before runtime-libs.sh below --
# that scan has to see these .so files to pull in their runtime libraries
# (libyaml, libtidy, librabbitmq, ...), and it walks /usr/local/lib once.
#
# PHP_ERA is exported explicitly rather than left to ARG scoping:
# build-shared-ext.sh hard-requires it to pick the configure/make flag split
# (php/flag-split.sh), and an unset value there is a build failure by design --
# defaulting it would silently drop the demotions that keep autoconf's probes
# answerable on the legacy branches.
RUN --mount=type=cache,target=/root/.cache/ccache \
    --mount=type=cache,target=/var/cache/src,id=php-src-cache,sharing=locked \
    set -eux; \
    export CFLAGS="$(bash /build/php/cflags.sh "$UARCH")"; \
    export CXXFLAGS="$CFLAGS -std=c++17"; \
    export LDFLAGS="$(bash /build/php/ldflags.sh /opt/net-snmp)"; \
    export PHP_ERA="$PHP_ERA"; \
    bash /build/php/build-shared-ext.sh "$PHP_VERSION" "$PWD"; \
    find /usr/local/lib/php/extensions -name '*.so' -exec strip --strip-unneeded {} +

# chmod-sanitize (task 13): an opt-in LD_PRELOAD shim that rewrites
# chmod/fchmod/fchmodat(path, 0) to 0644 (files) / 0755 (dirs). Works around
# a PrestaShop cache-regeneration bug where chmod(file, 0000) is not
# followed by a successful replacement, leaving every later request a 500
# (PS issues #10998, #13050, #30786, #37666). Unchanged from the predecessor
# repo (docker-php-fpm-with-ext/shim/chmod-sanitize.c). Independent of PHP
# itself -- only needs libc/dl -- so it's built here, after the expensive PHP
# steps above, rather than before them: editing shim/chmod-sanitize.c must
# not invalidate the PHP build cache. Placed before runtime-libs.sh below so
# that scan also covers it (it resolves to nothing beyond libc, already
# guaranteed by the base image, but the scan is cheap and this keeps every
# .so under /usr/local/lib subject to the same check).
COPY shim/chmod-sanitize.c /build/shim/chmod-sanitize.c
# Built through php/cflags.sh and php/ldflags.sh like everything else this
# image produces, not with a hand-written flag list. It used to be
# `clang -shared -fPIC -O2 -Wall ... -ldl`, which meant the one object here
# that gets LD_PRELOADed into every FPM worker was the one object built with
# no hardening: no -z now (partial RELRO, writable GOT), no
# -fstack-protector-strong, no _FORTIFY_SOURCE, no -fcf-protection. Nothing
# noticed until tests/assert-elf-hardening.sh started measuring the shipped
# files instead of the flag strings, and it failed on this .so first.
# cflags.sh already supplies -fPIC and -O2, so nothing is lost. $CC, not a
# hardcoded `clang`: task 37a made COMPILER=gcc the default for 7.0-8.4, and
# this shim must not become the one object in the image built by a different
# compiler than the rest of it just because it predates that switch.
RUN set -eux; \
    CFLAGS="$(bash /build/php/cflags.sh "$UARCH")"; \
    LDFLAGS="$(bash /build/php/ldflags.sh)"; \
    $CC -shared $CFLAGS $LDFLAGS -Wall \
      -o /usr/local/lib/php-chmod-sanitize.so /build/shim/chmod-sanitize.c -ldl; \
    strip --strip-unneeded /usr/local/lib/php-chmod-sanitize.so

# What /deps-stage ships to every runtime image, trimmed to what a running php
# loads. The COPY out of this stage sees the final view, so removing here is
# what keeps these files out of the runtime layer. php links MagickWand and
# MagickCore only (imagick is static; `readelf -d php` has no Magick++ NEEDED,
# nor does any shared extension), so the C++ binding and ImageMagick's
# pkg-config files are dead weight; the legacy era's vendored ICU also installs
# a Makefile.inc per version under lib/icu, which only an ICU build reads.
RUN set -eux; \
    rm -f /deps-stage/opt/imagemagick/lib/libMagick++-*; \
    rm -rf /deps-stage/opt/imagemagick/lib/pkgconfig; \
    if [ -d /deps-stage/opt/php-deps/lib/icu ]; then \
      find /deps-stage/opt/php-deps/lib/icu -name Makefile.inc -delete; \
    fi

# Resolve the runtime package set from actual linkage.
RUN bash /build/scripts/runtime-libs.sh /usr/local/bin /usr/local/sbin /usr/local/lib \
      > /tmp/runtime-packages.txt && cat /tmp/runtime-packages.txt

# ------------------------------------------------------------ runtime-conf
# Build-only: the config half of the runtime image's file payload, assembled
# (and version-patched) under /stage so runtime-base can take the whole tree in
# one COPY. Every COPY/RUN in here would be its own layer in the shipped image
# if it sat in runtime-base; as a stage of its own they cost nothing.
FROM ${BASE_IMAGE} AS runtime-conf
ARG PHP_VERSION

# php-ext-enable (task 9): the only thing that may ever turn a shared module
# on. Landed here, not baked into the flavor stages below, so cli/fpm/
# cli-builder all get it the same way.
# --chmod: the scripts are executable in the checkout already, this makes the
# image not depend on file modes there (it replaces a `chmod +x` RUN).
COPY --chmod=0755 rootfs/ /stage/

# CA trust store (task 14): every flavor/era, unconditional. Fixes a Critical
# found in review -- the legacy era's vendored OpenSSL had no CA store at all
# (deps/build-deps.sh's --openssldir pointed at an empty vendored path that
# "make install_sw" never populates), so every TLS connection made through
# PHP's own openssl extension (file_get_contents, stream_socket_client,
# SoapClient, SMTP+TLS) failed to verify the peer -- silently masked by curl,
# which resolves its own CA bundle independently and was the only thing
# task 14 originally tested over HTTPS. See deps/build-deps.sh's openssl
# case for the compiled-in-default half of the fix; this ini is the explicit,
# visible half, and applies equally (and harmlessly) to the modern era, whose
# system OpenSSL already gets this right on its own.
COPY conf/openssl.ini /stage/usr/local/etc/php/conf.d/12-openssl.ini

# Baseline opcache settings (task 10), the one ini every flavor shares
# unmodified. Numbered so task 11's entrypoint-written 90-opcache-env.ini
# and 99-env.ini sort after it and win. (FPM pool tuning is ${VAR}-driven
# in www.conf as of task 11 round 3 -- no file is written for it at all.)
COPY conf/opcache.ini /stage/usr/local/etc/php/conf.d/15-opcache.ini
# PHP 8.5 folded opcache fully into the engine (configure-args.sh already
# knows this: --enable-opcache is omitted there from 8.5 on) and dropped it
# as a loadable Zend extension, so conf/opcache.ini above is enough on its
# own. Every other version (7.0-8.4) still needs zend_extension=opcache to
# actually activate a statically-compiled opcache -- being built in doesn't
# register it as a Zend extension the way it does for a regular extension;
# task 14's PHP 8.0 build is what surfaced this (php -m had no opcache and
# no [Zend Modules] entry at all, despite --enable-opcache and a clean
# compile). Confirmed the other direction too: adding this line
# unconditionally to an 8.5 image produces a "Failed loading Zend extension
# 'opcache'" warning on every request (8.5 has nothing named "opcache" left
# to load) -- so this has to stay version-gated, not folded into
# conf/opcache.ini itself.
# The ".so" is not decoration. PHP only started appending it to a
# zend_extension= value that names no file extension somewhere after 7.1: on
# 7.0.33 and 7.1.33 "zend_extension=opcache" resolves to
# <extension_dir>/opcache, with no suffix, and every single php invocation
# prints "Failed loading .../opcache: cannot open shared object file" while
# running with no opcache at all. Measured on the built images: with "opcache"
# 7.0/7.1 fail and 7.2+ work; with "opcache.so" 7.0, 7.1, 7.2 and 8.4 all load
# it. The suffixed form is correct on every version, so it is not gated.
RUN [ "$PHP_VERSION" = "8.5" ] || echo "zend_extension=opcache.so" >> /stage/usr/local/etc/php/conf.d/15-opcache.ini

# Task 16 found this while building the PGO corpus, and it belongs to task 10's
# conf/opcache.ini rather than to the corpus: PHP before 7.3 cannot allocate the
# 32MB interned strings buffer that file asks for. On those branches the
# interned strings buffer is carved out of opcache's shared segment with a 16MB
# ceiling, and exceeding it is a hard "Fatal Error Zend OPcache cannot allocate
# buffer for interned strings" at startup rather than a warning.
#
# Measured on the built images, not inferred: `docker run lotuswebagency/php:7.0-fpm`,
# 7.1 and 7.2 all exited 254 with that line and never accepted a connection --
# three published images dead on arrival -- while 7.3 and up reached "ready to
# handle connections". `php -S` died identically, which is what surfaced it:
# task 17 trains through the built-in server. 16 is still twice opcache's own
# default of 8.
#
# Guarded on both sides for the reason the php-fpm.conf substitution below is:
# `sed -i` exits 0 whether or not it matched, so a reworded conf/opcache.ini
# would silently turn this into a no-op and hand 7.0-7.2 back a broken image.
RUN set -eux; \
    case "$PHP_VERSION" in \
      7.0|7.1|7.2) \
        grep -qx 'opcache.interned_strings_buffer = 32' /stage/usr/local/etc/php/conf.d/15-opcache.ini \
          || { echo "FATAL: conf/opcache.ini no longer sets interned_strings_buffer = 32; the <7.3 clamp below is dead" >&2; exit 1; }; \
        sed -i 's/^opcache.interned_strings_buffer = 32$/opcache.interned_strings_buffer = 16/' /stage/usr/local/etc/php/conf.d/15-opcache.ini; \
        grep -qx 'opcache.interned_strings_buffer = 16' /stage/usr/local/etc/php/conf.d/15-opcache.ini \
          || { echo "FATAL: interned strings clamp did not apply" >&2; exit 1; }; \
        echo "ok: clamped interned_strings_buffer to 16 for php $PHP_VERSION" ;; \
    esac

# Snuffleupagus rulesets (task 12): present in every flavor, but inert until
# PHP_SNUFFLEUPAGUS names one -- the module itself ships as a dormant .so
# like every other shared extension (task 9) and is never referenced by any
# baked ini here.
COPY conf/snuffleupagus/ /stage/usr/local/etc/php/snuffleupagus/

# ----------------------------------------------------------- runtime-payload
# Build-only: every file runtime-base takes from php-build and runtime-conf, in
# the order they used to be copied (later wins), so runtime-base needs a single
# COPY -- one layer -- instead of eleven.
FROM scratch AS runtime-payload
# Vendored libraries (ImageMagick in every era, plus the legacy era's vendored
# openssl/icu/curl -- libxml2 is NOT vendored, task 14 review I2), at the absolute path their
# binaries' rpath names (php/build.sh stages them). Empty of the legacy tree,
# but not of ImageMagick, in the modern era -- either way one unconditional
# COPY is enough.
COPY --from=php-build /deps-stage/ /

COPY --from=php-build /usr/local/bin/php /usr/local/bin/php
COPY --from=php-build /usr/local/lib/php /usr/local/lib/php
COPY --from=php-build /usr/local/etc/php /usr/local/etc/php
# What the compile actually did: pgo on or off, the flags, the profile's
# sha256 and coverage, the corpus versions it was trained on. tests/test-pgo.sh
# cross-checks the pgo= line against matrix.json, so a version that silently
# stops taking PGO fails a test instead of shipping quietly slower.
COPY --from=php-build /usr/local/share/php-build /usr/local/share/php-build
# chmod-sanitize.so (task 13): carried into every flavor, same as every other
# shared module -- opt-in via PHP_CHMOD_SHIM in the entrypoint, inert until
# then regardless of which flavor.
COPY --from=php-build /usr/local/lib/php-chmod-sanitize.so /usr/local/lib/php-chmod-sanitize.so

COPY --from=runtime-conf /stage/ /

# ------------------------------------------------------------ runtime-base
FROM ${BASE_IMAGE} AS runtime-base
ARG PHP_VERSION
ARG WWW_UID=33
ARG WWW_GID=33
# Core client packages, not the metapackages: ~38MB of tooling instead of ~85MB.
# 17 is trixie's PostgreSQL major (apt-cache search '^postgresql-client-[0-9]').
ARG PG_MAJOR=17
# Without a UTF-8 LC_CTYPE, PHP 7.x's basename()/pathinfo() treat multibyte
# bytes as invalid and cut them away: basename('/x/файл.txt') is '.txt', and
# ZipArchive::extractTo() writes '日本語/.txt'. 8.0+ is locale-independent there.
# C.UTF-8 is built into glibc, no locales package needed.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

COPY --from=php-build /tmp/runtime-packages.txt /tmp/runtime-packages.txt
# upgrade: BASE_IMAGE is digest-pinned, so without it a Debian security fix
# to a package the base already ships (libpcre2-8-0 on the legacy era, which
# bundles its own pcre and never names it) waits for the next digest bump
# instead of landing in the weekly rebuild.
RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl tzdata tini less nano procps \
      tar gzip bzip2 zip unzip zstd xz-utils \
      mariadb-client-core "postgresql-client-${PG_MAJOR}" \
# libfcgi-bin (task 13): ships cgi-fcgi, the client the vendored
# php-fpm-healthcheck (and its HEALTHCHECK in the fpm stage) uses to speak
# FastCGI to the pool's ping.path directly, without a front web server.
      libfcgi-bin \
      $(tr '\n' ' ' < /tmp/runtime-packages.txt); \
# Debian's /usr/bin/psql is a symlink to pg_wrapper, a #!/usr/bin/perl script that
# dispatches between installed postgres majors. This image has exactly one, and that
# wrapper is the only reason ~49MB of perl modules and libperl.so are here. Keep the
# real client binaries, drop the wrapper machinery. postgresql-client-N Depends on
# postgresql-client-common, so the package cannot outlive the purge: the binaries
# have to be copied out first. Naming only `perl` lets apt take libperl/perl-modules
# with it, which keeps this working across the next perl major. That only works
# because nothing else Depends on libperl: Debian's libsnmp40t64 does, which is why
# ext-snmp links the vendored client-only net-snmp (deps/build-netsnmp.sh) and no
# libsnmp* package is ever installed. tests/smoke.sh asserts libperl is gone.
#
# This does not remove the perl interpreter: /usr/bin/perl belongs to perl-base,
# which is Essential, which dpkg needs, and which debian:trixie-slim already ships.
# What goes is the module library and one #!/usr/bin/perl script in front of a
# database client -- a real size win, a modest surface one, not "no interpreter".
    for b in psql pg_dump pg_dumpall pg_restore pg_isready; do \
      cp -a "/usr/lib/postgresql/${PG_MAJOR}/bin/$b" "/usr/local/bin/$b"; \
    done; \
    apt-get purge -y --auto-remove "postgresql-client-${PG_MAJOR}" perl; \
# dpkg --audit exits 0 whether or not it finds anything, so the output is the
# signal: any at all means the purge left a half-configured package behind.
    audit="$(dpkg --audit 2>&1 || true)"; \
    [ -z "$audit" ] || { echo "$audit" >&2; echo "FATAL: inconsistent dpkg state after purge" >&2; exit 1; }; \
    rm -rf /var/lib/apt/lists/* /tmp/runtime-packages.txt; \
# Housekeeping, in this RUN because a later one would only whiteout files this
# layer already stored. debconf keeps a *-old copy of its databases after every
# apt run (0.8MB). mariadb-check (mysqlcheck) and my_print_defaults ride along in
# mariadb-client-core for ~10MB, and neither is a client this image documents or
# tests: the mariadb shell is what the package is here for, and it reads its
# option files itself.
    rm -f /var/cache/debconf/*-old /usr/bin/mariadb-check /usr/bin/my_print_defaults

# Everything php-build produced for the runtime (vendored libraries, php, its
# extensions, the build record, the chmod shim) plus the baked config, see the
# runtime-payload stage above.
COPY --from=runtime-payload / /

RUN set -eux; \
    getent group www-data >/dev/null || groupadd -g "$WWW_GID" www-data; \
    id -u www-data >/dev/null 2>&1 || useradd -u "$WWW_UID" -g "$WWW_GID" -s /usr/sbin/nologin -M www-data; \
    mkdir -p /app /usr/local/etc/php/conf.d; \
    chown -R www-data:www-data /app; \
# php-ext-enable (task 9) has to write here as whatever user actually runs the
# container -- fpm/cli/cli-builder all set USER www-data, not root, and
# task 11's PHP_EXT_ENABLE entrypoint runs after that same drop, not before
# it. Root-owned 755 made every direct invocation fail with EACCES; this is
# the "writable by default" half of the contract, PHP_CONF_DIR is the other
# half for a read-only rootfs.
    chown www-data:www-data /usr/local/etc/php/conf.d; \
    find / -xdev -perm /6000 -type f -exec chmod a-s {} + || true

WORKDIR /app
# tini reaps zombies and forwards signals; docker-php-entrypoint (task 11)
# translates the environment into ini/pool overrides, then execs "$@".
ENTRYPOINT ["/usr/bin/tini", "--", "docker-php-entrypoint"]

# ----------------------------------------------------------------- flavors
# Build-only: php-fpm's own files plus the two pool/ini configs, as one tree for
# a single COPY (one layer) into the fpm image. conf/www.conf is copied last so
# it replaces the stock pool file php-build installed.
FROM scratch AS fpm-payload
COPY --from=php-build /usr/local/sbin/php-fpm /usr/local/sbin/php-fpm
COPY --from=php-build /usr/local/etc/php-fpm.conf /usr/local/etc/php-fpm.conf
COPY --from=php-build /usr/local/etc/php-fpm.d /usr/local/etc/php-fpm.d
COPY conf/php-fpm.ini /usr/local/etc/php/conf.d/10-php.ini
COPY conf/www.conf /usr/local/etc/php-fpm.d/www.conf

FROM runtime-base AS fpm
# ARG does not cross a FROM: runtime-base declares PHP_VERSION, this stage has to
# declare it again or the version gates below silently match nothing.
ARG PHP_VERSION
COPY --from=fpm-payload / /
# Ruling T11-G: no pool config file is ever written by the entrypoint, on a
# read-only rootfs or otherwise -- www.conf below references every tunable
# pool directive as ${PHP_FPM_*}, which php-fpm resolves from its own
# process environment at startup. These ENV defaults are what a container
# that bypasses docker-php-entrypoint entirely (`--entrypoint php-fpm`)
# actually gets: the same numbers this file hardcoded before task 11
# existed. Confirmed live that an unresolved ${VAR} is a hard FPM startup
# failure for pm.max_children and listen specifically, not a graceful
# fallback, so these can't be left unset. The entrypoint autotunes and
# `export`s over pm.max_children/start_servers/min_spare_servers/
# max_spare_servers when it runs; the rest are plain passthrough (operator
# `-e` overrides, or these defaults) with no entrypoint involvement at all.
#
# Ruling T11-I: the four autotuned values are baked, and read by www.conf,
# under _EFFECTIVE names that no operator is expected to set. The names
# operators do set (PHP_FPM_MAX_CHILDREN, ...) are deliberately left with no
# ENV default here, so that "unset" still means "nobody asked for a specific
# number" inside the entrypoint. Baking a default onto those names is what
# made `-e PHP_FPM_MAX_CHILDREN=16` -- the value below, and so the value any
# template rendering the documented default would pass -- indistinguishable
# from an untouched default, and silently autotuned up to 44 workers on a
# 4GB container.
ENV PHP_FPM_PM=dynamic \
    PHP_FPM_MAX_CHILDREN_EFFECTIVE=16 \
    PHP_FPM_START_SERVERS_EFFECTIVE=4 \
    PHP_FPM_MIN_SPARE_EFFECTIVE=4 \
    PHP_FPM_MAX_SPARE_EFFECTIVE=8 \
    PHP_FPM_MAX_REQUESTS=1000 \
    PHP_FPM_LISTEN=0.0.0.0:9000 \
    PHP_FPM_STATUS_PATH=/fpm-status \
    PHP_FPM_ACCESS_LOG=/proc/self/fd/2 \
    PHP_FPM_SLOWLOG_TIMEOUT=10s \
    PHP_DISABLE_FUNCTIONS="passthru, shell_exec, exec, system, show_source, dl, popen, pcntl_exec"
# One RUN for everything that edits or verifies the files above, in the order
# the separate steps used to run (each a layer of its own for no reason).
RUN set -eux; \
# php-fpm's stock config logs to $prefix/var/log and drops its pid in
# $prefix/var/run; make install creates both in the build stage, not here.
    mkdir -p /usr/local/var/log /usr/local/var/run; \
    chown -R www-data:www-data /usr/local/var; \
# Copying fpm-payload as a tree also stamps its (root-owned) conf.d directory
# onto the one runtime-base made writable for php-ext-enable; hand it back.
    chown www-data:www-data /usr/local/etc/php/conf.d; \
# The [global] error_log in the stock php-fpm.conf defaults to a file under
# $prefix/var/log, commented out in the shipped template. www.conf's
# catch_workers_output=yes makes every worker's own fd 2 a private pipe back
# to the master, not the container's real stderr -- so a worker's
# php_admin_value[error_log]=/proc/self/fd/2 resolves to that pipe, and the
# master then re-logs the captured line through *its own* error_log. Left at
# the stock default, that line -- and the master's own notices -- go to
# /usr/local/var/log/php-fpm.log and never reach `docker logs`. Pointing the
# global log at /proc/self/fd/2 too closes that loop: self there resolves to
# the master process, whose fd 2 is the real container stderr.
#
# `sed -i` exits 0 whether or not it matched anything, so a bare substitution
# here would silently no-op -- and stay silent -- the moment a future PHP
# point release rewords this line even slightly: the build stays green, the
# master's own startup notices still reach `docker logs` (they're emitted
# before the log target opens), and the regression looks exactly like a
# healthy image. Guarded on both sides: fail before touching the file unless
# there is exactly one error_log directive (commented or not) to replace,
# and fail after unless the replacement is actually present. The regex
# itself is loosened to match any error_log value, not just today's exact
# commented default, so a reworded *value* doesn't retrigger this --
# only the directive disappearing or multiplying does.
    n="$(grep -cE '^;?error_log[[:space:]]*=' /usr/local/etc/php-fpm.conf || true)"; \
    [ "$n" = "1" ] || { echo "FATAL: expected exactly one [global] error_log directive in php-fpm.conf, found $n" >&2; exit 1; }; \
    sed -i -E 's|^;?error_log[[:space:]]*=.*|error_log = /proc/self/fd/2|' /usr/local/etc/php-fpm.conf; \
    grep -qx 'error_log = /proc/self/fd/2' /usr/local/etc/php-fpm.conf \
      || { echo "FATAL: php-fpm.conf error_log substitution did not apply" >&2; exit 1; }; \
# docker-php-entrypoint refuses a PHP_FPM_*_EFFECTIVE that differs from what
# this stage baked -- they are computed outputs, and the only pool variables
# `docker image inspect` shows, so they are exactly what an operator finds
# and sets by mistake. That refusal compares against BAKED_* constants
# inside the script, which therefore have to agree with the ENV line above:
# if they ever drift, every container of this image refuses to start. Fail
# the build instead, the same way the php-fpm.conf error_log substitution
# above refuses to pass unverified.
    for pair in "MAX_CHILDREN=$PHP_FPM_MAX_CHILDREN_EFFECTIVE" \
                "START_SERVERS=$PHP_FPM_START_SERVERS_EFFECTIVE" \
                "MIN_SPARE=$PHP_FPM_MIN_SPARE_EFFECTIVE" \
                "MAX_SPARE=$PHP_FPM_MAX_SPARE_EFFECTIVE"; do \
      grep -qx "BAKED_${pair}" /usr/local/bin/docker-php-entrypoint \
        || { echo "FATAL: docker-php-entrypoint has no 'BAKED_${pair}' -- its constants disagree with this stage's PHP_FPM_*_EFFECTIVE ENV defaults" >&2; exit 1; }; \
    done; \
# decorate_workers_output arrived in php-fpm 7.3. On 7.0-7.2 it is not an
# ignored unknown key, it is a hard startup failure:
#
#   ERROR: [/usr/local/etc/php-fpm.d/www.conf:41] unknown entry 'decorate_workers_output'
#   ERROR: FPM initialization failed                                    (exit 78)
#
# Found by task 16, and it belongs to task 11's conf/www.conf. It sat behind the
# opcache interned-strings fatal above -- both had to be fixed before 7.0, 7.1
# and 7.2 could start at all. Removing the line restores those versions to
# php-fpm's own default (undecorated output), which is what `no` asks for.
#
# Guarded like every other substitution here: `sed -i` exits 0 whether or not it
# matched, so a reworded www.conf would turn this into a no-op and hand three
# versions back a dead image.
    case "$PHP_VERSION" in \
      7.0|7.1|7.2) \
        grep -qx 'decorate_workers_output = no' /usr/local/etc/php-fpm.d/www.conf \
          || { echo "FATAL: conf/www.conf no longer sets decorate_workers_output = no; the <7.3 removal below is dead" >&2; exit 1; }; \
        sed -i '/^decorate_workers_output = no$/d' /usr/local/etc/php-fpm.d/www.conf; \
        ! grep -q '^decorate_workers_output' /usr/local/etc/php-fpm.d/www.conf \
          || { echo "FATAL: decorate_workers_output survived removal" >&2; exit 1; }; \
        echo "ok: dropped decorate_workers_output for php $PHP_VERSION" ;; \
    esac; \
# php-fpm parses its own configuration and refuses to start on anything it does
# not recognise, so ask it here rather than finding out in production. Both
# defects above shipped because nothing in this build or in tests/smoke.sh
# ever started php-fpm -- `php -r` runs fine on an image whose fpm binary cannot
# initialise. This catches any future directive that outruns the oldest PHP in
# the matrix, not just the one that was found.
    php-fpm -t
EXPOSE 9000
STOPSIGNAL SIGQUIT
# php-fpm-healthcheck (vendored, task 13) speaks FastCGI directly to the
# pool's ping.path (conf/www.conf) via cgi-fcgi -- no front web server
# needed, and no HTTP port to expose just for this. USER www-data still
# applies to the HEALTHCHECK's own process, same as the main command.
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD php-fpm-healthcheck || exit 1
USER www-data
CMD ["php-fpm", "-F"]

FROM runtime-base AS cli
COPY conf/php-cli.ini /usr/local/etc/php/conf.d/10-php.ini
USER www-data
CMD ["php", "-a"]

# Node 24 LTS for cli-builder, copied out of the official image instead of
# Debian's nodejs/npm (trixie ships Node 20, which upstream no longer
# maintains). Pinned by the multi-arch INDEX digest, so both the amd64 and the
# arm64 build resolve it and a retag upstream cannot change what ships.
# node 24.21.0 / npm 11.19.0 at the time of pinning.
FROM node:24-trixie-slim@sha256:8ec5d7557396cfe32d21c3f9c13072355ceab22b584578ca4bb28af31120cffe AS node24

# Node, npm and semantic-release as the one tree cli-builder takes, finished
# here so that no intermediate npm ever lands in a shipped layer: copying the
# node image's node_modules and upgrading npm in a later RUN left the 11.19
# copy (~20MB) underneath the new one.
#
# npm itself is moved past the 11.19.0 the node image bundles: 11.21.0 ships
# the fixed tar and ip-address. Its bundled brace-expansion and undici are
# still behind their fixes in every npm release (see .trivyignore). The /out
# tree is built by hand rather than by copying /usr/local/bin wholesale, which
# also holds the node image's docker-entrypoint.sh and yarn. semantic-release is
# not run here (it refuses to start without git, which the node image lacks);
# tests/smoke.sh runs `semantic-release --version` in the finished image. The
# readme/changelog markdown inside the packages is 2.5MB nothing reads.
FROM node24 AS node-tools
RUN set -eux; \
    node -v; \
    npm install -g npm@11.21.0; \
    npm -v; \
    npm install -g semantic-release; \
    npm cache clean --force; \
    test -x /usr/local/bin/semantic-release; \
    find /usr/local/lib/node_modules -type f \( -iname 'readme*.md' -o -iname 'changelog*.md' -o -iname 'history.md' \) -delete; \
    mkdir -p /out/bin /out/lib; \
    cp -a /usr/local/lib/node_modules /out/lib/node_modules; \
    for b in node npm npx corepack semantic-release; do \
      cp -a "/usr/local/bin/$b" "/out/bin/$b"; \
    done

# cli-builder is a pure asset/test/deploy image: composer, node and the CLI
# tooling a build or deploy stage reaches for. It carries no compiler and no
# phpize -- compiling an extension is ext-builder's job below.
FROM cli AS cli-builder
USER root
COPY --from=node-tools /out/ /usr/local/
# less, nano, procps, zip, unzip and zstd are already in runtime-base.
# mariadb-client-core there only has the mariadb/mysql shell; the full
# mariadb-client adds mariadb-dump/mysqldump (and pulls perl back in).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      git rsync patch make brotli sqlite3 jq mariadb-client; \
    rm -rf /var/lib/apt/lists/*; \
# runtime-base dropped mariadb-check; the full client's mysqlcheck alias would
# be left pointing at it.
    find /usr/bin -xtype l -lname 'mariadb-check' -delete; \
    rm -f /var/cache/debconf/*-old
COPY conf/php-builder.ini /usr/local/etc/php/conf.d/10-php.ini
# The installer is verified against the signature Composer publishes; piping it
# straight into php would trust whatever the network returned.
RUN set -eux; \
    curl -fsSLo /tmp/composer-setup.php https://getcomposer.org/installer; \
    curl -fsSLo /tmp/composer-setup.sig https://composer.github.io/installer.sig; \
    echo "$(cat /tmp/composer-setup.sig)  /tmp/composer-setup.php" | sha384sum -c -; \
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer; \
    rm -f /tmp/composer-setup.php /tmp/composer-setup.sig; \
    composer --version
USER www-data
# www-data's HOME (/var/www) does not exist, so npm and corepack would try to
# write their caches under a directory uid 33 cannot create.
ENV COMPOSER_HOME=/tmp/composer \
    npm_config_cache=/tmp/npm \
    COREPACK_HOME=/tmp/corepack
CMD ["bash"]

# Build-only: the three paths ext-builder takes from php-build, as one tree for
# a single COPY.
FROM scratch AS ext-builder-payload
COPY --from=php-build /usr/local/bin/phpize /usr/local/bin/phpize
COPY --from=php-build /usr/local/bin/php-config /usr/local/bin/php-config
COPY --from=php-build /usr/local/include/php /usr/local/include/php

# Build-stage-only image for compiling PHP extensions that are then COPYed into
# fpm/cli of the same PHP version. Same php-build output as every other flavor
# of that version (no second compile, no second PGO run); only the headers and
# phpize/php-config are copied out of it. Runs as root: it is a build stage and
# `make install` writes into the extension dir. No composer, no node.
FROM cli AS ext-builder
USER root
# g++: several extensions are C++. autoconf: phpize regenerates ./configure
# from config.m4 and fails outright ("Cannot find autoconf") without it.
# pkg-config: extension configure scripts locate their -dev libraries with it.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      gcc g++ make autoconf pkg-config libc6-dev; \
    rm -rf /var/lib/apt/lists/*; \
    rm -f /var/cache/debconf/*-old
COPY --from=ext-builder-payload / /
CMD ["bash"]
