#!/usr/bin/env bash
# End to end for the ext-builder flavor, across the three images of one PHP
# version:
#
#   ./tests/test-ext-builder.sh <php-version>        e.g. 8.5
#
# Needs lotuswebagency/php:<version>-{ext-builder,fpm,cli} in the local daemon
# (PHP_IMAGE overrides the repository part). What it proves that smoke.sh,
# which sees one image at a time, cannot:
#
#   - php-config in ext-builder reports the extension_dir the fpm and cli
#     runtimes actually use (the dir name carries the Zend module API number,
#     so equal dirs mean an extension built there loads here);
#   - the tests/fixtures/ext-hello extension, compiled with phpize/configure/
#     make in ext-builder and COPYed into fpm and cli by a multi-stage build --
#     the same shape the README documents -- loads there under PHP_EXT_ENABLE=
#     hello and answers a call, as the images' own uid 33.
#
# The two derived images are tagged lotuswebagency/php-ext-hello-test:* and
# removed again on exit.
set -euo pipefail
VERSION="${1:?usage: test-ext-builder.sh <php-version>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PHP_IMAGE="${PHP_IMAGE:-lotuswebagency/php}"
FIXTURE="$HERE/fixtures/ext-hello"
EXT="$PHP_IMAGE:$VERSION-ext-builder"
FPM="$PHP_IMAGE:$VERSION-fpm"
CLI="$PHP_IMAGE:$VERSION-cli"
DERIVED_REPO="lotuswebagency/php-ext-hello-test"

fail() { echo "FAIL: $*" >&2; exit 1; }
# Every container: removed on exit, signal-forwarding init, and the time limit
# inside it (a host-side `timeout docker run` only kills the client, not PID 1).
run() { docker run --rm --init "$@"; }

for img in "$EXT" "$FPM" "$CLI"; do
  docker image inspect "$img" >/dev/null 2>&1 \
    || fail "$img is not in the local daemon -- build it first (tests/build-all.sh --only $VERSION)"
done
[ -d "$FIXTURE" ] || fail "$FIXTURE is missing"

# Same rule as smoke.sh: three images that do not all come from this tree prove
# nothing about this tree.
tree_hash="$(bash "$ROOT/scripts/inputs-hash.sh")"
for img in "$EXT" "$FPM" "$CLI"; do
  label="$(docker inspect --format '{{index .Config.Labels "com.lotuswebagency.inputs-hash"}}' "$img" 2>/dev/null || true)"
  if [ "$label" != "$tree_hash" ]; then
    if [ "${SMOKE_ALLOW_STALE:-}" = "1" ]; then
      echo "WARNING: $img inputs-hash is '${label:-none}', the tree hashes to $tree_hash -- proceeding because SMOKE_ALLOW_STALE=1" >&2
    else
      fail "$img inputs-hash label is '${label:-none}', the current tree is $tree_hash -- rebuild (tests/build-all.sh --only $VERSION) or set SMOKE_ALLOW_STALE=1"
    fi
  fi
done
echo "ok: $EXT, $FPM and $CLI are all built from the current tree ($tree_hash)"

# ----------------------------------------------------- extension_dir agreement
pc_dir="$(run "$EXT" php-config --extension-dir)"
[ -n "$pc_dir" ] || fail "php-config --extension-dir printed nothing in $EXT"
for img in "$EXT" "$FPM" "$CLI"; do
  dir="$(run "$img" php -r 'echo ini_get("extension_dir");')"
  [ "$dir" = "$pc_dir" ] || fail "$img extension_dir is '$dir', php-config in $EXT says '$pc_dir'"
done
echo "ok: php-config --extension-dir in ext-builder equals extension_dir in ext-builder, fpm and cli ($pc_dir)"

# ZEND_MODULE_API_NO is a C macro with no userland constant; phpinfo's
# "PHP Extension" row prints it on every version 7.0-8.5.
module_api() { run "$1" php -i | sed -n 's/^PHP Extension => //p'; }
api_ext="$(module_api "$EXT")"
[ -n "$api_ext" ] || fail "$EXT: php -i printed no 'PHP Extension' row"
for img in "$FPM" "$CLI"; do
  api="$(module_api "$img")"
  [ "$api" = "$api_ext" ] || fail "$img reports Zend module API $api, ext-builder $api_ext"
done
case "$pc_dir" in
  *"-$api_ext") ;;
  *) fail "extension_dir '$pc_dir' does not end in the Zend module API number $api_ext" ;;
esac
echo "ok: Zend module API $api_ext on all three"

# ------------------------------------------------- multi-stage build of the .so
cleanup() { docker rmi -f "$DERIVED_REPO:$VERSION-fpm" "$DERIVED_REPO:$VERSION-cli" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# --builder default: the docker driver, which resolves FROM against the local
# image store. A docker-container builder (what CI's setup-buildx-action makes
# current) cannot see the images this test is about, and would go to a registry.
for flavor in fpm cli; do
  docker buildx build --builder default -q -f "$FIXTURE/Dockerfile" --target "$flavor" \
    --build-arg "PHP_VERSION=$VERSION" --build-arg "PHP_IMAGE=$PHP_IMAGE" \
    -t "$DERIVED_REPO:$VERSION-$flavor" "$FIXTURE" >/dev/null \
    || fail "multi-stage build of the ext-hello fixture failed for $flavor (re-run without -q: docker buildx build --builder default -f $FIXTURE/Dockerfile --target $flavor --build-arg PHP_VERSION=$VERSION --build-arg PHP_IMAGE=$PHP_IMAGE $FIXTURE)"
done
echo "ok: ext-hello compiled in ext-builder and COPYed into fpm and cli of php $VERSION"

# ------------------------------------------------------ load and call, per flavor
for flavor in fpm cli; do
  img="$DERIVED_REPO:$VERSION-$flavor"

  run "$img" test -f "$pc_dir/hello.so" || fail "$flavor: hello.so is not in $pc_dir"

  # Negative control: the .so being on disk must not be enough, or the checks
  # below would pass for a reason other than PHP_EXT_ENABLE.
  off="$(run "$img" timeout 20 php -r 'echo function_exists("hello_world") ? "loaded" : "absent";')"
  [ "$off" = "absent" ] || fail "$flavor: hello_world() exists without PHP_EXT_ENABLE ('$off') -- the enable check below would prove nothing"

  out="$(run -e PHP_EXT_ENABLE=hello "$img" timeout 20 php -r 'echo hello_world(), "|", hello_api();')" \
    || fail "$flavor: php with PHP_EXT_ENABLE=hello failed: $out"
  [ "${out%%|*}" = "hello from ext-builder" ] || fail "$flavor: hello_world() returned '$out'"
  [ "${out##*|}" = "$api_ext" ] || fail "$flavor: hello_api() is '${out##*|}', the runtime's Zend module API is $api_ext"
  echo "ok: $flavor loads hello via PHP_EXT_ENABLE=hello and answers ($out)"

  uid="$(run -e PHP_EXT_ENABLE=hello "$img" timeout 20 id -u)"
  [ "$uid" = "33" ] || fail "$flavor: derived image runs as uid $uid, expected 33"
done

# php-fpm is a separate SAPI binary reading the same scan dir; php -r above
# only proves the CLI SAPI.
mods="$(run -e PHP_EXT_ENABLE=hello "$DERIVED_REPO:$VERSION-fpm" timeout 20 php-fpm -m)"
grep -qx hello <<<"$mods" || fail "php-fpm -m does not list hello: $mods"
echo "ok: php-fpm -m lists hello"

echo "EXT-BUILDER TEST PASSED (php $VERSION)"
