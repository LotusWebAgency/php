#!/usr/bin/env bash
# The one smoke suite CI runs per built image:
#
#   ./tests/smoke.sh <image> <php-version> <flavor>
#
# <php-version> is a matrix.json key ("8.5", "7.0", ...); every era-specific
# expectation below (release string, era, pgo, icu) is derived from it, never
# a literal. <flavor> is fpm, cli, cli-builder or ext-builder -- also asserted against,
# never inferred from the image tag, which a caller could always get wrong or
# rename.
set -euo pipefail
IMAGE="${1:?usage: smoke.sh <image> <php-version> <flavor>}"
EXPECT="${2:?usage: smoke.sh <image> <php-version> <flavor>}"
FLAVOR="${3:?usage: smoke.sh <image> <php-version> <flavor>}"
case "$FLAVOR" in
  fpm|cli|cli-builder|ext-builder) ;;
  *) echo "FAIL: flavor '$FLAVOR' is not one of fpm, cli, cli-builder, ext-builder"; exit 1 ;;
esac
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker-lib.sh
. "$HERE/docker-lib.sh"
ROOT="$(cd "$HERE/.." && pwd)"

# Refuse to run any check against an image that cannot prove it was built from
# this tree: a green gate on a stale image proves nothing. Timestamps cannot
# catch it -- build-then-commit is the normal order, so an older image is
# routine. A content hash of the build-context inputs (the image's inputs-hash
# label against scripts/inputs-hash.sh) is the only thing that tells them apart.
label_hash=$(docker inspect --format '{{index .Config.Labels "com.lotuswebagency.inputs-hash"}}' "$IMAGE" 2>/dev/null || true)
tree_hash=$(bash "$ROOT/scripts/inputs-hash.sh")
if [ -z "$label_hash" ] || [ "$label_hash" = "<no value>" ]; then
  if [ "${SMOKE_ALLOW_STALE:-}" = "1" ]; then
    echo "WARNING: $IMAGE carries no com.lotuswebagency.inputs-hash label -- cannot verify it was built from this tree. Proceeding because SMOKE_ALLOW_STALE=1 (only meant for inspecting an already-published image)." >&2
  else
    echo "FAIL: $IMAGE carries no com.lotuswebagency.inputs-hash label -- it may not correspond to the current tree. Rebuild with: INPUTS_HASH=\"\$(./scripts/inputs-hash.sh)\" docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl <target> --set '*.platform=linux/amd64' --load  (or set SMOKE_ALLOW_STALE=1 to inspect this image anyway)"
    exit 1
  fi
elif [ "$label_hash" != "$tree_hash" ]; then
  if [ "${SMOKE_ALLOW_STALE:-}" = "1" ]; then
    echo "WARNING: $IMAGE was built from a tree whose inputs-hash was $label_hash, but the working tree now hashes to $tree_hash -- this image is STALE. Proceeding because SMOKE_ALLOW_STALE=1." >&2
  else
    echo "FAIL: $IMAGE's com.lotuswebagency.inputs-hash label ($label_hash) does not match the current tree ($tree_hash) -- the image predates a change to its own build inputs. Rebuild with: INPUTS_HASH=\"\$(./scripts/inputs-hash.sh)\" docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl <target> --set '*.platform=linux/amd64' --load  (or set SMOKE_ALLOW_STALE=1 to inspect this image anyway)"
    exit 1
  fi
else
  echo "ok: $IMAGE's inputs-hash label matches the current tree ($tree_hash)"
fi

# Every era-specific expectation below (the exact release string, the
# static-vs-dynamic OpenSSL boundary) is read out of matrix.json for this
# version, never a literal or a hand-derived boundary -- a version whose era
# changes, or whose point release moves, changes this script's behavior by
# editing matrix.json, not by editing smoke.sh.
matrix_field() {  # matrix_field <key> -> matrix.json's versions[$EXPECT][<key>] ("" for null/absent, space-joined for a list)
  python3 -c '
import json, sys
matrix = json.load(open(sys.argv[1]))
version, key = sys.argv[2], sys.argv[3]
if version not in matrix["versions"]:
    sys.exit("php %s is not a version in matrix.json" % version)
val = matrix["versions"][version].get(key)
if isinstance(val, list):
    print(" ".join(val))
elif isinstance(val, bool):
    print("true" if val else "false")
elif val is None:
    print("")
else:
    print(val)
' "$ROOT/matrix.json" "$EXPECT" "$1"
}
ERA=$(matrix_field era)
RELEASE=$(matrix_field release)
PGO=$(matrix_field pgo)
UARCH=$(matrix_field uarch)
MATRIX_COMPILER=$(matrix_field compiler)
echo "ok: matrix.json says php $EXPECT is era=$ERA release=$RELEASE pgo=$PGO uarch=[$UARCH] compiler=$MATRIX_COMPILER"

# The VM-kind expectation below (and the compiler-identity check further down)
# is keyed on the compiler that actually built this image, not on the PHP
# version -- gcc gets the HYBRID VM on every version it builds, clang gets CALL
# except on 8.5 where it gets TAILCALL. matrix.json says what *should* have
# built it; docker-bake.hcl's "php" target writes that same value onto the image
# as com.lotuswebagency.compiler. Cross-checking the label against matrix.json
# makes a mislabeled image (built with the wrong COMPILER for its tag) fail
# here instead of shipping.
compiler_label=$(docker inspect --format '{{index .Config.Labels "com.lotuswebagency.compiler"}}' "$IMAGE" 2>/dev/null || true)
if [ -z "$compiler_label" ] || [ "$compiler_label" = "<no value>" ]; then
  if [ "${SMOKE_ALLOW_STALE:-}" = "1" ]; then
    echo "WARNING: $IMAGE carries no com.lotuswebagency.compiler label -- cannot verify which compiler actually built it. Proceeding with matrix.json's compiler ($MATRIX_COMPILER) because SMOKE_ALLOW_STALE=1 (only meant for inspecting an image that predates this label)." >&2
    VM_COMPILER="$MATRIX_COMPILER"
  else
    echo "FAIL: $IMAGE carries no com.lotuswebagency.compiler label -- cannot verify which compiler built it (rebuild, or set SMOKE_ALLOW_STALE=1 to inspect this image anyway)"
    exit 1
  fi
elif [ "$compiler_label" != "$MATRIX_COMPILER" ]; then
  echo "FAIL: $IMAGE is labeled com.lotuswebagency.compiler=$compiler_label, but matrix.json says php $EXPECT should be built with $MATRIX_COMPILER -- mislabeled image (wrong COMPILER was used, or the label was not updated to match a matrix.json change)"
  exit 1
else
  VM_COMPILER="$compiler_label"
  echo "ok: com.lotuswebagency.compiler=$VM_COMPILER matches matrix.json"
fi

# The expectation is a function of VM_COMPILER, the PHP version and the image's
# architecture, mirroring what Zend/zend_vm_opcodes.h derives at build time:
#   - 7.0 and 7.1 define ZEND_VM_KIND as ZEND_VM_KIND_CALL unconditionally, on
#     every compiler and arch. gcc still pins execute_data/opline in global
#     registers there (HAVE_GCC_GLOBAL_REGS), but that is the CALL VM with
#     registers, not HYBRID.
#   - gcc from 7.2 gets the HYBRID VM (global register variables), except on
#     arm64 below 7.4, where Zend/Zend.m4's probe only knows __aarch64__ from
#     7.4 on -- 7.2/7.3 run the CALL VM there.
#   - clang has no usable global register variables: TAILCALL
#     (preserve_none + musttail, 8.5+ only -- see php/build-canaries.sh's
#     assert_preserve_none_canary), the plain CALL VM before that.
#
# The image's own architecture, not the host's: an arm64 image smoke-tested
# under emulation on an amd64 host is still an arm64 build.
IMAGE_ARCH=$(docker image inspect --format '{{.Architecture}}' "$IMAGE")
version_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }
case "$VM_COMPILER" in
  gcc)
    if version_lt "$EXPECT" 7.2; then
      EXPECTED_VM_KIND=1
      EXPECTED_VM_NAME=CALL
      echo "note: PHP $EXPECT defines ZEND_VM_KIND as CALL unconditionally (HYBRID arrived in 7.2), expecting the CALL VM"
    elif [ "$IMAGE_ARCH" = arm64 ] && version_lt "$EXPECT" 7.4; then
      EXPECTED_VM_KIND=1
      EXPECTED_VM_NAME=CALL
      echo "note: arm64 gcc build of PHP $EXPECT -- no aarch64 global registers before 7.4, expecting the CALL VM"
    else
      EXPECTED_VM_KIND=4
      EXPECTED_VM_NAME=HYBRID
    fi
    ;;
  clang)
    if version_lt "$EXPECT" 8.5; then
      EXPECTED_VM_KIND=1
      EXPECTED_VM_NAME=CALL
    else
      EXPECTED_VM_KIND=5
      EXPECTED_VM_NAME=TAILCALL
    fi
    ;;
  *)
    echo "FAIL: unknown compiler '$VM_COMPILER' -- tests/smoke.sh does not know its expected VM kind"; exit 1
    ;;
esac

# Capture, then match. `docker run ... | grep -q` exits at the first match and
# SIGPIPEs the producer, and pipefail reports that as a failure of the pipeline.
ver=$(drun --rm "$IMAGE" php -r 'echo PHP_VERSION;')
[ "$ver" = "$RELEASE" ] || { echo "FAIL: expected exactly $RELEASE (matrix.json), got $ver"; exit 1; }
echo "ok: php $ver"

# ext-builder is a build stage and runs as root (make install writes into the
# extension dir); every other flavor drops to www-data.
want_uid=33
[ "$FLAVOR" != ext-builder ] || want_uid=0
uid=$(drun --rm "$IMAGE" id -u)
[[ "$uid" == "$want_uid" ]] || { echo "FAIL: running as uid $uid, expected $want_uid"; exit 1; }
echo "ok: uid $want_uid"

# Uncompressed image size against the per-flavor budget. The measurement (the
# sum of `docker history` layer sizes -- NOT `docker image inspect .Size`, which
# under the containerd store adds the compressed blobs and overstates by
# 100-200 MB) lives once, in tests/image-size.sh, so the two scripts can't
# drift on what "size" means.
#
# One budget per flavor (decimal MB, as image-size.sh reports), covering the
# largest era built: the measured size plus ~3% headroom. Report-only until
# every version has a measured size to budget against.
# tests/image-size.sh --breakdown names where the bytes are.
declare -A SIZE_BUDGET_MB=( [fpm]=290 [cli]=268 [cli-builder]=679 [ext-builder]=609 )
budget_mb="${SIZE_BUDGET_MB[$FLAVOR]}"
actual_bytes=$(bash "$HERE/image-size.sh" --bytes "$IMAGE")
budget_bytes=$(( budget_mb * 1000 * 1000 ))
actual_mb=$(awk -v b="$actual_bytes" 'BEGIN { printf "%.1f", b / 1000 / 1000 }')
if [ "$actual_bytes" -le "$budget_bytes" ]; then
  echo "ok: $IMAGE is ${actual_mb} MB, within the $FLAVOR budget of ${budget_mb} MB"
else
  over_pct=$(awk -v a="$actual_bytes" -v b="$budget_bytes" 'BEGIN { printf "%.1f", (a - b) / b * 100 }')
  echo "note: size budget is report-only -- $IMAGE is ${actual_mb} MB, over the $FLAVOR budget of ${budget_mb} MB by ${over_pct}% (run tests/image-size.sh --breakdown $IMAGE for where the bytes are)"
fi

# php -m names some extensions differently from the vocabulary used elsewhere
# (ext.json, matrix.json, the $ext loop variables). opcache reports as "Zend
# OPcache" under [Zend Modules], a different word, not a case variant. A
# substring match is too loose (it would let `xml` match `xmlwriter`), so the
# SHARED_EXTS loops use anchored `grep -qix`. xdebug/pdo/phar/simplexml/ffi
# differ from their registry names only in case ("Xdebug", "PDO", "Phar",
# "SimpleXML", "FFI"), which the anchored `-i` flag normalizes, so they need no
# entry here; a name that needs a real alias is added deliberately.
php_registry_alias() {  # php_registry_alias <ext.json/matrix.json name> -> the exact php -m line to expect
  case "$1" in
    opcache) echo "Zend OPcache" ;;
    *) echo "$1" ;;
  esac
}

extdir=$(drun --rm "$IMAGE" php -r 'echo ini_get("extension_dir");')
mods=$(drun --rm "$IMAGE" php -m)
grep -qix "$(php_registry_alias opcache)" <<<"$mods" || { echo "FAIL: opcache missing (looked for the exact, anchored line 'Zend OPcache')"; exit 1; }
echo "ok: opcache present"

# Matched against the capture above, not re-piped per extension: `docker run
# ... | grep -q` exits at the first match, the producer takes SIGPIPE, and
# `set -o pipefail` reports the pipeline as failed. This flakes under load (CI):
# "write /dev/stdout: broken pipe" and a false "FAIL: apcu missing" against an
# image whose php -m lists apcu. Reusing $mods also saves six containers.
for ext in igbinary redis imagick memcached apcu zstd; do
  grep -qix "$ext" <<<"$mods" || { echo "FAIL: $ext missing"; exit 1; }
done
echo "ok: pecl extensions compiled in"

# Static means no .so on disk for these
for ext in igbinary redis imagick memcached apcu zstd; do
  if drun --rm "$IMAGE" sh -c "ls \$(php -r 'echo ini_get(\"extension_dir\");')/$ext.so" 2>/dev/null; then
    echo "FAIL: $ext is a shared module, expected static"; exit 1
  fi
done
echo "ok: pecl extensions are static, not shared"

# imagick's delegate set: the PHP-level check that static linkage wired up the
# libraries.
formats=$(drun --rm "$IMAGE" php -r 'echo implode(",", Imagick::queryFormats());')
for fmt in PNG JPEG WEBP AVIF; do
  grep -qi "$fmt" <<<"$formats" || { echo "FAIL: Imagick::queryFormats() missing $fmt (got: $formats)"; exit 1; }
done
echo "ok: imagick delegate formats present"

# ImageMagick is built with --disable-openmp; confirm that holds once imagick
# links it into the php binary -- OpenMP spawns a thread per core per request if
# it sneaks back in under FPM.
linkage=$(drun --rm "$IMAGE" ldd /usr/local/bin/php)
grep -qi libgomp <<<"$linkage" && { echo "FAIL: php binary links libgomp (openmp leaked in)"; exit 1; }
echo "ok: no libgomp in php binary linkage"

# The legacy era's vendored OpenSSL must be linked statically: no
# libssl/libcrypto may appear as a *direct* NEEDED entry in the php binary's own
# ELF dynamic section. This keeps an EOL OpenSSL from escaping into the image.
#
# `ldd` (used above for libgomp) resolves the full transitive closure, which
# would wrongly flag 8.0: it links trixie's system libcurl.so.4 (not vendored
# there -- deps/versions.lock caps the vendored copy at 7.0-7.2), and that needs
# libssl.so.3. readelf -d reads only the binary's own recorded NEEDED list,
# which isolates the property that matters. Neither readelf nor nm exist inside
# the runtime image, so extract the binary via docker cp and inspect it on the
# host.
command -v readelf >/dev/null || { echo "FAIL: readelf not found on this host, cannot verify the static OpenSSL property"; exit 1; }
cid=$(docker create --pull never "$IMAGE")
tmp_php=$(mktemp)
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true; rm -f "$tmp_php"' EXIT
docker cp "$cid:/usr/local/bin/php" "$tmp_php" >/dev/null
docker rm -f "$cid" >/dev/null
# Capture the raw `readelf -d` output alone, with nothing to swallow its exit
# status: a non-ELF file, garbled docker cp or moved binary path then fails
# loudly here under set -e. A `readelf | grep | grep || true` pipeline would
# fail open, since the legacy branch below reads an empty direct_needed as proof
# OpenSSL is static. Then require at least one NEEDED line (catches a binary
# with no dynamic section), and scope `|| true` to the one grep that may
# legitimately match nothing.
dyn=$(readelf -d "$tmp_php")
grep -qi NEEDED <<<"$dyn" || { echo "FAIL: readelf found no NEEDED entries in the extracted php binary -- the static OpenSSL check could not be measured (corrupt extraction?)"; exit 1; }
direct_needed=$(grep -i NEEDED <<<"$dyn" | grep -iE 'libssl|libcrypto' || true)
rm -f "$tmp_php"

# A shared *extension* is held to a narrower bar than php itself. On 7.4-8.0,
# event.so NEEDs libssl.so.3/libcrypto.so.3 directly, and snmp.so reaches them
# too (directly on clang builds, transitively through the vendored libnetsnmp on
# gcc builds): Debian's supported OpenSSL 3, which libevent and libnetsnmp link
# and bind to cleanly (LD_DEBUG=bindings shows SSL_CTX_new et al. resolving to
# /lib/.../libssl.so.3, never to php's static 1.1). That is two independent
# OpenSSL stacks in one process, not the EOL vendored one escaping. What must
# never happen is the vendored 1.1.1 (built --no-shared) becoming loadable,
# which shows up in exactly two ways: (a) a NEEDED entry resolving under the
# vendored prefix (/opt/php-deps, or anywhere under /opt) instead of Debian's
# system copy, or (b) a NEEDED soname below .so.3 -- 1.1.x is the only ABI the
# vendored build produces and Debian ships nothing else.
#
# `ldd` resolves each NEEDED entry the way the dynamic linker would at load
# time, RPATH/RUNPATH included, which a bare `readelf -d` soname list would
# miss. It exists in the runtime image (scripts/runtime-libs.sh relies on it too,
# for bare .so files as well as executables), so run it in a container per
# object.
#
# Fail closed: a NEEDED entry `ldd` cannot resolve ("not found") is unproven,
# not innocent, and counts as a hit.
ssl_load_violations=""
scan_ssl_resolution() {  # scan_ssl_resolution <label for messages> <ldd output> -- appends any vendored/EOL hit to $ssl_load_violations
  while IFS= read -r ldd_line; do
    case "$ldd_line" in
      *libssl.so*|*libcrypto.so*) ;;
      *) continue ;;
    esac
    soname=$(awk '{print $1}' <<<"$ldd_line")
    arrow=$(awk '{print $2}' <<<"$ldd_line")
    resolved=$(awk '{print $3}' <<<"$ldd_line")
    major=$(sed -n 's/^lib\(ssl\|crypto\)\.so\.\([0-9][0-9]*\).*/\2/p' <<<"$soname")
    reason=""
    if [ "$arrow" != "=>" ] || [ -z "$resolved" ] || [ "$resolved" = "not" ]; then
      reason="ldd could not resolve it"
    else
      case "$resolved" in
        /opt/*) reason="resolves under the vendored prefix" ;;
      esac
    fi
    if [ -z "$reason" ] && [ -n "$major" ] && [ "$major" -lt 3 ]; then
      reason="soname below .so.3"
    fi
    [ -z "$reason" ] || ssl_load_violations="${ssl_load_violations}${1}: ${ldd_line} (${reason})
"
  done <<<"$2"
}
scan_ssl_resolution "php binary" "$linkage"

ext_files=$(drun --rm "$IMAGE" sh -c "ls \"$extdir\"/*.so 2>/dev/null" || true)
n_ext_files=0
# shellcheck disable=SC2086  # ext_files is a newline/space-separated list of paths, meant to word-split
for sofile in $ext_files; do
  n_ext_files=$((n_ext_files + 1))
  so_ldd=$(drun --rm "$IMAGE" ldd "$sofile" 2>&1 || true)
  [ -n "$so_ldd" ] || { echo "FAIL: ldd produced no output for $sofile -- the OpenSSL scan could not be measured (corrupt image?)"; exit 1; }
  scan_ssl_resolution "$sofile" "$so_ldd"
done
echo "ok: inspected the php binary and $n_ext_files shared extension .so file(s) in $extdir for a libssl/libcrypto NEEDED entry resolving to a vendored path or a pre-.so.3 soname"

# The other half: a stray libssl/libcrypto file can sit in the image without
# being a NEEDED entry of anything php loads (a leftover from a build stage, a
# vendored copy nothing links against yet). Debian's libssl.so.3/libcrypto.so.3
# is allowed anywhere in a legacy image (curl, psql, the mariadb client and the
# vendored libnetsnmp pull it in); what must never exist is a file that could
# only be the vendored, EOL build: a libssl.so.1*/libcrypto.so.1* file anywhere,
# or a libssl.so*/libcrypto.so* file under a vendored prefix (/opt/php-deps, or
# anywhere under /opt). Scoped to shared-object naming: .pc/.a/.h files under
# the prefix carry no loadability risk.
# An absence assertion needs a positive control first: prove `find` can find
# something known to exist, or an empty result and "the scan is broken" are
# indistinguishable.
# `find` exits non-zero on one permission-denied directory while running as
# www-data, even though it printed every match it could reach; `|| true` is
# scoped to that single command so a genuinely empty result still reads as
# "found nothing".
find_control=$(drun --rm "$IMAGE" sh -c "find / -xdev -name 'libc.so*' 2>/dev/null" || true)
[ -n "$find_control" ] || { echo "FAIL: image-wide find could not even locate libc.so -- the file-existence scan below would prove nothing"; exit 1; }
stray_ssl=$(drun --rm "$IMAGE" sh -c "find / -xdev \\( \\( -name 'libssl.so.1*' -o -name 'libcrypto.so.1*' \\) -o \\( -path '/opt/*' -a \\( -name 'libssl.so*' -o -name 'libcrypto.so*' \\) \\) \\) 2>/dev/null" || true)

# 7.0-8.0 vendor OpenSSL statically (no-shared); 8.1+ link Debian's OpenSSL 3
# dynamically by design (system packages). The boundary comes from matrix.json's
# era field, not a hand-derived version cutover.
if [ "$ERA" = legacy ]; then
  [ -z "$direct_needed" ] || { echo "FAIL: legacy php binary directly links libssl/libcrypto, but its OpenSSL must be static: $direct_needed"; exit 1; }
  echo "ok: legacy php binary has no direct libssl/libcrypto NEEDED entry (OpenSSL fully static)"
  [ -z "$ssl_load_violations" ] || { printf 'FAIL: the vendored/EOL OpenSSL is loadable in this image:\n%s\n' "$ssl_load_violations"; exit 1; }
  echo "ok: nothing php or its shared extensions load resolves libssl/libcrypto to a vendored path or a pre-.so.3 soname (Debian's libssl.so.3/libcrypto.so.3 is allowed)"
  [ -z "$stray_ssl" ] || { echo "FAIL: a vendored/EOL libssl or libcrypto file exists in the image: $stray_ssl"; exit 1; }
  echo "ok: no libssl.so.1*/libcrypto.so.1* file, and no libssl.so*/libcrypto.so* file under a vendored prefix, exists anywhere in the image"
else
  [ -n "$direct_needed" ] || { echo "FAIL: modern php binary has no libssl/libcrypto NEEDED entry -- expected dynamic system OpenSSL"; exit 1; }
  echo "ok: modern php binary links system libssl/libcrypto dynamically, as expected"
  echo "ok: file/NEEDED OpenSSL scan not restricted on the modern era (dynamic system OpenSSL is expected everywhere): ext=${ssl_load_violations:-none} files=${stray_ssl:-none}"
fi

# Every library php-src can build from a bundled copy has to come from the
# system, and the ones that don't yet have to be known. Rows come from
# php/system-libs.lock; the measurement is the same as the OpenSSL check above:
# the binary's own NEEDED list, not the flags configure was handed.
#
# The flags lie by omission: if php/configure-args.sh emits no sqlite flag,
# configure takes its default and PHP 7.0 ships a statically compiled SQLite
# 3.14.2 (August 2016), which nobody would notice from reading the arguments.
#
# Exact strength: a NEEDED entry proves the library is linked dynamically rather
# than compiled in, which decides whether `apt upgrade` can reach it. It does not
# prove the .so is *Debian's* copy -- a self-built one at the same soname would
# satisfy it. Closing that would mean comparing against dpkg's shipped sonames,
# more machinery than the risk warrants while nothing here installs libraries
# outside apt.
sonames=$(grep -i NEEDED <<<"$dyn" | grep -oE 'lib[A-Za-z0-9._+-]+\.so[.0-9]*')
# Positive control for every "bundled" row below. Those rows assert an
# *absence*, which is satisfied just as well by a matcher that finds nothing at
# all -- a changed readelf format, a bad extraction, a typo in the regex above.
# libc is linked by every binary this project produces, so if the matcher
# cannot see it, it could not have seen libzstd either and no absence below
# means anything.
grep -q '^libc\.so' <<<"$sonames" \
  || { echo "FAIL: the NEEDED matcher did not find libc -- it cannot measure anything, so the bundled-library checks below prove nothing"; exit 1; }

checked=0
while read -r lib expect owner _why; do
  case "$lib" in ''|\#*) continue ;; esac
  linked=no
  grep -q "^${lib}\.so" <<<"$sonames" && linked=yes
  case "$expect" in
    system)
      [ "$linked" = yes ] || {
        echo "FAIL: $lib is not a direct NEEDED entry -- this image compiled in php's bundled copy, which no apt upgrade can ever reach"
        exit 1
      }
      echo "ok: $lib comes from the system, not php's bundled copy"
      ;;
    bundled)
      [ "$linked" = no ] || {
        echo "FAIL: $lib is now linked from the system, but php/system-libs.lock still says bundled (owner: $owner) -- flip the row"
        exit 1
      }
      echo "ok: $lib is still php's bundled copy, as php/system-libs.lock records (owner: $owner)"
      ;;
    *) echo "FAIL: php/system-libs.lock: unknown expectation '$expect' for $lib"; exit 1 ;;
  esac
  checked=$((checked + 1))
done < "$HERE/../php/system-libs.lock"
[ "$checked" -gt 0 ] || { echo "FAIL: php/system-libs.lock yielded no rows -- nothing was checked"; exit 1; }

# Shared modules exist on disk. EXPECT doubles as the PHP_VERSION to filter
# ext.json by (every caller passes matrix.json-shaped values like "8.0"/"8.5").
# The set is derived from build-shared-ext.sh --list, the one place that knows
# which shared extensions a version gets (ext.json floors, KNOWN_UNBUILDABLE), so
# this script cannot drift from it.
SHARED_EXTS=$(bash "$HERE/../php/build-shared-ext.sh" --list "$EXPECT")
# --list refuses to print nothing for an unrecognized version, but that guard
# lives one process away from this script's own `set -e`: a failing command
# substitution is caught, one that quietly succeeds empty is not. Assert here too.
[ -n "$SHARED_EXTS" ] || { echo "FAIL: build-shared-ext.sh --list $EXPECT derived zero shared extensions -- every real version has at least one"; exit 1; }
# extdir was captured near the top of this script and is reused here.
for ext in $SHARED_EXTS; do
  drun --rm "$IMAGE" test -f "$extdir/$ext.so" || { echo "FAIL: $ext.so missing"; exit 1; }
done
echo "ok: shared modules present on disk"

# ...and nothing extra is there: the loop above never notices a .so in
# extension_dir that SHARED_EXTS doesn't know about, which is the direction an
# accidental extra build/copy would drift. Assert set equality against the
# files actually on disk.
#
# opcache.so is the one documented exception on every version except 8.5
# (php/ext.json's opcache entry): --enable-opcache always produces a loadable
# opcache.so, even though ext.json marks it "linkage": "static" and it ships
# pre-activated via conf.d. It is not a member of SHARED_EXTS but is a real file.
disk_exts=$(drun --rm "$IMAGE" sh -c "ls \"$extdir\"" | sed -n 's/\.so$//p' | sort -u)
# shellcheck disable=SC2086  # SHARED_EXTS is a space-separated list, meant to word-split
expected_disk_exts=$(printf '%s\n' $SHARED_EXTS | sort -u)
if [ "$EXPECT" != "8.5" ]; then
  expected_disk_exts=$(printf '%s\nopcache\n' "$expected_disk_exts" | sort -u)
fi
extra=$(comm -13 <(echo "$expected_disk_exts") <(echo "$disk_exts"))
[ -z "$extra" ] || { echo "FAIL: extension_dir has unexplained .so files not in the derived shared set (or opcache exception): $extra"; exit 1; }
echo "ok: extension_dir has no unexplained .so files"

# ...but are not loaded by default (ffi is in the list above; it is called out
# by name because it matters most: ffi escapes every PHP-level sandbox, so it
# ships disabled on purpose).
#
# Matched against the $mods capture, never `docker run ... | grep -qix`: a
# SIGPIPE-killed pipeline exits non-zero, the `if` is false, and the check would
# print ok having proved nothing -- and SIGPIPE needs grep to match early, which
# is most likely exactly when the extension is loaded.
#
# $mods is a fresh `php -m` with nothing enabled, the default state asserted
# here. The image is immutable and every php-ext-enable call below runs in its
# own throwaway container, so one capture serves both uses.
for ext in $SHARED_EXTS; do
  if grep -qix "$ext" <<<"$mods"; then
    echo "FAIL: $ext loaded by default, must be opt-in"; exit 1
  fi
done
echo "ok: shared modules not loaded by default (including ffi)"

# Positive control for the loop above, an absence assertion that cannot tell
# "nothing is loaded" from "I cannot see what is loaded". Enable one shared
# module in a throwaway container and require the same grep, against the same
# kind of capture, to find it.
# shellcheck disable=SC2086  # SHARED_EXTS is a space-separated list, meant to word-split
control_ext=$(printf '%s\n' $SHARED_EXTS | head -1)
control_mods=$(drun --rm "$IMAGE" sh -c "php-ext-enable $control_ext >/dev/null && php -m")
grep -qix "$control_ext" <<<"$control_mods" \
  || { echo "FAIL: enabled $control_ext but php -m does not report it -- the 'not loaded by default' check above cannot detect a loaded module, so its result means nothing"; exit 1; }
echo "ok: control -- an enabled module ($control_ext) is visible to the same check"

# ...and no conf.d ini enables anything shared, not just what -m happens to
# report: grep the baseline ini files (10-php.ini, 15-opcache.ini, ...) for an
# extension= or zend_extension= line naming a shared module.
for ext in $SHARED_EXTS; do
  if drun --rm "$IMAGE" sh -c "grep -hE '^[[:space:]]*(zend_)?extension[[:space:]]*=' /usr/local/etc/php/conf.d/*.ini 2>/dev/null | grep -qiE \"(^|[/=])${ext}(\\.so)?\\\$\""; then
    echo "FAIL: conf.d enables $ext by default, shared extensions must ship dormant"; exit 1
  fi
done
echo "ok: conf.d does not enable shared modules by default"

# ...and opt-in works, including the zend_extension= case. One container:
# php-ext-enable's ini write has to be visible to the php -m that follows it,
# which a second `docker run` on the same read-only image would not see.
#
# The zend subject is derived, not named: a fixed "xdebug" fails on 7.0-7.4,
# where ext.json excludes it (its pecl.lock-pinned package, 3.5.3, has a PHP 8.0
# floor). php-ext-enable decides which names take the zend_extension= path, so
# ask it (--list-zend, the same variable its is_zend() reads) and intersect with
# this version's derived shared set. The other subjects come from SHARED_EXTS.
zend_known=$(drun --rm "$IMAGE" php-ext-enable --list-zend)
[ -n "$zend_known" ] || { echo "FAIL: php-ext-enable --list-zend printed nothing -- cannot pick a zend_extension subject"; exit 1; }
# shellcheck disable=SC2086  # zend_known and SHARED_EXTS are space-separated lists, meant to word-split
zend_subjects=$(comm -12 <(printf '%s\n' $zend_known | sort -u) <(printf '%s\n' $SHARED_EXTS | sort -u))

# shellcheck disable=SC2086  # zend_subjects and SHARED_EXTS are space-separated lists, meant to word-split
enable_exts="$(printf '%s\n' $zend_subjects $SHARED_EXTS | awk '!seen[$0]++' | head -3 | tr '\n' ' ')"
mods=$(drun --rm "$IMAGE" sh -c "php-ext-enable $enable_exts >&2 && php -m")
for ext in $enable_exts; do
  grep -qix "$ext" <<<"$mods" || { echo "FAIL: php-ext-enable did not load $ext"; exit 1; }
done

if [ -n "$zend_subjects" ]; then
  # Prove the zend_extension= branch is what ran, rather than trusting that
  # the name happened to be in the list: read back the ini php-ext-enable
  # wrote for the subject it just enabled.
  # shellcheck disable=SC2086  # zend_subjects is a space-separated list, meant to word-split
  zsub=$(printf '%s\n' $zend_subjects | head -1)
  line=$(drun --rm "$IMAGE" sh -c "php-ext-enable $zsub >/dev/null && cat /usr/local/etc/php/conf.d/20-${zsub}.ini")
  [ "$line" = "zend_extension=${zsub}.so" ] || { echo "FAIL: php-ext-enable wrote '$line' for $zsub, expected zend_extension=${zsub}.so"; exit 1; }
  echo "ok: php-ext-enable works, including zend_extension ($zsub) [$enable_exts]"
else
  # An empty intersection must be *explained*, not silently skipped. The
  # explanation that carries weight is on-disk, not in the derived set: if a
  # zend-capable module sits in extension_dir but the derivation left it out,
  # the derivation is wrong and the subject was skipped rather than absent (an
  # ext.json floor can drop xdebug from 7.0-7.4 while every set-based check
  # still agrees with itself).
  for zx in $zend_known; do
    # opcache is compiled in and ships pre-activated (Dockerfile), so its .so
    # legitimately exists while never being a php-ext-enable subject.
    [ "$zx" = opcache ] && continue
    if drun --rm "$IMAGE" test -f "$extdir/$zx.so"; then
      echo "FAIL: $zx.so exists in extension_dir but is not in this version's derived shared set -- the derivation is wrong, so the zend_extension= path was skipped rather than genuinely absent"; exit 1
    fi
  done
  # shellcheck disable=SC2086,SC2116  # zend_known is a space-separated list meant to word-split; the echo just flattens it into one line for the message
  echo "ok: php-ext-enable works [$enable_exts]; no zend_extension subject exists on PHP $EXPECT (php-ext-enable knows: $(echo $zend_known), none of them in this version's shared set)"
fi

# ...php-ext-enable refuses unknown names loudly. The name is well-formed
# (letters/digits/underscore, like every real name in ext.json) but not a real
# extension; a hyphenated name is caught earlier by the charset guard, a
# different assertion (see test-entrypoint.sh).
if drun --rm "$IMAGE" php-ext-enable not_a_real_extension 2>/tmp/php-ext-enable.err; then
  echo "FAIL: php-ext-enable accepted an unknown extension name"; exit 1
fi
grep -qi "no such extension" /tmp/php-ext-enable.err || { echo "FAIL: unknown extension did not fail loudly"; exit 1; }
echo "ok: php-ext-enable refuses unknown names"

# COPY from a scratch stage stamps its own directory metadata onto directories
# that already exist in the image, so runtime-base re-asserts the one that
# matters after its payload COPYs: conf.d is where php-ext-enable and the
# entrypoint write as the image user. ext-builder runs as root but inherits the
# same runtime-base, so conf.d is www-data:www-data on every flavor.
conf_d_owner=$(drun --rm --entrypoint stat "$IMAGE" -c '%U:%G' /usr/local/etc/php/conf.d)
[ "$conf_d_owner" = "www-data:www-data" ] \
  || { echo "FAIL: /usr/local/etc/php/conf.d is owned by $conf_d_owner, expected www-data:www-data (a payload COPY reset it)"; exit 1; }
echo "ok: /usr/local/etc/php/conf.d is owned by www-data"

# Root has to start php without a word on stderr too (the entrypoint's own
# notices aside): anything a library creates or logs on first use as root would
# show up in every `docker run -u 0` and in every CI job that runs as root.
root_err=$(drun --rm -u 0 "$IMAGE" php -r 'echo 1;' 2>&1 >/dev/null | grep -v '^docker-php-entrypoint:' || true)
[ -z "$root_err" ] || { echo "FAIL: php -r as root wrote to stderr: $root_err"; exit 1; }
echo "ok: php starts silent as root"

# net-snmp (deps/build-netsnmp.sh): Debian's libsnmp40t64 hard-depends on
# libperl5.40, and a package another package Depends on cannot be purged, so
# the only way to ship no libperl/perl-modules (~49 MB) is to link ext-snmp
# against a vendored client-only build. These assertions are what keeps that
# true: a regression to libsnmp-dev brings libperl back silently, with every
# functional check still green.
#
# dpkg-query takes package names and globs, which `dpkg -s` does not. It exits
# non-zero when nothing matches, which for an absence assertion is the answer
# rather than an error, so the exit status is deliberately ignored and the
# Status column is what is read. The control proves the query can see an
# installed package at all -- an empty result is otherwise indistinguishable
# from a dpkg-query that cannot run.
dpkg_installed() {  # dpkg_installed <name-or-glob>... -> the installed packages matching, one per line
  drun --rm "$IMAGE" dpkg-query -W -f='${Package} ${Status}\n' "$@" 2>/dev/null \
    | sed -n 's/ install ok installed$//p' || true
}
[ "$(dpkg_installed libc6)" = "libc6" ] \
  || { echo "FAIL: dpkg-query could not see libc6 as installed -- the libperl/libsnmp absence check below would prove nothing"; exit 1; }
# The builders bring perl in on purpose: cli-builder's git and full
# mariadb-client Depend on it (git's perl scripts, mariadb-hotcopy), and
# ext-builder's autoconf/automake are perl programs, so libperl5.40 and
# perl-modules are there whatever ext-snmp links. Both are still held to the
# snmp half: no Debian libsnmp*/libnetsnmp* package, which is what would put a
# second net-snmp in the image.
stray_globs=('libsnmp*' 'libnetsnmp*')
perl_note="libperl*, perl-modules*, "
case "$FLAVOR" in
  cli-builder|ext-builder) perl_note="" ;;
  *) stray_globs+=('libperl*' 'perl-modules*') ;;
esac
stray_pkgs=$(dpkg_installed "${stray_globs[@]}" | tr '\n' ' ')
[ -z "$stray_pkgs" ] || { echo "FAIL: the runtime image carries Debian perl/snmp library packages ($stray_pkgs) -- ext-snmp is meant to link the vendored /opt/net-snmp, and libsnmp40t64 pulls in libperl5.40"; exit 1; }
echo "ok: no ${perl_note}libsnmp* or libnetsnmp* Debian package in the image (control: libc6 is visible to the same query)"

if grep -qw snmp <<<"$SHARED_EXTS"; then
  snmp_ldd=$(drun --rm "$IMAGE" ldd "$extdir/snmp.so" 2>&1 || true)
  grep -qE '^[[:space:]]*libnetsnmp\.so\.[0-9]+ => /opt/net-snmp/lib/libnetsnmp\.so\.[0-9]+' <<<"$snmp_ldd" \
    || { echo "FAIL: snmp.so does not resolve libnetsnmp from /opt/net-snmp/lib: $snmp_ldd"; exit 1; }
  ! grep -q 'not found' <<<"$snmp_ldd" || { echo "FAIL: snmp.so has an unresolved NEEDED entry: $snmp_ldd"; exit 1; }
  nsnmp_ldd=$(drun --rm "$IMAGE" sh -c 'ldd /opt/net-snmp/lib/libnetsnmp.so.*[0-9]' 2>&1 || true)
  # USM auth/priv crypto goes through Debian's supported libssl3, from the system
  # path -- not a vendored copy, never an EOL one.
  grep -qE 'libcrypto\.so\.3 => /(usr/)?lib/' <<<"$nsnmp_ldd" \
    || { echo "FAIL: libnetsnmp does not link the system libcrypto.so.3: $nsnmp_ldd"; exit 1; }
  ! grep -qE 'libperl|libwrap|libsensors|libpci|not found' <<<"$nsnmp_ldd" \
    || { echo "FAIL: libnetsnmp links something it is built without, or has an unresolved entry: $nsnmp_ldd"; exit 1; }
  echo "ok: snmp.so resolves libnetsnmp from /opt/net-snmp/lib, which links only the system libssl3 (no perl/wrap/sensors/pci)"

  # Only the library and the MIB files ship; the prefix's bin/include/pkgconfig
  # were build-time inputs for ext-snmp. Control: the same find sees the library.
  nsnmp_files=$(drun --rm "$IMAGE" find /opt/net-snmp \( -type f -o -type l \))
  grep -q '/lib/libnetsnmp\.so\.' <<<"$nsnmp_files" \
    || { echo "FAIL: find /opt/net-snmp did not list the library -- the dev-file absence check below would prove nothing"; exit 1; }
  nsnmp_dev=$(grep -E '\.(a|la|pc|h)$|/(bin|include)/' <<<"$nsnmp_files" || true)
  [ -z "$nsnmp_dev" ] || { echo "FAIL: build-time files shipped under /opt/net-snmp: $nsnmp_dev"; exit 1; }
  echo "ok: /opt/net-snmp ships the library and MIB files only"

  # Works with no network. Output is compared exactly, stderr included: a wrong
  # compiled-in MIB directory or an unresolvable libnetsnmp prints noise on load
  # (the fpm entrypoint's own memory-limit notice is the one line filtered out).
  #   - snmp_read_mib on a shipped MIB succeeds; on a missing file it fails (control).
  #   - SNMPv3 authPriv key generation (SHA + AES) is local, so success means the
  #     OpenSSL-backed USM crypto is really there.
  #   - A MIB-qualified name resolves from the compiled-in MIB directory with no
  #     MIBS set: the request then fails on the network, not on the name. The
  #     control name, from a module that does not exist, must fail on the name --
  #     otherwise the resolution check cannot tell the two failures apart.
  snmp_out=$(drun --rm -i "$IMAGE" sh -c 'php-ext-enable snmp >/dev/null && php' 2>&1 <<'PHP' | grep -v '^docker-php-entrypoint:' || true
<?php
$fail = function ($m) { echo "FAIL: $m\n"; exit(1); };
(extension_loaded("snmp") && class_exists("SNMP")) || $fail("snmp extension or SNMP class missing");
is_int(snmp_get_valueretrieval()) || $fail("snmp_get_valueretrieval() did not return an int");
snmp_read_mib("/opt/net-snmp/share/snmp/mibs/SNMPv2-MIB.txt") === true || $fail("snmp_read_mib failed on a shipped MIB");
@snmp_read_mib("/nonexistent/NO-SUCH-MIB.txt") === false || $fail("snmp_read_mib accepted a missing file");
$s = new SNMP(SNMP::VERSION_3, "127.0.0.1", "smokeuser");
$s->setSecurity("authPriv", "SHA", "12345678", "AES", "12345678") === true || $fail("USM authPriv SHA/AES setup failed");
$last = "";
set_error_handler(function ($no, $str) use (&$last) { $last = $str; return true; });
snmpget("127.0.0.1:1", "public", "SNMPv2-MIB::sysDescr.0", 100000, 0);
stripos($last, "Invalid object identifier") === false || $fail("SNMPv2-MIB::sysDescr.0 did not resolve from the default MIB directory: $last");
$last = "";
snmpget("127.0.0.1:1", "public", "NO-SUCH-MIB::nothing.0", 100000, 0);
stripos($last, "Invalid object identifier") !== false || $fail("control: an unknown MIB name did not fail on the name ($last), so the resolution check above proves nothing");
echo "snmp-ok";
PHP
)
  [ "$snmp_out" = "snmp-ok" ] || { echo "FAIL: ext-snmp functional check printed: $snmp_out"; exit 1; }
  echo "ok: ext-snmp loads clean and works offline (snmp_read_mib, USM SHA/AES keys, MIB name resolution, negative controls)"

  # net-snmp creates /var/lib/snmp and /var/lib/snmp/cert_indexes the first time
  # the extension loads and logs "Created directory: ..." to stderr when it does;
  # runtime-base pre-creates both, owned by www-data, so neither root nor www-data
  # prints anything. The control removes them and requires the notice to come
  # back, otherwise a clean stderr below would only prove the notice is gone from
  # this net-snmp build, not that the directories are what silenced it. -d
  # extension=snmp.so rather than php-ext-enable: the entrypoint is bypassed so
  # stderr holds php's and net-snmp's output only.
  for snmp_uid in 0 33; do
    snmp_err=$(drun --rm -u "$snmp_uid" --entrypoint php "$IMAGE" -d extension=snmp.so -r 'echo extension_loaded("snmp") ? "" : "snmp not loaded";' 2>&1 >/dev/null || true)
    [ -z "$snmp_err" ] || { echo "FAIL: loading snmp.so as uid $snmp_uid wrote to stderr: $snmp_err"; exit 1; }
  done
  snmp_ctl=$(drun --rm -u 0 --entrypoint sh "$IMAGE" -c 'rm -rf /var/lib/snmp; exec php -d extension=snmp.so -r "echo 1;"' 2>&1 >/dev/null || true)
  grep -q 'Created directory: /var/lib/snmp' <<<"$snmp_ctl" \
    || { echo "FAIL: control: with /var/lib/snmp removed, loading snmp.so as root did not log its directory creation ($snmp_ctl), so the clean-stderr check above proves nothing"; exit 1; }
  echo "ok: loading snmp.so is silent as root and as uid 33 (control: without /var/lib/snmp net-snmp logs 'Created directory')"

  # MIBs mounted where a Debian host keeps them are found without MIBDIRS: the
  # compiled-in search path is Debian's plus /opt/net-snmp's. A renamed copy of
  # IF-MIB in /usr/share/snmp/mibs/ietf (a directory net-snmp does not search
  # recursively, so it has to be named in the path) resolves a qualified name;
  # the same name before the copy exists must fail on the name (control).
  # shellcheck disable=SC2016  # the script is for the container's shell
  snmp_mibdir=$(drun --rm -u 0 -i --entrypoint sh "$IMAGE" -c '
    set -eu
    cat > /tmp/probe.php <<"PHP"
<?php
$last = "";
set_error_handler(function ($no, $str) use (&$last) { $last = $str; return true; });
snmpget("127.0.0.1:1", "public", "ZZ-SMOKE-MIB::ifNumber.0", 100000, 0);
echo stripos($last, "Invalid object identifier") === false ? "resolved" : "unresolved";
PHP
    before=$(php -d extension=snmp.so /tmp/probe.php)
    mkdir -p /usr/share/snmp/mibs/ietf
    sed s/IF-MIB/ZZ-SMOKE-MIB/g /opt/net-snmp/share/snmp/mibs/IF-MIB.txt > /usr/share/snmp/mibs/ietf/ZZ-SMOKE-MIB.txt
    after=$(php -d extension=snmp.so /tmp/probe.php)
    echo "$before $after"' 2>&1 || true)
  [ "$snmp_mibdir" = "unresolved resolved" ] \
    || { echo "FAIL: MIB lookup in the Debian directories: expected 'unresolved resolved' (before/after a MIB appears in /usr/share/snmp/mibs/ietf), got: $snmp_mibdir"; exit 1; }
  echo "ok: a MIB placed in /usr/share/snmp/mibs/ietf is found without MIBDIRS (control: unknown before it exists)"
fi

# Baseline php.ini: expose_php/display_errors/allow_url_include off.
for pair in "expose_php:" "display_errors:" "allow_url_include:"; do
  key="${pair%%:*}"
  val=$(drun --rm "$IMAGE" php -r "echo ini_get('$key') ?: '0';")
  [[ "$val" == "0" || "$val" == "" ]] || { echo "FAIL: $key is '$val', expected off"; exit 1; }
done
echo "ok: php.ini hardened"

# proc_open must stay enabled: composer and symfony/process need it. Builder
# (conf/php-builder.ini) drops disable_functions entirely -- build tooling
# legitimately needs shell_exec/exec too -- so shell_exec is only required to
# be disabled on the fpm/cli flavors.
dis=$(drun --rm "$IMAGE" php -r "echo ini_get('disable_functions');")
echo "$dis" | grep -q 'proc_open' && { echo "FAIL: proc_open disabled"; exit 1; }
case "$FLAVOR" in
  cli-builder) : ;;
  *) echo "$dis" | grep -q 'shell_exec' || { echo "FAIL: shell_exec not disabled"; exit 1; } ;;
esac
echo "ok: disable_functions correct"

# opcache baseline (15-opcache.ini, laid down once in runtime-base for every flavor)
oc=$(drun --rm "$IMAGE" php -r '
foreach (["opcache.enable","opcache.enable_file_override","opcache.save_comments","opcache.validate_timestamps"] as $k) {
  echo $k . "=" . ini_get($k) . PHP_EOL;
}')
grep -qx 'opcache.enable=1' <<<"$oc" || { echo "FAIL: opcache.enable wrong: $oc"; exit 1; }
grep -qx 'opcache.enable_file_override=0' <<<"$oc" || { echo "FAIL: opcache.enable_file_override wrong: $oc"; exit 1; }
grep -qx 'opcache.save_comments=1' <<<"$oc" || { echo "FAIL: opcache.save_comments wrong: $oc"; exit 1; }
echo "ok: opcache settings applied"

# "opcache is actually enabled" and "JIT on PHP >= 8.0" are proven on the
# binary's real behavior, not read back as ini strings: ini_get() above only
# proves the values landed, not that the module ever activates. `docker run
# $IMAGE php -r` always runs the CLI SAPI, and conf/opcache.ini sets
# opcache.enable_cli=0 on purpose (a short-lived CLI process gains nothing from
# a persistent opcache, and JIT trades startup time for it), so opcache is
# inactive here by default -- assert that first, or the "activates when asked"
# proof below has nothing to distinguish itself from.
off=$(drun --rm "$IMAGE" php -r '$s = opcache_get_status(false); echo $s === false ? "off" : "on";')
[ "$off" = "off" ] || { echo "FAIL: opcache is active under plain CLI by default, expected inactive (opcache.enable_cli=0 in conf/opcache.ini): $off"; exit 1; }
echo "ok: opcache inactive under plain CLI by default (opcache.enable_cli=0), as conf/opcache.ini sets it"

on=$(drun --rm "$IMAGE" php -d opcache.enable_cli=1 -r '
$s = opcache_get_status(false);
if ($s === false) { echo "off"; exit; }
// jit.enabled only means "this opcache build has JIT compiled in"; it stays
// true even with opcache.jit=off. jit.on reflects whether the JIT is compiling
// right now.
echo "on:jit=" . (!empty($s["jit"]["on"]) ? "1" : "0");
')
[[ "$on" == on:* ]] || { echo "FAIL: opcache did not activate even with opcache.enable_cli=1 forced -- the module or its config is broken: $on"; exit 1; }
echo "ok: opcache activates when explicitly enabled ($on)"

php_major="${RELEASE%%.*}"
# 8.0's ext/opcache/config.m4 builds the JIT for i386/x86 hosts only (aarch64
# DynASM arrived in 8.1) and turns it off elsewhere with a configure warning,
# so an arm64 8.0 has no JIT to run -- asserted as off, not skipped.
if [ "$IMAGE_ARCH" = arm64 ] && [ "$EXPECT" = "8.0" ]; then
  [ "$on" = "on:jit=0" ] || { echo "FAIL: PHP 8.0 on arm64 reports a running JIT, but 8.0's opcache builds none for aarch64: $on"; exit 1; }
  echo "ok: JIT not available on PHP 8.0/arm64 (8.0's JIT is x86-only; aarch64 support arrived in 8.1)"
elif [ "$php_major" -ge 8 ]; then
  [ "$on" = "on:jit=1" ] || { echo "FAIL: opcache activated but JIT is not actually running -- PHP $EXPECT should support it: $on"; exit 1; }
  echo "ok: JIT active on PHP $EXPECT when opcache is enabled"
else
  echo "ok: JIT not applicable on PHP $EXPECT (introduced in PHP 8.0)"
fi

# The VM kind, expected from VM_COMPILER/PHP version/IMAGE_ARCH (see the table
# above), checked two ways:
#
#   - the build record's vm_kind_config (php/build.sh: ZEND_VM_KIND as the
#     generated Zend/zend_vm_opcodes.h resolves it against this build's own
#     php_config.h), on every version. A build that got the wrong VM records the
#     wrong value there just as reliably as it would answer wrong at runtime.
#   - on versions with FFI, zend_vm_kind() called in a throwaway process. It is
#     ZEND_API and exported, and this is the end-to-end half of
#     assert_preserve_none_canary and of the record itself. ext.json floors ffi
#     at >=7.4, so 7.0-7.3 can only be checked through the record.
has_ffi=false
for _sx in $SHARED_EXTS; do [ "$_sx" = ffi ] && has_ffi=true; done

build_record=$(drun --rm --entrypoint cat "$IMAGE" /usr/local/share/php-build/pgo.txt 2>/dev/null) \
  || { echo "FAIL: $IMAGE has no /usr/local/share/php-build/pgo.txt -- cannot check vm_kind_config"; exit 1; }
vm_kind_config=$(sed -n 's/^vm_kind_config=//p' <<<"$build_record" | head -1)
[ -n "$vm_kind_config" ] \
  || { echo "FAIL: the build record has no vm_kind_config line -- this image predates VM-kind recording, rebuild it"; exit 1; }
want=$(tr '[:upper:]' '[:lower:]' <<<"$EXPECTED_VM_NAME")
[ "$vm_kind_config" = "$want" ] \
  || { echo "FAIL: the build record says vm_kind_config=$vm_kind_config for PHP $EXPECT ($VM_COMPILER, $IMAGE_ARCH), expected $want (ZEND_VM_KIND_$EXPECTED_VM_NAME)"; exit 1; }
echo "ok: build record shows vm_kind_config=$vm_kind_config for PHP $EXPECT ($VM_COMPILER, $IMAGE_ARCH)"

if [ "$has_ffi" = true ]; then
  vm_kind=$(drun --rm "$IMAGE" php -d extension=ffi -d ffi.enable=1 \
    -r 'echo FFI::cdef("int zend_vm_kind(void);")->zend_vm_kind();')
  [ "$vm_kind" = "$EXPECTED_VM_KIND" ] \
    || { echo "FAIL: PHP $EXPECT ($VM_COMPILER) runs VM kind '$vm_kind', expected $EXPECTED_VM_KIND (ZEND_VM_KIND_$EXPECTED_VM_NAME)"; exit 1; }
  echo "ok: interpreter is ZEND_VM_KIND_$EXPECTED_VM_NAME (zend_vm_kind()=$vm_kind)"
else
  echo "note: no FFI on PHP $EXPECT, so the VM kind rests on the build record alone"
fi

# Per-flavor ini differences, driven by the $FLAVOR argument, not the image tag.
mem=$(drun --rm "$IMAGE" php -r "echo ini_get('memory_limit');")
case "$FLAVOR" in
  cli-builder)
    [[ "$mem" == "-1" ]] || { echo "FAIL: builder memory_limit is '$mem', expected -1"; exit 1; }
    dis_b=$(drun --rm "$IMAGE" php -r "echo ini_get('disable_functions');")
    [[ -z "$dis_b" ]] || { echo "FAIL: builder disable_functions is '$dis_b', expected empty"; exit 1; }
    echo "ok: builder ini (unbounded memory, no disable_functions)"
    ;;
  cli|ext-builder)
    [[ "$mem" == "512M" ]] || { echo "FAIL: $FLAVOR memory_limit is '$mem', expected 512M"; exit 1; }
    met=$(drun --rm "$IMAGE" php -r "echo ini_get('max_execution_time');")
    [[ "$met" == "0" ]] || { echo "FAIL: $FLAVOR max_execution_time is '$met', expected 0"; exit 1; }
    echo "ok: $FLAVOR ini (512M memory, unbounded execution time)"
    ;;
  fpm)
    [[ "$mem" == "256M" ]] || { echo "FAIL: fpm memory_limit is '$mem', expected 256M"; exit 1; }
    errlog=$(drun --rm "$IMAGE" php -r "echo ini_get('error_log');")
    [[ "$errlog" == "/dev/stderr" ]] || { echo "FAIL: fpm error_log is '$errlog', expected /dev/stderr"; exit 1; }
    echo "ok: fpm ini (256M memory, error_log to /dev/stderr)"

    # FPM's *global* error_log (php-fpm.conf, not php.ini) is what
    # catch_workers_output's relayed lines go through; ini_get() never sees it.
    # The Dockerfile patches it from the stock file-based default so those lines
    # reach `docker logs`; assert the patch landed, independently of the
    # build-time grep. if/else so a regression prints a FAIL message rather than
    # a bare non-zero exit.
    if drun --rm "$IMAGE" grep -qx 'error_log = /proc/self/fd/2' /usr/local/etc/php-fpm.conf; then
      echo "ok: fpm global error_log patched (php-fpm.conf, not just php.ini)"
    else
      echo "FAIL: php-fpm.conf global error_log is not patched to /proc/self/fd/2"; exit 1
    fi
    ;;
esac

# Hardening, asserted on the binaries that ship rather than on the flag strings
# that were meant to produce them. scripts/test_flags.py already checks that
# php/cflags.sh and php/ldflags.sh *emit* the right flags; that is our intent,
# and a flag can still be dropped by configure, overridden later on the same
# command line, or ignored by the target. This measures the result.
#
# Everything in the image that this build produced is covered, not just `php`:
# the FPM binary, the chmod shim, and every shared extension .so -- 18 of them
# on 8.5 -- because a shared module is loaded into the same address space and
# an executable stack or a writable GOT in any one of them is the whole
# process's problem.
hard_dir=$(mktemp -d)
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true; rm -f "$tmp_php"; rm -rf "$hard_dir"' EXIT
hcid=$(docker create --pull never "$IMAGE")
docker cp "$hcid:/usr/local/bin/php" "$hard_dir/php" >/dev/null
docker cp "$hcid:/usr/local/lib/php-chmod-sanitize.so" "$hard_dir/php-chmod-sanitize.so" >/dev/null
mkdir -p "$hard_dir/ext"
docker cp "$hcid:$extdir/." "$hard_dir/ext" >/dev/null
# ImageMagick's libraries ship in every flavor (Dockerfile stages them via
# /deps-stage) and are dlopened into the same process as everything else, so
# they are covered here too.
mkdir -p "$hard_dir/im"
docker cp "$hcid:/opt/imagemagick/lib/." "$hard_dir/im" >/dev/null 2>&1 || true
# Same for the vendored net-snmp client library.
mkdir -p "$hard_dir/nsnmp"
docker cp "$hcid:/opt/net-snmp/lib/." "$hard_dir/nsnmp" >/dev/null 2>&1 || true
# Everything under /opt, for the RPATH scan below: the vendored libraries'
# plugins (ImageMagick's coder modules) and the legacy era's vendored tree are
# ELF files nothing above names. docker cp keeps symlinks as symlinks, so each
# file is seen once, under its real name.
mkdir -p "$hard_dir/opt"
docker cp "$hcid:/opt/." "$hard_dir/opt" >/dev/null
case "$FLAVOR" in
  fpm) docker cp "$hcid:/usr/local/sbin/php-fpm" "$hard_dir/php-fpm" >/dev/null ;;
esac
# The image's own C++ runtime, for the symbol-version check below: the GCC 16
# built objects are linked against GCC 16's libstdc++ headers but run against
# Debian's libstdc++6/libgcc-s1, resolved the way ldd resolved them for php.
for rt_lib in libstdc++.so.6 libgcc_s.so.1; do
  rt_path=$(awk -v l="$rt_lib" '$1 == l { print $3; exit }' <<<"$linkage")
  [ -n "$rt_path" ] || { echo "FAIL: ldd of /usr/local/bin/php lists no $rt_lib -- cannot check the GLIBCXX/GCC symbol versions against the image's own copy"; exit 1; }
  docker cp -L "$hcid:$rt_path" "$hard_dir/$rt_lib" >/dev/null
done
docker rm -f "$hcid" >/dev/null

# The extraction is itself a measurement, so check it landed before trusting
# what it produced: an empty or short copy would otherwise make the assertions
# below pass on a handful of files, or none.
n_so=$(find "$hard_dir/ext" -name '*.so' | wc -l)
n_disk=$(printf '%s\n' "$disk_exts" | grep -c . || true)
[ "$n_so" -eq "$n_disk" ] || { echo "FAIL: extracted $n_so .so files but extension_dir holds $n_disk -- the hardening check would have measured the wrong set"; exit 1; }
[ -s "$hard_dir/php" ] || { echo "FAIL: extracted php binary is empty -- nothing to verify hardening on"; exit 1; }

# Fail-closed control, run first: a file that is not an ELF at all must be
# rejected, or the assertions below are only known to pass, never known to be
# capable of failing. (scripts/test_elf_hardening.py carries the stronger
# controls: it builds deliberately partial-RELRO and executable-stack objects
# and requires the same script to reject each.)
printf 'not an elf\n' > "$hard_dir/notanelf"
if bash "$HERE/assert-elf-hardening.sh" "control" "$hard_dir/notanelf" >/dev/null 2>&1; then
  echo "FAIL: the hardening checker accepted a non-ELF file -- it fails open, so its results below mean nothing"; exit 1
fi
rm -f "$hard_dir/notanelf"
echo "ok: hardening checker rejects a non-ELF file (it fails closed)"

bash "$HERE/assert-elf-hardening.sh" --main "php-$EXPECT" "$hard_dir/php" || exit 1

# Prove VM_COMPILER is not just a label someone typed: read the binary's own
# .comment section, which records the compiler that actually produced the object
# code. It survives `strip --strip-unneeded` and carries one entry per distinct
# compiler in the link, so a gcc build shows both the pinned "GCC: (GNU) 16.2.0"
# (php-src) and Debian's own gcc (crt startup objects, always present). Checked
# as presence of the expected compiler's line, not equality. The runtime image
# has no strings/readelf, so this reads the binary extracted to the host above.
case "$VM_COMPILER" in
  gcc)   comment_pattern='GCC: \(GNU\) 16\.2' ;;
  clang) comment_pattern='Debian clang version 19\.' ;;
esac
assert_compiler_comment() {  # assert_compiler_comment <label> <file>
  local out
  out=$(readelf -p .comment "$2" 2>/dev/null || true)
  grep -qE "$comment_pattern" <<<"$out" \
    || { echo "FAIL: $1's .comment does not show $VM_COMPILER's expected identity (looked for /$comment_pattern/): $out"; exit 1; }
  echo "ok: $1's .comment confirms $VM_COMPILER ($(grep -oE "$comment_pattern" <<<"$out" | head -1))"
}
assert_compiler_comment "php-$EXPECT" "$hard_dir/php"
[ -f "$hard_dir/php-fpm" ] && assert_compiler_comment "php-fpm-$EXPECT" "$hard_dir/php-fpm"

# shellcheck disable=SC2046  # the .so list is meant to word-split
im_libs=$(find "$hard_dir/im" -maxdepth 1 -type f -name '*.so.*' 2>/dev/null | tr '\n' ' ')
[ -n "$im_libs" ] || { echo "FAIL: no ImageMagick libraries extracted -- they ship in every flavor, so an empty set means the copy failed"; exit 1; }
# shellcheck disable=SC2046  # the .so list is meant to word-split
nsnmp_libs=$(find "$hard_dir/nsnmp" -maxdepth 1 -type f -name '*.so.*' 2>/dev/null | tr '\n' ' ')
[ -n "$nsnmp_libs" ] || { echo "FAIL: no net-snmp library extracted -- it ships in every flavor, so an empty set means the copy failed"; exit 1; }
module_files=("$hard_dir/php-chmod-sanitize.so")
[ -f "$hard_dir/php-fpm" ] && module_files+=("$hard_dir/php-fpm")
# shellcheck disable=SC2206  # both are deliberate globs/word-splits
module_files+=("$hard_dir"/ext/*.so $im_libs $nsnmp_libs)
bash "$HERE/assert-elf-hardening.sh" "modules-$EXPECT" "${module_files[@]}" || exit 1

# RPATH/RUNPATH hygiene: every directory a shipped ELF names must exist in the
# image. A leaked build-stage rpath (e.g. libtool hardcoding the GCC 16
# toolchain's lib dir, /opt/gcc16/lib64, via the stale libstdc++.la) names a
# directory only the build stage has; whoever creates it gets their libstdc++
# ahead of Debian's. One container checks the whole set; the scratch files live
# inside $hard_dir so the EXIT trap removes them however this script ends.
rpath_hits="$hard_dir/rpath_hits"
: > "$rpath_hits"
scan_rpath() {  # scan_rpath <label> <file>: append "<label> <dir>" per RPATH/RUNPATH entry
  local dyn_out
  dyn_out=$(readelf -dW "$2") || { echo "FAIL: readelf could not read the dynamic section of $1"; exit 1; }
  sed -n -E 's/.*\((RPATH|RUNPATH)\)[^[]*\[(.*)\].*/\2/p' <<<"$dyn_out" | tr ':' '\n' | grep -v '^$' \
    | sed "s|^|$1 |" >> "$rpath_hits" || true
}
for f in "${module_files[@]}" "$hard_dir/php"; do
  scan_rpath "$(basename "$f")" "$f"
done
# Every ELF under /opt, picked by magic number rather than by name: the vendored
# trees hold versioned libraries (*.so.1.2), plugin modules and, on the legacy
# era, whatever the dependency builds installed. Labeled by path so a hit in
# a plugin does not read as one of php's own extensions. The legacy tree may be
# empty of ELF files (static-only openssl/icu, .a files deleted) -- that is fine,
# but the ImageMagick libraries are in every image, so zero ELF files means the
# extraction or the magic test is broken.
opt_elf=0
while IFS= read -r -d '' f; do
  [ "$(head -c4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ] || continue
  opt_elf=$((opt_elf + 1))
  scan_rpath "opt/${f#"$hard_dir"/opt/}" "$f"
done < <(find "$hard_dir/opt" -type f -print0)
[ "$opt_elf" -ge 1 ] || { echo "FAIL: no ELF file found under the extracted /opt -- the RPATH scan of vendored libraries saw nothing"; exit 1; }
# Positive controls: php carries /opt/imagemagick/lib on purpose (ldflags.sh), so
# a parser that found nothing would pass the check below by being blind.
grep -qx 'php /opt/imagemagick/lib' "$rpath_hits" \
  || { echo "FAIL: the RPATH scan did not see php's /opt/imagemagick/lib entry -- it would not see a bad one either: $(cat "$rpath_hits")"; exit 1; }
if grep -qw snmp <<<"$SHARED_EXTS"; then
  # snmp.so is the one shared extension that names /opt/net-snmp/lib (from its own
  # link line), and it has to: nothing else tells the loader where libnetsnmp is.
  grep -qx 'snmp.so /opt/net-snmp/lib' "$rpath_hits" \
    || { echo "FAIL: snmp.so has no /opt/net-snmp/lib RUNPATH, so libnetsnmp cannot be found: $(grep '^snmp.so ' "$rpath_hits" || echo 'no entries at all')"; exit 1; }
  # ... and no other extension should: that prefix on ldflags.sh also switches on
  # --exclude-libs=ALL, which has no business in twenty unrelated modules.
  stray_nsnmp=$(grep -E '^[^/ ]+\.so /opt/net-snmp/lib$' "$rpath_hits" | grep -v '^snmp\.so ' || true)
  [ -z "$stray_nsnmp" ] || { echo "FAIL: shared extensions other than snmp.so carry the net-snmp RUNPATH: $stray_nsnmp"; exit 1; }
fi
# $ORIGIN-relative entries resolve per file and are not a fixed directory.
rpath_dirs=$(awk '{ print $2 }' "$rpath_hits" | grep -v '^\$ORIGIN' | sort -u)
# shellcheck disable=SC2086  # the dir list is meant to word-split into arguments
rpath_missing=$(drun --rm "$IMAGE" sh -c 'for d in "$@"; do [ -d "$d" ] || echo "$d"; done' sh $rpath_dirs)
if [ -n "$rpath_missing" ]; then
  echo "FAIL: RPATH/RUNPATH entries name directories that do not exist in the image:"
  while IFS= read -r d; do grep -F " $d" "$rpath_hits" | sed 's/^/  /'; done <<<"$rpath_missing"
  exit 1
fi
echo "ok: every RPATH/RUNPATH entry of php, php-fpm, the shared extensions and the $opt_elf ELF files under /opt names a directory present in the image ($(wc -l < "$rpath_hits") entries, $(wc -l <<<"$rpath_dirs") distinct dirs)"

# The objects are built with GCC 16 (7.0-8.4) or clang 19 but run on Debian's
# libstdc++/libgcc_s, so a GLIBCXX_/CXXABI_/GCC_ version they need that the
# image's own copies do not define is a dlopen failure at the first request
# that reaches it -- swoole.so, the one big C++ object, is the likeliest.
elf_versions() {  # elf_versions defs|needs <file> -> GLIBCXX_/CXXABI_/GCC_ version names, one per line
  readelf -VW "$2" | awk -v want="$1" '
    /^Version definition section/ { in_sec = (want == "defs"); next }
    /^Version needs section/      { in_sec = (want == "needs"); next }
    /^Version symbols section/    { in_sec = 0; next }
    in_sec { for (i = 1; i < NF; i++) if ($i == "Name:" && $(i+1) ~ /^(GLIBCXX|CXXABI|GCC)_/) print $(i+1) }'
}
provided_versions=$( { elf_versions defs "$hard_dir/libstdc++.so.6"; elf_versions defs "$hard_dir/libgcc_s.so.1"; } | sort -u)
grep -q '^GLIBCXX_3\.4$' <<<"$provided_versions" \
  || { echo "FAIL: the image's libstdc++.so.6 defines no GLIBCXX_3.4 -- the symbol-version scan is not reading it"; exit 1; }
for f in "${module_files[@]}" "$hard_dir/php"; do
  unmet=$(comm -23 <(elf_versions needs "$f" | sort -u) <(printf '%s\n' "$provided_versions"))
  [ -z "$unmet" ] || { echo "FAIL: $(basename "$f") needs symbol versions the image's libstdc++/libgcc_s do not define: $(tr '\n' ' ' <<<"$unmet")"; exit 1; }
done
echo "ok: every GLIBCXX_/CXXABI_/GCC_ version the shipped ELF files need is defined by the image's own libstdc++/libgcc_s ($(grep -c '^GLIBCXX_' <<<"$provided_versions") GLIBCXX versions available)"

# intl, against the ICU this version is supposed to have. The legacy 7.0-7.3
# range works against exactly one ICU release (67.1, the last with both the
# U_USING_ICU_NAMESPACE escape hatch and the TRUE/FALSE macros ext/intl needs).
#
# The expectation is derived: for the legacy era from deps/build-deps.sh --pin,
# which reads deps/versions.lock with the builder's own range arithmetic; for the
# modern era (no vendored ICU) from the libicuuc soname the runtime image
# carries. Neither can drift from what the build did.
icu_reported=$(drun --rm "$IMAGE" php -r 'echo INTL_ICU_VERSION;')
[ -n "$icu_reported" ] || { echo "FAIL: INTL_ICU_VERSION is empty -- intl did not load, or ICU is not linked"; exit 1; }

icu_pinned=$(bash "$HERE/../deps/build-deps.sh" --pin icu "$EXPECT")
if [ -n "$icu_pinned" ]; then
  case "$icu_reported" in
    "$icu_pinned"|"$icu_pinned".*)
      echo "ok: intl reports the vendored ICU $icu_reported (deps/versions.lock pins $icu_pinned for $EXPECT)" ;;
    *)
      echo "FAIL: intl reports ICU $icu_reported but deps/versions.lock pins $icu_pinned for PHP $EXPECT"; exit 1 ;;
  esac
else
  # No vendored ICU: the image must be using the system one, and INTL_ICU_VERSION
  # must match the libicuuc it actually ships. Reading the soname rather than a
  # package name keeps this working across Debian's libicuNN renames.
  icu_soname=$(drun --rm "$IMAGE" sh -c 'ls /usr/lib/*/libicuuc.so.* 2>/dev/null | head -1')
  [ -n "$icu_soname" ] || { echo "FAIL: no libicuuc.so in the image, but PHP $EXPECT is supposed to link the system ICU"; exit 1; }
  icu_major="${icu_soname##*.so.}"
  case "$icu_reported" in
    "$icu_major".*)
      echo "ok: intl reports the system ICU $icu_reported (image ships libicuuc.so.$icu_major)" ;;
    *)
      echo "FAIL: intl reports ICU $icu_reported but the image ships libicuuc.so.$icu_major"; exit 1 ;;
  esac
fi

# ...and ICU is not merely linked, it works. Comparing against "" cannot detect
# a broken formatter: NumberFormatter::format() returns false on failure and
# `false === ""` is false, so an outright failure would have read as success.
# Compare the value.
fmt=$(drun --rm "$IMAGE" php -r '$f=new NumberFormatter("de_DE",NumberFormatter::DECIMAL); echo $f->format(1234.5);')
[ "$fmt" = "1.234,5" ] || { echo "FAIL: intl de_DE formatting wrong: expected '1.234,5', got '$fmt'"; exit 1; }
echo "ok: intl formats de_DE correctly (1234.5 -> $fmt)"

# The endpoint every TLS check below uses. Overridable because these are the
# only assertions in this script that need outbound HTTPS, and an
# egress-filtered CI runner would otherwise report every image as broken with a
# message blaming ext/curl or the CA store. One constant, so the positive and
# negative controls cannot drift onto different hosts. BUILD_CHECK_TLS_URL=off
# skips the whole block; the run says so, because an image that was never
# checked against a real CA store must not read as one that was.
TLS_URL="${BUILD_CHECK_TLS_URL:-https://www.php.net/}"

# One PHP program for all four checks, so retry and classification cannot
# drift between them. TLS_VIA picks the client (stream = file_get_contents
# through php's own openssl extension, curl = ext/curl); TLS_EXPECT=ok is the
# positive check, TLS_EXPECT=verify-fail the negative control, which breaks the
# CA store (curl: CURLOPT_CAINFO here; stream: openssl.cafile on the php
# command line) and so must be refused for a certificate reason.
#
# Prints exactly one line:
#   OK:<bytes>        the request succeeded
#   VERIFY:<reason>   the peer's certificate (or the CA store) was rejected:
#                     curl_errno 60 or 77, or a stream error naming "certificate
#                     verify failed" or the unloadable cafile
#   FAIL:<reason>     any other error
#   TRANSIENT:<why>   DNS, connect, timeout, reset or TLS-handshake errors that
#                     persisted through every attempt
# A transient error is retried with a short backoff, so one flaky resolver
# lookup does not fail an image. The negative control passes only on VERIFY: a
# DNS or connection failure there proves nothing about the CA store, so it is
# retried and, if it persists, fails the check.
TLS_PHP='
$url = getenv("TLS_URL"); $via = getenv("TLS_VIA"); $neg = getenv("TLS_EXPECT") === "verify-fail";
$verify_re = "/certificate verify failed|failed loading cafile/i";
$transient_re = "/getaddrinfo|timed out|refused|reset/i";
$reason = "no attempt made";
for ($attempt = 1; $attempt <= 4; $attempt++) {
    if ($attempt > 1) { sleep(2 * ($attempt - 1)); }
    if ($via === "curl") {
        $ch = curl_init($url);
        $opts = [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 30];
        if ($neg) { $opts[CURLOPT_CAINFO] = "/nonexistent"; }
        curl_setopt_array($ch, $opts);
        $b = curl_exec($ch);
        $no = curl_errno($ch);
        $reason = "curl_errno $no: " . curl_error($ch);
        if ($b !== false) { echo "OK:" . strlen($b); exit; }
        if ($no === 60 || $no === 77) { echo "VERIFY:$reason"; exit; }
        if (in_array($no, [6, 7, 28, 35, 52, 56], true)) { continue; }
        echo "FAIL:$reason"; exit;
    }
    $msgs = [];
    set_error_handler(function ($n, $s) use (&$msgs) { $msgs[] = $s; return true; });
    $b = file_get_contents($url);
    restore_error_handler();
    $reason = $msgs ? implode(" | ", $msgs) : "no error reported";
    if ($b !== false) { echo "OK:" . strlen($b); exit; }
    if (preg_match($verify_re, $reason)) { echo "VERIFY:$reason"; exit; }
    if (preg_match($transient_re, $reason)) { continue; }
    echo "FAIL:$reason"; exit;
}
echo "TRANSIENT:still failing after 4 attempts: $reason";
'
tls_probe() {  # tls_probe <stream|curl> <ok|verify-fail> [php args] -> the one-line verdict above
  local via="$1" expect="$2"; shift 2
  docker run --rm -e TLS_URL="$TLS_URL" -e TLS_VIA="$via" -e TLS_EXPECT="$expect" "$IMAGE" php "$@" -r "$TLS_PHP"
}

if [ "$TLS_URL" = off ]; then
  echo "WARNING: BUILD_CHECK_TLS_URL=off -- the four TLS checks (openssl stream and ext/curl, each with a negative control) are SKIPPED; this image's CA store was NOT verified end to end" >&2
  echo "skip: TLS checks (BUILD_CHECK_TLS_URL=off)"
else
  # A real TLS handshake through PHP's own openssl extension, not curl. curl
  # resolves its CA bundle independently of PHP's openssl config, so a curl-only
  # check stayed green while the legacy era's vendored OpenSSL had a compiled-in CA
  # store pointing at an empty directory (openssl_get_cert_locations() reported
  # /opt/php-deps/ssl/cert.pem and .../certs, neither real) and file_get_contents,
  # stream_socket_client, SoapClient and SMTP+TLS all failed to verify the peer.
  # Runs for every flavor. These containers keep plain `docker run`: reaching the
  # internet is the point.
  body=$(tls_probe stream ok)
  [[ "$body" == OK:* ]] || { echo "FAIL: file_get_contents() over HTTPS to $TLS_URL failed (openssl CA store broken, or the endpoint unreachable?): $body"; exit 1; }
  echo "ok: TLS handshake via php's own openssl extension over $TLS_URL ($body)"

  # Negative control: a CA file that cannot verify anything must make the same
  # request fail, or the check above is vacuous. It must fail on verification: a
  # network error would also be a failure and would prove nothing.
  broken=$(tls_probe stream verify-fail -d openssl.cafile=/nonexistent)
  [[ "$broken" == VERIFY:* ]] || { echo "FAIL: negative control did not fail on certificate verification with a bogus cafile (got: $broken) -- the TLS check above may be vacuous"; exit 1; }
  echo "ok: negative control confirms the TLS check has discriminating power"

  # The same handshake through ext/curl, a different code path and the one
  # deps/patches/php-7.4 and php-8.0 exist for. Their curl-openssl3-not-old patch
  # stops ext/curl/config.m4's probe from concluding that trixie's libcurl is
  # linked against a pre-1.1 OpenSSL; without it HAVE_CURL_OLD_OPENSSL is defined,
  # ext/curl reaches into OpenSSL 3's opaque structs and every HTTPS curl_exec()
  # segfaults while plain HTTP keeps working. A segfault kills the child, so it
  # shows up as an empty body and a non-zero exit, not a PHP-level error.
  #
  # stderr is deliberately not folded in with 2>&1: the entrypoint writes an
  # autotuning notice there on every run, and capturing it would make the
  # comparison below fail on a perfectly healthy image.
  body=$(tls_probe curl ok) || { echo "FAIL: curl_exec() over HTTPS crashed the php process (exit $?): $body"; exit 1; }
  [[ "$body" == OK:* ]] || { echo "FAIL: curl_exec() over HTTPS to $TLS_URL failed: $body"; exit 1; }
  echo "ok: TLS handshake via ext/curl over $TLS_URL ($body)"

  # Negative control for the same measurement channel: a CA file that cannot
  # verify anything must make the curl request fail, on verification (curl_errno
  # 60 or 77), or the check above is vacuous.
  broken_curl=$(tls_probe curl verify-fail)
  [[ "$broken_curl" == VERIFY:* ]] || { echo "FAIL: curl negative control did not fail on certificate verification with a bogus CA file (got: $broken_curl) -- the curl TLS check above may be vacuous"; exit 1; }
  echo "ok: negative control confirms the ext/curl check has discriminating power"
fi

# Flavor shape, checked against what the Dockerfile's own stages actually
# build rather than assumed. Only ext-builder carries a compiler, g++, autoconf
# and the PHP headers/phpize/php-config, so an extension can genuinely be
# compiled against it. cli-builder (composer, node, deploy tooling), cli and
# fpm see none of that -- a compiler sitting in a shipped image is CVE surface
# and attack surface bought for nothing (an attacker who can write a .c file
# and already has a shell has one less step to a native payload).
no_toolchain() {  # no_toolchain <flavor> -- no compiler, assembler, linker, autoconf, phpize, PHP headers
  # Explicit names, not a `ld*` glob: that would also match ldd and ldconfig,
  # which every image has. The triplet forms are what a cross/multiarch
  # binutils installs. Fail-closed control first: if the probe shell cannot
  # run at all, "found nothing" below would be a pass on a dead container.
  drun --rm "$IMAGE" sh -c 'command -v sh' >/dev/null 2>&1 \
    || { echo "FAIL: $1: the toolchain probe cannot run a shell in the image, so its absence checks would prove nothing"; exit 1; }
  local found
  found=$(drun --rm "$IMAGE" sh -c '
    for t in gcc g++ cc c++ cpp clang clang++ as ld ld.bfd ld.gold ld.lld lld gold \
             x86_64-linux-gnu-gcc x86_64-linux-gnu-g++ x86_64-linux-gnu-as x86_64-linux-gnu-ld \
             aarch64-linux-gnu-gcc aarch64-linux-gnu-g++ aarch64-linux-gnu-as aarch64-linux-gnu-ld \
             autoconf phpize php-config; do
      command -v "$t"
    done
    for p in /usr/local/include/php /usr/include/php; do test -e "$p" && echo "$p"; done
    exit 0' 2>/dev/null) || { echo "FAIL: $1: the toolchain probe did not run"; exit 1; }
  [ -z "$found" ] \
    || { echo "FAIL: $1 carries a compiler, assembler, linker, autoconf, phpize/php-config or the PHP headers (expected only in ext-builder): $(tr '\n' ' ' <<<"$found")"; exit 1; }
}
case "$FLAVOR" in
  ext-builder)
    for tool in gcc g++ make autoconf pkg-config phpize php-config; do
      drun --rm "$IMAGE" sh -c "command -v $tool" >/dev/null \
        || { echo "FAIL: ext-builder is missing $tool (Dockerfile's ext-builder stage should provide it)"; exit 1; }
    done
    drun --rm "$IMAGE" test -f /usr/local/include/php/main/php.h \
      || { echo "FAIL: ext-builder has no PHP headers under /usr/local/include/php"; exit 1; }
    for tool in composer node npm; do
      if drun --rm "$IMAGE" sh -c "command -v $tool" >/dev/null 2>&1; then
        echo "FAIL: ext-builder carries $tool -- it is a compile stage, composer and node belong to cli-builder"; exit 1
      fi
    done
    echo "ok: ext-builder carries a compiler, g++, make, autoconf, pkg-config, phpize/php-config and the PHP headers, and no composer/node"

    # php-config has to describe the runtime it sits in: the extension dir
    # names the Zend module API, so equal dirs mean an extension built here
    # loads in the fpm/cli image of the same version.
    pc_dir=$(drun --rm "$IMAGE" php-config --extension-dir)
    rt_dir=$(drun --rm "$IMAGE" php -r 'echo ini_get("extension_dir");')
    [ -n "$pc_dir" ] && [ "$pc_dir" = "$rt_dir" ] \
      || { echo "FAIL: php-config --extension-dir ('$pc_dir') != the runtime's extension_dir ('$rt_dir')"; exit 1; }
    pc_ver=$(drun --rm "$IMAGE" php-config --version)
    [ "$pc_ver" = "$RELEASE" ] || { echo "FAIL: php-config --version is '$pc_ver', expected $RELEASE"; exit 1; }
    echo "ok: php-config matches the runtime ($pc_ver, extension_dir $pc_dir)"

    # The real thing, small: compile tests/fixtures/ext-hello with
    # phpize/configure/make, install it under a scratch root and load that .so
    # into this image's own php. The cross-image half (copy into fpm and cli,
    # PHP_EXT_ENABLE) is tests/test-ext-builder.sh, which needs all three
    # images of a version and so cannot run from one build leg.
    hello_out=$(drun --rm --init -v "$HERE/fixtures/ext-hello":/src:ro "$IMAGE" \
      timeout 600 sh -c '/src/build.sh /out >/tmp/build.log 2>&1 || { cat /tmp/build.log; exit 1; }
        so=$(find /out -name hello.so); test -n "$so" || exit 1
        php -d "extension=$so" -r "echo hello_world(), \"|\", hello_api();"') \
      || { echo "FAIL: the ext-hello fixture did not build or load in ext-builder: $hello_out"; exit 1; }
    [ "${hello_out%%|*}" = "hello from ext-builder" ] \
      || { echo "FAIL: hello_world() returned '$hello_out'"; exit 1; }
    echo "ok: ext-builder compiles an extension with phpize/configure/make and its php loads it ($hello_out)"
    ;;
  cli-builder)
    no_toolchain cli-builder
    echo "ok: cli-builder carries no compiler, autoconf, phpize/php-config or PHP headers"

    for tool in git rsync patch make brotli sqlite3 jq less nano ps unzip zip zstd composer node npm npx corepack semantic-release mariadb mariadb-dump; do
      drun --rm "$IMAGE" sh -c "command -v $tool" >/dev/null \
        || { echo "FAIL: cli-builder is missing $tool (Dockerfile's cli-builder stage should provide it)"; exit 1; }
    done
    node_major=$(drun --rm "$IMAGE" node -p 'process.versions.node.split(".")[0]')
    [ "$node_major" = "24" ] || { echo "FAIL: cli-builder's node major is '$node_major', expected 24 (copied from the node:24 image)"; exit 1; }
    for cmd in "npm --version" "npx --version" "corepack --version" "composer --version" "semantic-release --version"; do
      drun --rm "$IMAGE" sh -c "$cmd" >/dev/null 2>&1 \
        || { echo "FAIL: cli-builder: '$cmd' does not run as the image user"; exit 1; }
    done
    # npm and corepack cache under HOME by default, and uid 33's HOME (/var/www)
    # does not exist: `npm ci` as the image user fails unless both caches point
    # somewhere writable.
    for probe in "npm config get cache" 'printenv COREPACK_HOME'; do
      cache_dir=$(drun --rm "$IMAGE" sh -c "$probe") \
        || { echo "FAIL: cli-builder: '$probe' failed as the image user"; exit 1; }
      [ -n "$cache_dir" ] && [ "$cache_dir" != undefined ] \
        || { echo "FAIL: cli-builder: '$probe' printed '$cache_dir'"; exit 1; }
      drun --rm "$IMAGE" sh -c 'mkdir -p "$1" && t=$(mktemp -p "$1") && rm -f "$t"' sh "$cache_dir" \
        || { echo "FAIL: cli-builder: $cache_dir ('$probe') is not writable as the image user (uid $(drun --rm "$IMAGE" id -u))"; exit 1; }
    done
    echo "ok: cli-builder's npm and corepack caches are writable as the image user"
    # npm is pinned to 11.21.0 in the node-tools stage (the node image bundles an
    # older one with a vulnerable tar/ip-address). The finished tree must hold
    # exactly one npm of its own; the copy semantic-release carries for
    # @semantic-release/npm is a dependency of that package and expected. The
    # pattern is the exact node_modules/npm path, so
    # @semantic-release/npm/package.json is not a match.
    npm_version=$(drun --rm "$IMAGE" npm --version)
    [ "$npm_version" = "11.21.0" ] || { echo "FAIL: cli-builder: npm --version is '$npm_version', expected 11.21.0"; exit 1; }
    npm_pkgs=$(drun --rm "$IMAGE" find /usr/local/lib/node_modules -path '*/node_modules/npm/package.json' -not -path '/usr/local/lib/node_modules/semantic-release/*')
    [ "$npm_pkgs" = "/usr/local/lib/node_modules/npm/package.json" ] \
      || { echo "FAIL: cli-builder: expected exactly one npm outside semantic-release's own tree, found: $npm_pkgs"; exit 1; }
    npm_pkg_version=$(drun --rm "$IMAGE" node -p 'require("/usr/local/lib/node_modules/npm/package.json").version')
    [ "$npm_pkg_version" = "11.21.0" ] || { echo "FAIL: cli-builder: the installed npm package.json says $npm_pkg_version, expected 11.21.0"; exit 1; }
    sr_npm=$(drun --rm "$IMAGE" find /usr/local/lib/node_modules/semantic-release -path '*/node_modules/npm/package.json')
    [ -n "$sr_npm" ] || { echo "FAIL: cli-builder: the control find saw no npm inside semantic-release's tree -- the exclusion above is untested, so its result proves nothing"; exit 1; }
    echo "ok: cli-builder's npm is 11.21.0 and the only npm outside semantic-release's tree (control: its own nested copy is found)"
    # VEX drift: vex/php.openvex.json names the bundled npm packages we accepted a
    # finding in, by exact version (purl). When an npm or semantic-release bump
    # moves them, the statement describes a package that is gone or a version
    # nobody reviewed. Read from the VEX file at test time; a package may be
    # installed in several copies (npm's own and semantic-release's), the pinned
    # version must be one of them.
    vex_pkgs=$(python3 - "$ROOT/vex/php.openvex.json" <<'PY'
import json, sys, urllib.parse
seen = set()
for st in json.load(open(sys.argv[1]))["statements"]:
    for p in st["products"]:
        for sub in p.get("subcomponents", []):
            purl = sub["@id"]
            if purl.startswith("pkg:npm/") and purl not in seen:
                seen.add(purl)
                name, _, version = urllib.parse.unquote(purl[len("pkg:npm/"):]).rpartition("@")
                print(name, version)
PY
    )
    [ -n "$vex_pkgs" ] || { echo "FAIL: cli-builder: vex/php.openvex.json names no npm package -- the drift check below would prove nothing"; exit 1; }
    while read -r vex_name vex_want; do
      vex_have=$(drun --rm "$IMAGE" find /usr/local/lib/node_modules -path "*/node_modules/$vex_name/package.json" \
        -exec node -p 'require(process.argv[1]).version' {} \;)
      grep -qxF "$vex_want" <<<"$vex_have" \
        || { echo "FAIL: cli-builder: vex/php.openvex.json says $vex_name@$vex_want but the image has: ${vex_have:-no copy of it} -- update vex/php.openvex.json (and run: python3 ci/vex.py trivyignore --write)"; exit 1; }
    done <<<"$vex_pkgs"
    echo "ok: cli-builder carries the npm packages vex/php.openvex.json names, at the versions it pins: $(paste -sd, - <<<"${vex_pkgs// /@}")"
    echo "ok: cli-builder carries node $node_major, npm, npx, corepack, composer, semantic-release, git, rsync, patch, make, brotli, sqlite3, jq, less, nano, procps, unzip, zip, zstd and the mariadb client"
    ;;
  cli|fpm)
    no_toolchain "$FLAVOR"
    echo "ok: $FLAVOR carries no compiler"
    ;;
esac

if [ "$FLAVOR" = fpm ]; then
  # `php-fpm -t` also runs at build time (Dockerfile); assert it against the
  # shipped image too, since a pulled image is run as-is.
  if drun --rm --entrypoint php-fpm "$IMAGE" -t >/dev/null 2>&1; then
    echo "ok: php-fpm -t against the shipped config"
  else
    echo "FAIL: php-fpm -t failed against the image's own shipped config"; exit 1
  fi

  # php-fpm has to actually start and serve under its default entrypoint/CMD,
  # not merely parse its config. test-fpm-health.sh starts the image unmodified,
  # waits for its baked HEALTHCHECK to report healthy, drives a real FastCGI
  # request through cgi-fcgi that executes a PHP script, and carries its own
  # negative control (pool down -> unhealthy).
  bash "$HERE/test-fpm-health.sh" "$IMAGE"
fi

# What the compile did, not just what the image contains -- delegated to
# test-pgo.sh, which derives its own expectation from matrix.json. Runs for every
# flavor: the php binary and its PGO profile are built once and shared.
# SMOKE_SKIP_PGO is the explicit escape hatch for a bootstrap image built with
# PGO=false ahead of what matrix.json says for it (a cli-builder built to seed
# the very corpus PGO training needs).
if [ "${SMOKE_SKIP_PGO:-}" = "1" ]; then
  echo "WARNING: PGO check skipped because SMOKE_SKIP_PGO=1 -- only meant for a known-bootstrap image that predates matrix.json's current pgo setting." >&2
elif [ "$PGO" = true ]; then
  bash "$HERE/test-pgo.sh" "$IMAGE" "$EXPECT"
else
  echo "ok: PGO check skipped -- matrix.json says php $EXPECT is pgo=false"
fi

# mariadb-server is apt-installed inside the php-build stage only, to run PGO
# training's prestashop corpus app; the corpus ships only the app tree and a
# populated datadir, and runtime-base copies specific /usr/local/... paths out of
# php-build, none of which that install touches. Neither the server nor the
# client tools training needs to start it may exist in a shipped image.
#
# This is an absence assertion, so prove the instrument works first: a container
# that never started makes `docker run` exit non-zero, which reads exactly like
# "command -v found nothing". Something definitely on the image must be found
# the same way the loop below looks for absence.
control_bin=$(drun --rm "$IMAGE" sh -c "command -v php" 2>/dev/null || true)
[ -n "$control_bin" ] \
  || { echo "FAIL: docker run $IMAGE sh -c 'command -v php' produced nothing -- the container may not even start, so the mariadb-absence loop below would prove nothing"; exit 1; }
echo "ok: control -- the image runs and 'command -v' finds php ($control_bin), so the absence loop below can be trusted"

for b in mariadbd mysqld mariadb-install-db mysql_install_db; do
  if drun --rm "$IMAGE" sh -c "command -v $b" >/dev/null 2>&1; then
    echo "FAIL: $b is present in the runtime image -- mariadb-server leaked out of the php-build stage"
    exit 1
  fi
done
echo "ok: mariadb-server binaries (mariadbd, mysqld, mariadb-install-db, mysql_install_db) absent from the runtime image"

# test-entrypoint.sh runs once per flavor against the image under test; it gates
# only its fpm-pool-specific assertions (`php-fpm -tt` does not exist outside
# fpm) on the flavor. test-snuffleupagus.sh's behavioral/security assertions stay
# fpm-only.
if [ "$FLAVOR" = ext-builder ]; then
  # Same entrypoint and same cli ini as the cli flavor, which test-entrypoint.sh
  # already covers; its assertions are written for the uid-33 runtime flavors
  # and ext-builder runs as root, so they are not repeated here.
  echo "ok: test-entrypoint.sh skipped for ext-builder (identical entrypoint to cli, runs as root)"
else
  bash "$HERE/test-entrypoint.sh" "$IMAGE" "$FLAVOR"
  # `--read-only --tmpfs /tmp` end to end (ext-builder runs as root and is not
  # a runtime shape): the documented deployment, with a control wherever the
  # assertion depends on /tmp (see the header of test-readonly.sh).
  bash "$HERE/test-readonly.sh" "$IMAGE" "$FLAVOR"
fi
# Only where the registry builds it at all (ext.json: php >=7.2) -- 7.0 and
# 7.1 ship without it, so there is nothing to exercise there.
if [ "$FLAVOR" = fpm ] && grep -qw snuffleupagus <<<"$SHARED_EXTS"; then
  bash "$HERE/test-snuffleupagus.sh" "$IMAGE"
fi

echo "SMOKE PASSED"
