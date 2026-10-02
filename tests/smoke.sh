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
ROOT="$(cd "$HERE/.." && pwd)"

# CF-47/T15-P: a green gate on a stale image proved nothing, twice, in this
# project (task 15's fix rounds rebuilt 3 of 11 versions and stopped; task 16
# found three images that predated a shim fix, purely by accident). Comparing
# timestamps cannot catch this -- build-then-commit is the normal order here,
# so an image being *older* than the latest commit is routine and means
# nothing. A content hash of the build-context inputs is the only thing that
# tells "built from this tree" from "built from some earlier tree" apart, so
# refuse to run any of the checks below against an image that cannot prove
# that -- they would all pass while proving nothing about the tree under test.
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
  echo "ok: CF-47 -- $IMAGE's inputs-hash label matches the current tree ($tree_hash)"
fi

# CF-10: every era-specific expectation below (the exact release string, the
# static-vs-dynamic OpenSSL boundary) is read out of matrix.json for this
# version, never a literal or a hand-derived arithmetic boundary -- a version
# whose era changes, or whose point release moves, changes this script's
# behaviour by editing matrix.json, not by editing smoke.sh.
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

# Task 37b: the VM-kind expectation below (and the compiler-identity check
# further down) is keyed on the compiler that actually built this image, not
# on the PHP version -- gcc gets the HYBRID VM on every version it builds,
# clang gets CALL except on 8.5 where it gets TAILCALL. matrix.json says what
# *should* have built it; docker-bake.hcl's "php" target now also writes that
# same value onto the image itself, from the COMPILER build arg, as
# com.lotuswebagency.compiler. Reading it back and cross-checking it against
# matrix.json (rather than trusting matrix.json alone) is what makes a
# mislabelled image -- one built with the wrong COMPILER for its own tag --
# fail here instead of shipping.
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
  echo "FAIL: $IMAGE is labeled com.lotuswebagency.compiler=$compiler_label, but matrix.json says php $EXPECT should be built with $MATRIX_COMPILER -- mislabelled image (wrong COMPILER was used, or the label was not updated to match a matrix.json change)"
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
ver=$(docker run --rm "$IMAGE" php -r 'echo PHP_VERSION;')
[ "$ver" = "$RELEASE" ] || { echo "FAIL: expected exactly $RELEASE (matrix.json), got $ver"; exit 1; }
echo "ok: php $ver"

# ext-builder is a build stage and runs as root (make install writes into the
# extension dir); every other flavor drops to www-data.
want_uid=33
[ "$FLAVOR" != ext-builder ] || want_uid=0
uid=$(docker run --rm "$IMAGE" id -u)
[[ "$uid" == "$want_uid" ]] || { echo "FAIL: running as uid $uid, expected $want_uid"; exit 1; }
echo "ok: uid $want_uid"

# CF-12: uncompressed image size against spec section 13's per-flavor budget.
# The measurement (the sum of `docker history` layer sizes -- NOT `docker image
# inspect .Size`, which under the containerd store adds the compressed blobs
# and overstates by 100-200 MB) lives once, in tests/image-size.sh, so the two
# scripts can't drift on what "size" means.
#
# Budgets are the measured real size of the finished image + ~3%, in decimal MB
# (fpm 8.2 and 7.4 -- the larger, vendored-library era -- cli, cli-builder and
# ext-builder 8.2; see the commit that set them for the numbers). That is one
# number per flavor, so it is only as tight as the largest version measured:
# 8.5 (clang) and 7.0-7.3 were not rebuilt for it. Still report-only for that
# reason -- it becomes a hard failure once every version has a measured size
# to budget against. tests/image-size.sh --breakdown names where the bytes are.
declare -A SIZE_BUDGET_MB=( [fpm]=280 [cli]=270 [cli-builder]=550 [ext-builder]=420 )
budget_mb="${SIZE_BUDGET_MB[$FLAVOR]}"
actual_bytes=$(bash "$HERE/image-size.sh" --bytes "$IMAGE")
budget_bytes=$(( budget_mb * 1000 * 1000 ))
actual_mb=$(awk -v b="$actual_bytes" 'BEGIN { printf "%.1f", b / 1000 / 1000 }')
if [ "$actual_bytes" -le "$budget_bytes" ]; then
  echo "ok: CF-12 -- $IMAGE is ${actual_mb} MB, within the $FLAVOR budget of ${budget_mb} MB"
else
  over_pct=$(awk -v a="$actual_bytes" -v b="$budget_bytes" 'BEGIN { printf "%.1f", (a - b) / b * 100 }')
  echo "note: CF-12 (report-only until the images are final) -- $IMAGE is ${actual_mb} MB, over the $FLAVOR budget of ${budget_mb} MB by ${over_pct}% (run tests/image-size.sh --breakdown $IMAGE for where the bytes are)"
fi

# CF-19: php -m names some extensions differently from the vocabulary the
# rest of this project (ext.json, matrix.json, this script's own $ext loop
# variables) uses for them. opcache is the one that matters: it reports as
# "Zend OPcache" under [Zend Modules], a different word entirely, not a case
# variant -- the substring match this line used to be (`grep -qi opcache`)
# happened to still catch it, but a substring match is exactly what let `xml`
# match `xmlwriter` elsewhere in this project (CF-19's other half, fixed
# below at the SHARED_EXTS loops, which already use anchored `grep -qix`).
# xdebug/pdo/phar/simplexml/ffi differ from their registry names only in
# case ("Xdebug", "PDO", "Phar", "SimpleXML", "FFI"), which the anchored
# `-i` flag already normalises, so they need no entry here -- listed as a
# comment, not silently assumed, so the next name that turns out to need a
# real alias is added deliberately.
php_registry_alias() {  # php_registry_alias <ext.json/matrix.json name> -> the exact php -m line to expect
  case "$1" in
    opcache) echo "Zend OPcache" ;;
    *) echo "$1" ;;
  esac
}

extdir=$(docker run --rm "$IMAGE" php -r 'echo ini_get("extension_dir");')
mods=$(docker run --rm "$IMAGE" php -m)
grep -qix "$(php_registry_alias opcache)" <<<"$mods" || { echo "FAIL: opcache missing (looked for the exact, anchored line 'Zend OPcache')"; exit 1; }
echo "ok: opcache present"

# Matched against the capture above, not re-piped per extension. `docker run
# ... | grep -q` is the anti-pattern this file's own header describes: grep -q
# exits at the first match, the producer takes SIGPIPE, and `set -o pipefail`
# reports the pipeline as failed. Observed for real, not theorised -- a
# parallel 11-image gate sweep printed "write /dev/stdout: broken pipe" and
# "FAIL: apcu missing" against an image whose php -m lists apcu, and three
# re-runs of the same command passed. It needs load to reproduce, which is
# exactly what CI is. Reusing $mods also drops six containers to zero here.
for ext in igbinary redis imagick memcached apcu zstd; do
  grep -qix "$ext" <<<"$mods" || { echo "FAIL: $ext missing"; exit 1; }
done
echo "ok: pecl extensions compiled in"

# Static means no .so on disk for these
for ext in igbinary redis imagick memcached apcu zstd; do
  if docker run --rm "$IMAGE" sh -c "ls \$(php -r 'echo ini_get(\"extension_dir\");')/$ext.so" 2>/dev/null; then
    echo "FAIL: $ext is a shared module, expected static"; exit 1
  fi
done
echo "ok: pecl extensions are static, not shared"

# imagick's delegate set (task 8 built the libraries; this is the PHP-level
# check that static linkage actually wired them up).
formats=$(docker run --rm "$IMAGE" php -r 'echo implode(",", Imagick::queryFormats());')
for fmt in PNG JPEG WEBP AVIF; do
  grep -qi "$fmt" <<<"$formats" || { echo "FAIL: Imagick::queryFormats() missing $fmt (got: $formats)"; exit 1; }
done
echo "ok: imagick delegate formats present"

# ImageMagick is built with --disable-openmp (task 8); confirm that holds once
# imagick links it into the php binary -- OpenMP spawns a thread per core per
# request if it sneaks back in under FPM.
linkage=$(docker run --rm "$IMAGE" ldd /usr/local/bin/php)
grep -qi libgomp <<<"$linkage" && { echo "FAIL: php binary links libgomp (openmp leaked in)"; exit 1; }
echo "ok: no libgomp in php binary linkage"

# CF-5 / hard requirement: the legacy era's vendored OpenSSL must be linked
# statically -- no libssl/libcrypto may appear as a *direct* NEEDED entry in
# the php binary's own ELF dynamic section. This was prose-only in task 14's
# report until this review round (C2): CF-5 exists specifically to keep an
# EOL OpenSSL from escaping into the image, and a proof that only lives in a
# report doesn't run again on the next build.
#
# `ldd` (used above for libgomp) resolves the full *transitive* closure,
# which would wrongly flag 8.0: it dynamically links trixie's system
# libcurl.so.4 for curl (not vendored there -- deps/versions.lock caps the
# vendored copy at 7.0-7.2), and libcurl.so.4 itself needs libssl.so.3, so
# ldd legitimately reports libssl.so.3 even on a fully static-openssl build.
# readelf -d reads only the binary's own recorded NEEDED list, without
# following anything, which isolates exactly the property that matters.
# Neither readelf nor nm exist inside the runtime image, so extract the
# binary via docker cp and inspect it on the host.
command -v readelf >/dev/null || { echo "FAIL: readelf not found on this host, cannot verify CF-5"; exit 1; }
cid=$(docker create "$IMAGE")
tmp_php=$(mktemp)
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true; rm -f "$tmp_php"' EXIT
docker cp "$cid:/usr/local/bin/php" "$tmp_php" >/dev/null
docker rm -f "$cid" >/dev/null
# `readelf -d ... | grep NEEDED | grep -iE 'libssl|libcrypto' || true` (the
# original shape of this check) fails OPEN under a measurement failure: a
# garbled docker cp, a moved binary path, a corrupt extraction, or any
# readelf error all make the *whole pipeline* fail, and the trailing
# `|| true` swallowed that indiscriminately, same as a legitimate "grep
# found no libssl" no-match -- both produced an empty direct_needed, and the
# legacy branch below reads empty as proof OpenSSL is static. Reproduced
# against a non-ELF temp file: "ok: CF-5 ... exit=0" on a file readelf
# couldn't even parse (task 14 review round 3, C2 reopened). Fix: capture
# the raw `readelf -d` output first, alone, with nothing to swallow its exit
# status -- a non-ELF fails loudly right here, under set -e, before any grep
# gets a chance to run. Then require at least one NEEDED line to exist at
# all (catches a binary with no dynamic section, not just a bad file), and
# only scope `|| true` to the one grep that is legitimately allowed to match
# nothing: "no libssl/libcrypto among the NEEDED entries that do exist."
dyn=$(readelf -d "$tmp_php")
grep -qi NEEDED <<<"$dyn" || { echo "FAIL: readelf found no NEEDED entries in the extracted php binary -- CF-5 could not be measured (corrupt extraction?)"; exit 1; }
direct_needed=$(grep -i NEEDED <<<"$dyn" | grep -iE 'libssl|libcrypto' || true)
rm -f "$tmp_php"

# T19-T ruling (on L-1/L-2, refining CF-9): CF-5 above is the property that
# matters for php itself -- OpenSSL fully static, zero libssl/libcrypto
# NEEDED at all, direct or transitive. A shared *extension* was never held to
# that same bar in practice, and measurement (L-1) showed why the original
# "any NEEDED at all" version of this check was the wrong instrument: on
# 7.4-8.0, event.so and snmp.so directly NEED libssl.so.3/libcrypto.so.3 --
# Debian's supported, dynamically-patched OpenSSL 3, pulled in by libevent
# and libsnmp -- and bind to it cleanly (LD_DEBUG=bindings confirmed
# SSL_CTX_new et al. resolve to /lib/.../libssl.so.3, never to php's static
# 1.1). That is two independent OpenSSL stacks in one process, not the EOL
# vendored one escaping. CF-5's actual purpose is narrower: the legacy era's
# *EOL, vendored* OpenSSL (1.1.1, built --no-shared) must never ship as a
# loadable object. Debian's supported .so.3 is not that object, so an
# extension linking it directly is not a violation -- what would be a
# violation is the vendored OpenSSL surfacing as something loadable, which
# happens in exactly two ways: (a) a NEEDED entry resolves to a path under
# the vendored prefix (/opt/php-deps, or anywhere under /opt) instead of
# Debian's system copy, or (b) a NEEDED soname is below .so.3 -- 1.1.x is the
# only ABI this era's vendored build ever produces, and Debian ships nothing
# else. Either signal alone means the EOL OpenSSL became dynamically
# loadable.
#
# `ldd` resolves each NEEDED entry the way the dynamic linker would at load
# time -- RPATH/RUNPATH included -- which is exactly what a vendored-prefix
# rpath trick depends on and a bare `readelf -d` soname list would miss.
# `ldd` exists in the runtime image (scripts/runtime-libs.sh already relies
# on this, against extracted trees, including bare .so files, not just
# executables), so run it in a container per object instead of extracting
# each one with `docker cp` to inspect on the host the way CF-5 above does
# for the php binary (readelf still needed there, since $dyn is reused below
# for T16-G).
#
# Fail-closed guard, same posture as CF-5's: a NEEDED entry `ldd` cannot
# resolve ("not found") is unproven, not innocent, and is treated as a hit
# rather than silently passed through -- the property under test is "never
# loadable", and "we couldn't tell" does not establish that.
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

ext_files=$(docker run --rm "$IMAGE" sh -c "ls \"$extdir\"/*.so 2>/dev/null" || true)
n_ext_files=0
# shellcheck disable=SC2086  # ext_files is a newline/space-separated list of paths, meant to word-split
for sofile in $ext_files; do
  n_ext_files=$((n_ext_files + 1))
  so_ldd=$(docker run --rm "$IMAGE" ldd "$sofile" 2>&1 || true)
  [ -n "$so_ldd" ] || { echo "FAIL: ldd produced no output for $sofile -- CF-9 could not be measured (corrupt image?)"; exit 1; }
  scan_ssl_resolution "$sofile" "$so_ldd"
done
echo "ok: CF-9 -- inspected the php binary and $n_ext_files shared extension .so file(s) in $extdir for a libssl/libcrypto NEEDED entry resolving to a vendored path or a pre-.so.3 soname"

# CF-9's other half: a stray libssl/libcrypto file can sit in the image
# without ever being a NEEDED entry of anything php loads (a leftover from an
# earlier build stage, a vendored copy nothing links against yet). Narrowed
# by the same T19-T ruling as the NEEDED scan above: Debian's libssl.so.3/
# libcrypto.so.3 is expected and allowed anywhere in a legacy image (curl,
# psql, the mariadb client and libsnmp all pull it in) -- what must never
# exist is a file that could only be the vendored, EOL build: a
# libssl.so.1*/libcrypto.so.1* file anywhere, or a libssl.so*/libcrypto.so*
# file under a vendored prefix (/opt/php-deps, or anywhere under /opt) --
# scoped to the shared-object naming, since a .pc/.a/.h file lying around
# under the vendored prefix (deps/build-deps.sh's own pkgconfig output, e.g.)
# carries no loadability risk and is not what this check is for.
# An absence assertion needs its own positive control first (T14-G): prove
# `find` can find *something* known to exist, or an empty result and "the
# scan is broken" are indistinguishable.
# `find` exits non-zero the moment it hits one permission-denied directory
# while running as www-data, even though it still printed every match it
# could reach -- `|| true` is scoped to that single command, not to the
# absence check that follows, so a genuinely empty result still reads as
# "found nothing" rather than being conflated with "find itself errored".
find_control=$(docker run --rm "$IMAGE" sh -c "find / -xdev -name 'libc.so*' 2>/dev/null" || true)
[ -n "$find_control" ] || { echo "FAIL: image-wide find could not even locate libc.so -- the CF-9 file-existence scan below would prove nothing"; exit 1; }
stray_ssl=$(docker run --rm "$IMAGE" sh -c "find / -xdev \\( \\( -name 'libssl.so.1*' -o -name 'libcrypto.so.1*' \\) -o \\( -path '/opt/*' -a \\( -name 'libssl.so*' -o -name 'libcrypto.so*' \\) \\) \\) 2>/dev/null" || true)

# 7.0-8.0 vendor OpenSSL statically (no-shared); 8.1+ link Debian's OpenSSL 3
# dynamically by design (system packages, matrix.json's modern era). Boundary
# comes from matrix.json's own era field (CF-10), not a hand-derived 8.1
# arithmetic cutover duplicating what matrix.json already says.
if [ "$ERA" = legacy ]; then
  [ -z "$direct_needed" ] || { echo "FAIL: CF-5 violated -- legacy php binary directly links libssl/libcrypto: $direct_needed"; exit 1; }
  echo "ok: CF-5 -- legacy php binary has no direct libssl/libcrypto NEEDED entry (OpenSSL fully static)"
  [ -z "$ssl_load_violations" ] || { printf 'FAIL: CF-9 violated -- the vendored/EOL OpenSSL is loadable in this image:\n%s\n' "$ssl_load_violations"; exit 1; }
  echo "ok: CF-9 -- nothing php or its shared extensions load resolves libssl/libcrypto to a vendored path or a pre-.so.3 soname (Debian's libssl.so.3/libcrypto.so.3 is allowed)"
  [ -z "$stray_ssl" ] || { echo "FAIL: CF-9 violated -- a vendored/EOL libssl or libcrypto file exists in the image: $stray_ssl"; exit 1; }
  echo "ok: CF-9 -- no libssl.so.1*/libcrypto.so.1* file, and no libssl.so*/libcrypto.so* file under a vendored prefix, exists anywhere in the image"
else
  [ -n "$direct_needed" ] || { echo "FAIL: modern php binary has no libssl/libcrypto NEEDED entry -- expected dynamic system OpenSSL"; exit 1; }
  echo "ok: modern php binary links system libssl/libcrypto dynamically, as expected"
  echo "ok: CF-9 file/NEEDED scan not restricted on the modern era (dynamic system OpenSSL is expected everywhere): ext=${ssl_load_violations:-none} files=${stray_ssl:-none}"
fi

# T16-G: every library php-src can build from a bundled copy has to come from
# the system, and the ones that do not yet have to be known. Rows come from
# php/system-libs.lock; the measurement is the same instrument CF-5 uses one
# block up -- the binary's own NEEDED list, not the flags configure was handed.
#
# The whole point is that the flags lie by omission: php/configure-args.sh
# emitted no sqlite flag at all for years, configure took its default, and
# PHP 7.0 shipped a statically compiled SQLite 3.14.2 from August 2016 while
# 7.4+ happened to be clean only because php-src had dropped the bundle by
# then. Nobody was going to notice that from reading the arguments.
# Exact strength of this check: a NEEDED entry proves the library is linked
# dynamically rather than compiled in, which is the property that decides
# whether `apt upgrade` can ever reach it. It does not prove the .so resolves to
# *Debian's* copy -- a self-built one installed at the same soname would satisfy
# it. Closing that would mean comparing against dpkg's shipped sonames, which is
# more machinery than the risk warrants while nothing in this image installs
# libraries outside apt (T16-G review, ruled to leave).
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


# Shared modules (task 9, plus lz4 and snuffleupagus fixed/added in task 12)
# exist on disk... EXPECT doubles as the PHP_VERSION to filter ext.json by
# (every caller already passes "8.0"/"8.5"-shaped values, matching matrix.json).
# This used to be a hand-maintained literal list naming mongodb/protobuf/swoole
# unconditionally -- task 14 review, C1: that's exactly what 8.0 excludes via
# ext.json floors and build-shared-ext.sh's KNOWN_UNBUILDABLE, so this script
# failed on the very image task 14 exists to prove, and would fail the same way
# on every future version whose shared set differs from 8.5's (task 24's PR
# group already includes php-7_0-fpm). Deriving from build-shared-ext.sh --list
# means there is exactly one place that knows "what shared extensions does
# version X actually get" -- this script can't drift out of sync with it again.
SHARED_EXTS=$(bash "$HERE/../php/build-shared-ext.sh" --list "$EXPECT")
# build-shared-ext.sh --list now refuses to print nothing for a version it
# doesn't recognize (task 14 review round 3, empty-derivation guard), but
# that guard lives one process away from this script's own `set -e`: a
# command substitution that fails is caught, one that quietly succeeds empty
# is not. Assert it here too, at the point this script actually consumes the
# derivation, rather than trusting the producer never regresses.
[ -n "$SHARED_EXTS" ] || { echo "FAIL: build-shared-ext.sh --list $EXPECT derived zero shared extensions -- every real version has at least one"; exit 1; }
# extdir was already captured near the top of this script (CF-9 needs it
# before SHARED_EXTS exists yet), reused here rather than re-queried.
for ext in $SHARED_EXTS; do
  docker run --rm "$IMAGE" test -f "$extdir/$ext.so" || { echo "FAIL: $ext.so missing"; exit 1; }
done
echo "ok: shared modules present on disk"

# ...and nothing extra is there. The loop above only proves every extension
# SHARED_EXTS expects exists; it never notices a .so sitting in extension_dir
# that SHARED_EXTS doesn't know about -- the other half of the same drift,
# and the direction an accidental extra build/copy would introduce it (task
# 14 review round 3, "empty-derivation guard": "assert set equality against
# the .so files actually in extension_dir, not just derived-⊆-disk").
#
# opcache.so is the one legitimate, documented exception on every version
# except 8.5 (Dockerfile:342-360, php/ext.json's opcache entry): PHP's own
# --enable-opcache build always produces a loadable opcache.so, the same as
# a Zend extension, even though ext.json marks it "linkage": "static" and it
# ships pre-activated via conf.d rather than opt-in through php-ext-enable --
# so it is not, and should not be, a member of SHARED_EXTS, but it is a real
# file this script would otherwise misreport as unexplained drift.
disk_exts=$(docker run --rm "$IMAGE" sh -c "ls \"$extdir\"" | sed -n 's/\.so$//p' | sort -u)
# shellcheck disable=SC2086  # SHARED_EXTS is a space-separated list, meant to word-split
expected_disk_exts=$(printf '%s\n' $SHARED_EXTS | sort -u)
if [ "$EXPECT" != "8.5" ]; then
  expected_disk_exts=$(printf '%s\nopcache\n' "$expected_disk_exts" | sort -u)
fi
extra=$(comm -13 <(echo "$expected_disk_exts") <(echo "$disk_exts"))
[ -z "$extra" ] || { echo "FAIL: extension_dir has unexplained .so files not in the derived shared set (or opcache exception): $extra"; exit 1; }
echo "ok: extension_dir has no unexplained .so files"

# ...but are not loaded by default (ffi is already in the list above -- it's
# called out by name in the assertion because it's the one that matters most:
# ffi escapes every PHP-level sandbox, so it ships disabled on purpose)
#
# This one used to be `if docker run ... | grep -qix "$ext"; then FAIL`, and
# that shape did not merely flake -- it failed **open**. A SIGPIPE-killed
# pipeline exits non-zero, the `if` is false, and the loop prints
# "ok: shared modules not loaded by default" having proved nothing. Worse, the
# race correlates with the condition: SIGPIPE requires grep to match early,
# which is precisely when the extension *is* loaded. So the check was most
# likely to miss exactly when it should have fired -- including on ffi.
#
# $mods is the capture from the top of this script: a fresh `docker run` of
# `php -m` with nothing enabled, which is the default state this asserts. The
# image is immutable and every php-ext-enable call below runs in its own
# throwaway container, so one capture is valid for both uses.
for ext in $SHARED_EXTS; do
  if grep -qix "$ext" <<<"$mods"; then
    echo "FAIL: $ext loaded by default, must be opt-in"; exit 1
  fi
done
echo "ok: shared modules not loaded by default (including ffi)"

# Positive control for the loop above, which is an absence assertion and so
# cannot distinguish "nothing is loaded" from "I cannot see what is loaded".
# That distinction is not academic here: the previous shape of this check
# answered ok on a SIGPIPE-killed pipeline. Enable one shared module in a
# throwaway container and require the same grep, against the same kind of
# capture, to find it.
# shellcheck disable=SC2086  # SHARED_EXTS is a space-separated list, meant to word-split
control_ext=$(printf '%s\n' $SHARED_EXTS | head -1)
control_mods=$(docker run --rm "$IMAGE" sh -c "php-ext-enable $control_ext >/dev/null && php -m")
grep -qix "$control_ext" <<<"$control_mods" \
  || { echo "FAIL: enabled $control_ext but php -m does not report it -- the 'not loaded by default' check above cannot detect a loaded module, so its result means nothing"; exit 1; }
echo "ok: control -- an enabled module ($control_ext) is visible to the same check"

# ...and no conf.d ini enables anything shared, not just what -m happens to report.
# Task 10 lays down baseline ini files (10-php.ini, 15-opcache.ini), so conf.d
# is no longer empty -- the assertion instead greps those files for an
# extension= or zend_extension= line naming any of the shared modules.
for ext in $SHARED_EXTS; do
  if docker run --rm "$IMAGE" sh -c "grep -hE '^[[:space:]]*(zend_)?extension[[:space:]]*=' /usr/local/etc/php/conf.d/*.ini 2>/dev/null | grep -qiE \"(^|[/=])${ext}(\\.so)?\\\$\""; then
    echo "FAIL: conf.d enables $ext by default, shared extensions must ship dormant"; exit 1
  fi
done
echo "ok: conf.d does not enable shared modules by default"

# ...and opt-in works, including the zend_extension= case. One container:
# php-ext-enable's ini write has to be visible to the php -m that follows it,
# which a second `docker run` on the same read-only image would not see.
#
# The zend subject is derived, not named. It used to be the literal "xdebug",
# on the reasoning that it is the one entry exercising the zend_extension=
# code path -- true, but xdebug's pecl.lock-pinned package (3.5.3) declares a
# PHP 8.0 floor, so ext.json excludes it from 7.0-7.4 entirely and
# `php-ext-enable xdebug` there fails on a missing .so. Which names take that
# path is php-ext-enable's own decision, so ask it (--list-zend reads the same
# variable its is_zend() does) and intersect with this version's derived
# shared set. The other subjects come from SHARED_EXTS the same way.
zend_known=$(docker run --rm "$IMAGE" php-ext-enable --list-zend)
[ -n "$zend_known" ] || { echo "FAIL: php-ext-enable --list-zend printed nothing -- cannot pick a zend_extension subject"; exit 1; }
# shellcheck disable=SC2086  # zend_known and SHARED_EXTS are space-separated lists, meant to word-split
zend_subjects=$(comm -12 <(printf '%s\n' $zend_known | sort -u) <(printf '%s\n' $SHARED_EXTS | sort -u))

# shellcheck disable=SC2086  # zend_subjects and SHARED_EXTS are space-separated lists, meant to word-split
enable_exts="$(printf '%s\n' $zend_subjects $SHARED_EXTS | awk '!seen[$0]++' | head -3 | tr '\n' ' ')"
mods=$(docker run --rm "$IMAGE" sh -c "php-ext-enable $enable_exts >&2 && php -m")
for ext in $enable_exts; do
  grep -qix "$ext" <<<"$mods" || { echo "FAIL: php-ext-enable did not load $ext"; exit 1; }
done

if [ -n "$zend_subjects" ]; then
  # Prove the zend_extension= branch is what ran, rather than trusting that
  # the name happened to be in the list: read back the ini php-ext-enable
  # wrote for the subject it just enabled.
  # shellcheck disable=SC2086  # zend_subjects is a space-separated list, meant to word-split
  zsub=$(printf '%s\n' $zend_subjects | head -1)
  line=$(docker run --rm "$IMAGE" sh -c "php-ext-enable $zsub >/dev/null && cat /usr/local/etc/php/conf.d/20-${zsub}.ini")
  [ "$line" = "zend_extension=${zsub}.so" ] || { echo "FAIL: php-ext-enable wrote '$line' for $zsub, expected zend_extension=${zsub}.so"; exit 1; }
  echo "ok: php-ext-enable works, including zend_extension ($zsub) [$enable_exts]"
else
  # An empty intersection must be *explained*, not silently skipped -- that is
  # exactly the shape of a check that reports ok on having measured nothing.
  #
  # The explanation that carries weight is on-disk, not in the derived set: if
  # a zend-capable module is sitting in extension_dir but the derivation left
  # it out, the derivation is wrong and the subject was skipped rather than
  # absent. That is not hypothetical -- it is precisely how 7.0-7.4 lost
  # xdebug: an ext.json floor excluded it, so SHARED_EXTS shrank, and every
  # set-based check agreed with itself.
  #
  # (An earlier version of this block also re-tested $zend_known against
  # SHARED_EXTS here. That was unreachable: zend_subjects *is* their
  # intersection, so inside this branch no member of one can be in the other.
  # It read like a safety net and was not one.)
  for zx in $zend_known; do
    # opcache is compiled in and ships pre-activated (Dockerfile), so its .so
    # legitimately exists while never being a php-ext-enable subject.
    [ "$zx" = opcache ] && continue
    if docker run --rm "$IMAGE" test -f "$extdir/$zx.so"; then
      echo "FAIL: $zx.so exists in extension_dir but is not in this version's derived shared set -- the derivation is wrong, so the zend_extension= path was skipped rather than genuinely absent"; exit 1
    fi
  done
  # shellcheck disable=SC2086,SC2116  # zend_known is a space-separated list meant to word-split; the echo just flattens it into one line for the message
  echo "ok: php-ext-enable works [$enable_exts]; no zend_extension subject exists on PHP $EXPECT (php-ext-enable knows: $(echo $zend_known), none of them in this version's shared set)"
fi

# ...php-ext-enable refuses unknown names loudly. Well-formed (letters/digits/
# underscore, matching every real name in ext.json) but not a real extension --
# a hyphenated name would now be caught a layer earlier by task 11's charset
# guard instead, which is a different assertion (see test-entrypoint.sh).
if docker run --rm "$IMAGE" php-ext-enable not_a_real_extension 2>/tmp/php-ext-enable.err; then
  echo "FAIL: php-ext-enable accepted an unknown extension name"; exit 1
fi
grep -qi "no such extension" /tmp/php-ext-enable.err || { echo "FAIL: unknown extension did not fail loudly"; exit 1; }
echo "ok: php-ext-enable refuses unknown names"

# Baseline php.ini (task 10): expose_php/display_errors/allow_url_include off.
for pair in "expose_php:" "display_errors:" "allow_url_include:"; do
  key="${pair%%:*}"
  val=$(docker run --rm "$IMAGE" php -r "echo ini_get('$key') ?: '0';")
  [[ "$val" == "0" || "$val" == "" ]] || { echo "FAIL: $key is '$val', expected off"; exit 1; }
done
echo "ok: php.ini hardened"

# proc_open must stay enabled: composer and symfony/process need it. Builder
# (conf/php-builder.ini) drops disable_functions entirely -- build tooling
# legitimately needs shell_exec/exec too -- so shell_exec is only required to
# be disabled on the fpm/cli flavors.
dis=$(docker run --rm "$IMAGE" php -r "echo ini_get('disable_functions');")
echo "$dis" | grep -q 'proc_open' && { echo "FAIL: proc_open disabled"; exit 1; }
case "$FLAVOR" in
  cli-builder) : ;;
  *) echo "$dis" | grep -q 'shell_exec' || { echo "FAIL: shell_exec not disabled"; exit 1; } ;;
esac
echo "ok: disable_functions correct"

# opcache baseline (15-opcache.ini, laid down once in runtime-base for every flavor)
oc=$(docker run --rm "$IMAGE" php -r '
foreach (["opcache.enable","opcache.enable_file_override","opcache.save_comments","opcache.validate_timestamps"] as $k) {
  echo $k . "=" . ini_get($k) . PHP_EOL;
}')
grep -qx 'opcache.enable=1' <<<"$oc" || { echo "FAIL: opcache.enable wrong: $oc"; exit 1; }
grep -qx 'opcache.enable_file_override=0' <<<"$oc" || { echo "FAIL: opcache.enable_file_override wrong: $oc"; exit 1; }
grep -qx 'opcache.save_comments=1' <<<"$oc" || { echo "FAIL: opcache.save_comments wrong: $oc"; exit 1; }
echo "ok: opcache settings applied"

# CF-19's other half: "opcache is actually enabled" and "JIT on PHP >= 8.0"
# have to be proven on the binary's real behaviour, not read back as ini
# strings -- ini_get() above only proves conf/opcache.ini's *values* landed,
# not that the opcache module ever activates. `docker run $IMAGE php -r`
# always runs the CLI SAPI regardless of flavor, and conf/opcache.ini sets
# opcache.enable_cli=0 on purpose (a short-lived CLI process gains nothing
# from a persistent opcache and JIT trades startup time for it), so opcache
# is genuinely inactive here by default -- assert that first, or the "activate
# when asked" proof below has nothing to distinguish itself from.
off=$(docker run --rm "$IMAGE" php -r '$s = opcache_get_status(false); echo $s === false ? "off" : "on";')
[ "$off" = "off" ] || { echo "FAIL: opcache is active under plain CLI by default, expected inactive (opcache.enable_cli=0 in conf/opcache.ini): $off"; exit 1; }
echo "ok: opcache inactive under plain CLI by default (opcache.enable_cli=0), as conf/opcache.ini sets it"

on=$(docker run --rm "$IMAGE" php -d opcache.enable_cli=1 -r '
$s = opcache_get_status(false);
if ($s === false) { echo "off"; exit; }
// jit.enabled means only "this opcache build has JIT compiled in" -- it stays
// true even with opcache.jit=0/off (verified: $s["jit"]["enabled"] was still
// true against this same image with opcache.jit=off forced). jit.on is the
// field that reflects whether the JIT is actually compiling right now.
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

# The VM kind, expected from VM_COMPILER/PHP version/IMAGE_ARCH (task 37b, see
# the table above), checked two ways:
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

build_record=$(docker run --rm --entrypoint cat "$IMAGE" /usr/local/share/php-build/pgo.txt 2>/dev/null) \
  || { echo "FAIL: $IMAGE has no /usr/local/share/php-build/pgo.txt -- cannot check vm_kind_config"; exit 1; }
vm_kind_config=$(sed -n 's/^vm_kind_config=//p' <<<"$build_record" | head -1)
[ -n "$vm_kind_config" ] \
  || { echo "FAIL: the build record has no vm_kind_config line -- this image predates the task 37b VM-kind recording, rebuild it"; exit 1; }
want=$(tr '[:upper:]' '[:lower:]' <<<"$EXPECTED_VM_NAME")
[ "$vm_kind_config" = "$want" ] \
  || { echo "FAIL: the build record says vm_kind_config=$vm_kind_config for PHP $EXPECT ($VM_COMPILER, $IMAGE_ARCH), expected $want (ZEND_VM_KIND_$EXPECTED_VM_NAME)"; exit 1; }
echo "ok: build record shows vm_kind_config=$vm_kind_config for PHP $EXPECT ($VM_COMPILER, $IMAGE_ARCH)"

if [ "$has_ffi" = true ]; then
  vm_kind=$(docker run --rm "$IMAGE" php -d extension=ffi -d ffi.enable=1 \
    -r 'echo FFI::cdef("int zend_vm_kind(void);")->zend_vm_kind();')
  [ "$vm_kind" = "$EXPECTED_VM_KIND" ] \
    || { echo "FAIL: PHP $EXPECT ($VM_COMPILER) runs VM kind '$vm_kind', expected $EXPECTED_VM_KIND (ZEND_VM_KIND_$EXPECTED_VM_NAME)"; exit 1; }
  echo "ok: interpreter is ZEND_VM_KIND_$EXPECTED_VM_NAME (zend_vm_kind()=$vm_kind)"
else
  echo "note: no FFI on PHP $EXPECT, so the VM kind rests on the build record alone"
fi

# Per-flavor ini differences, driven by the $FLAVOR argument, not the image tag.
mem=$(docker run --rm "$IMAGE" php -r "echo ini_get('memory_limit');")
case "$FLAVOR" in
  cli-builder)
    [[ "$mem" == "-1" ]] || { echo "FAIL: builder memory_limit is '$mem', expected -1"; exit 1; }
    dis_b=$(docker run --rm "$IMAGE" php -r "echo ini_get('disable_functions');")
    [[ -z "$dis_b" ]] || { echo "FAIL: builder disable_functions is '$dis_b', expected empty"; exit 1; }
    echo "ok: builder ini (unbounded memory, no disable_functions)"
    ;;
  cli|ext-builder)
    [[ "$mem" == "512M" ]] || { echo "FAIL: $FLAVOR memory_limit is '$mem', expected 512M"; exit 1; }
    met=$(docker run --rm "$IMAGE" php -r "echo ini_get('max_execution_time');")
    [[ "$met" == "0" ]] || { echo "FAIL: $FLAVOR max_execution_time is '$met', expected 0"; exit 1; }
    echo "ok: $FLAVOR ini (512M memory, unbounded execution time)"
    ;;
  fpm)
    [[ "$mem" == "256M" ]] || { echo "FAIL: fpm memory_limit is '$mem', expected 256M"; exit 1; }
    errlog=$(docker run --rm "$IMAGE" php -r "echo ini_get('error_log');")
    [[ "$errlog" == "/dev/stderr" ]] || { echo "FAIL: fpm error_log is '$errlog', expected /dev/stderr"; exit 1; }
    echo "ok: fpm ini (256M memory, error_log to /dev/stderr)"

    # FPM's *global* error_log (php-fpm.conf, not php.ini) is what
    # catch_workers_output's relayed lines actually go through -- ini_get()
    # above never sees this directive at all. The Dockerfile patches it away
    # from the stock file-based default so those lines reach `docker logs`
    # instead of vanishing into a file inside the container; this asserts
    # the patch actually landed, independently of whether the build-time
    # grep in the Dockerfile itself still matches on a future PHP bump.
    # grep -qx can itself fail (exit non-zero) when the line is absent, and
    # `var=$(failing command)` under set -e kills the script right there --
    # before a "FAIL: ..." message ever prints. Use if/else, like every
    # other docker-run assertion below, so a regression here is loud, not a
    # bare non-zero exit with no explanation.
    if docker run --rm "$IMAGE" grep -qx 'error_log = /proc/self/fd/2' /usr/local/etc/php-fpm.conf; then
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
hcid=$(docker create "$IMAGE")
docker cp "$hcid:/usr/local/bin/php" "$hard_dir/php" >/dev/null
docker cp "$hcid:/usr/local/lib/php-chmod-sanitize.so" "$hard_dir/php-chmod-sanitize.so" >/dev/null
mkdir -p "$hard_dir/ext"
docker cp "$hcid:$extdir/." "$hard_dir/ext" >/dev/null
# ImageMagick's libraries ship in every flavor (Dockerfile stages them via
# /deps-stage) and are dlopened into the same process as everything else, so
# they are covered here too. They are built through the same cflags.sh/
# ldflags.sh path and pass; including them is coverage that costs nothing.
mkdir -p "$hard_dir/im"
docker cp "$hcid:/opt/imagemagick/lib/." "$hard_dir/im" >/dev/null 2>&1 || true
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
# rejected. Without this the assertions below are only known to pass, never
# known to be capable of failing -- and an unparseable file producing empty
# readelf output is precisely how task 14's CF-5 check passed on a non-ELF.
# (scripts/test_elf_hardening.py carries the stronger controls: it builds
# deliberately partial-RELRO and executable-stack objects and requires the same
# script to reject each.)
printf 'not an elf\n' > "$hard_dir/notanelf"
if bash "$HERE/assert-elf-hardening.sh" "control" "$hard_dir/notanelf" >/dev/null 2>&1; then
  echo "FAIL: the hardening checker accepted a non-ELF file -- it fails open, so its results below mean nothing"; exit 1
fi
rm -f "$hard_dir/notanelf"
echo "ok: hardening checker rejects a non-ELF file (it fails closed)"

bash "$HERE/assert-elf-hardening.sh" --main "php-$EXPECT" "$hard_dir/php" || exit 1

# Task 37b: prove VM_COMPILER is not just a label someone typed, by reading
# the binary's own .comment section -- the one thing that says which compiler
# actually produced the object code, independently of any build arg or
# runtime label. No strings(1)/readelf inside the runtime image, so this reads
# the binary extracted to the host above, the same way assert-elf-hardening.sh
# does. .comment is not an allocated section but survives this project's
# `strip --strip-unneeded` (task 35 confirmed this against a real gcc16
# build): it carries one entry per distinct compiler that contributed any
# object file in the link, so a gcc build's php binary shows both "GCC: (GNU)
# 16.2.0" (php-src, compiled by the pinned toolchain) and Debian's own gcc
# (crt startup objects, always present, not something this build controls) --
# checked as presence of the expected compiler's line, not exact equality,
# since the crt noise is normal and expected on every build regardless of
# COMPILER.
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
module_files=("$hard_dir/php-chmod-sanitize.so")
[ -f "$hard_dir/php-fpm" ] && module_files+=("$hard_dir/php-fpm")
# shellcheck disable=SC2206  # both are deliberate globs/word-splits
module_files+=("$hard_dir"/ext/*.so $im_libs)
bash "$HERE/assert-elf-hardening.sh" "modules-$EXPECT" "${module_files[@]}" || exit 1

# RPATH/RUNPATH hygiene: every directory a shipped ELF names must exist in the
# image. libtool used to hardcode the GCC 16 toolchain's own lib dir
# (/opt/gcc16/lib64, via the stale libstdc++.la) into php, php-fpm and the C++
# extensions -- a directory only the build stage has. Harmless until someone
# creates it, and then that someone's libstdc++ wins over Debian's. Same
# extraction as the hardening check above, one container for the whole set.
rpath_hits=$(mktemp)
for f in "${module_files[@]}" "$hard_dir/php"; do
  dyn_out=$(readelf -dW "$f") || { echo "FAIL: readelf could not read the dynamic section of $(basename "$f")"; exit 1; }
  sed -n -E 's/.*\((RPATH|RUNPATH)\)[^[]*\[(.*)\].*/\2/p' <<<"$dyn_out" | tr ':' '\n' | grep -v '^$' \
    | sed "s|^|$(basename "$f") |" >> "$rpath_hits" || true
done
# Positive control: php carries /opt/imagemagick/lib on purpose (ldflags.sh), so
# a parser that found nothing would pass the check below by being blind.
grep -qx 'php /opt/imagemagick/lib' "$rpath_hits" \
  || { echo "FAIL: the RPATH scan did not see php's /opt/imagemagick/lib entry -- it would not see a bad one either: $(cat "$rpath_hits")"; exit 1; }
# $ORIGIN-relative entries resolve per file and are not a fixed directory.
rpath_dirs=$(awk '{ print $2 }' "$rpath_hits" | grep -v '^\$ORIGIN' | sort -u)
# shellcheck disable=SC2086  # the dir list is meant to word-split into arguments
rpath_missing=$(docker run --rm "$IMAGE" sh -c 'for d in "$@"; do [ -d "$d" ] || echo "$d"; done' sh $rpath_dirs)
if [ -n "$rpath_missing" ]; then
  echo "FAIL: RPATH/RUNPATH entries name directories that do not exist in the image:"
  while IFS= read -r d; do grep -F " $d" "$rpath_hits" | sed 's/^/  /'; done <<<"$rpath_missing"
  exit 1
fi
echo "ok: every RPATH/RUNPATH entry of php, php-fpm, the shared extensions and the vendored libraries names a directory present in the image ($(wc -l < "$rpath_hits") entries, $(wc -l <<<"$rpath_dirs") distinct dirs)"
rm -f "$rpath_hits"

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

# intl, against the ICU this version is supposed to have. Both of these came
# back from spike/verify.sh, which was deleted with the rest of spike/ -- and
# nothing here had covered intl since, so a build that silently picked up the
# wrong ICU passed green. ICU is the pin the whole legacy design rests on: the
# 7.0-7.3 range works against exactly one release (67.1, which is the last with
# both the U_USING_ICU_NAMESPACE escape hatch and the TRUE/FALSE macros
# ext/intl needs), so "which ICU did this image actually get" is not a detail.
#
# The expectation is derived, not listed. For the legacy era it comes from
# deps/build-deps.sh --pin, which reads deps/versions.lock with the same range
# arithmetic the builder uses. For the modern era there is no vendored ICU at
# all, so the expectation is whatever libicu the image itself carries, read out
# of the runtime image's own soname. Neither branch can drift from what the
# build did.
icu_reported=$(docker run --rm "$IMAGE" php -r 'echo INTL_ICU_VERSION;')
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
  icu_soname=$(docker run --rm "$IMAGE" sh -c 'ls /usr/lib/*/libicuuc.so.* 2>/dev/null | head -1')
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
fmt=$(docker run --rm "$IMAGE" php -r '$f=new NumberFormatter("de_DE",NumberFormatter::DECIMAL); echo $f->format(1234.5);')
[ "$fmt" = "1.234,5" ] || { echo "FAIL: intl de_DE formatting wrong: expected '1.234,5', got '$fmt'"; exit 1; }
echo "ok: intl formats de_DE correctly (1234.5 -> $fmt)"

# The endpoint both TLS checks below use. Overridable because these are the
# only two assertions in this script that need outbound HTTPS, and an
# egress-filtered CI runner would otherwise report every image as broken with a
# message blaming ext/curl or the CA store. One constant, so the positive and
# negative controls cannot drift onto different hosts.
TLS_URL="${BUILD_CHECK_TLS_URL:-https://www.php.net/}"

# A real TLS handshake through PHP's own openssl extension, not curl. This is
# the assertion that would have caught the legacy era's original bug: the
# vendored OpenSSL's compiled-in CA store pointed at an empty directory
# (openssl_get_cert_locations() reported /opt/php-deps/ssl/cert.pem and
# .../certs, neither real), so file_get_contents/stream_socket_client/
# SoapClient/SMTP+TLS all failed to verify the peer -- but curl_exec()
# resolves its own CA bundle independently of PHP's openssl config and never
# touched any of this, so a curl-only HTTPS check (what task 14 originally
# ran) stayed green on a build with no usable CA store at all. Applies to
# every flavor unconditionally, unlike the case block above -- file_get_
# contents works identically on fpm/cli/cli-builder.
body=$(docker run --rm -e TLS_URL="$TLS_URL" "$IMAGE" php -r '
$b = @file_get_contents(getenv("TLS_URL"));
echo $b === false ? "FAIL" : "OK:" . strlen($b);
')
[[ "$body" == OK:* ]] || { echo "FAIL: file_get_contents() over HTTPS failed (openssl CA store broken?): $body"; exit 1; }
echo "ok: TLS handshake via php's own openssl extension over $TLS_URL ($body)"

# Negative control: prove the check above can actually fail, not just
# tautologically pass -- point php at a CA file that cannot possibly verify
# anything and confirm the same kind of request now fails. Without this,
# "ok: TLS handshake..." above would carry the same false confidence the
# original curl-only check did.
broken=$(docker run --rm -e TLS_URL="$TLS_URL" "$IMAGE" php -d openssl.cafile=/nonexistent -r '
$b = @file_get_contents(getenv("TLS_URL"));
echo $b === false ? "FAIL" : "OK:" . strlen($b);
')
[[ "$broken" == "FAIL" ]] || { echo "FAIL: negative control did not fail with a bogus cafile (got: $broken) -- the TLS check above may be vacuous"; exit 1; }
echo "ok: negative control confirms the TLS check has discriminating power"

# ...and the same handshake through ext/curl, which is a *different* code path
# and the one deps/patches/php-7.4 and php-8.0 exist for. Their
# curl-openssl3-not-old patch stops ext/curl/config.m4's probe from concluding
# that trixie's libcurl is linked against a pre-1.1 OpenSSL; without it,
# HAVE_CURL_OLD_OPENSSL is defined, ext/curl reaches into OpenSSL 3's opaque
# structs, and every HTTPS curl_exec() segfaults while plain HTTP keeps
# working. Nothing here tested that: the openssl check above deliberately
# avoids curl (it exists because a curl-only check masked a broken CA store in
# task 14), so between the two of them curl_exec-over-TLS was the one path with
# no assertion at all -- and an image with a segfaulting HTTPS client would
# have passed this script. A segfault kills the child, so the failure shows up
# as an empty body and a non-zero exit, not as a PHP-level error.
#
# stderr is deliberately not folded in with 2>&1: the entrypoint writes an
# autotuning notice there on every run, and capturing it would make the
# comparison below fail on a perfectly healthy image.
body=$(docker run --rm -e TLS_URL="$TLS_URL" "$IMAGE" php -r '
$ch = curl_init(getenv("TLS_URL"));
curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 30]);
$b = curl_exec($ch);
echo $b === false ? "FAIL:" . curl_error($ch) : "OK:" . strlen($b);
') || { echo "FAIL: curl_exec() over HTTPS crashed the php process (exit $?): $body"; exit 1; }
[[ "$body" == OK:* ]] || { echo "FAIL: curl_exec() over HTTPS failed: $body"; exit 1; }
echo "ok: TLS handshake via ext/curl over $TLS_URL ($body)"

# Negative control for the same measurement channel: point curl at a CA file
# that cannot verify anything and require the request to fail. Without this,
# "ok: TLS handshake via ext/curl" would carry exactly the false confidence the
# openssl check above already learned to distrust.
broken_curl=$(docker run --rm -e TLS_URL="$TLS_URL" "$IMAGE" php -r '
$ch = curl_init(getenv("TLS_URL"));
curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 30,
                        CURLOPT_CAINFO => "/nonexistent"]);
$b = curl_exec($ch);
echo $b === false ? "FAIL" : "OK:" . strlen($b);
')
[[ "$broken_curl" == "FAIL" ]] || { echo "FAIL: curl negative control did not fail with a bogus CA file (got: $broken_curl) -- the curl TLS check above may be vacuous"; exit 1; }
echo "ok: negative control confirms the ext/curl check has discriminating power"

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
  docker run --rm "$IMAGE" sh -c 'command -v sh' >/dev/null 2>&1 \
    || { echo "FAIL: $1: the toolchain probe cannot run a shell in the image, so its absence checks would prove nothing"; exit 1; }
  local found
  found=$(docker run --rm "$IMAGE" sh -c '
    for t in gcc g++ cc c++ cpp clang clang++ as ld ld.bfd ld.gold ld.lld lld gold \
             x86_64-linux-gnu-gcc x86_64-linux-gnu-g++ x86_64-linux-gnu-as x86_64-linux-gnu-ld \
             aarch64-linux-gnu-gcc aarch64-linux-gnu-g++ aarch64-linux-gnu-as aarch64-linux-gnu-ld \
             autoconf phpize php-config; do
      command -v "$t"
    done
    for p in /usr/local/include/php /usr/include/php; do test -e "$p" && echo "$p"; done
    exit 0' 2>&1) || { echo "FAIL: $1: the toolchain probe did not run: $found"; exit 1; }
  [ -z "$found" ] \
    || { echo "FAIL: $1 carries a compiler, assembler, linker, autoconf, phpize/php-config or the PHP headers (expected only in ext-builder): $(tr '\n' ' ' <<<"$found")"; exit 1; }
}
case "$FLAVOR" in
  ext-builder)
    for tool in gcc g++ make autoconf pkg-config phpize php-config; do
      docker run --rm "$IMAGE" sh -c "command -v $tool" >/dev/null \
        || { echo "FAIL: ext-builder is missing $tool (Dockerfile's ext-builder stage should provide it)"; exit 1; }
    done
    docker run --rm "$IMAGE" test -f /usr/local/include/php/main/php.h \
      || { echo "FAIL: ext-builder has no PHP headers under /usr/local/include/php"; exit 1; }
    for tool in composer node npm; do
      if docker run --rm "$IMAGE" sh -c "command -v $tool" >/dev/null 2>&1; then
        echo "FAIL: ext-builder carries $tool -- it is a compile stage, composer and node belong to cli-builder"; exit 1
      fi
    done
    echo "ok: ext-builder carries a compiler, g++, make, autoconf, pkg-config, phpize/php-config and the PHP headers, and no composer/node"

    # php-config has to describe the runtime it sits in: the extension dir
    # names the Zend module API, so equal dirs mean an extension built here
    # loads in the fpm/cli image of the same version.
    pc_dir=$(docker run --rm "$IMAGE" php-config --extension-dir)
    rt_dir=$(docker run --rm "$IMAGE" php -r 'echo ini_get("extension_dir");')
    [ -n "$pc_dir" ] && [ "$pc_dir" = "$rt_dir" ] \
      || { echo "FAIL: php-config --extension-dir ('$pc_dir') != the runtime's extension_dir ('$rt_dir')"; exit 1; }
    pc_ver=$(docker run --rm "$IMAGE" php-config --version)
    [ "$pc_ver" = "$RELEASE" ] || { echo "FAIL: php-config --version is '$pc_ver', expected $RELEASE"; exit 1; }
    echo "ok: php-config matches the runtime ($pc_ver, extension_dir $pc_dir)"

    # The real thing, small: compile tests/fixtures/ext-hello with
    # phpize/configure/make, install it under a scratch root and load that .so
    # into this image's own php. The cross-image half (copy into fpm and cli,
    # PHP_EXT_ENABLE) is tests/test-ext-builder.sh, which needs all three
    # images of a version and so cannot run from one build leg.
    hello_out=$(docker run --rm --init -v "$HERE/fixtures/ext-hello":/src:ro "$IMAGE" \
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
      docker run --rm "$IMAGE" sh -c "command -v $tool" >/dev/null \
        || { echo "FAIL: cli-builder is missing $tool (Dockerfile's cli-builder stage should provide it)"; exit 1; }
    done
    node_major=$(docker run --rm "$IMAGE" node -p 'process.versions.node.split(".")[0]')
    [ "$node_major" = "24" ] || { echo "FAIL: cli-builder's node major is '$node_major', expected 24 (copied from the node:24 image)"; exit 1; }
    for cmd in "npm --version" "npx --version" "corepack --version" "composer --version" "semantic-release --version"; do
      docker run --rm "$IMAGE" sh -c "$cmd" >/dev/null 2>&1 \
        || { echo "FAIL: cli-builder: '$cmd' does not run as the image user"; exit 1; }
    done
    # npm and corepack cache under HOME by default, and uid 33's HOME (/var/www)
    # does not exist: `npm ci` as the image user fails unless both caches point
    # somewhere writable.
    for probe in "npm config get cache" 'printenv COREPACK_HOME'; do
      cache_dir=$(docker run --rm "$IMAGE" sh -c "$probe") \
        || { echo "FAIL: cli-builder: '$probe' failed as the image user"; exit 1; }
      [ -n "$cache_dir" ] && [ "$cache_dir" != undefined ] \
        || { echo "FAIL: cli-builder: '$probe' printed '$cache_dir'"; exit 1; }
      docker run --rm "$IMAGE" sh -c 'mkdir -p "$1" && t=$(mktemp -p "$1") && rm -f "$t"' sh "$cache_dir" \
        || { echo "FAIL: cli-builder: $cache_dir ('$probe') is not writable as the image user (uid $(docker run --rm "$IMAGE" id -u))"; exit 1; }
    done
    echo "ok: cli-builder's npm and corepack caches are writable as the image user"
    echo "ok: cli-builder carries node $node_major, npm, npx, corepack, composer, semantic-release, git, rsync, patch, make, brotli, sqlite3, jq, less, nano, procps, unzip, zip, zstd and the mariadb client"
    ;;
  cli|fpm)
    no_toolchain "$FLAVOR"
    echo "ok: $FLAVOR carries no compiler"
    ;;
esac

if [ "$FLAVOR" = fpm ]; then
  # Build-time already runs `RUN php-fpm -t` (Dockerfile), which protects the
  # build but not a published image someone pulls later and runs as-is --
  # CF-51 wants this asserted against the shipped image too.
  if docker run --rm --entrypoint php-fpm "$IMAGE" -t >/dev/null 2>&1; then
    echo "ok: php-fpm -t against the shipped config"
  else
    echo "FAIL: php-fpm -t failed against the image's own shipped config"; exit 1
  fi

  # CF-51: php-fpm has to actually start and serve, under its own default
  # entrypoint/CMD -- no overrides -- not merely parse its config. This is
  # the gap that let three DOA images (task 16: 7.0/7.1/7.2 could not start
  # FPM at all) pass "all 11 versions PASS" at 27 CLI-only assertions.
  # test-fpm-health.sh already does exactly this: starts the image unmodified,
  # waits for its baked HEALTHCHECK to report healthy, drives a real FastCGI
  # request through cgi-fcgi that executes a PHP script and asserts its
  # output, and carries its own negative control (the pool down -> the
  # healthcheck reports unhealthy). Reused rather than duplicated.
  bash "$HERE/test-fpm-health.sh" "$IMAGE"
fi

# What the compile did, not just what the image contains -- delegated because
# test-pgo.sh already derives its own expectation from matrix.json and this
# script would otherwise be duplicating that lookup. Runs regardless of
# flavor: the php binary and its PGO profile are built once and shared by
# fpm/cli/cli-builder alike. SMOKE_SKIP_PGO exists for a bootstrap image built
# with PGO=false ahead of what matrix.json now says for it (the corpus
# chicken-and-egg: a cli-builder built to seed the very corpus PGO training
# needs) -- an explicit, named escape hatch rather than a silent skip.
if [ "${SMOKE_SKIP_PGO:-}" = "1" ]; then
  echo "WARNING: PGO check skipped because SMOKE_SKIP_PGO=1 -- only meant for a known-bootstrap image that predates matrix.json's current pgo setting." >&2
elif [ "$PGO" = true ]; then
  bash "$HERE/test-pgo.sh" "$IMAGE" "$EXPECT"
else
  echo "ok: PGO check skipped -- matrix.json says php $EXPECT is pgo=false"
fi

# T29b: mariadb-server is apt-get installed inside the php-build stage only,
# to run PGO training's prestashop corpus app (task 29a/29b) -- the corpus
# ships only the app tree and a populated datadir, never the server binary,
# and runtime-base only COPYs specific /usr/local/... paths out of php-build,
# none of which that apt install ever touches. Checked directly here rather
# than trusted by construction: neither the server nor the client-side tools
# training needs to start it may exist on a shipped image.
#
# T14-G: this is an absence assertion (`if command -v $b` succeeds, FAIL), and
# the same failure shape as every other absence check in this file -- a
# container that never started at all (a crashed entrypoint, a daemon that
# rejected the run) makes `docker run` itself exit non-zero, which reads
# exactly like "command -v found nothing", and the loop below would report
# every binary absent having executed nothing. Prove the instrument works
# first: something that is definitely on this image must be found the same
# way the loop below looks for absence.
control_bin=$(docker run --rm "$IMAGE" sh -c "command -v php" 2>/dev/null || true)
[ -n "$control_bin" ] \
  || { echo "FAIL: docker run $IMAGE sh -c 'command -v php' produced nothing -- the container may not even start, so the mariadb-absence loop below would prove nothing"; exit 1; }
echo "ok: control -- the image runs and 'command -v' finds php ($control_bin), so the absence loop below can be trusted"

for b in mariadbd mysqld mariadb-install-db mysql_install_db; do
  if docker run --rm "$IMAGE" sh -c "command -v $b" >/dev/null 2>&1; then
    echo "FAIL: $b is present in the runtime image -- mariadb-server leaked out of the php-build stage"
    exit 1
  fi
done
echo "ok: mariadb-server binaries (mariadbd, mysqld, mariadb-install-db, mysql_install_db) absent from the runtime image"

# T19-I: test-entrypoint.sh used to run only for the fpm flavor (most of its
# assertions drive `php-fpm -tt`, which does not exist outside it), with
# cli/cli-builder coverage of everything else in that file -- the
# disable_functions cases (T19-B) chief among them -- faked by deriving a
# second "companion" image tag and silently skipping when it was not present,
# never actually exercising the real cli/cli-builder images even when it
# was. Fixed at both ends: test-entrypoint.sh itself now takes the flavor and
# gates only its genuinely fpm-pool-specific assertions on it, and this call
# now runs once per flavor against the image actually under test, no
# companion tag involved.
#
# test-snuffleupagus.sh's behavioural/security assertions (CF-34, CF-42) stay
# fpm-only, unchanged -- out of T19-I's scope, and its own probes already
# branch on the image's flavor (cli-builder-only system()/eval_blacklist
# cases) when it is called directly for those.
if [ "$FLAVOR" = ext-builder ]; then
  # Same entrypoint and same cli ini as the cli flavor, which test-entrypoint.sh
  # already covers; its assertions are written for the uid-33 runtime flavors
  # and ext-builder runs as root, so they are not repeated here.
  echo "ok: test-entrypoint.sh skipped for ext-builder (identical entrypoint to cli, runs as root)"
else
  bash "$HERE/test-entrypoint.sh" "$IMAGE" "$FLAVOR"
fi
# Only where the registry builds it at all (ext.json: php >=7.2) -- 7.0 and
# 7.1 ship without it, so there is nothing to exercise there.
if [ "$FLAVOR" = fpm ] && grep -qw snuffleupagus <<<"$SHARED_EXTS"; then
  bash "$HERE/test-snuffleupagus.sh" "$IMAGE"
fi

echo "SMOKE PASSED"
