#!/usr/bin/env bash
# Build every shared extension against the installed PHP. Core extensions are
# built from the php-src tree; PECL extensions are fetched. Nothing is enabled:
# .so files land in extension_dir and stay dormant until php-ext-enable runs.
set -euo pipefail
# --list <php-version> prints the names this script would attempt to build for
# that version (ext.json's shared set, minus KNOWN_UNBUILDABLE) and exits: no
# SRC_DIR, no phpize, nothing built. tests/smoke.sh derives its SHARED_EXTS from
# it, so the expectation cannot drift from what this script skips.
if [ "${1:-}" = "--list" ]; then
  PHP_VERSION="${2:?usage: build-shared-ext.sh --list <php-version>}"
  LIST_ONLY=1
else
  PHP_VERSION="${1:?usage: build-shared-ext.sh <php-version> <php-src-dir>|--list <php-version>}"
  SRC_DIR="${2:?usage: build-shared-ext.sh <php-version> <php-src-dir>}"
  LIST_ONLY=0
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The same configure/make suppression split core PHP uses, from php/flag-split.sh.
# The phpize'd extensions are not C99-clean either: PECL uuid's PHP_CHECK_LIBRARY
# probes are pre-C99 (`conftest.c:9:1: error: type specifier missing, defaults to
# 'int' [-Wimplicit-int]`), so without the demotions configure concludes libuuid
# and its functions are absent and drops seven feature defines (HAVE_LIBUUID,
# HAVE_UUID_GENERATE_MD5, HAVE_UUID_GENERATE_SHA1, HAVE_UUID_TIME,
# HAVE_UUID_TIME64, HAVE_UUID_TYPE, HAVE_UUID_VARIANT) from a uuid.so that still
# compiles and loads. PHP_CHECK_LIBRARY does not announce itself, so config.log's
# "checking ... / result: ..." lines are identical either way; only the
# generated config.h differs.
#
# PHP_ERA rather than a version list: the demotions exist for pre-C99 probe
# programs, an era-shaped property, and the era is what the Dockerfile already
# passes down.
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
    # The 4th field is the per-version pin, if the registry has one, so a shared
    # extension whose current release dropped a PHP version can be pinned back to
    # the last release that supports it instead of being dropped.
    # \x1f, not \t: tab is an IFS *whitespace* character, so bash's `read`
    # collapses a run of them into one delimiter and an empty field disappears.
    # Every extension whose "configure" is null (xdebug, msgpack, pcov, ...)
    # produces one, and the version pin slid into its place and reached
    # ./configure as a bare argument, which autoconf reads as the host alias:
    # "configure: error: /bin/bash ./config.sub 2.6.1 failed". A non-whitespace
    # delimiter preserves empty fields, and \x1f cannot occur in these values.
    # overrides.source/configure let one name come from php-src on the versions
    # that still have it in core and from PECL after it left (mcrypt, 7.0-7.1).
    source = override.get("source", e["source"])
    configure = override.get("configure", e["configure"])
    print("\x1f".join([e["name"], source, configure or "", override.get("version", "")]))
PY
)

built=0 skipped=0

# imap's php constraint (ext.json: >=7.0,<8.4) is right about php-src
# availability but not about this environment: Debian dropped c-client, so
# libc-client-dev has never existed on trixie. That is not a per-version registry
# gap to override (test_ext_registry.py's test_imap_excluded_above_83 pins the
# constraint deliberately), and every targeted version that has ext/imap
# (7.0-8.3) sits inside the range. configure fails here, not phpize, so the
# pecl.lock/php-src-dir skips below do not catch it; it is skipped loudly and
# counted. The list may only grow by "trixie categorically cannot build this",
# never "this run happened to fail": a per-version entry here says the latter,
# while an ext.json range says "this pinned version does not support that PHP".
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
  # Every PHP_VERSION this project targets has a non-empty shared set. Zero
  # output with exit 0 is never a real "builds no shared extensions" answer, only
  # a version string ext.json's constraints do not recognize (`--list 6.0`).
  # Callers doing `X=$(build-shared-ext.sh --list "$v")` would not notice under
  # `set -e`, and every downstream loop would iterate zero times and report
  # success having verified nothing.
  [ "$count" -gt 0 ] || { echo "FAIL: --list derived zero shared extensions for PHP $PHP_VERSION -- not a real empty set, check the version string" >&2; exit 1; }
  exit 0
fi

# Debian multiarch: the one thing every phpize'd extension here needs told.
#
# Several config.m4 files test for their library at $DIR/$PHP_LIBDIR/libfoo.so
# with $PHP_LIBDIR defaulting to "lib", while Debian ships libraries under
# /usr/lib/<triplet>. ext/ldap is the one that broke: on 7.0 it tests only
# $LDAP_LIBDIR/liblber.so ("configure: error: Cannot find ldap libraries in
# /usr/lib."), and on 7.1-8.0 its multiarch fallback
# $LDAP_LIBDIR/$($CC -dumpmachine)/liblber.so misses too, because clang's
# -dumpmachine prints x86_64-pc-linux-gnu where Debian (and gcc) say
# x86_64-linux-gnu.
#
# --with-libdir is PHP's own answer (the official docker-library/php images pass
# it too). Pointing it at the multiarch subdirectory makes $PHP_LIBDIR name the
# directory the libraries are really in, for every extension at once. It also
# makes PHP_ADD_LIBRARY_WITH_PATH skip a redundant -L (build/php.m4 suppresses -L
# for /usr/$PHP_LIBDIR).
#
# Derived from dpkg, never spelled out: this file also runs on arm64. A missing
# dpkg-architecture is a hard error because an omitted flag does not fail, it
# just goes back to searching the wrong directory.
command -v dpkg-architecture >/dev/null 2>&1 || {
  echo "dpkg-architecture not found; cannot derive the multiarch libdir" >&2; exit 1; }
LIBDIR_ARG="--with-libdir=lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
echo "shared extensions: configuring with $LIBDIR_ARG"

# Required, not defaulted: falling back to "modern" on a legacy build would
# silently drop the demotions and put uuid.so back to missing seven feature
# defines. Resolved after the --list early exit, which runs on the host
# (tests/smoke.sh) where no era is set.
php_docker_flag_split "${PHP_ERA:?build-shared-ext.sh needs PHP_ERA to pick the flag split}"

# Prove the split before relying on it, once rather than per extension, since
# the flags are the same for all of them. In a phpize build CFLAGS_CLEAN is
# literally $(CFLAGS), so the make-time set is the configure CFLAGS followed by
# EXTRA_CFLAGS -- the same order the compile rule expands,
# $(COMMON_FLAGS) $(CFLAGS_CLEAN) $(EXTRA_CFLAGS).
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
    # No pecl.lock version column to key off: the url/subdir live in ext.json
    # itself (the url pins the tag), and pecl.lock supplies only the sha256 for
    # that url.
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
    # generic grep-exit-1: it means the registry points at a PECL package that
    # does not resolve (pecl.php.net has no "lz4" package, which is why lz4 is
    # source=github). Skip it loudly and keep building the rest.
    # A per-version pin (ext.json overrides.version) is keyed name@X.Y in
    # pecl.lock, as fetch-pecl.sh keys the static ones, so a version whose
    # current release dropped support keeps the extension on the last release
    # that had it (xdebug on 7.0-7.4). A pin with no matching row is a hard
    # failure, not a skip: falling back to the unpinned row would install a
    # release that does not support this PHP.
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
