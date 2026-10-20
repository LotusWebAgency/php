# syntax=docker/dockerfile:1.28@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# One Dockerfile for every published tag; docker-bake.hcl feeds it the matrix.
ARG BASE_IMAGE=cgr.dev/chainguard/wolfi-base:latest@sha256:c2a4815b6ca49b9bbafd451b4bde690d567a86b2b6b54877faac8082a7bc4296
ARG PHP_ERA=modern
# Declared before any FROM so `FROM toolchain-select-${COMPILER}` can resolve it.
# The toolchain-base stage redeclares it for use inside the stage.
ARG COMPILER=clang

# --- toolchain ---
# Busybox's raw-socket and interface applets have no job in a PHP runtime and only
# hand an attacker with code execution a ready-made network toolbox. Every image
# stage that runs `apk add` prunes them again, because busybox's apk trigger
# recreates the links. curl stays (healthchecks and Composer need it); tests/smoke.sh
# asserts these are gone.
ARG BUSYBOX_NET_APPLETS="arping dnsdomainname microcom netstat ping ping6 traceroute traceroute6 tunctl vconfig"

FROM ${BASE_IMAGE} AS toolchain-base
ARG COMPILER=clang
# The compiler binary names COMPILER implies, supplied by docker-bake.hcl (clang
# -> clang++ is not a string transform). Defaults are the clang set so a bare
# `docker build` works. Bare names, not paths: ccache's masquerade symlinks in
# /usr/lib/ccache/bin dispatch on the argv[0] basename.
ARG CXX_COMPILER=clang++
ARG AR_COMPILER=llvm-ar
ARG RANLIB_COMPILER=llvm-ranlib
ARG NM_COMPILER=llvm-nm
# The base's repository is apk.cgr.dev/chainguard; every package here comes from
# the public Wolfi index instead. The Wolfi signing key is already trusted by the
# base, so only the URL changes.
#
# The build scripts are bash and use GNU grep/sed/find/coreutils options that the
# base's busybox applets lack.
#
# build-base brings the native GCC 16.2 (toolchain-select-gcc asserts it) and the
# binutils tools both toolchains share. PHP's HYBRID VM pins execute_data/opline
# into registers via GCC global register variables (HAVE_GCC_GLOBAL_REGS,
# Zend/zend_execute.c), a GNU-C extension clang lacks, so COMPILER=gcc is the
# path that keeps that dispatch.
# upgrade: the digest-pinned base can hold a library older than the -dev package the
# deps stages install next (sqlite-libs 3.54.0 beside sqlite-dev 3.54.1, whose
# libsqlite3.so names a file only 3.54.1 ships), and gold, unlike GNU ld, fails the
# link on that dangling symlink. WOLFI_INDEX_STATE re-runs this layer whenever the
# index stamp changes instead of replaying a cached upgrade.
ARG WOLFI_INDEX_STATE=""
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    echo "wolfi index state: ${WOLFI_INDEX_STATE:-unset}" \
    && echo 'https://packages.wolfi.dev/os' > /etc/apk/repositories \
    && apk upgrade --cache-dir /var/cache/apk -U \
    && apk add --cache-dir /var/cache/apk \
      build-base clang-19 lld-19 llvm-19 binutils-gold ccache pkgconf ca-certificates curl \
      bash coreutils findutils grep sed gawk diffutils \
      autoconf automake libtool bison re2c patch xz file \
      gpg gpg-agent python3 linux-headers \
    && apk list -I gcc binutils clang-19 lld-19 llvm-19 | sort > /etc/compiler-revisions \
    && case "$COMPILER" in clang|gcc) ;; *) echo "COMPILER must be clang or gcc, got COMPILER=$COMPILER" >&2; exit 1 ;; esac
# Wolfi's compilers harden by default (gcc through /usr/local/bin wrappers that add
# -specs openssf.spec, clang through /etc/clang/*.cfg) and bake in -march=x86-64-v2
# -mtune=sapphirerapids (arm64: armv8-a+crc+crypto -mtune=neoverse-v2). Both switches
# turn those defaults off so php/cflags.sh decides every flag, including the part of
# the default hardening set it restores itself. GCC_SPEC_FILE drops
# only the hardening: gcc keeps its compiled-in -march/-mtune, so every compile,
# vendored libraries included, must take its arch flags from php/cflags.sh.
ENV GCC_SPEC_FILE=no-hardening.spec CLANG_NO_DEFAULT_CONFIG=1
# ccache's default compiler check hashes the mtime of the compiler binary. For gcc
# that is the openssf wrapper script, which a gcc upgrade does not touch, and
# `--version` does not change between apk revisions of one version. The check
# hashes the installed package revisions instead (a file, so each compile pays one
# cat rather than an apk run).
ENV CCACHE_COMPILERCHECK="cat /etc/compiler-revisions"
ENV CC=$COMPILER CXX=$CXX_COMPILER AR=$AR_COMPILER RANLIB=$RANLIB_COMPILER NM=$NM_COMPILER
# Plain ENV rather than the ARG, which does not survive into child stages:
# php/build.sh, php/pgo/train.sh and php/pgo/discriminator-control.sh branch on it.
ENV COMPILER=$COMPILER
ENV PATH=/usr/lib/ccache/bin:$PATH
# gcc ships its own omp.h, found without -fopenmp. PECL imagick's config.m4 uses
# that header plus a -lgomp link as its "GCC with OpenMP" probe and then adds
# -lgomp to the static imagick, giving gcc builds a libgomp NEEDED entry that
# clang builds (no omp.h without libomp-dev) never get. Removing the header makes
# gcc answer "no OpenMP" like clang, matching deps/build-imagemagick.sh's
# --disable-openmp. Nothing else includes <omp.h>.
RUN if [ "$COMPILER" = "gcc" ]; then \
      find /usr/lib /usr/lib64 -path '*/gcc/*/include/omp.h' -delete; \
    fi

# The shipped compilers: COMPILER=clang (Wolfi's clang 19, a plain passthrough)
# and COMPILER=gcc (Wolfi's GCC 16.2). `toolchain` resolves to the one COMPILER
# names.
FROM toolchain-base AS toolchain-select-clang

FROM toolchain-base AS toolchain-select-gcc
# Fail if gcc/cc do not resolve to GCC 16.2 (a stale PATH, a masquerade
# regression or a Wolfi bump past 16.2 would otherwise build with the wrong
# compiler and still pass).
RUN v="$(gcc -dumpfullversion)"; case "$v" in \
      16.2*) echo "ok: COMPILER=gcc resolves to GCC $v" ;; \
      *) echo "FATAL: COMPILER=gcc must resolve to GCC 16.2.x, got $v" >&2; exit 1 ;; \
    esac

FROM toolchain-select-${COMPILER} AS toolchain

# --- imagemagick ---
# ImageMagick from source: the distro build is a standing CVE source and its
# default OpenMP support causes thread explosions in FPM workers. One stage that
# both deps eras derive from, so it builds once per (arch, COMPILER). It has no
# UARCH: ImageMagick is always baseline.
FROM toolchain AS imagemagick
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add --cache-dir /var/cache/apk -U \
      libpng-dev libjpeg-turbo-dev libwebp-dev tiff-dev freetype-dev \
      openjpeg-dev cmake samurai meson nasm
COPY deps/build-imagemagick.sh deps/build-heif.sh deps/versions.lock deps/fetch-verified.sh /build/deps/
COPY php/arch.sh php/cflags.sh php/ldflags.sh /build/php/
RUN --mount=type=cache,target=/var/cache/src,id=php-src-cache,sharing=locked \
    bash /build/deps/build-imagemagick.sh /opt/imagemagick
# Nothing upstream sets PKG_CONFIG_PATH; a flat assignment avoids buildkit's
# UndefinedVar lint.
ENV PKG_CONFIG_PATH=/opt/imagemagick/lib/pkgconfig

# --- net-snmp ---
# net-snmp's client library, vendored so the runtime needs neither the distro's
# net-snmp packages nor perl. Its own stage so it neither invalidates nor waits for
# ImageMagick; both eras share the result. It links the system OpenSSL
# (openssl-4.0-dev below), never the legacy vendored one; OpenSSL 4 made ASN1_STRING
# opaque, which deps/patches/net-snmp-5.9.5.2 accounts for.
# The deps stages COPY the whole prefix (ext-snmp needs net-snmp-config and the
# headers); php/build.sh's stage_runtime_deps ships only the library and MIBs.
FROM toolchain AS net-snmp
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add --cache-dir /var/cache/apk -U openssl-4.0-dev
COPY deps/build-netsnmp.sh deps/versions.lock deps/fetch-verified.sh /build/deps/
COPY deps/patches/net-snmp-5.9.5.2 /build/deps/patches/net-snmp-5.9.5.2
COPY php/arch.sh php/cflags.sh php/ldflags.sh /build/php/
RUN --mount=type=cache,target=/var/cache/src,id=php-src-cache,sharing=locked \
    bash /build/deps/build-netsnmp.sh /opt/net-snmp

# --- libssh2 ---
# libssh2 for ext-ssh2, vendored from an upstream master commit (the fixes for six
# HIGH CVEs are unreleased) and installed as a static archive that ssh2.so absorbs, so
# neither the distro's libssh2 package nor a libssh2.so ships. Its own stage, shared by
# both eras. It links the system OpenSSL (openssl-4.0-dev below), never the legacy
# vendored one. The deps stages COPY the prefix (ext-ssh2 needs the header and the
# archive); nothing of it reaches the runtime image except what ssh2.so holds.
FROM toolchain AS libssh2
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add --cache-dir /var/cache/apk -U openssl-4.0-dev zlib-dev
COPY deps/build-libssh2.sh deps/versions.lock deps/fetch-verified.sh /build/deps/
COPY php/arch.sh php/cflags.sh php/ldflags.sh /build/php/
RUN --mount=type=cache,target=/var/cache/src,id=php-src-cache,sharing=locked \
    bash /build/deps/build-libssh2.sh /opt/libssh2

# --- deps: modern ---
# PHP 8.1+ links against what Wolfi ships. The system OpenSSL is 4.0: curl-dev
# requires openssl-4.0-dev, which conflicts with openssl-dev (3.6), so ext/openssl
# builds against 4.0 too, with the SSL_CTX options patch from deps/patches.
FROM imagemagick AS deps-modern
# GD also needs libavif-dev; the other image libraries come from the imagemagick stage.
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add --cache-dir /var/cache/apk -U \
      openssl-4.0-dev curl-dev libxml2-dev libxslt-dev icu-dev \
      oniguruma-dev libzip-dev sqlite-dev postgresql-18-dev zlib-dev zstd-dev \
      brotli-dev libavif-dev \
      libsodium-dev argon2-dev gmp-dev readline-dev libmemcached-dev \
# Shared-extension dependencies: one package per non-empty `libs` entry in
# php/ext.json for each linkage:"shared" extension. libmcrypt-dev is for mcrypt
# on PHP < 8.0. imap is absent: Wolfi has no c-client. pcre2-dev is
# snuffleupagus's build dependency (its config.m4 calls pcre2-config).
      rabbitmq-c-dev bzip2-dev libffi-dev openldap-2.7-dev libldap-2.7 lz4-dev \
      libmcrypt-dev tidy-html5-dev util-linux-dev \
      yaml-dev libevent-dev pcre2-dev
# ext-snmp links this instead of the distro's net-snmp-dev.
COPY --from=net-snmp /opt/net-snmp /opt/net-snmp
# ext-ssh2 links this instead of the distro's libssh2-dev.
COPY --from=libssh2 /opt/libssh2 /opt/libssh2
ENV PHP_DEPS_PREFIX=""

# --- deps: legacy ---
# PHP 7.0-8.0 cannot link against Wolfi's libraries: OpenSSL 3 support only
# became solid in 8.1, and ICU 74+ needs C++17 that ext/intl below 8.1 does not
# use, and libxml2 2.15 is past what php-src below 8.1.27 compiles against. This
# era vendors pinned copies (deps/versions.lock), libxml2 and libxslt included.
#
# OpenSSL, ICU, libxml2 and libxslt are built static-only by deps/build-deps.sh, so
# no EOL libssl.so, duplicate ICU data or second libxml2 exists in the image and
# none needs an rpath. The rpath
# (LD_LIBRARY_PATH would break the host curl; see php/ldflags.sh) covers whatever
# is shared under PHP_DEPS_PREFIX, i.e. the vendored curl of 7.0-7.2.
#
# curl is vendored only for 7.0-7.2: ext/curl's config.m4 takes a DIR-style
# --with-curl=DIR through 7.3 and is pure pkg-config (PKG_CHECK_MODULES) from 7.4.
# 7.4-8.0 build against Wolfi's curl-dev; 7.4 and 8.0 carry
# deps/patches/php-*/010-curl-openssl3-not-old.patch so ext/curl does not link
# a second OpenSSL.
#
# Two further build-environment adjustments:
#   - ext/gd's --with-freetype-dir=/usr (php/ext.json overrides, 7.0-7.3) needs
#     a freetype-config script, which upstream freetype dropped in 2.9.1; Wolfi's
#     package still ships one, and the shim below is created only if it is absent.
#   - ext/intl's -DU_USING_ICU_NAMESPACE=1 (7.0-7.3 use unqualified `icu::`
#     types) is a compile flag set in php/build.sh's CPPFLAGS/CXXFLAGS.
FROM imagemagick AS deps-legacy
ARG PHP_VERSION
# The image libraries come from the imagemagick stage, as in deps-modern. ICU,
# libxml2 and libxslt are vendored, so no icu-dev, libxml2-dev or libxslt-dev
# (php/build.sh points every PHP version at the vendored copies); pkgconf-dev
# ships pkg.m4, which their autoreconf needs. openssl-4.0-dev is for ext-snmp only: net-snmp-config
# adds -lssl -lcrypto, which needs the system libssl.so symlink. PHP itself is
# pointed at the vendored OpenSSL by --with-openssl=/opt/php-deps (php/build.sh
# asserts the substitution). No libavif-dev: GD has no AVIF before 8.1.
# Otherwise the package set mirrors deps-modern and must be kept in sync by hand.
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add --cache-dir /var/cache/apk -U \
      openssl-4.0-dev curl-dev pkgconf-dev \
      oniguruma-dev libzip-dev sqlite-dev postgresql-18-dev zlib-dev zstd-dev \
      brotli-dev \
      libsodium-dev argon2-dev gmp-dev readline-dev libmemcached-dev \
      rabbitmq-c-dev bzip2-dev libffi-dev openldap-2.7-dev libldap-2.7 lz4-dev \
      libmcrypt-dev tidy-html5-dev util-linux-dev \
      yaml-dev libevent-dev pcre2-dev
COPY deps/build-deps.sh deps/versions.lock deps/fetch-verified.sh /build/deps/
COPY php/arch.sh php/cflags.sh php/ldflags.sh /build/php/
RUN --mount=type=cache,target=/var/cache/src,id=php-src-cache,sharing=locked \
    bash /build/deps/build-deps.sh "$PHP_VERSION" /opt/php-deps
# After the vendored build (twenty minutes of openssl + ICU + libxml2 + curl) so these
# five-line steps do not invalidate it; build-deps.sh does not use either shim.
# Both satisfy an autoconf search on 7.0-7.3 without changing what is linked,
# and stay in this build-only stage.
#
#  1. freetype-config. ext/gd's config.m4 on these branches tests
#     -f "$i/bin/freetype-config" for $PHP_FREETYPE_DIR, /usr/local and /usr and
#     then calls --cflags and --libs. 7.4 moved gd to pkg-config.
#
#  2. /usr/include/gmp.h. ext/gmp's config.m4 searches $i/include/gmp.h and
#     $i/include/$($CC -dumpmachine)/gmp.h. Wolfi ships gmp.h in /usr/include, so
#     this is a no-op there; it stays keyed off the found path so a distro that
#     moves the header into a triple directory still configures.
RUN set -eu; \
    case "$PHP_VERSION" in \
      7.0|7.1|7.2|7.3) \
        if [ ! -e /usr/bin/freetype-config ]; then \
          printf '%s\n' '#!/bin/sh' 'case "$1" in' \
            '  --cflags) exec pkg-config --cflags freetype2 ;;' \
            '  --libs) exec pkg-config --libs freetype2 ;;' \
            '  --ftversion) exec pkg-config --modversion freetype2 ;;' \
            '  --prefix) exec pkg-config --variable=prefix freetype2 ;;' \
            'esac' 'exit 1' > /usr/bin/freetype-config; \
          chmod +x /usr/bin/freetype-config; \
        fi; \
        gmp_h="$(find /usr/include -maxdepth 2 -name gmp.h -print -quit)"; \
        [ -n "$gmp_h" ] || { echo "gmp-dev is installed but no gmp.h was found under /usr/include" >&2; exit 1; }; \
        [ -e /usr/include/gmp.h ] || ln -s "$gmp_h" /usr/include/gmp.h; \
        echo "gmp.h: $gmp_h -> /usr/include/gmp.h"; \
        ;; \
      *) : ;; \
    esac
# ext-snmp links this instead of the distro's net-snmp-dev.
COPY --from=net-snmp /opt/net-snmp /opt/net-snmp
# ext-ssh2 links this instead of the distro's libssh2-dev.
COPY --from=libssh2 /opt/libssh2 /opt/libssh2
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
# prefix"; Wolfi's icu-dev ships no icu-config. So 7.0 alone needs
# --with-icu-dir=${PHP_DEPS_PREFIX}, which comes from a php/ext.json override
# and is spliced in by php/build.sh (derived from ${PHP_DEPS_PREFIX}/bin/icu-config
# existing, like --with-curl, so the version range lives in one place). Hence this
# ENV names only --with-openssl and --with-xsl. 7.0-7.3 find libxslt by DIR
# (xslt-config) and libxml2 by --with-libxml-dir, a php/ext.json override on dom
# that php/build.sh splices like --with-icu-dir; 7.4+ find both through
# PKG_CONFIG_LIBDIR and ignore the DIR value, which is why --with-xsl is
# spliced for every version of this era.
#
# ${PHP_DEPS_PREFIX}/bin is deliberately not put on PATH: it holds the vendored
# curl binary for 7.0-7.2, and shadowing /usr/bin/curl for the whole build is the
# LD_LIBRARY_PATH failure again.
ENV PHP_DEPS_PREFIX=/opt/php-deps
ENV PREFIXED_CONFIGURE_FLAGS="--with-openssl --with-xsl"

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

# Wolfi's libargon2.pc and libmemcached.pc name library directories that do not
# exist (${prefix}/lib/<triplet>-linux-gnu, /usr//usr/lib). php's configure turns every
# non-default -L from pkg-config into an RPATH entry, so php, php-fpm and the
# shared extensions would carry a search path into directories that the image
# lacks and a later writer could populate. Pointing both at /usr/lib makes the -L
# a default directory, which configure drops.
RUN for pc in libargon2 libmemcached; do \
      f="/usr/lib/pkgconfig/$pc.pc"; \
      [ -f "$f" ] || { echo "$f is missing" >&2; exit 1; }; \
      sed -i -e 's|/usr//usr/lib|/usr/lib|g' -e 's|/lib/[a-z0-9_]*-linux-gnu|/lib|g' "$f"; \
      ! grep -qE '/lib/[^ /]+-linux-gnu|//usr' "$f" || { echo "$f still names a bad directory" >&2; exit 1; }; \
    done

# The clang profile runtime: Wolfi's `clang-19` does not pull it in, and without it
# PGO pass 1 fails at the link on a missing libclang_rt.profile.a, twenty minutes
# in. llvm-profdata (merges .profraw files) is asserted too. Installed here
# rather than in `toolchain` because only this stage compiles with a profile
# flag; upstream it would put ImageMagick and the legacy vendored libraries in
# the invalidation path of every PGO change.
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add --cache-dir /var/cache/apk -U compiler-rt-19 \
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
# (binutils 2.47) does not fold them into a .text.hot output section,
# so assert_profile_reached_the_link would measure nothing. gold does. A
# -fuse-ld=gold flag fails for the same libtool reason as lld.
# Wolfi's gcc does not look at PATH for ld: collect2 takes the first ld in
# COMPILER_PATH, which ends with /usr/x86_64-pc-linux-gnu/bin (binutils' own
# target directory). The PATH shim alone leaves gcc on bfd, so for gcc that
# private ld is replaced as well and the check asks gcc which ld it will run.
RUN set -eux; \
    mkdir -p /usr/local/lib/php-docker-ld; \
    case "$COMPILER" in \
      clang) ln -sf /usr/bin/ld.lld /usr/local/lib/php-docker-ld/ld ;; \
      gcc)   ln -sf /usr/bin/ld.gold /usr/local/lib/php-docker-ld/ld; \
             gcc_ld="$(gcc -print-prog-name=ld)"; \
             case "$gcc_ld" in /*) ;; *) echo "FATAL: gcc -print-prog-name=ld printed '$gcc_ld', not an absolute path; the private ld cannot be replaced" >&2; exit 1 ;; esac; \
             ln -sf /usr/bin/ld.gold "$gcc_ld" ;; \
    esac; \
    PATH=/usr/local/lib/php-docker-ld:$PATH; \
    if [ "$COMPILER" = gcc ]; then v="$("$(gcc -print-prog-name=ld)" --version | head -1)"; \
    else v="$(ld --version | head -1)"; fi; \
    case "$COMPILER:$v" in \
      clang:*LLD*) echo "ok: ld on PATH is '$v'" ;; \
      clang:*) echo "FATAL: ld on PATH is '$v', not lld; ThinLTO shared-object links will fail" >&2; exit 1 ;; \
      gcc:*GNU\ gold*) echo "ok: ld run by gcc is '$v'" ;; \
      gcc:*) echo "FATAL: ld run by gcc is '$v', not gold; profile-guided .text.hot would not survive the link" >&2; exit 1 ;; \
    esac
ENV PATH=/usr/local/lib/php-docker-ld:$PATH

COPY php/ /build/php/
COPY scripts/runtime-libs.sh /build/scripts/
COPY deps/patches/ /build/patches/
# The fetch scripts share the cache helper; it lives under deps/, outside the
# `COPY php/` tree above.
COPY deps/fetch-verified.sh /build/deps/fetch-verified.sh
# The runtime opcache settings. php/pgo/train.sh replays them onto the
# instrumented binaries so the profile is taken with the JIT, interned-string
# buffer and accelerated-file count deployments use, with no second copy to drift.
COPY conf/opcache.ini /build/conf/opcache.ini
# php/pgo/train.sh feeds the instrumented php-fpm through this FastCGI client, run by
# the instrumented php.
COPY --chmod=0755 rootfs/usr/local/bin/php-fcgi /build/bin/php-fcgi

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
# non-interactive. A version without a directory needs no patches;
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
# The apk cache mount is for build.sh installing mariadb-13.1, which the
# PrestaShop corpus app needs while training (php/pgo/train.sh brackets it with
# corpus/prestashop/db-up.sh and db-down.sh). It stays in this stage:
# runtime-base copies only specific /usr/local paths out, and tests/smoke.sh
# asserts the mariadb-server binaries are absent from shipped images.
RUN --mount=type=cache,target=/root/.cache/ccache \
    --mount=type=cache,target=/var/cache/apk,sharing=locked \
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
    export CXXFLAGS="$(bash /build/php/cflags.sh "$UARCH" cxx) -std=c++17"; \
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
# `--openssldir=/etc/ssl/openssl-1.1` sets the compiled-in default; this ini is the
# explicit half and is harmless on the modern era.
COPY conf/openssl.ini /stage/usr/local/etc/php/conf.d/12-openssl.ini

# The legacy era's openssldir: a 1.1-syntax openssl.cnf (the system's is OpenSSL 4
# syntax, which 1.1.1w cannot parse) and symlinks to the system CA store, so the
# compiled-in default_cert_file/default_cert_dir resolve.
ARG PHP_ERA
COPY conf/openssl-1.1.cnf /tmp/openssl-1.1.cnf
RUN set -eux; \
    if [ "$PHP_ERA" = legacy ]; then \
      install -d /stage/etc/ssl/openssl-1.1; \
      install -m 0644 /tmp/openssl-1.1.cnf /stage/etc/ssl/openssl-1.1/openssl.cnf; \
      ln -s /etc/ssl/certs /stage/etc/ssl/openssl-1.1/certs; \
      ln -s /etc/ssl/cert.pem /stage/etc/ssl/openssl-1.1/cert.pem; \
    fi; \
    rm -f /tmp/openssl-1.1.cnf

# Baseline opcache settings, shared unmodified by every flavor. The numeric prefix
# sorts before the entrypoint-written 90-opcache-env.ini and 99-env.ini, which
# win. FPM pool tuning is ${VAR}-driven in www.conf; no file is written for it.
# php/pgo/shipped-opcache-ini.sh applies the per-version adjustment; php/pgo/train.sh
# renders the ini it trains under with the same script.
COPY conf/opcache.ini /tmp/opcache.ini.src
COPY php/pgo/shipped-opcache-ini.sh /tmp/shipped-opcache-ini.sh
RUN set -eux; \
    install -d /stage/usr/local/etc/php/conf.d; \
    sh /tmp/shipped-opcache-ini.sh "$PHP_VERSION" /tmp/opcache.ini.src /stage/usr/local/etc/php/conf.d/15-opcache.ini; \
    rm -f /tmp/opcache.ini.src /tmp/shipped-opcache-ini.sh
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

# --- mariadb-dump ---
# Build-only: mariadb-13.1-dump depends on perl for its slow-log scripts and
# mariadb-13.1 (the server) on perl and OpenSSL 3, but mariadb-dump, mariadb-admin
# and mariadb-check are native binaries linking only libssl 4, libcrypto 4, zlib and
# glibc. runtime-base copies just those three, so neither perl nor the server ships.
# WOLFI_INDEX_STATE and `apk upgrade` keep this layer in step with the runtime apk
# layer, so these tools and the `mariadb` shell come from the same index and server
# version. The copied binaries are not in the runtime image's apk database, so Trivy
# cannot attribute CVEs to them.
FROM ${BASE_IMAGE} AS mariadb-dump-src
ARG WOLFI_INDEX_STATE=""
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    set -eux; \
    echo "wolfi index state: ${WOLFI_INDEX_STATE:-unset}"; \
    echo 'https://packages.wolfi.dev/os' > /etc/apk/repositories; \
    apk upgrade --cache-dir /var/cache/apk -U; \
    apk add --cache-dir /var/cache/apk mariadb-13.1 mariadb-13.1-dump; \
    for b in mariadb-dump mariadb-admin mariadb-check; do \
      test -x "/usr/bin/$b"; \
      [ "$(head -c 4 "/usr/bin/$b" | tail -c 3)" = ELF ] || { echo "$b is not a native binary" >&2; exit 1; }; \
    done

# --- runtime-base ---
FROM ${BASE_IMAGE} AS runtime-base
ARG PHP_VERSION
ARG WWW_UID=33
ARG WWW_GID=33
# Client packages for the PostgreSQL major whose libpq links OpenSSL 4, like
# everything else PHP loads; 17's libpq and libldap-2.6 pull OpenSSL 3 in beside it.
ARG PG_MAJOR=18
# Without a UTF-8 LC_CTYPE, PHP 7.x's basename()/pathinfo() treat multibyte
# bytes as invalid and cut them away: basename('/x/файл.txt') is '.txt', and
# ZipArchive::extractTo() writes '日本語/.txt'. 8.0+ is locale-independent there.
# C.UTF-8 is built into glibc, no locales package needed. glibc-iconv carries the
# gconv modules ext/iconv needs for any codepage beyond UTF-8, ASCII and Latin-1.
ENV LANG=C.UTF-8

COPY --from=php-build /tmp/runtime-packages.txt /tmp/runtime-packages.txt
# The base's repository is apk.cgr.dev/chainguard; the public Wolfi index replaces
# it (the signing key is already trusted), so a derived image's `apk add` reaches
# the same packages this one was built from.
#
# upgrade: BASE_IMAGE is digest-pinned, so without it a security fix to a package
# the base already ships waits for the next digest bump instead of landing in the
# weekly rebuild. WOLFI_INDEX_STATE (CI: a hash of the APKINDEX files) re-runs
# this layer the day Wolfi publishes a fix, instead of replaying the cached one.
#
# The package list is the tools every flavor keeps, the MariaDB shell and the
# PostgreSQL client tools, and the libraries php and its extensions link
# (scripts/runtime-libs.sh, resolved in php-build). libldap-2.7 is named so that
# libpq's `so:libldap.so.2` cannot resolve to libldap-2.6 (OpenSSL 3). tar and
# gzip are busybox applets, so they are not packages here. No shadow, no perl,
# no ldd, no getent, no posix-libc-utils.
ARG WOLFI_INDEX_STATE=""
RUN set -eux; \
    echo "wolfi index state: ${WOLFI_INDEX_STATE:-unset}"; \
    echo 'https://packages.wolfi.dev/os' > /etc/apk/repositories; \
    apk upgrade --no-cache; \
    apk add --no-cache \
      bash ca-certificates curl tzdata tini less nano procps glibc-iconv \
      bzip2 zip unzip zstd xz \
      mariadb-13.1-client "postgresql-${PG_MAJOR}-client" libldap-2.7 \
      $(tr '\n' ' ' < /tmp/runtime-packages.txt); \
    rm -f /tmp/runtime-packages.txt
ARG BUSYBOX_NET_APPLETS
RUN set -eux; \
    for applet in $BUSYBOX_NET_APPLETS; do \
      for dir in /bin /sbin /usr/bin /usr/sbin; do \
        case "$(readlink "$dir/$applet" 2>/dev/null)" in */busybox) rm -f "$dir/$applet" ;; esac; \
      done; \
    done
COPY --from=mariadb-dump-src /usr/bin/mariadb-dump /usr/bin/mariadb-admin /usr/bin/mariadb-check /usr/bin/
# mariadb-13.1-client ships only `mariadb`; keep the names scripts and people type.
# Wrappers rather than symlinks: MariaDB warns "Deprecated program name" on stderr
# when argv[0] is mysql*.
RUN set -eux; \
    for pair in mysql:mariadb mysqldump:mariadb-dump mysqladmin:mariadb-admin mysqlcheck:mariadb-check; do \
      printf '#!/bin/sh\nexec %s "$@"\n' "${pair#*:}" > "/usr/bin/${pair%%:*}"; \
      chmod 755 "/usr/bin/${pair%%:*}"; \
    done

# php-build's output, then the baked config, as two layers (see runtime-payload).
# The config layer stays last so a config edit never re-ships the binaries.
COPY --from=runtime-payload / /
COPY --from=runtime-payload-conf / /

RUN set -eux; \
    grep -q '^www-data:' /etc/group || addgroup -S -g "$WWW_GID" www-data; \
    grep -q '^www-data:' /etc/passwd || adduser -S -D -H -u "$WWW_UID" -G www-data -h /var/www -s /sbin/nologin www-data; \
    mkdir -p /app /usr/local/etc/php/conf.d; \
    install -d -o www-data -g www-data /var/www; \
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
# (conf/www.conf) via php-fcgi, so no front web server or extra HTTP port is
# needed. It runs as www-data, like the main command.
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD php-fpm-healthcheck || exit 1
USER www-data
CMD ["php-fpm", "-F"]

FROM runtime-base AS cli
COPY conf/php-cli.ini /usr/local/etc/php/conf.d/10-php.ini
USER www-data
CMD ["php", "-a"]

# npm and semantic-release as one tree for cli-builder, installed under /usr/local
# so the apk-managed Node (nodejs-26, /usr/bin/node) carries no npm of its own and
# the pinned npm is the only one outside semantic-release's tree.
#
# The pin is npm 12.2.1, the newest release and the first 12.x whose bundled
# brace-expansion, undici, ip-address, http-cache-semantics and
# postcss-selector-parser carry their fixes (12.2.0, still npm's `latest` tag, does
# not). Wolfi's npm package lags it. The apk npm is only the bootstrap that installs
# it and never ships. semantic-release is not run
# here (it refuses to start without git); tests/smoke.sh runs
# `semantic-release --version` in the finished image. The readme/changelog markdown
# in the packages is 2.5MB nothing reads.
FROM ${BASE_IMAGE} AS node-tools
ARG WOLFI_INDEX_STATE=""
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    set -eux; \
    echo "wolfi index state: ${WOLFI_INDEX_STATE:-unset}"; \
    echo 'https://packages.wolfi.dev/os' > /etc/apk/repositories; \
    apk upgrade --cache-dir /var/cache/apk -U; \
    apk add --cache-dir /var/cache/apk nodejs-26 npm; \
    node -v; \
    npm install -g --prefix /usr/local npm@12.2.1; \
    [ "$(/usr/local/bin/npm -v)" = "12.2.1" ]; \
    /usr/local/bin/npm install -g --prefix /usr/local semantic-release; \
    /usr/local/bin/npm cache clean --force; \
    test -x /usr/local/bin/semantic-release; \
    find /usr/local/lib/node_modules -type f \( -iname 'readme*.md' -o -iname 'changelog*.md' -o -iname 'history.md' \) -delete; \
    mkdir -p /out/bin /out/lib; \
    cp -a /usr/local/lib/node_modules /out/lib/node_modules; \
    for b in npm npx semantic-release; do \
      cp -a "/usr/local/bin/$b" "/out/bin/$b"; \
    done

# cli-builder: composer, node and the CLI tooling a build or deploy stage needs.
# No compiler or phpize; compiling extensions is ext-builder's job.
FROM cli AS cli-builder
ARG BUSYBOX_NET_APPLETS
USER root
COPY --from=node-tools /out/ /usr/local/
# runtime-base already has less, nano, procps, zip, unzip, zstd and the mariadb
# shell, plus the mariadb-dump/-admin/-check binaries and mysql* wrappers it copies
# from mariadb-dump-src; every flavor keeps those same copies, so all report one
# version and apk audit stays clean.
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    set -eux; \
    apk add --cache-dir /var/cache/apk -U \
      nodejs-26 corepack git rsync patch make brotli sqlite jq; \
    for applet in $BUSYBOX_NET_APPLETS; do \
      for dir in /bin /sbin /usr/bin /usr/sbin; do \
        case "$(readlink "$dir/$applet" 2>/dev/null)" in */busybox) rm -f "$dir/$applet" ;; esac; \
      done; \
    done; \
    find / -xdev -perm /6000 -type f -exec chmod a-s {} + || true
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
ARG BUSYBOX_NET_APPLETS
USER root
# build-base: gcc, g++, make, binutils, glibc-dev and the openssf compiler wrappers
# in /usr/local/bin, which stay on so extensions built here are hardened like
# Wolfi's own. g++: several extensions are C++. autoconf: phpize regenerates
# ./configure from config.m4. pkgconf: extension configure scripts locate -dev
# libraries with it. A -dev package an extension needs is an `apk add` away; the
# runtime libraries' headers (openssl-4.0-dev, ...) come from the same index.
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    set -eux; \
    apk add --cache-dir /var/cache/apk -U build-base autoconf pkgconf linux-headers; \
    for applet in $BUSYBOX_NET_APPLETS; do \
      for dir in /bin /sbin /usr/bin /usr/sbin; do \
        case "$(readlink "$dir/$applet" 2>/dev/null)" in */busybox) rm -f "$dir/$applet" ;; esac; \
      done; \
    done; \
    find / -xdev -perm /6000 -type f -exec chmod a-s {} + || true
COPY --from=ext-builder-payload / /
CMD ["bash"]
