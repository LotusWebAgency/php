#!/usr/bin/env bash
# End to end for the ext-builder flavor, across the three images of one PHP
# version:
#
#   ./tests/test-ext-builder.sh <php-version>[-v3]        e.g. 8.5 or 8.4-v3
#
# Needs lotuswebagency/php:<version>-{ext-builder,fpm,cli}[-v3] in the local
# daemon (PHP_IMAGE overrides the repository part). What it proves that
# smoke.sh, which sees one image at a time, cannot:
#
#   - php-config in ext-builder reports the extension_dir the fpm and cli
#     runtimes actually use (the dir name carries the Zend module API number,
#     so equal dirs mean an extension built there loads here);
#   - the tests/fixtures/ext-hello extension, compiled with phpize/configure/
#     make in ext-builder and COPYed into fpm and cli by a multi-stage build --
#     the same shape the README documents -- loads there under PHP_EXT_ENABLE=
#     hello and answers a call, as the images' own uid 33;
#   - the default compile flags follow the microarchitecture: the baseline
#     ext-builder sets none (Wolfi's compiler defaults), the -v3 one sets the
#     -march/-mtune php/cflags.sh passes for v3, and the fixture's compile
#     lines carry them, so the .so matches the -v3 runtime it is COPYed into.
#
# The two derived images are tagged lotuswebagency/php-ext-hello-test:* and
# removed again on exit.
set -euo pipefail
ARG="${1:?usage: test-ext-builder.sh <php-version>[-v3]}"
VERSION="${ARG%-v3}"
SUFFIX=""
[ "$ARG" = "$VERSION" ] || SUFFIX="-v3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/docker-lib.sh
. "$HERE/docker-lib.sh"
PHP_IMAGE="${PHP_IMAGE:-lotuswebagency/php}"
FIXTURE="$HERE/fixtures/ext-hello"
EXT="$PHP_IMAGE:$VERSION-ext-builder$SUFFIX"
FPM="$PHP_IMAGE:$VERSION-fpm$SUFFIX"
CLI="$PHP_IMAGE:$VERSION-cli$SUFFIX"
DERIVED_REPO="lotuswebagency/php-ext-hello-test"

fail() { echo "FAIL: $*" >&2; exit 1; }
# Every container: removed on exit, signal-forwarding init, and the time limit
# inside it (a host-side `timeout docker run` only kills the client, not PID 1).
run() { drun --rm --init "$@"; }

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

# ------------------------------------------------- default flags per microarch
# Expected -march/-mtune come from php/cflags.sh run on this host, whose
# architecture is the one of the images in the local daemon.
env_flag() { run "$EXT" sh -c "printf %s \"\${$1-}\""; }
cflags_env="$(env_flag CFLAGS)"
cxxflags_env="$(env_flag CXXFLAGS)"
# The compile lines of the fixture, built the way the README builds an extension.
build_log="$(run -v "$FIXTURE":/src:ro "$EXT" timeout 600 sh -c '/src/build.sh /out 2>&1')" \
  || fail "ext-hello did not build in $EXT: $build_log"
if [ -n "$SUFFIX" ]; then
  isa="$(bash "$ROOT/php/cflags.sh" v3 | grep -oE -- '-m(arch|tune)=[^ ]+' | paste -sd' ' -)"
  [ -n "$isa" ] || fail "php/cflags.sh v3 printed no -march/-mtune"
  for pair in "CFLAGS:$cflags_env" "CXXFLAGS:$cxxflags_env"; do
    case " ${pair#*:} " in
      *" $isa "*) ;;
      *) fail "$EXT: ${pair%%:*} is '${pair#*:}', expected it to carry '$isa' (php/cflags.sh v3)" ;;
    esac
  done
  case "$build_log" in
    *"$isa"*) ;;
    *) fail "$EXT: the ext-hello compile lines do not carry '$isa':
$build_log" ;;
  esac
  case "$(run "$EXT" uname -m)" in
    x86_64)  macro=__AVX2__ ;;
    aarch64) macro=__ARM_FEATURE_SVE2 ;;
    *) fail "$EXT: unsupported machine" ;;
  esac
  run "$EXT" sh -c "gcc \$CFLAGS -dM -E -x c /dev/null | grep -q '^#define $macro '" \
    || fail "$EXT: gcc with the default CFLAGS does not define $macro -- the v3 instruction set is not on"
  echo "ok: the -v3 ext-builder compiles with '$isa' by default ($macro defined, ext-hello compile lines carry it)"
else
  [ -z "$cflags_env$cxxflags_env" ] \
    || fail "$EXT: the baseline ext-builder sets CFLAGS='$cflags_env' CXXFLAGS='$cxxflags_env', expected neither"
  case "$build_log" in
    *"-march=x86-64-v3"* | *"-march=armv9-a"*) fail "$EXT: the baseline ext-hello compile lines carry a v3 -march" ;;
  esac
  echo "ok: the baseline ext-builder sets no default CFLAGS/CXXFLAGS and compiles ext-hello without a v3 -march"
fi

# ------------------------------------------------- multi-stage build of the .so
hello_dir=""
hello_cid=""
cleanup() {
  [ -z "$hello_cid" ] || docker rm -f "$hello_cid" >/dev/null 2>&1 || true
  [ -z "$hello_dir" ] || rm -rf "$hello_dir"
  docker rmi -f "$DERIVED_REPO:$VERSION-fpm$SUFFIX" "$DERIVED_REPO:$VERSION-cli$SUFFIX" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --builder default: the docker driver, which resolves FROM against the local
# image store. A docker-container builder (what CI's setup-buildx-action makes
# current) cannot see the images this test is about, and would go to a registry.
# --network=none: phpize/configure/make of a local fixture need no network, so a
# RUN that tried to fetch something fails here instead of passing on whatever
# the runner happens to reach.
for flavor in fpm cli; do
  docker buildx build --builder default --network=none -q -f "$FIXTURE/Dockerfile" --target "$flavor" \
    --build-arg "PHP_VERSION=$VERSION" --build-arg "PHP_IMAGE=$PHP_IMAGE" --build-arg "TAG_SUFFIX=$SUFFIX" \
    -t "$DERIVED_REPO:$VERSION-$flavor$SUFFIX" "$FIXTURE" >/dev/null \
    || fail "multi-stage build of the ext-hello fixture failed for $flavor (re-run without -q: docker buildx build --builder default --network=none -f $FIXTURE/Dockerfile --target $flavor --build-arg PHP_VERSION=$VERSION --build-arg PHP_IMAGE=$PHP_IMAGE --build-arg TAG_SUFFIX=$SUFFIX $FIXTURE)"
done
echo "ok: ext-hello compiled in ext-builder and COPYed into fpm and cli of php $VERSION"

# The module an extension author builds with the ext-builder must carry the same
# hardening as the shared extensions the image ships: PIE-style link flags (full
# RELRO, BIND_NOW, non-executable stack) and the code-level properties. Measured
# on the .so that landed in the derived image, not on the flags that were meant
# to produce it. Needs readelf and objdump (or llvm-objdump) on the host, as
# smoke.sh does.
hello_dir="$(mktemp -d)"
hello_cid="$(docker create --pull never "$DERIVED_REPO:$VERSION-fpm$SUFFIX")"
docker cp "$hello_cid:$pc_dir/hello.so" "$hello_dir/hello.so" >/dev/null \
  || fail "could not copy $pc_dir/hello.so out of the derived fpm image"
bash "$HERE/assert-elf-hardening.sh" --code "ext-builder-hello-$VERSION$SUFFIX" "$hello_dir/hello.so" \
  || fail "the hello.so built by ext-builder is not hardened like the shipped extensions"
docker rm -f "$hello_cid" >/dev/null 2>&1 || true
hello_cid=""

# ------------------------------------------------------ load and call, per flavor
for flavor in fpm cli; do
  img="$DERIVED_REPO:$VERSION-$flavor$SUFFIX"

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
mods="$(run -e PHP_EXT_ENABLE=hello "$DERIVED_REPO:$VERSION-fpm$SUFFIX" timeout 20 php-fpm -m)"
grep -qx hello <<<"$mods" || fail "php-fpm -m does not list hello: $mods"
echo "ok: php-fpm -m lists hello"

echo "EXT-BUILDER TEST PASSED (php $VERSION${SUFFIX:+ }$SUFFIX)"
