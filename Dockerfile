# syntax=docker/dockerfile:1.27@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# One Dockerfile for every published tag; docker-bake.hcl feeds it the matrix.
ARG BASE_IMAGE=debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
ARG PHP_ERA=modern
# Declared before any FROM so `FROM toolchain-select-${COMPILER}` can resolve it.
# The toolchain-base stage redeclares it for use inside the stage.
ARG COMPILER=clang

# --- gcc16-toolchain ---
# GCC 16.2 is not packaged for trixie, so COMPILER=gcc takes it from the official
# image, pinned by multi-arch index digest (an arm64 build resolves it too). That
# image is debian:13-slim plus a from-source GCC under /usr/local, copied out by
# toolchain-select-gcc. buildkit builds this stage only when COMPILER=gcc.
FROM gcc:16.2-trixie@sha256:ef558a40d1f13115293feee01526dbdb9aaad7c9c5a00da05f471ce042e855c1 AS gcc16-toolchain

# --- toolchain ---
FROM ${BASE_IMAGE} AS toolchain-base
ARG COMPILER=clang
# The compiler binary names COMPILER implies, supplied by docker-bake.hcl (clang
# -> clang++ is not a string transform). Defaults are the clang set so a bare
# `docker build` works. Bare names, not paths: ccache's masquerade symlinks in
# /usr/lib/ccache dispatch on the argv[0] basename.
ARG CXX_COMPILER=clang++
ARG AR_COMPILER=llvm-ar
ARG RANLIB_COMPILER=llvm-ranlib
ARG NM_COMPILER=llvm-nm
ENV DEBIAN_FRONTEND=noninteractive
# gcc/g++ are installed only as a build-essential dependency and for the
# binutils tools both toolchains share (build-only stage). Nothing compiles with
# this gcc: toolchain-select-gcc puts GCC 16.2 ahead of it on PATH. PHP's HYBRID
# VM pins execute_data/opline into registers via GCC global register variables
# (HAVE_GCC_GLOBAL_REGS, Zend/zend_execute.c), a GNU-C extension clang lacks, so
# COMPILER=gcc is the path that keeps that dispatch.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      build-essential clang lld llvm gcc g++ binutils-gold ccache pkg-config ca-certificates curl \
      autoconf automake libtool bison re2c make patch xz-utils file \
      gnupg dirmngr python3 dpkg-dev \
    && case "$COMPILER" in clang|gcc) ;; *) echo "COMPILER must be clang or gcc, got COMPILER=$COMPILER" >&2; exit 1 ;; esac
ENV CC=$COMPILER CXX=$CXX_COMPILER AR=$AR_COMPILER RANLIB=$RANLIB_COMPILER NM=$NM_COMPILER
# Plain ENV rather than the ARG, which does not survive into child stages:
# php/build.sh, php/pgo/train.sh and php/pgo/discriminator-control.sh branch on it.
ENV COMPILER=$COMPILER
ENV PATH=/usr/lib/ccache:$PATH
# gcc ships its own omp.h, found without -fopenmp. PECL imagick's config.m4 uses
# that header plus a -lgomp link as its "GCC with OpenMP" probe and then adds
# -lgomp to the static imagick, giving gcc builds a libgomp NEEDED entry that
# clang builds (no omp.h without libomp-dev) never get. Removing the header makes
# gcc answer "no OpenMP" like clang, matching deps/build-imagemagick.sh's
# --disable-openmp. Nothing else includes <omp.h>.
RUN if [ "$COMPILER" = "gcc" ]; then \
      rm -f "$(dirname "$(gcc -print-libgcc-file-name)")/include/omp.h"; \
    fi

# The shipped compilers: COMPILER=clang (Debian trixie's clang 19, a plain
# passthrough) and COMPILER=gcc (GCC 16.2 overlaid by toolchain-select-gcc).
# `toolchain` resolves to the one COMPILER names.
FROM toolchain-base AS toolchain-select-clang

FROM toolchain-base AS toolchain-select-gcc
COPY --from=gcc16-toolchain /usr/local /opt/gcc16
# GCC installs .la files whose libdir names the original /usr/local prefix. Once
# the tree sits at /opt/gcc16, libtool resolves -lstdc++ (ext/intl, C++ PECL
# modules) to that .la, warns "library ... was moved" and bakes /opt/gcc16/lib64
# into the RUNPATH of php, php-fpm and swoole.so, a directory the runtime image
# lacks. Without the .la files libtool treats -lstdc++ as a system library.
RUN find /opt/gcc16 -name '*.la' -delete
# Ahead of ccache's masquerade dir's target search, not of the dir itself: ccache
# still intercepts every gcc/g++ call and its compiler_check=mtime hashes the real
# binary, so gcc16 objects never collide with apt-gcc ones in the shared cache.
ENV PATH=/usr/lib/ccache:/opt/gcc16/bin:$PATH
# Same omp.h removal as above, for GCC 16's own copy.
RUN rm -f "$(dirname "$(gcc -print-libgcc-file-name)")/include/omp.h"
# Fail if gcc/cc do not resolve to GCC 16.2 (a stale PATH or masquerade
# regression would otherwise build with the wrong compiler and still pass).
RUN v="$(gcc -dumpfullversion)"; case "$v" in \
      16.2*) echo "ok: COMPILER=gcc resolves to GCC $v (/opt/gcc16)" ;; \
      *) echo "FATAL: COMPILER=gcc must resolve to GCC 16.2.x, got $v" >&2; exit 1 ;; \
    esac

FROM toolchain-select-${COMPILER} AS toolchain

# --- imagemagick ---
# ImageMagick from source: the distro build is a standing CVE source and its
# default OpenMP support causes thread explosions in FPM workers. One stage that
# both deps eras derive from, so it builds once per (arch, uarch, COMPILER).
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
# Nothing upstream sets PKG_CONFIG_PATH; a flat assignment avoids buildkit's
# UndefinedVar lint.
ENV PKG_CONFIG_PATH=/opt/imagemagick/lib/pkgconfig

# --- net-snmp ---
# net-snmp's client library, vendored because the distro libsnmp40t64 depends on
# libperl5.40 (~49 MB of perl in every runtime image, unpurgeable). Its own stage
# so it neither invalidates nor waits for ImageMagick; both eras share the result.
# It links Debian's libssl3 (libssl-dev below), never the legacy vendored OpenSSL.
# The deps stages COPY the whole prefix (ext-snmp needs net-snmp-config and the
# headers); php/build.sh's stage_runtime_deps ships only the library and MIBs.
FROM toolchain AS net-snmp
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends libssl-dev
COPY deps/build-netsnmp.sh deps/versions.lock deps/fetch-verified.sh /build/deps/
COPY php/cflags.sh php/ldflags.sh /build/php/
RUN --mount=type=cache,target=/var/cache/src,id=php-src-cache,sharing=locked \
    bash /build/deps/build-netsnmp.sh /opt/net-snmp

# --- deps: modern ---
# PHP 8.1+ links against what trixie ships.
FROM imagemagick AS deps-modern
# GD also needs libavif-dev; the other image libraries come from the imagemagick stage.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      libssl-dev libcurl4-openssl-dev libxml2-dev libxslt1-dev libicu-dev \
      libonig-dev libzip-dev libsqlite3-dev libpq-dev zlib1g-dev libzstd-dev \
      libbrotli-dev libavif-dev \
      libsodium-dev libargon2-dev libgmp-dev libreadline-dev libmemcached-dev \
# Shared-extension dependencies: one package per non-empty `libs` entry in
# php/ext.json for each linkage:"shared" extension. libmcrypt-dev is for mcrypt
# on PHP < 8.0. imap is absent: trixie has no libc-client-dev. libpcre2-dev is
# snuffleupagus's build dependency (its config.m4 calls pcre2-config).
      librabbitmq-dev libbz2-dev libffi-dev libldap2-dev liblz4-dev \
      libmcrypt-dev libssh2-1-dev libtidy-dev uuid-dev \
      libyaml-dev libevent-dev libpcre2-dev
# ext-snmp links this instead of libsnmp-dev.
COPY --from=net-snmp /opt/net-snmp /opt/net-snmp
ENV PHP_DEPS_PREFIX=""

# --- deps: legacy ---
# PHP 7.0-8.0 cannot link against trixie's libraries: OpenSSL 3 support only
# became solid in 8.1, and ICU 74+ needs C++17 that ext/intl below 8.1 does not
# use. This era vendors pinned copies (deps/versions.lock), except libxml2:
# trixie's 2.9.14-series package carries security backports the upstream tarball
# lacks, so libxml2-dev comes from apt.
#
# OpenSSL and ICU are built static-only by deps/build-deps.sh, so no EOL libssl.so
# or duplicate ICU data exists in the image and neither needs an rpath. The rpath
# (LD_LIBRARY_PATH would break the host curl; see php/ldflags.sh) covers whatever
# is shared under PHP_DEPS_PREFIX, i.e. the vendored curl of 7.0-7.2.
#
# curl is vendored only for 7.0-7.2: ext/curl's config.m4 takes a DIR-style
# --with-curl=DIR through 7.3 and is pure pkg-config (PKG_CHECK_MODULES) from 7.4.
# 7.4-8.0 build against trixie's libcurl4-openssl-dev; 7.4 and 8.0 carry
# deps/patches/php-*/010-curl-openssl3-not-old.patch so ext/curl does not link
# a second OpenSSL.
#
# Two further build-environment adjustments:
#   - ext/gd's --with-freetype-dir=/usr (php/ext.json overrides, 7.0-7.3) needs
#     a freetype-config script, which freetype dropped in 2.9.1; the shim is
#     created below.
#   - ext/intl's -DU_USING_ICU_NAMESPACE=1 (7.0-7.3 use unqualified `icu::`
#     types) is a compile flag set in php/build.sh's CPPFLAGS/CXXFLAGS.
FROM imagemagick AS deps-legacy
ARG PHP_VERSION
# The image libraries come from the imagemagick stage, as in deps-modern. ICU is
# vendored, so no libicu-dev. libssl-dev is for ext-snmp only: net-snmp-config
# adds -lssl -lcrypto, which needs the system libssl.so symlink. PHP itself is
# pointed at the vendored OpenSSL by --with-openssl=/opt/php-deps (php/build.sh
# asserts the substitution). No libavif-dev: GD has no AVIF before 8.1.
# Otherwise the package set mirrors deps-modern and must be kept in sync by hand.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      libssl-dev libcurl4-openssl-dev libxslt1-dev libxml2-dev \
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
# After the vendored build (twenty minutes of openssl + ICU + curl) so these
# five-line steps do not invalidate it; build-deps.sh does not use either shim.
# Both satisfy an autoconf search on 7.0-7.3 without changing what is linked,
# and stay in this build-only stage.
#
#  1. freetype-config. ext/gd's config.m4 on these branches tests
#     -f "$i/bin/freetype-config" for $PHP_FREETYPE_DIR, /usr/local and /usr and
#     then calls --cflags and --libs. 7.4 moved gd to pkg-config.
#
#  2. /usr/include/gmp.h. ext/gmp's config.m4 searches $i/include/gmp.h and
#     $i/include/$($CC -dumpmachine)/gmp.h, but Debian ships gmp.h only in the
#     multiarch directory. Clang's -dumpmachine ("x86_64-pc-linux-gnu") differs
#     from Debian's triple ("x86_64-linux-gnu"), so that fallback missed and
#     configure died with "Unable to locate gmp.h". gcc matches, but the symlink
#     stays unconditional and keyed off the found path, which also covers clang
#     and arm64 triples that do not match.
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
# ext-snmp links this instead of libsnmp-dev.
COPY --from=net-snmp /opt/net-snmp /opt/net-snmp
# PKG_CONFIG_PATH/PKG_CONFIG_LIBDIR (the latter set in php/build.sh) is what makes
# PHP's ./configure find the vendored openssl and icu: PHP_SETUP_OPENSSL and
# PHP_SETUP_ICU are PKG_CHECK_MODULES-based and ignore a DIR value. For OpenSSL
# that holds from 7.4 (--with-openssl=DIR is accepted but never read). For ICU,
# PHP_ARG_WITH(icu-dir,,...,DEFAULT,no) defaults $PHP_ICU_DIR to "DEFAULT" when
# the flag is absent, which routes PHP_SETUP_ICU to pkg-config, so omitting
# --with-icu-dir is correct back to 7.1.
#
# 7.0 is the exception: its PHP_SETUP_ICU does not use pkg-config. It runs
# icu-config from $PHP_ICU_DIR/bin or $PATH and fails with "Unable to detect ICU
# prefix"; trixie ships no icu-config. So 7.0 alone needs
# --with-icu-dir=${PHP_DEPS_PREFIX}, which comes from a php/ext.json override
# and is spliced in by php/build.sh (derived from ${PHP_DEPS_PREFIX}/bin/icu-config
# existing, like --with-curl, so the version range lives in one place). Hence this
# ENV names only --with-openssl.
#
# ${PHP_DEPS_PREFIX}/bin is deliberately not put on PATH: it holds the vendored
# curl binary for 7.0-7.2, and shadowing /usr/bin/curl for the whole build is the
# LD_LIBRARY_PATH failure again.
ENV PHP_DEPS_PREFIX=/opt/php-deps
ENV PREFIXED_CONFIGURE_FLAGS="--with-openssl"

# --- deps ---
FROM deps-${PHP_ERA} AS deps

# --- php-build ---
FROM deps AS php-build
ARG PHP_VERSION
ARG PHP_RELEASE
ARG PHP_ERA
ARG UARCH=baseline
# Passed by bake; declared so buildkit does not warn about unused build args.
ARG PGO
ARG ICU_VERSION
WORKDIR /src

# The clang profile runtime: Debian's `clang` does not pull it in, and without it
# PGO pass 1 fails at the link on a missing libclang_rt.profile.a, twenty minutes
# in. llvm-profdata (merges .profraw files) is asserted too. Installed here
# rather than in `toolchain` because only this stage compiles with a profile
# flag; upstream it would put ImageMagick and the legacy vendored libraries in
# the invalidation path of every PGO change.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends libclang-rt-dev \
    && { command -v llvm-profdata >/dev/null || { echo "llvm-profdata is missing; two-pass PGO cannot merge a profile" >&2; exit 1; }; } \
    && { [ -n "$(find /usr/lib/llvm-* -name 'libclang_rt.profile*' -print -quit)" ] \
         || { echo "no libclang_rt.profile under /usr/lib/llvm-*; -fprofile-generate cannot link" >&2; exit 1; }; }

# `ld` means lld (clang) or gold (gcc) in this stage, via a PATH shim.
# -fuse-ld=lld in LDFLAGS is not enough: libtool forwards only flags it knows
# (-O*, -flto*, -fstack-protector*, ...) to its shared-library link template, so
# opcache.la was linked by /usr/bin/ld, which cannot read ThinLTO bitcode:
#
#   /usr/bin/ld: warning: -z keep-text-section-prefix ignored
#   ext/opcache/.libs/ZendAccelerator.o: file not recognized: file format not recognized
#
# This shows only on 7.0-8.4; 8.5 compiles opcache into the binary.
# -Wc,-fuse-ld=lld would reach libtool's compiler flags, but ./configure's own
# probes call clang directly, where it is an unknown argument; every probe would
# fail and autoconf would read that as a feature answer.
# gcc needs gold for a different reason: its profile-guided hot/cold split puts
# hot functions in .text.hot.* input sections, and the default bfd ld
# (binutils 2.47 on trixie) does not fold them into a .text.hot output section,
# so assert_profile_reached_the_link would measure nothing. gold does. A
# -fuse-ld=gold flag fails for the same libtool reason as lld.
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
# The fetch scripts share the cache helper; it lives under deps/, outside the
# `COPY php/` tree above.
COPY deps/fetch-verified.sh /build/deps/fetch-verified.sh
# The runtime opcache settings. php/pgo/train.sh replays them onto the
# instrumented binary so the profile is taken with the JIT, interned-string
# buffer and accelerated-file count deployments use, with no second copy to drift.
COPY conf/opcache.ini /build/conf/opcache.ini

# php.net tarballs are GPG-signed. The release keys are vendored in
# php/release-keys.asc and imported offline: a keyserver fetch per build is flaky
# in CI and trusts whatever comes back. The sha256 pins in php/php-src.lock are
# additive to the GPG check and put the fetch through the content-addressed
# cache, so it survives a php.net or GitHub outage.
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

# Patches apply in filename order (the NNN- prefix). --fuzz=0: `patch` otherwise
# applies a partly matching hunk ("succeeded at 42 with fuzz 2") and exits 0, a
# silent behavior change on a security-relevant binary; a patch whose context no
# longer matches exactly must fail the build. --forward turns an already-applied
# patch into an error instead of an interactive prompt; --batch keeps the rest
# non-interactive. A version without a directory needs no patches (8.1-8.5);
# deps/patches/README.md records which versions carry what. The count is echoed
# so "applied nothing" is visible in the log.
RUN set -eux; \
    dir="/build/patches/php-${PHP_VERSION}"; \
    n=0; \
    if [ -d "$dir" ]; then for p in "$dir"/*.patch; do \
      [ -e "$p" ] || continue; echo "applying $p"; \
      patch -p1 --batch --forward --fuzz=0 < "$p"; n=$((n+1)); \
    done; fi; \
    echo "php-${PHP_VERSION}: applied $n patch(es) from deps/patches"

# PECL sources land in ext/ before buildconf so configure treats them as core.
# --force: the release tarball ships a generated configure, and buildconf refuses
# to run without it.
RUN --mount=type=cache,target=/var/cache/src,id=php-src-cache,sharing=locked \
    set -eux; \
    bash /build/php/fetch-pecl.sh "$PHP_VERSION" "$PWD"; \
    ./buildconf --force

# The corpus is mounted on every build, not only PGO ones: a mount cannot be
# conditional, and a placeholder image for pgo=false would split the fallback
# path from the real one. scripts/gen_matrix.py derives the tag per version from
# scripts/pgo_tiers.py.
#
# /corpus is rw because Laravel, Symfony and WordPress write while serving
# (compiled views, sqlite journals); the write layer is discarded with this RUN.
# /corpus-src stays read-only: it holds the endpoints files train.sh asserts
# against, which training must not be able to rewrite.
#
# The apt cache mounts are for build.sh installing mariadb-server, which the
# PrestaShop corpus app needs while training (php/pgo/train.sh brackets it with
# corpus/prestashop/db-up.sh and db-down.sh). It stays in this stage:
# runtime-base copies only specific /usr/local paths out, and tests/smoke.sh
# asserts the mariadb-server binaries are absent from shipped images.
RUN --mount=type=cache,target=/root/.cache/ccache \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=bind,from=corpus,source=/corpus,target=/corpus,rw \
    --mount=type=bind,from=corpus,source=/corpus-src,target=/corpus-src \
    bash /build/php/build.sh

# Shared extensions: built against the installed PHP, dropped into extension_dir,
# never enabled. Must run before runtime-libs.sh, whose single scan of
# /usr/local/lib has to see these .so files to pull in their runtime libraries.
#
# No deps prefix on ldflags.sh: it would add /opt/net-snmp's rpath and
# --exclude-libs=ALL to every shared extension, and only snmp.so needs them.
# snmp.so's RUNPATH comes from what ext-snmp's configure links via
# net-snmp-config; tests/smoke.sh asserts it.
#
# PHP_ERA is exported explicitly: build-shared-ext.sh requires it to pick the
# configure/make flag split (php/flag-split.sh) and must fail when unset, since a
# default would drop the demotions that keep autoconf's probes answerable on the
# legacy branches.
RUN --mount=type=cache,target=/root/.cache/ccache \
    --mount=type=cache,target=/var/cache/src,id=php-src-cache,sharing=locked \
    set -eux; \
    export CFLAGS="$(bash /build/php/cflags.sh "$UARCH")"; \
    export CXXFLAGS="$CFLAGS -std=c++17"; \
    export LDFLAGS="$(bash /build/php/ldflags.sh)"; \
    export PHP_ERA="$PHP_ERA"; \
    bash /build/php/build-shared-ext.sh "$PHP_VERSION" "$PWD"; \
    find /usr/local/lib/php/extensions -name '*.so' -exec strip --strip-unneeded {} +

# chmod-sanitize: an opt-in LD_PRELOAD shim rewriting chmod/fchmod/fchmodat(path, 0)
# to 0644 (files) / 0755 (dirs). It works around a PrestaShop cache-regeneration
# bug where chmod(file, 0000) is not followed by a successful replacement, leaving
# every later request a 500 (PS issues #10998, #13050, #30786, #37666). Built
# after the PHP steps so editing it does not invalidate the PHP build cache, and
# before runtime-libs.sh so that scan covers it.
COPY shim/chmod-sanitize.c /build/shim/chmod-sanitize.c
# Built through php/cflags.sh and php/ldflags.sh so this object, which is
# LD_PRELOADed into every FPM worker, gets the same hardening as the rest (-z now,
# stack protector, _FORTIFY_SOURCE, -fcf-protection). $CC, not a hardcoded
# compiler, so it matches the rest of the image.
RUN set -eux; \
    CFLAGS="$(bash /build/php/cflags.sh "$UARCH")"; \
    LDFLAGS="$(bash /build/php/ldflags.sh)"; \
    $CC -shared $CFLAGS $LDFLAGS -Wall \
      -o /usr/local/lib/php-chmod-sanitize.so /build/shim/chmod-sanitize.c -ldl; \
    strip --strip-unneeded /usr/local/lib/php-chmod-sanitize.so

# Trim /deps-stage to what a running php loads; the COPY out of this stage sees
# the final view, so removing here keeps these files out of the runtime layer.
# php links only MagickWand and MagickCore (imagick is static), so the Magick++
# binding and ImageMagick's pkg-config files are dead weight, as are the
# Makefile.inc files of the legacy era's vendored ICU.
RUN set -eux; \
    rm -f /deps-stage/opt/imagemagick/lib/libMagick++-*; \
    rm -rf /deps-stage/opt/imagemagick/lib/pkgconfig; \
    if [ -d /deps-stage/opt/php-deps/lib/icu ]; then \
      find /deps-stage/opt/php-deps/lib/icu -name Makefile.inc -delete; \
    fi

# Resolve the runtime package set from actual linkage.
RUN bash /build/scripts/runtime-libs.sh /usr/local/bin /usr/local/sbin /usr/local/lib \
      > /tmp/runtime-packages.txt && cat /tmp/runtime-packages.txt

# --- runtime-conf ---
# Build-only: the config half of the runtime payload, assembled and
# version-patched under /stage so runtime-base takes it in one COPY.
FROM ${BASE_IMAGE} AS runtime-conf
ARG PHP_VERSION

# php-ext-enable is the only thing that may turn a shared module on; copying it
# here gives every flavor the same copy. --chmod makes the image independent of
# file modes in the checkout.
COPY --chmod=0755 rootfs/ /stage/

# CA trust store, for every flavor and era. The legacy era's vendored OpenSSL has
# no CA store of its own, so TLS peer verification through PHP's openssl extension
# (file_get_contents, stream_socket_client, SoapClient, SMTP+TLS) would fail
# without help; curl resolves its own bundle and hides it. deps/build-deps.sh's
# `--openssldir=/etc/ssl` sets the compiled-in default to Debian's store; this ini
# is the explicit half and is harmless on the modern era.
COPY conf/openssl.ini /stage/usr/local/etc/php/conf.d/12-openssl.ini

# Baseline opcache settings, shared unmodified by every flavor. The numeric prefix
# sorts before the entrypoint-written 90-opcache-env.ini and 99-env.ini, which
# win. FPM pool tuning is ${VAR}-driven in www.conf; no file is written for it.
COPY conf/opcache.ini /stage/usr/local/etc/php/conf.d/15-opcache.ini
# PHP 8.5 folded opcache into the engine (configure-args.sh omits --enable-opcache
# from 8.5), so conf/opcache.ini suffices there. On 7.0-8.4 a statically compiled
# opcache still needs zend_extension= to register as a Zend extension (php -m
# shows no opcache otherwise). On 8.5 the line produces "Failed loading Zend
# extension 'opcache'" on every request, so it is version-gated.
# The ".so" matters: on 7.0 and 7.1 "zend_extension=opcache" resolves to
# <extension_dir>/opcache without a suffix and every php invocation prints
# "Failed loading .../opcache: cannot open shared object file". The suffixed form
# works on every version, so it is not gated.
RUN [ "$PHP_VERSION" = "8.5" ] || echo "zend_extension=opcache.so" >> /stage/usr/local/etc/php/conf.d/15-opcache.ini

# PHP before 7.3 cannot allocate the 32MB interned strings buffer that
# conf/opcache.ini asks for: there it is carved from opcache's shared segment with
# a 16MB ceiling, and exceeding it is a fatal "Zend OPcache cannot allocate buffer
# for interned strings" at startup. 7.0-7.2 images exited 254 before accepting a
# connection. 16 is still twice opcache's default of 8.
#
# Guarded on both sides: `sed -i` exits 0 whether or not it matched, so a reworded
# conf/opcache.ini would silently turn this into a no-op.
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

# Snuffleupagus rulesets: present in every flavor but inert until
# PHP_SNUFFLEUPAGUS names one. The module is a dormant shared .so and no baked ini
# references it.
COPY conf/snuffleupagus/ /stage/usr/local/etc/php/snuffleupagus/

# --- runtime-payload ---
# Build-only, in two halves so runtime-base needs two COPYs (two layers), split by
# change rate: this one holds the tens of MB (php, extensions, vendored libraries),
# the next the few KB of config, so an ini, rootfs script or ruleset edit re-ships
# only the small layer.
FROM scratch AS runtime-payload
# Vendored libraries (ImageMagick and net-snmp in every era, plus the legacy
# era's openssl/icu/curl) at the absolute path their binaries' rpath names
# (php/build.sh stages them). One COPY covers both eras.
COPY --from=php-build /deps-stage/ /

COPY --from=php-build /usr/local/bin/php /usr/local/bin/php
COPY --from=php-build /usr/local/lib/php /usr/local/lib/php
# What the compile did: pgo on or off, the flags, the profile sha256 and
# coverage, the corpus versions. tests/test-pgo.sh cross-checks the pgo= line
# against matrix.json, so a version that silently stops taking PGO fails a test.
COPY --from=php-build /usr/local/share/php-build /usr/local/share/php-build
# chmod-sanitize.so: in every flavor, opt-in via PHP_CHMOD_SHIM in the entrypoint.
COPY --from=php-build /usr/local/lib/php-chmod-sanitize.so /usr/local/lib/php-chmod-sanitize.so

# php-build's own /usr/local/etc/php first, then everything runtime-conf baked on
# top of it (later wins). runtime-base copies this half last.
FROM scratch AS runtime-payload-conf
COPY --from=php-build /usr/local/etc/php /usr/local/etc/php
COPY --from=runtime-conf /stage/ /

# --- runtime-base ---
FROM ${BASE_IMAGE} AS runtime-base
ARG PHP_VERSION
ARG WWW_UID=33
ARG WWW_GID=33
# Core client packages rather than the metapackages (~38MB instead of ~85MB).
# 17 is trixie's PostgreSQL major.
ARG PG_MAJOR=17
# Without a UTF-8 LC_CTYPE, PHP 7.x's basename()/pathinfo() treat multibyte
# bytes as invalid and cut them away: basename('/x/файл.txt') is '.txt', and
# ZipArchive::extractTo() writes '日本語/.txt'. 8.0+ is locale-independent there.
# C.UTF-8 is built into glibc, no locales package needed.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

COPY --from=php-build /tmp/runtime-packages.txt /tmp/runtime-packages.txt
# upgrade: BASE_IMAGE is digest-pinned, so without it a Debian security fix to a
# package the base already ships (e.g. libpcre2-8-0 on the legacy era) waits for
# the next digest bump instead of landing in the weekly rebuild.
RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl tzdata tini less nano procps \
      tar gzip bzip2 zip unzip zstd xz-utils \
      mariadb-client-core "postgresql-client-${PG_MAJOR}" \
# libfcgi-bin ships cgi-fcgi, which php-fpm-healthcheck uses to speak FastCGI to
# the pool's ping.path without a front web server.
      libfcgi-bin \
      $(tr '\n' ' ' < /tmp/runtime-packages.txt); \
# /usr/bin/psql is a symlink to pg_wrapper, a perl script that dispatches between
# installed postgres majors; with one major, it is the only reason ~49MB of perl
# modules and libperl.so are here. Keep the real client binaries and drop the
# wrapper. postgresql-client-N depends on postgresql-client-common, so the
# binaries are copied out before the purge. Naming only `perl` lets apt take
# libperl/perl-modules with it across perl majors; this works because nothing else
# depends on libperl (Debian's libsnmp40t64 does, hence the vendored net-snmp,
# deps/build-netsnmp.sh). tests/smoke.sh asserts libperl is gone. perl-base, with
# /usr/bin/perl, stays: it is Essential.
    for b in psql pg_dump pg_dumpall pg_restore pg_isready; do \
      cp -a "/usr/lib/postgresql/${PG_MAJOR}/bin/$b" "/usr/local/bin/$b"; \
    done; \
    apt-get purge -y --auto-remove "postgresql-client-${PG_MAJOR}" perl; \
# dpkg --audit exits 0 either way; any output means the purge left a
# half-configured package.
    audit="$(dpkg --audit 2>&1 || true)"; \
    [ -z "$audit" ] || { echo "$audit" >&2; echo "FATAL: inconsistent dpkg state after purge" >&2; exit 1; }; \
    rm -rf /var/lib/apt/lists/* /tmp/runtime-packages.txt; \
# Housekeeping goes in this RUN because a later one would only whiteout files this
# layer already stored. debconf keeps a *-old copy of its databases (0.8MB). Files
# of installed packages stay, however unused: dpkg still lists the package, so apt
# never restores a deleted file, and a derived image installing mariadb-server
# fails in mariadb-install-db on the missing my_print_defaults.
    rm -f /var/cache/debconf/*-old

# php-build's output, then the baked config, as two layers (see runtime-payload).
# The config layer stays last so a config edit never re-ships the binaries.
COPY --from=runtime-payload / /
COPY --from=runtime-payload-conf / /

RUN set -eux; \
    getent group www-data >/dev/null || groupadd -g "$WWW_GID" www-data; \
    id -u www-data >/dev/null 2>&1 || useradd -u "$WWW_UID" -g "$WWW_GID" -s /usr/sbin/nologin -M www-data; \
    mkdir -p /app /usr/local/etc/php/conf.d; \
    chown -R www-data:www-data /app; \
# php-ext-enable writes here as whatever user runs the container (the flavors set
# USER www-data, and the entrypoint's PHP_EXT_ENABLE runs after the drop). Root
# ownership made every invocation fail with EACCES. PHP_CONF_DIR is the
# counterpart for a read-only rootfs.
    chown www-data:www-data /usr/local/etc/php/conf.d; \
# net-snmp keeps state in /var/lib/snmp (cert_indexes below it), creating both on
# first use and logging "Created directory: ..." to stderr. Creating them up front
# owned by www-data keeps that silent; a non-root user cannot create them under a
# root-owned /var/lib.
    install -d -o www-data -g www-data /var/lib/snmp /var/lib/snmp/cert_indexes; \
    find / -xdev -perm /6000 -type f -exec chmod a-s {} + || true

WORKDIR /app
# tini reaps zombies and forwards signals; docker-php-entrypoint turns the
# environment into ini/pool overrides, then execs "$@".
ENTRYPOINT ["/usr/bin/tini", "--", "docker-php-entrypoint"]

# --- flavors ---
# Build-only: php-fpm's files plus the two pool/ini configs as one tree, for a
# single COPY (one layer) into fpm. conf/www.conf is copied last so it replaces
# the stock pool file.
FROM scratch AS fpm-payload
COPY --from=php-build /usr/local/sbin/php-fpm /usr/local/sbin/php-fpm
COPY --from=php-build /usr/local/etc/php-fpm.conf /usr/local/etc/php-fpm.conf
COPY --from=php-build /usr/local/etc/php-fpm.d /usr/local/etc/php-fpm.d
COPY conf/php-fpm.ini /usr/local/etc/php/conf.d/10-php.ini
COPY conf/www.conf /usr/local/etc/php-fpm.d/www.conf

FROM runtime-base AS fpm
# ARG does not cross a FROM; without this redeclaration the version gates below
# silently match nothing.
ARG PHP_VERSION
COPY --from=fpm-payload / /
# The entrypoint never writes a pool config file, even on a read-only rootfs:
# www.conf references every tunable pool directive as ${PHP_FPM_*}, which php-fpm
# resolves from its environment at startup. These ENV defaults are what a
# container that bypasses docker-php-entrypoint (`--entrypoint php-fpm`) gets. An
# unresolved ${VAR} is a hard startup failure for pm.max_children and listen, so
# they cannot be left unset. The entrypoint autotunes and exports
# pm.max_children/start_servers/min_spare_servers/max_spare_servers; the rest pass
# straight through.
#
# The four autotuned values are baked under _EFFECTIVE names that operators are
# not expected to set. The operator-facing names (PHP_FPM_MAX_CHILDREN, ...) get
# no ENV default, so "unset" still means "nobody asked for a number" in the
# entrypoint. A baked default there would make an explicit
# `-e PHP_FPM_MAX_CHILDREN=16` indistinguishable from an untouched one, and it
# would be silently autotuned up (to 44 workers on a 4GB container).
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
# One RUN for everything that edits or verifies the files above.
RUN set -eux; \
# php-fpm's stock config logs to $prefix/var/log and writes its pid to
# $prefix/var/run; make install creates both in the build stage, not here.
    mkdir -p /usr/local/var/log /usr/local/var/run; \
    chown -R www-data:www-data /usr/local/var; \
# Copying fpm-payload as a tree also stamps its root-owned conf.d over the
# writable one runtime-base made for php-ext-enable; hand it back.
    chown www-data:www-data /usr/local/etc/php/conf.d; \
# The stock php-fpm.conf [global] error_log defaults to a file under
# $prefix/var/log (commented out). With catch_workers_output=yes in www.conf,
# each worker's fd 2 is a private pipe to the master, so a worker's
# php_admin_value[error_log]=/proc/self/fd/2 hits that pipe and the master re-logs
# the line through its own error_log. At the stock default that line, and the
# master's own notices, go to /usr/local/var/log/php-fpm.log and never reach
# `docker logs`. Pointing the global log at /proc/self/fd/2 closes the loop: there
# "self" is the master, whose fd 2 is the container's stderr.
#
# `sed -i` exits 0 whether or not it matched, so a bare substitution would
# silently no-op if a PHP point release rewords the line, and the image would look
# healthy. Guarded on both sides: require exactly one error_log directive
# (commented or not) before, and the replacement after. The regex matches any
# error_log value, so only the directive disappearing or multiplying fails.
    n="$(grep -cE '^;?error_log[[:space:]]*=' /usr/local/etc/php-fpm.conf || true)"; \
    [ "$n" = "1" ] || { echo "FATAL: expected exactly one [global] error_log directive in php-fpm.conf, found $n" >&2; exit 1; }; \
    sed -i -E 's|^;?error_log[[:space:]]*=.*|error_log = /proc/self/fd/2|' /usr/local/etc/php-fpm.conf; \
    grep -qx 'error_log = /proc/self/fd/2' /usr/local/etc/php-fpm.conf \
      || { echo "FATAL: php-fpm.conf error_log substitution did not apply" >&2; exit 1; }; \
# docker-php-entrypoint refuses a PHP_FPM_*_EFFECTIVE differing from what this
# stage baked (they are computed outputs, and the only pool variables
# `docker image inspect` shows, so operators find and set them by mistake). It
# compares against BAKED_* constants in the script, which must match the ENV above
# or every container refuses to start; fail the build instead.
    for pair in "MAX_CHILDREN=$PHP_FPM_MAX_CHILDREN_EFFECTIVE" \
                "START_SERVERS=$PHP_FPM_START_SERVERS_EFFECTIVE" \
                "MIN_SPARE=$PHP_FPM_MIN_SPARE_EFFECTIVE" \
                "MAX_SPARE=$PHP_FPM_MAX_SPARE_EFFECTIVE"; do \
      grep -qx "BAKED_${pair}" /usr/local/bin/docker-php-entrypoint \
        || { echo "FATAL: docker-php-entrypoint has no 'BAKED_${pair}' -- its constants disagree with this stage's PHP_FPM_*_EFFECTIVE ENV defaults" >&2; exit 1; }; \
    done; \
# decorate_workers_output arrived in php-fpm 7.3. On 7.0-7.2 it is a hard startup
# failure, not an ignored key:
#
#   ERROR: [/usr/local/etc/php-fpm.d/www.conf:41] unknown entry 'decorate_workers_output'
#   ERROR: FPM initialization failed                                    (exit 78)
#
# Removing the line restores php-fpm's default (undecorated output), which is what
# `no` asks for. Guarded like the other substitutions: `sed -i` exits 0 whether or
# not it matched.
    case "$PHP_VERSION" in \
      7.0|7.1|7.2) \
        grep -qx 'decorate_workers_output = no' /usr/local/etc/php-fpm.d/www.conf \
          || { echo "FATAL: conf/www.conf no longer sets decorate_workers_output = no; the <7.3 removal below is dead" >&2; exit 1; }; \
        sed -i '/^decorate_workers_output = no$/d' /usr/local/etc/php-fpm.d/www.conf; \
        ! grep -q '^decorate_workers_output' /usr/local/etc/php-fpm.d/www.conf \
          || { echo "FATAL: decorate_workers_output survived removal" >&2; exit 1; }; \
        echo "ok: dropped decorate_workers_output for php $PHP_VERSION" ;; \
    esac; \
# php-fpm refuses to start on any directive it does not recognize, so check the
# config here: `php -r` runs fine on an image whose fpm binary cannot initialize.
# This catches any directive that outruns the oldest PHP in the matrix.
    php-fpm -t
EXPOSE 9000
STOPSIGNAL SIGQUIT
# php-fpm-healthcheck (vendored) speaks FastCGI to the pool's ping.path
# (conf/www.conf) via cgi-fcgi, so no front web server or extra HTTP port is
# needed. It runs as www-data, like the main command.
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD php-fpm-healthcheck || exit 1
USER www-data
CMD ["php-fpm", "-F"]

FROM runtime-base AS cli
COPY conf/php-cli.ini /usr/local/etc/php/conf.d/10-php.ini
USER www-data
CMD ["php", "-a"]

# Node 24 LTS for cli-builder, copied from the official image (trixie ships the
# unmaintained Node 20). Pinned by multi-arch index digest so amd64 and arm64 both
# resolve it and a retag cannot change what ships.
FROM node:24-trixie-slim@sha256:8ec5d7557396cfe32d21c3f9c13072355ceab22b584578ca4bb28af31120cffe AS node24

# Node, npm and semantic-release as one tree for cli-builder, finished here so no
# intermediate npm lands in a shipped layer (upgrading npm in a later RUN left the
# bundled 11.19 copy, ~20MB, underneath).
#
# npm moves past the bundled 11.19.0 to 11.21.0, which ships the fixed tar and
# ip-address; its bundled brace-expansion and undici are still behind their fixes
# in every npm release (see .trivyignore). /out is built by hand because
# /usr/local/bin also holds the node image's docker-entrypoint.sh and yarn.
# semantic-release is not run here (it refuses to start without git);
# tests/smoke.sh runs `semantic-release --version` in the finished image. The
# readme/changelog markdown in the packages is 2.5MB nothing reads.
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

# cli-builder: composer, node and the CLI tooling a build or deploy stage needs.
# No compiler or phpize; compiling extensions is ext-builder's job.
FROM cli AS cli-builder
USER root
COPY --from=node-tools /out/ /usr/local/
# runtime-base already has less, nano, procps, zip, unzip and zstd.
# mariadb-client-core has only the mariadb/mysql shell; mariadb-client adds
# mariadb-dump/mysqldump (and pulls perl back in).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      git rsync patch make brotli sqlite3 jq mariadb-client; \
    rm -rf /var/lib/apt/lists/*; \
    rm -f /var/cache/debconf/*-old
COPY conf/php-builder.ini /usr/local/etc/php/conf.d/10-php.ini
# Verify the installer against Composer's published signature rather than piping
# the download into php.
RUN set -eux; \
    curl -fsSLo /tmp/composer-setup.php https://getcomposer.org/installer; \
    curl -fsSLo /tmp/composer-setup.sig https://composer.github.io/installer.sig; \
    echo "$(cat /tmp/composer-setup.sig)  /tmp/composer-setup.php" | sha384sum -c -; \
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer; \
    rm -f /tmp/composer-setup.php /tmp/composer-setup.sig; \
    composer --version
USER www-data
# www-data's HOME (/var/www) does not exist, so npm and corepack could not create
# their caches.
ENV COMPOSER_HOME=/tmp/composer \
    npm_config_cache=/tmp/npm \
    COREPACK_HOME=/tmp/corepack
CMD ["bash"]

# Build-only: the three paths ext-builder takes from php-build, as one tree.
FROM scratch AS ext-builder-payload
COPY --from=php-build /usr/local/bin/phpize /usr/local/bin/phpize
COPY --from=php-build /usr/local/bin/php-config /usr/local/bin/php-config
COPY --from=php-build /usr/local/include/php /usr/local/include/php

# Build-stage-only image for compiling PHP extensions that are then COPYed into
# fpm/cli of the same PHP version. It reuses php-build's output (no second compile
# or PGO run), taking only the headers and phpize/php-config. Runs as root because
# `make install` writes into the extension dir. No composer, no node.
FROM cli AS ext-builder
USER root
# g++: several extensions are C++. autoconf: phpize regenerates ./configure from
# config.m4. pkg-config: extension configure scripts locate -dev libraries with it.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      gcc g++ make autoconf pkg-config libc6-dev; \
    rm -rf /var/lib/apt/lists/*; \
    rm -f /var/cache/debconf/*-old
COPY --from=ext-builder-payload / /
CMD ["bash"]
