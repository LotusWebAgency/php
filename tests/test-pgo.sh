#!/usr/bin/env bash
# Assert what the compile actually did to the binaries this image ships.
#
#   ./tests/test-pgo.sh <image> <php-version>
#
# The expectation is read from matrix.json, never passed in: a version whose
# `pgo` flag is true must ship a profile-guided binary, and one whose flag is
# false must ship a binary built without a profile (plain ThinLTO on clang, no
# LTO at all on the gcc versions). Both directions fail loudly, so
# flipping a version to pgo:false is a deliberate recorded act rather than
# something that can happen by drift.
#
# HOW "THE PROFILE WAS USED" IS MEASURED
#
# A build that instruments, trains, merges a profile and then links without it
# looks identical from the outside to one that worked: same binary name, same
# version string, same tests passing. So the assertion is on a property only a
# profile-guided compile can produce -- a .text.hot section of a size only a
# profile can account for. Presence alone is not enough: __attribute__((hot))
# puts a single function in that section with no profile involved, so the check
# is a share of the binary's own text (roughly 17-36% on profile-guided builds,
# 0% on a build without a profile).
#
# Clang gives a function a .text.hot/.text.unlikely section prefix only when
# something marks it hot or cold, and llvm's PGOInstrumentation pass is what
# sets those from an IR profile. -ffunction-sections and
# -Wl,-z,keep-text-section-prefix are applied identically to every build
# php/build.sh produces, PGO or not, so the profile is the only variable.
# php/pgo/discriminator-control.sh re-proves that in both directions on every
# build, with that build's own flags, and the image records that it ran.
#
# .text.unlikely is deliberately not the signal: php-src marks many functions
# ZEND_COLD, so the cold section exists either way. ZEND_HOT is defined but
# unused.
#
# WHAT THIS FILE DELIBERATELY DOES NOT DO
#
# It does not assert "no instrumentation in the shipped binary" with
# `nm -D /usr/local/bin/php | grep __llvm_profile`: an instrumented binary built
# with -fprofile-generate exports *zero* such dynamic symbols (the profiling
# runtime is a static archive), so that check passes on an instrumented binary
# too -- it is fail-open. The allocated __llvm_prf_* sections are the property
# that actually differs, and they survive `strip --strip-unneeded`, so they are
# what is checked below.
set -euo pipefail

IMAGE="${1:?usage: test-pgo.sh <image> <php-version>}"
VERSION="${2:?usage: test-pgo.sh <image> <php-version>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker-lib.sh
. "$HERE/docker-lib.sh"
ROOT="$(cd "${HERE}/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

for tool in readelf python3 docker; do
  command -v "$tool" >/dev/null || fail "$tool not found; cannot verify the build"
done

# Capture, then match. `docker run ... | grep -q` exits at the first match and
# SIGPIPEs the producer, which pipefail then reports as a failed pipeline -- a
# real flake under parallel load.
ver="$(drun --rm "$IMAGE" php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
[ "$ver" = "$VERSION" ] || fail "$IMAGE is php $ver, not the $VERSION this check was given"
echo "ok: $IMAGE is php $VERSION"

expect_pgo="$(python3 -c '
import json, sys
matrix = json.load(open(sys.argv[1]))
version = sys.argv[2]
if version not in matrix["versions"]:
    sys.exit("php %s is not in matrix.json" % version)
spec = matrix["versions"][version]
print("true" if spec.get("pgo") else "false")
' "${ROOT}/matrix.json" "$VERSION")"
echo "ok: matrix.json says php $VERSION is pgo=$expect_pgo"

# ---------------------------------------------------------------- the record
record="$(drun --rm --entrypoint cat "$IMAGE" /usr/local/share/php-build/pgo.txt 2>/dev/null)" \
  || fail "$IMAGE has no /usr/local/share/php-build/pgo.txt -- it was not built by a php/build.sh that records what it did"
field() {  # field <key> -> value (empty if absent)
  sed -n "s/^${1}=//p" <<<"$record" | head -1
}

[ "$(field pgo)" = "$expect_pgo" ] \
  || fail "the image records pgo=$(field pgo) but matrix.json says $expect_pgo for php $VERSION"
[ "$(field php_version)" = "$VERSION" ] \
  || fail "the build record says php $(field php_version), the image is php $VERSION"
# COMPILER=gcc records lto=none -- GCC's LTO rejects
# ext/opcache/jit/zend_jit_vm_helpers.c's global-register-variable placement,
# so the gcc path never passes -flto and its CFLAGS differ from the clang
# default. An image with no compiler= line is treated as a clang build.
compiler="$(field compiler)"; compiler="${compiler:-clang}"
case "$compiler" in
  clang) expect_lto=thin;   want_flags="-flto=thin -ffunction-sections" ;;
  gcc)   expect_lto=none;   want_flags="-ffunction-sections -freorder-functions -freorder-blocks-and-partition" ;;
  *)     fail "the build record names an unknown compiler=$compiler" ;;
esac
# php/build.sh leaves block partitioning off for gcc on arm64 (aarch64 jump
# tables cannot span .text/.text.unlikely), and it must stay off there.
if [ "$compiler" = gcc ] && [ "$(docker image inspect --format '{{.Architecture}}' "$IMAGE")" = arm64 ]; then
  want_flags="-ffunction-sections -freorder-functions"
  case "$(field cflags)" in
    *-freorder-blocks-and-partition*) fail "arm64 gcc build records -freorder-blocks-and-partition, which aarch64 cannot assemble" ;;
  esac
fi
[ "$(field lto)" = "$expect_lto" ] \
  || fail "the build record says lto=$(field lto) for compiler=$compiler; expected $expect_lto"
[ "$(field discriminator_control)" = ok ] \
  || fail "the build record has no discriminator_control=ok -- the .text.hot assertion below rests on a channel this build never verified"

cflags="$(field cflags)"
for want in $want_flags; do
  case " $cflags " in *" $want "*) ;; *) fail "the recorded CFLAGS carry no $want: $cflags" ;; esac
done
# The profile flag must NOT be in CFLAGS: those are the flags ./configure ran
# with, and a warning from -fprofile-use makes AX_GCC_FUNC_ATTRIBUTE answer
# "no", which removes every __attribute__((target)) SIMD implementation in
# php-src. It belongs on the make command line, recorded as prof_flags.
# LDFLAGS as well as CFLAGS: AX_GCC_FUNC_ATTRIBUTE's probe *links*
# (ac_fn_c_try_link), so a profile flag hidden in LDFLAGS reaches the same
# compile and produces the same warning on the same stderr.
for recorded in cflags ldflags; do
  case "$(field "$recorded")" in
    *-fprofile-*) fail "the recorded $recorded carries a profile flag: ./configure ran with it, and its function-attribute probes link, so clang's warnings were read as feature answers. $(field "$recorded")" ;;
  esac
done
case "$(field prof_flags)" in
  *-fprofile-use=*) had_profile_flag=true ;;
  '')               had_profile_flag=false ;;
  *)                fail "unexpected prof_flags in the build record: $(field prof_flags)" ;;
esac
[ "$had_profile_flag" = "$expect_pgo" ] \
  || fail "the record says prof_flags='$(field prof_flags)' but matrix.json says pgo=$expect_pgo"
echo "ok: build record is consistent with matrix.json (pgo=$expect_pgo, thinlto, function sections, profile flag off configure's command line)"

# php-src's SIMD implementations are static symbols that `strip --strip-unneeded`
# removes, so whether they are present cannot be established from the shipped
# image at all -- and counting vector instructions in the whole binary is
# useless on the legacy era, where the statically linked OpenSSL 1.1.1w
# contributes every single one of them. The real
# assertion therefore runs in the php-build stage against the unstripped
# binary and fails the build; what is checkable here is that it ran and what it
# concluded.
#
# Which assertion ran depends on the image's architecture (php/build.sh: x86
# target-attributed implementations on amd64, the NEON base64 loops on arm64),
# so the recorded result has to be the one for this image's arch -- an amd64
# record claiming NEON, or an arm64 one claiming x86 vector instructions, is a
# mislabeled or mixed-up build.
simd="$(field simd_php_src)"
image_arch="$(docker image inspect --format '{{.Architecture}}' "$IMAGE")"
case "$simd" in
  neon:*)  [ "$image_arch" = arm64 ] || fail "the build record reports an aarch64 NEON result ('$simd') on a $image_arch image" ;;
  */*)     [ "$image_arch" = amd64 ] || fail "the build record reports an x86 target-attributed SIMD result ('$simd') on a $image_arch image" ;;
esac
case "$simd" in
  '')                     fail "the build record has no simd_php_src line -- this image predates the SIMD assertion and there is no evidence php-src's vector implementations survived the build" ;;
  unchecked)              fail "the build record says simd_php_src=unchecked -- the build-stage assertion did not run" ;;
  none-in-this-branch)    if [ "$image_arch" = arm64 ]; then
                            echo "ok: php $VERSION has no aarch64 NEON code in ext/standard/base64.c (7.4+), asserted at build time against its own source tree"
                          else
                            echo "ok: php $VERSION declares no target-attributed SIMD, asserted at build time against its own configure probes"
                          fi ;;
  *)                      [ "$(field simd_php_src_functions)" -gt 0 ] 2>/dev/null \
                            || fail "the build record reports simd_php_src='$simd' but simd_php_src_functions='$(field simd_php_src_functions)'"
                          echo "ok: build asserted php-src's own SIMD implementations in the unstripped binary ($simd)" ;;
esac

if [ "$expect_pgo" = true ]; then
  requests="$(field training_requests)"
  [ "${requests:-0}" -gt 0 ] 2>/dev/null || fail "training made $requests http requests"
  if [ "$compiler" = clang ]; then
    sha="$(field profdata_sha256)"
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fail "profdata_sha256 is not a sha256: '$sha'"
    functions="$(field profile_functions)"
    maxcount="$(field profile_max_function_count)"
    [ "${functions:-0}" -gt 0 ] 2>/dev/null || fail "the profile covered $functions functions"
    # Derived rather than a threshold: every request runs the engine's busiest
    # function many times over, so a profile whose maximum count does not even
    # exceed the request count recorded startup, not the workload.
    [ "${maxcount:-0}" -gt "$requests" ] 2>/dev/null \
      || fail "the profile's busiest function ran $maxcount times over $requests requests -- the workload was not recorded"
    echo "ok: profile covers $functions functions, busiest ran $maxcount times over $requests requests"
  else
    # gcc has no llvm-profdata equivalent to summarize (no per-function count,
    # no single sha to name -- the profile is a directory of .gcda files
    # consumed in place). What is checkable from the record is that a merge
    # step ran and reported itself, and that training made real requests.
    merge="$(field profile_merge)"
    [ -n "$merge" ] || fail "the build record has no profile_merge line for a gcc pgo=true build"
    echo "ok: profile_merge=$merge, trained over $requests http requests (gcc: no profdata summary to check)"
  fi
fi

# The same attribution problem as simd_php_src, for the two hardening
# properties that are code facts rather than link facts: __*_chk references and
# endbr64 landing pads are contributed by everything linked in, and on 7.0-8.0
# the vendored static archives supply thousands of them. tests/assert-elf-
# hardening.sh still counts them whole-binary as a smoke check; the assertion
# that attributes them to php-src runs in the build stage against the unstripped
# binary, and this is where its verdict is checked.
hardening="$(field hardening_php_src)"
case "$hardening" in
  '')          fail "the build record has no hardening_php_src line -- this image predates the attributed hardening assertion" ;;
  unchecked)   fail "the build record says hardening_php_src=unchecked -- the build-stage assertion did not run" ;;
  *)           echo "ok: build attributed the hardening flags to php-src's own code ($hardening)" ;;
esac

# ------------------------------------------------------- the shipped binaries
# readelf is not installed in the runtime image, so the binaries come out to
# the host the same way tests/smoke.sh extracts them for the hardening
# assertions.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; [ -z "${cid:-}" ] || docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
cid="$(docker create --pull never "$IMAGE")"
docker cp "$cid:/usr/local/bin/php" "$tmp/php" >/dev/null
binaries=("$tmp/php")
if docker cp "$cid:/usr/local/sbin/php-fpm" "$tmp/php-fpm" >/dev/null 2>&1; then
  binaries+=("$tmp/php-fpm")
fi
docker rm -f "$cid" >/dev/null; cid=""
[ -s "$tmp/php" ] || fail "the extracted php binary is empty -- docker cp produced nothing to measure"

# The floor comes out of the image's own build record, so this test asserts the
# threshold the build actually applied rather than one of its own that could
# drift from it.
TEXT_HOT_MIN_PERCENT="$(field text_hot_min_percent)"
[ -n "$TEXT_HOT_MIN_PERCENT" ] && [ "$TEXT_HOT_MIN_PERCENT" -gt 0 ] 2>/dev/null \
  || fail "the build record carries no text_hot_min_percent; this image predates the floor and its .text.hot claim is unverifiable"

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
for bin in "${binaries[@]}"; do
  name="$(basename "$bin")"
  sections="$(readelf -SW "$bin")" || fail "readelf could not read the sections of $name"
  # Positive control for all three absence/presence checks below: a listing
  # that could not be produced would make every "not present" answer true.
  grep -q '\.dynamic' <<<"$sections" \
    || fail "readelf printed no .dynamic section for $name -- nothing below was measured"

  # `if`, not `grep ... && fail`: the && form does not trip errexit when grep
  # finds nothing, but it leaves $? at 1 for whatever reads it next.
  if grep -q '__llvm_prf_' <<<"$sections"; then
    fail "$name carries __llvm_prf_* sections -- an instrumented binary shipped"
  fi
  if grep -qE '\.llvmbc|\.llvmcmd' <<<"$sections"; then
    fail "$name still carries llvm bitcode sections -- the ThinLTO link did not complete"
  fi

  text="$(section_size "$sections" .text)"
  hot="$(section_size "$sections" .text.hot)"
  unlikely="$(section_size "$sections" .text.unlikely)"
  total=$((text + hot + unlikely))
  [ "$total" -gt 0 ] || fail "$name has no executable text at all -- nothing was measured"
  pct=$((100 * hot / total))
  if [ "$expect_pgo" = true ]; then
    [ "$pct" -ge "$TEXT_HOT_MIN_PERCENT" ] \
      || fail "$name has $hot bytes of .text.hot, ${pct}% of its text, below the ${TEXT_HOT_MIN_PERCENT}% a profile-guided build produces -- php $VERSION is pgo=true in matrix.json but this binary was compiled without the profile"
    echo "ok: $name has $hot bytes of .text.hot (${pct}% of text) -- the profile reached the compiler"
  else
    [ "$hot" -eq 0 ] \
      || fail "$name has $hot bytes of .text.hot on a pgo=false build -- either a profile leaked in, or .text.hot has stopped discriminating and every PGO result here is unproven"
    echo "ok: $name has no .text.hot, as a plain ThinLTO build must not"
  fi


done

# ---------------------------------------------------- what it was trained on
# The corpus the record names has to be the corpus this version's tier
# actually publishes, app for app and version for version. Without this, a
# build trained against some other tier's corpus -- which would still serve, as
# long as it was compatible -- would look identical.
if [ "$expect_pgo" = true ]; then
  tier="$(python3 "${ROOT}/scripts/pgo_tiers.py" tier-of "$VERSION")"
  tag="$(python3 "${ROOT}/scripts/pgo_tiers.py" field "$tier" tag)"
  docker image inspect "$tag" >/dev/null 2>&1 \
    || fail "the tier $tier corpus ($tag) is not present locally; it is required to build this image, so it is required to check it -- ./tests/build-corpus.sh $tier"
  manifest="$(drun --rm "$tag" cat /corpus/MANIFEST)"
  want=""
  while IFS=$'\t' read -r app _docroot version _paths; do
    case "$app" in ''|\#*) continue ;; esac
    want="${want:+${want} }${app}=${version}"
  done <<<"$manifest"
  [ -n "$want" ] || fail "the tier $tier corpus has an empty MANIFEST"
  got="$(field training_corpus)"
  [ "$got" = "$want" ] \
    || fail "trained on '$got' but the tier $tier corpus serves '$want' -- this image was profiled against a different corpus than its tier publishes"
  echo "ok: trained on the tier $tier corpus ($want)"
fi

# ------------------------------------------- the functions whose dispatch moved
# php/build.sh answers configure's ifunc probe "no" so ld.lld can complete a
# ThinLTO link, which moves php_base64_encode_ex, php_base64_decode_ex,
# php_addslashes and mbstring's utf-8 check off the dynamic linker's ifunc
# resolution and onto php-src's function-pointer path, resolved in MINIT. That
# is a supported php-src configuration, but it is *this build* that chose it,
# so the functions it moved are checked here rather than assumed.
#
# Golden md5s, not just a round trip: base64_decode(base64_encode($s)) === $s
# holds even if both halves picked the same wrong SIMD kernel. The inputs are
# long enough (4600 and 1600 bytes) to leave the scalar prologue and run the
# vector body, which is the code the dispatch actually selects. The script goes
# in on stdin rather than through -r so that neither the shell nor docker has
# to be trusted with the backslashes and quotes the addslashes input is made of.
simd="$(drun --rm -i "$IMAGE" php <<'PHPEOF'
<?php
$data = str_repeat("PGO/ThinLTO corpus \xE2\x9C\x93 ", 200);
$slash = str_repeat("a'b\"c\\d\x00e ", 200);
echo "in=", md5($data), " ";
echo "b64=", md5(base64_encode($data)), " ";
echo "roundtrip=", (base64_decode(base64_encode($data)) === $data ? "y" : "n"), " ";
echo "slashin=", md5($slash), " ";
echo "slash=", md5(addslashes($slash)), " ";
echo "utf8ok=", (mb_check_encoding($data, "UTF-8") ? "y" : "n"), " ";
echo "utf8bad=", (mb_check_encoding($data . "\xC3\x28", "UTF-8") ? "y" : "n");
PHPEOF
)"
# The two md5s of the *inputs* are the positive control: if the test strings
# were mangled before php ever saw them, every other digest below would be
# wrong for a reason that has nothing to do with the binary.
grep -q "in=54ba6ebb8ea57cdc6171476fe8deeb83 " <<<"$simd" \
  || fail "the base64 test input is not what this check was written against: $simd"
grep -q "slashin=b44e4acf87803347210b970fad13eab7 " <<<"$simd" \
  || fail "the addslashes test input is not what this check was written against: $simd"
grep -q "b64=4027f74c08d08996751ac66ac97c252d " <<<"$simd" \
  || fail "base64_encode produced the wrong bytes after the ifunc change: $simd"
grep -q "roundtrip=y " <<<"$simd" || fail "base64 does not round-trip: $simd"
grep -q "slash=9bd027a09a70dad6ef1b142d3444a48d " <<<"$simd" \
  || fail "addslashes produced the wrong bytes after the ifunc change: $simd"
grep -q "utf8ok=y " <<<"$simd" || fail "mb_check_encoding rejected valid UTF-8: $simd"
grep -q "utf8bad=n" <<<"$simd" || fail "mb_check_encoding accepted invalid UTF-8 -- it answers yes to everything: $simd"
echo "ok: base64, addslashes and mb_check_encoding are byte-correct on the function-pointer dispatch path"

# ------------------------------------------------------------------- sanity
out="$(drun --rm "$IMAGE" php -r 'echo "php-ok";')"
[ "$out" = "php-ok" ] || fail "the shipped php binary does not run: '$out'"
mods="$(drun --rm "$IMAGE" php -m)"
grep -qi opcache <<<"$mods" || fail "opcache is missing after the two-pass build"
echo "ok: the shipped binary runs and opcache is loaded"

echo "PGO TESTS PASSED"
