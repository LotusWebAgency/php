#!/usr/bin/env bash
# Slim parity: a slim flavor must carry the same PHP build as its full flavor.
#
#   tests/test-slim-parity.sh [--full-is-builder] SLIM_IMAGE FULL_IMAGE
#
# php, php-fpm (when either image has it), php-fpm-healthcheck, the chmod shim, every
# extension .so and every file under /usr/local/{etc,bin,sbin,lib} and
# /usr/local/share/php-build must be identical (sha256) between the two images, and
# symlinks must have the same targets. The probe runs inside each image with
# `busybox <applet>` only, so it works on slim (no find, sort, sha256sum or apk
# there) and full images alike. A file that cannot be hashed fails the probe.
#
# --full-is-builder: FULL_IMAGE is cli-builder, which is cli plus a toolchain on the
# same php (the cli-slim rider is built and tested with it). Two deliberate
# differences are accounted for: cli-builder replaces conf.d/10-php.ini with
# conf/php-builder.ini, so the slim image's copy must instead equal conf/php-cli.ini
# from this checkout (what the plain cli flavor bakes in); and composer, npm, npx,
# semantic-release and /usr/local/lib/node_modules exist only in the builder, so they
# are left out of its manifest and the slim image must not have them.
# Fails with a unified diff of the two manifests.
set -euo pipefail

usage() { echo "usage: $0 [--full-is-builder] SLIM_IMAGE FULL_IMAGE" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

full_only_paths=()
slim_file_paths=()
slim_file_sources=()
while [ $# -gt 0 ]; do
  case "$1" in
    --full-is-builder)
      full_only_paths=(/usr/local/bin/composer /usr/local/bin/npm /usr/local/bin/npx
        /usr/local/bin/semantic-release /usr/local/lib/node_modules)
      slim_file_paths=(/usr/local/etc/php/conf.d/10-php.ini)
      slim_file_sources=("$HERE/../conf/php-cli.ini")
      shift
      ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -eq 2 ] || usage
SLIM_IMAGE="$1"
FULL_IMAGE="$2"

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
list=$(busybox mktemp) || exit 1
hash_file() {
  h=$(busybox sha256sum "$1") || { echo "FATAL: cannot hash $1" >&2; exit 1; }
  printf "file %s %s\n" "${h%% *}" "$1"
}
for bin in /usr/local/bin/php /usr/local/sbin/php-fpm /usr/local/bin/php-fpm-healthcheck /usr/local/lib/php-chmod-sanitize.so; do
  if [ -e "$bin" ]; then hash_file "$bin"; else printf "absent - %s\n" "$bin"; fi
done
for dir in "$extdir" /usr/local/etc /usr/local/bin /usr/local/sbin /usr/local/lib /usr/local/share/php-build; do
  [ -d "$dir" ] || { printf "absent - %s/\n" "$dir"; continue; }
  busybox find "$dir" -type f >"$list" || exit 1
  while read -r f; do hash_file "$f"; done <"$list"
  busybox find "$dir" -type l >"$list" || exit 1
  while read -r l; do printf "link %s %s\n" "$(busybox readlink "$l")" "$l"; done <"$list"
done
busybox rm -f "$list"
exit 0
'

manifest() {  # manifest <image> <outfile>
  local image="$1" out="$2"
  local raw="$out.raw"
  docker run --rm --init --label claude.adhoc=1 "${DRUN_FLAGS[@]}" --entrypoint busybox "$image" \
    timeout 120 sh -c "$probe" >"$raw" || { echo "FAIL: the manifest probe failed in $image"; exit 1; }
  LC_ALL=C sort -u -k3 "$raw" >"$out"
  rm -f "$raw"
}

manifest "$SLIM_IMAGE" "$work/slim.txt"
manifest "$FULL_IMAGE" "$work/full.txt"

# Controls: an empty or php-less manifest would make two broken images look equal.
for m in slim full; do
  grep -qvE '^(file [0-9a-f]{64}|link [^ ]+|absent -) /' "$work/$m.txt" \
    && { echo "FAIL: control: the $m manifest has a malformed line"; exit 1; }
  grep -q ' /usr/local/bin/php$' "$work/$m.txt" && ! grep -q '^absent - /usr/local/bin/php$' "$work/$m.txt" \
    || { echo "FAIL: control: the $m manifest has no php binary"; exit 1; }
  grep -qE '^file [0-9a-f]{64} .*\.so$' "$work/$m.txt" \
    || { echo "FAIL: control: the $m manifest lists no extension .so"; exit 1; }
  grep -qE '^file [0-9a-f]{64} /usr/local/etc/php/' "$work/$m.txt" \
    || { echo "FAIL: control: the $m manifest lists no ini file"; exit 1; }
done

# Deliberate overrides: the slim copy must equal the repo file, then the path is
# dropped from the image-to-image comparison.
for i in "${!slim_file_paths[@]}"; do
  path="${slim_file_paths[$i]}"
  source_file="${slim_file_sources[$i]}"
  [ -f "$source_file" ] || { echo "FAIL: --slim-file source $source_file is not a file"; exit 1; }
  want="$(sha256sum "$source_file" | cut -d' ' -f1)"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: cannot hash $source_file"; exit 1; }
  grep -qx "file $want $path" "$work/slim.txt" \
    || { echo "FAIL: $path in $SLIM_IMAGE is not $source_file ($(grep " $path\$" "$work/slim.txt" || echo missing))"; exit 1; }
  for m in slim full; do
    awk -v p="$path" '$3 != p' "$work/$m.txt" >"$work/$m.filtered"
    mv "$work/$m.filtered" "$work/$m.txt"
  done
done

for path in "${full_only_paths[@]}"; do
  awk -v p="$path" '$3 != p && index($3, p "/") != 1' "$work/full.txt" >"$work/full.filtered"
  mv "$work/full.filtered" "$work/full.txt"
done

if ! diff -u --label "slim: $SLIM_IMAGE" --label "full: $FULL_IMAGE" "$work/slim.txt" "$work/full.txt" >"$work/diff.txt"; then
  echo "FAIL: $SLIM_IMAGE and $FULL_IMAGE do not carry the same PHP build"
  cat "$work/diff.txt"
  exit 1
fi

so_count=$(grep -cE '^file [0-9a-f]{64} .*\.so$' "$work/slim.txt")
file_count=$(grep -c '^file ' "$work/slim.txt")
echo "ok: slim parity -- $file_count files ($so_count .so) under php, ini, /usr/local/{bin,sbin,lib} are identical between $SLIM_IMAGE and $FULL_IMAGE; ${#slim_file_paths[@]} overridden and ${#full_only_paths[@]} full-only path(s) accounted for"
