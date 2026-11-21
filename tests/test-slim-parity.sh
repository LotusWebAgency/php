#!/usr/bin/env bash
# Slim parity: a slim flavor must carry the same PHP build as its full flavor.
#
#   tests/test-slim-parity.sh SLIM_IMAGE FULL_IMAGE
#
# php, php-fpm (when either image has it) and every extension .so must be
# byte-identical (sha256), and everything under /usr/local/etc (php.ini conf.d, the
# Snuffleupagus rulesets, php-fpm.conf and php-fpm.d) must match file for file,
# including symlink targets. The probe runs inside each image with `busybox <applet>`
# only, so it works on slim (no find, sort, sha256sum or apk there) and full images
# alike.
# Fails with a unified diff of the two manifests.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 SLIM_IMAGE FULL_IMAGE" >&2
  exit 2
fi
SLIM_IMAGE="$1"
FULL_IMAGE="$2"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=docker-lib.sh
. "$HERE/docker-lib.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/slim-parity-XXXXXX")"
trap 'rm -rf "$work"' EXIT

# One manifest line per entry: "<kind> <sha256|target> <path>", sorted by path.
# Executables and extensions are looked up in the places the build puts them;
# a missing one is recorded as "absent" so a binary present in only one image
# shows up in the diff.
probe='
extdir=$(/usr/local/bin/php -n -r "echo ini_get(\"extension_dir\");") || exit 1
[ -n "$extdir" ] || { echo "FATAL: php reports no extension_dir" >&2; exit 1; }
hash_file() { printf "file %s %s\n" "$(busybox sha256sum "$1" | busybox cut -d" " -f1)" "$1"; }
for bin in /usr/local/bin/php /usr/local/sbin/php-fpm; do
  if [ -e "$bin" ]; then hash_file "$bin"; else printf "absent - %s\n" "$bin"; fi
done
for dir in "$extdir" /usr/local/etc; do
  [ -d "$dir" ] || { printf "absent - %s/\n" "$dir"; continue; }
  busybox find "$dir" -type f | while read -r f; do hash_file "$f"; done
  busybox find "$dir" -type l | while read -r l; do printf "link %s %s\n" "$(busybox readlink "$l")" "$l"; done
done
exit 0
'

manifest() {  # manifest <image> <outfile>
  local image="$1" out="$2"
  local raw="$out.raw"
  docker run --rm --init --label claude.adhoc=1 "${DRUN_FLAGS[@]}" --entrypoint busybox "$image" \
    timeout 120 sh -c "$probe" >"$raw" || { echo "FAIL: the manifest probe failed in $image"; exit 1; }
  LC_ALL=C sort -k3 "$raw" >"$out"
  rm -f "$raw"
}

manifest "$SLIM_IMAGE" "$work/slim.txt"
manifest "$FULL_IMAGE" "$work/full.txt"

# Controls: an empty or php-less manifest would make two broken images look equal.
for m in slim full; do
  grep -q ' /usr/local/bin/php$' "$work/$m.txt" && ! grep -q '^absent - /usr/local/bin/php$' "$work/$m.txt" \
    || { echo "FAIL: control: the $m manifest has no php binary"; exit 1; }
  grep -qE '^file [0-9a-f]{64} .*\.so$' "$work/$m.txt" \
    || { echo "FAIL: control: the $m manifest lists no extension .so"; exit 1; }
  grep -qE '^file [0-9a-f]{64} /usr/local/etc/php/' "$work/$m.txt" \
    || { echo "FAIL: control: the $m manifest lists no ini file"; exit 1; }
done

if ! diff -u --label "slim: $SLIM_IMAGE" --label "full: $FULL_IMAGE" "$work/slim.txt" "$work/full.txt" >"$work/diff.txt"; then
  echo "FAIL: $SLIM_IMAGE and $FULL_IMAGE do not carry the same PHP build"
  cat "$work/diff.txt"
  exit 1
fi

so_count=$(grep -cE '^file [0-9a-f]{64} .*\.so$' "$work/slim.txt")
ini_count=$(grep -cE " /usr/local/etc/" "$work/slim.txt")
echo "ok: slim parity -- php, php-fpm (if present), $so_count extension .so files and $ini_count ini-tree entries are identical between $SLIM_IMAGE and $FULL_IMAGE"
