#!/usr/bin/env bash
# Build every shared extension against the installed PHP. Core extensions are
# built from the php-src tree; PECL extensions are fetched. Nothing is enabled:
# .so files land in extension_dir and stay dormant until php-ext-enable runs.
set -euo pipefail
# --list <php-version> prints the names this script would actually attempt
# to build for that version (ext.json's shared set, minus KNOWN_UNBUILDABLE)
# and exits -- no SRC_DIR, no phpize, nothing built. This is the single
# source of truth smoke.sh's SHARED_EXTS now derives from, instead of
# a hand-maintained literal list that silently drifts out of sync with
# what this script actually skips (task 14 review, C1: the hardcoded list
# named mongodb/protobuf/swoole for every version, so smoke.sh failed
# on the exact image task 14 exists to prove).
if [ "${1:-}" = "--list" ]; then
  PHP_VERSION="${2:?usage: build-shared-ext.sh --list <php-version>}"
  LIST_ONLY=1
else
  PHP_VERSION="${1:?usage: build-shared-ext.sh <php-version> <php-src-dir>|--list <php-version>}"
  SRC_DIR="${2:?usage: build-shared-ext.sh <php-version> <php-src-dir>}"
  LIST_ONLY=0
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The same configure/make suppression split core PHP uses, for exactly the same
# reason and from the same file -- see php/flag-split.sh.
#
# This was originally core-only, on the assumption that the phpize'd extensions
# were C99-clean. They are not. Measured rather than assumed, by configuring
# every shared extension twice on PHP 7.0 -- once with the base CFLAGS this
# script used to pass, once with the demotions added -- and diffing the
# *generated config.h*, not just the build log: PECL uuid's PHP_CHECK_LIBRARY
# probes are pre-C99 (`conftest.c:9:1: error: type specifier missing, defaults
# to 'int' [-Wimplicit-int]`), so without the demotions configure concludes
# libuuid and its functions are absent and drops seven feature defines
# (HAVE_LIBUUID, HAVE_UUID_GENERATE_MD5, HAVE_UUID_GENERATE_SHA1,
# HAVE_UUID_TIME, HAVE_UUID_TIME64, HAVE_UUID_TYPE, HAVE_UUID_VARIANT) from a
# uuid.so that still compiles, still loads and still passes every check here.
#
# Worth noting how nearly that stayed hidden: config.log's stream of
# "checking … / result: …" lines was *identical* between the two runs, because
# PHP_CHECK_LIBRARY does not announce itself. Only the generated header
# differed. A comparison of configure's visible answers would have found
# nothing.
#
# PHP_ERA rather than a version list: the demotions exist for pre-C99 probe
# programs, which is an era-shaped property, and the era is what the Dockerfile
# already passes down.
# shellcheck source=php/flag-split.sh
. "$HERE/flag-split.sh"

rows=$(python3 - "$PHP_VERSION" "$HERE/ext.json" <<'PY'
import json, sys
version, path = sys.argv[1], sys.argv[2]

def parts(v): return tuple(int(x) for x in v.split("."))

def satisfies(constraint, v):
    for clause in (constraint or "").split(","):
        clause = clause.strip()
        for op in (">=", "<=", "<", ">", "=="):
            if clause.startswith(op):
                b, c = parts(clause[len(op):]), parts(v)
                if not {">=": c >= b, "<=": c <= b, "<": c < b,
                        ">": c > b, "==": c == b}[op]:
                    return False
                break
    return True

for e in json.load(open(path))["extensions"]:
    override = (e.get("overrides") or {}).get(version, {})
    if override.get("linkage", e["linkage"]) != "shared":
        continue
    if not satisfies(e["php"], version):
        continue
    # The 4th field is the per-version pin, if the registry has one. Only
    # fetch-pecl.sh read overrides.version until now, which meant a shared
    # extension whose current release dropped support for a version could only
    # be dropped outright, never pinned back to the last release that had it.
    # \x1f, not \t: tab is an IFS *whitespace* character, so bash's `read`
    # collapses a run of them into one delimiter and an empty field silently
    # disappears. Every extension whose "configure" is null (xdebug, msgpack,
    # pcov, ...) produces exactly that, and the next field -- the version pin --
    # slid into its place and was passed to ./configure as a bare argument,
    # which autoconf reads as the host alias: "configure: error: /bin/bash
    # ./config.sub 2.6.1 failed". A non-whitespace delimiter preserves empty
    # fields, and \x1f cannot occur in any of these values.
    # overrides.source/configure let one name come from php-src on the versions
    # that still have it in core and from PECL after it left (mcrypt, 7.0-7.1).
    source = override.get("source", e["source"])
    configure = override.get("configure", e["configure"])
    print("\x1f".join([e["name"], source, configure or "", override.get("version", "")]))
PY
)

built=0 skipped=0

# imap's php constraint (ext.json: >=7.0,<8.4) is honest about php-src
# availability but not about this environment: Debian dropped c-client
# entirely, so libc-client-dev has never existed on trixie at any package
# version, for any era. That's not a per-version registry gap to override
# (test_ext_registry.py's test_imap_excluded_above_83 pins the >=7.0,<8.4
# constraint deliberately, since it's correct on the php-src side), and
# every version this project targets (7.0-8.3; imap has no php-src ext/imap
# dir from 8.4 on, see the "core ext $name not in php-src" skip below) sits
# inside that range. First actually exercised by task 14's PHP 8.0 build --
# the modern era's 8.1-8.3 targets share the exact same gap, just unbuilt so
# far (only 8.5, which the constraint excludes outright, has shipped).
# configure fails here, not phpize, so it isn't caught by the pecl.lock/
# php-src-dir skips above; treated the same way -- loud, counted, and the
# only thing this list is allowed to grow by is "trixie categorically
# cannot build this," never "this particular run happened to fail."
#
# protobuf used to be a second entry here, gated to PHP_VERSION 8.0 -- task 14
# hit it as a mid-compile failure on 8.0 (php_protobuf's map.c/array.c
# reference arginfo_offsetGet/arginfo_current/arginfo_key, which 8.0's Zend
# headers do not declare) and skip-listed the one version it had reproduced,
# noting that "8.1-8.4 probably build it" was still a guess. Task 15 built
# those and replaced the guess with the pinned package's own declared floor:
# protobuf 5.35.1's package.xml says PHP 8.2.0, so ext.json now carries
# ">=8.2" and this list does not need to know about protobuf at all. That is
# the same correction mongodb got, and it is the right shape -- a per-version
# entry here says "this run happened to fail", an ext.json range says "this
# pinned version does not support that PHP", which is the actual fact.
KNOWN_UNBUILDABLE="imap"

if [ "$LIST_ONLY" -eq 1 ]; then
  count=0
  while IFS=$'\x1f' read -r name source configure pinned; do
    [ -n "$name" ] || continue
    case " $KNOWN_UNBUILDABLE " in
      *" $name "*) continue ;;
    esac
    echo "$name"
    count=$((count + 1))
  done <<< "$rows"
  # Every real PHP_VERSION this project targets (matrix.json's 7.0-8.5) has a
  # non-empty shared set -- ext.json's php-version constraints all still
  # leave something in range. Zero output with exit 0 here is never a real
  # "this version builds no shared extensions" answer, only a version string
  # ext.json's constraints don't recognize (a typo, an out-of-range value --
  # `--list 6.0` is the reproduction) silently matching nothing. Under `set
  # -e`, callers doing `X=$(build-shared-ext.sh --list "$v")` never notice:
  # the command substitution still exits 0, so an empty derivation just
  # makes every downstream loop iterate zero times and report success on
  # having verified nothing (task 14 review round 3, "empty-derivation
  # guard" -- found independently by two reviewers; smoke.sh is not
  # the only caller task 24's PR-group matrix will drive with more version
  # strings, so the guard belongs here, in the one place --list is defined,
  # not just in smoke.sh's use of it).
  [ "$count" -gt 0 ] || { echo "FAIL: --list derived zero shared extensions for PHP $PHP_VERSION -- not a real empty set, check the version string" >&2; exit 1; }
  exit 0
fi

# Debian multiarch, and the one thing every phpize'd extension here needs told.
#
# Several config.m4 files test for their library at $DIR/$PHP_LIBDIR/libfoo.so
# with $PHP_LIBDIR defaulting to "lib", while Debian ships libraries under
# /usr/lib/<triplet> because they are arch-dependent. ext/ldap is the one that
# actually broke: on 7.0 it tests only $LDAP_LIBDIR/liblber.so, so
# "configure: error: Cannot find ldap libraries in /usr/lib." On 7.1-8.0 it
# also tries $LDAP_LIBDIR/$($CC -dumpmachine)/liblber.so -- which is the
# multiarch fallback, and it misses too, because this build uses clang, whose
# -dumpmachine prints x86_64-pc-linux-gnu where Debian (and gcc) say
# x86_64-linux-gnu.
#
# --with-libdir is PHP's own answer to this and is what the official
# docker-library/php images pass for the same reason. Setting it to the
# multiarch subdirectory makes $PHP_LIBDIR name the directory the libraries are
# actually in, which fixes the search for every extension at once instead of
# one symlink per library. It also makes PHP_ADD_LIBRARY_WITH_PATH skip adding
# a redundant -L (build/php.m4 suppresses -L for /usr/$PHP_LIBDIR), so the
# linker resolves -lldap from its default paths exactly as before.
#
# Derived from dpkg, never spelled out: this file is also read on arm64.
# Missing dpkg-architecture is a hard error rather than a silently omitted
# flag -- an omitted flag here does not fail, it just goes back to searching
# the wrong directory, which is the failure this exists to prevent.
command -v dpkg-architecture >/dev/null 2>&1 || {
  echo "dpkg-architecture not found; cannot derive the multiarch libdir" >&2; exit 1; }
LIBDIR_ARG="--with-libdir=lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
echo "shared extensions: configuring with $LIBDIR_ARG"

# Required, not defaulted. Falling back to "modern" on a legacy build would
# silently drop the demotions and put uuid.so straight back to missing seven
# feature defines with nothing to show for it -- a default here would recreate
# the exact bug this seam exists to fix. Resolved after the --list early exit
# above, which runs on the host (tests/smoke.sh) where no era is set and
# none is needed.
php_docker_flag_split "${PHP_ERA:?build-shared-ext.sh needs PHP_ERA to pick the flag split}"

# Prove the split before relying on it, once, rather than per extension: the
# flags are the same for all of them. In a phpize build CFLAGS_CLEAN is
# literally $(CFLAGS) (checked in a generated Makefile), so the make-time set is
# the configure CFLAGS followed by EXTRA_CFLAGS -- the same order the compile
# rule expands, $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS), which is the
# same string in the installed build system as in php-src's own.
CONFIGURE_CFLAGS="${CFLAGS:-} $CONFIGURE_ONLY_CFLAGS"
php_docker_assert_flag_split "shared" \
  "$CONFIGURE_CFLAGS" "$CONFIGURE_CFLAGS $MAKE_ONLY_CFLAGS" || exit 1

while IFS=$'\x1f' read -r name source configure pinned; do
  [ -n "$name" ] || continue
  echo "=== building shared: $name"
  case " $KNOWN_UNBUILDABLE " in
    *" $name "*)
      echo "SKIP: $name is not buildable for PHP $PHP_VERSION on this base image" \
           "(see KNOWN_UNBUILDABLE in $(basename "$0")) -- not attempting phpize/configure" >&2
      skipped=$((skipped + 1))
      continue
      ;;
  esac
  if [ "$source" = "core" ]; then
    dir="${SRC_DIR}/ext/${name}"
    [ -d "$dir" ] || { echo "core ext $name not in php-src, skipping" >&2; skipped=$((skipped + 1)); continue; }
  elif [ "$source" = "github" ]; then
    # No pecl.lock version column to key off of -- the url/subdir live in
    # ext.json itself (github tarballs are already tag-pinned by the url),
    # pecl.lock supplies only the sha256 for that url, same as every other row.
    url=$(python3 -c "import json,sys;print(next(e['url'] for e in json.load(open('$HERE/ext.json'))['extensions'] if e['name']=='$name'))")
    sub=$(python3 -c "import json,sys;print(next(e.get('subdir','') for e in json.load(open('$HERE/ext.json'))['extensions'] if e['name']=='$name'))")
    row=$(grep -E "^${name}[[:space:]]" "$HERE/pecl.lock" || true)
    if [ -z "$row" ]; then
      echo "SKIP: no pecl.lock entry for $name -- github source has no pinned" \
           "sha256 to verify the tarball against" >&2
      skipped=$((skipped + 1))
      continue
    fi
    sha=$(echo "$row" | awk '{print $3}')
    bash "${HERE}/../deps/fetch-verified.sh" "$url" "$sha" "/tmp/${name}.tar.gz"
    dir="/tmp/build-${name}"
    mkdir -p "$dir" && tar xf "/tmp/${name}.tar.gz" -C "$dir" --strip-components=1
    rm -f "/tmp/${name}.tar.gz"
    # deps/patches/ext-<name>-<tag>/, same rules as php-src's (deps/patches/README.md):
    # keyed by the release tag so a bump drops them until someone re-reviews them.
    tag="$(basename "$url")"; tag="${tag%.tar.gz}"
    pdir="${HERE}/../patches/ext-${name}-${tag}"
    n=0
    if [ -d "$pdir" ]; then
      for p in "$pdir"/*.patch; do
        [ -e "$p" ] || continue
        patch -d "$dir" -p1 --batch --forward --fuzz=0 < "$p"
        n=$((n + 1))
      done
    fi
    echo "$name $tag: applied $n patch(es) from deps/patches"
    [ -n "$sub" ] && dir="${dir}/${sub}"
  else
    # A missing pecl.lock row is not a build failure to hide behind set -e's
    # generic grep-exit-1 -- it means the registry points at a PECL package
    # that does not resolve (pecl.php.net has 404'd before -- see the
    # comment on lz4's old row in php/pecl.lock's git history, fixed in
    # task 12 by moving it to source=github). Skip it loudly and keep
    # building the rest rather than dying on one bad grep.
    # A per-version pin (ext.json overrides.version) is keyed name@X.Y in
    # pecl.lock, exactly as fetch-pecl.sh keys the static ones. It exists so a
    # version whose current release dropped support can keep the extension on
    # the last release that had it, instead of losing it -- xdebug on 7.0-7.4
    # is why. A pin with no matching row is a hard failure, not a skip: the
    # registry asked for a specific version and silently falling back to the
    # unpinned row would install one that does not support this PHP.
    if [ -n "$pinned" ]; then
      row=$(grep -E "^${name}@${PHP_VERSION}[[:space:]]" "$HERE/pecl.lock" || true)
      [ -n "$row" ] || { echo "php/ext.json pins $name $pinned for PHP $PHP_VERSION but php/pecl.lock has no ${name}@${PHP_VERSION} row" >&2; exit 1; }
      version="$pinned"
      sha=$(echo "$row" | awk '{print $3}')
      locked=$(echo "$row" | awk '{print $2}')
      [ "$locked" = "$pinned" ] || { echo "php/ext.json pins $name $pinned for PHP $PHP_VERSION but php/pecl.lock's ${name}@${PHP_VERSION} row says $locked" >&2; exit 1; }
    else
      row=$(grep -E "^${name}[[:space:]]" "$HERE/pecl.lock" || true)
      if [ -z "$row" ]; then
        echo "SKIP: no pecl.lock entry for $name -- registry names a source that" \
             "does not resolve; see the comment in php/pecl.lock" >&2
        skipped=$((skipped + 1))
        continue
      fi
      version=$(echo "$row" | awk '{print $2}')
      sha=$(echo "$row" | awk '{print $3}')
    fi
    bash "${HERE}/../deps/fetch-verified.sh" "https://pecl.php.net/get/${name}-${version}.tgz" "$sha" "/tmp/${name}.tgz"
    dir="/tmp/build-${name}"
    mkdir -p "$dir" && tar xf "/tmp/${name}.tgz" -C "$dir" --strip-components=1
    rm -f "/tmp/${name}.tgz"
  fi

  # CFLAGS carries the demotions for ./configure only; EXTRA_CFLAGS re-promotes
  # them for the compile, exactly as php/build.sh does for core PHP. CXXFLAGS is
  # left alone: all three are C diagnostics that do not exist in C++, and naming
  # a warning group clang does not have in that language only invites noise.
  ( cd "$dir" \
    && phpize \
    && CFLAGS="$CONFIGURE_CFLAGS" ./configure ${LIBDIR_ARG} ${configure} \
    && make -j"$(nproc)" EXTRA_CFLAGS="$MAKE_ONLY_CFLAGS" \
    && make install EXTRA_CFLAGS="$MAKE_ONLY_CFLAGS" ) \
    || { echo "shared build failed: $name" >&2; exit 1; }
  built=$((built + 1))
done <<< "$rows"

echo "shared extensions: $built built, $skipped skipped"

# Anything make install created as an ini must go: shared means dormant.
rm -f /usr/local/etc/php/conf.d/*.ini
