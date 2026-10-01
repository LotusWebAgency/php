#!/usr/bin/env bash
# Print CFLAGS for the current architecture at the requested microarch level.
set -euo pipefail
UARCH="${1:-baseline}"

# dpkg is the authority when present (debian build stages); fall back to
# uname so the script — and its tests — can run on a non-debian dev host too.
# This widens where the script runs, it does not change what counts as
# supported: an unmapped uname still fails loudly below, same as an unmapped
# dpkg arch.
if command -v dpkg >/dev/null 2>&1; then
  ARCH="$(dpkg --print-architecture)"
else
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *)
      echo "unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
fi

# -U before -D: debian's build environment may already define _FORTIFY_SOURCE=2,
# and redefining it without undefining first is a warning, not an override.
COMMON="-O2 -fPIC -fstack-protector-strong -fstack-clash-protection"
COMMON="$COMMON -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -fno-semantic-interposition"
# Task 37a (owner ruling): -std=gnu17, pinned explicitly for every PHP version
# on both compilers, not just where gcc's newer default forced the issue.
# GCC 15+ defaults to -std=gnu23, whose stricter K&R semantics (a bare `()`
# now means "no parameters", not "unspecified") broke real php-src source on
# the legacy era outright (compile-probed: ext/standard/scanf.c, ext/date/
# php_date.c -- see task-37a-report.md) and risk the same on any PECL
# extension or vendored dep this project builds from source, on any PHP
# version, silently rather than loudly if the K&R code merely changes
# behaviour instead of failing to compile. Pinning one dialect everywhere
# removes that whole class of drift instead of chasing it version by version.
# Free of cost on the clang path: Debian trixie's clang 19 already defaults to
# -std=gnu17 (confirmed: __STDC_VERSION__ is 201710L identically with and
# without this flag; `clang -###` shows the only difference is the flag being
# spelled out explicitly instead of left implicit -- cc1's other args are
# unchanged), so this only changes anything on the gcc path.
COMMON="$COMMON -std=gnu17"

case "$ARCH" in
  amd64)
    SEC="-fcf-protection=full"
    if [ "$UARCH" = "v3" ]; then MARCH="-march=x86-64-v3 -mtune=generic"
    else MARCH="-march=x86-64 -mtune=generic"; fi
    ;;
  arm64)
    SEC="-mbranch-protection=standard"
    if [ "$UARCH" = "v3" ]; then MARCH="-march=armv8.2-a+crypto"
    else MARCH="-march=armv8-a"; fi
    ;;
  *)
    echo "unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

echo "$COMMON $SEC $MARCH"
