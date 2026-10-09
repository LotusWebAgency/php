#!/usr/bin/env bash
# Fetch one pinned source from apps.lock and verify its sha256. Runs inside
# the fixture builder container (build-fixture.sh mounts tests/apps at
# /apptest and a download cache at /cache), so it only relies on what every
# stock image has: bash, curl, sha256sum.
#
#   fetch.sh <name> <set> <dest>    fetch and verify ("-" rows match any set)
#   fetch.sh --pin <name> <set>     print the pinned version and exit
#
# Verified bytes are cached by sha256, so rebuilding a fixture does not
# re-download it and a flaky upstream does not break a rebuild.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="${APPTEST_LOCK:-$HERE/apps.lock}"
CACHE="${APPTEST_CACHE:-/cache}"

lookup() {
  local want_name="$1" want_set="$2" name set version sha url hits=0 out=""
  while read -r name set version sha url; do
    case "$name" in ''|\#*) continue ;; esac
    [ "$name" = "$want_name" ] || continue
    [ "$set" = "$want_set" ] || [ "$set" = "-" ] || continue
    hits=$((hits + 1))
    out="$version $sha $url"
  done < "$LOCK"
  [ "$hits" -le 1 ] || { echo "FATAL: $LOCK has $hits rows for $want_name/$want_set" >&2; return 2; }
  [ "$hits" -eq 1 ] || { echo "FATAL: $LOCK has no row for $want_name/$want_set" >&2; return 1; }
  printf '%s\n' "$out"
}

if [ "${1:-}" = "--pin" ]; then
  row="$(lookup "${2:?name}" "${3:?set}")"
  echo "${row%% *}"
  exit 0
fi

name="${1:?usage: fetch.sh <name> <set> <dest>}"
set="${2:?usage: fetch.sh <name> <set> <dest>}"
dest="${3:?usage: fetch.sh <name> <set> <dest>}"
read -r version sha url <<<"$(lookup "$name" "$set")"
case "$url" in docker://*) echo "FATAL: $name/$set is an image pin ($url) -- the host side copies it, not fetch.sh" >&2; exit 1 ;; esac

# `latest`: PrestaShop's en-US translation pack only, which upstream re-exports in place,
# so it is held to its shape rather than a hash and is not cached.
if [ "$sha" = latest ]; then
  [ "$name" = prestashop-lang ] || { echo "FATAL: $name/$set: only prestashop-lang rows may be 'latest', everything else pins a sha256" >&2; exit 1; }
  echo "=== fetching $name $version (latest)"
  curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 20 -o "$dest.part" "$url"
  size="$(stat -c %s "$dest.part")"
  [ "$size" -le 16777216 ] || { rm -f "$dest.part"; echo "FATAL: $name $version is $size bytes, a translation pack is well under 16 MiB" >&2; exit 1; }
  php -r '
    $z = new ZipArchive();
    if ($z->open($argv[1]) !== true) { fwrite(STDERR, "not a zip archive\n"); exit(1); }
    $xlf = 0;
    for ($i = 0; $i < $z->numFiles; $i++) {
      $n = $z->getNameIndex($i);
      if ($n === "en-US/") continue;
      if (!preg_match("~^en-US/[A-Za-z0-9._-]+\.xlf$~", $n)) { fwrite(STDERR, "unexpected entry: $n\n"); exit(1); }
      $xlf++;
    }
    if ($xlf === 0) { fwrite(STDERR, "no en-US/*.xlf entries\n"); exit(1); }
    echo "$xlf en-US/*.xlf files\n";
  ' "$dest.part" || { rm -f "$dest.part"; echo "FATAL: $name $version is not an en-US translation pack ($url)" >&2; exit 1; }
  echo "fetched $name $version: sha256 $(sha256sum "$dest.part" | cut -d' ' -f1), $size bytes"
  mv "$dest.part" "$dest"
  exit 0
fi

mkdir -p "$CACHE"
cached="$CACHE/$sha"
if [ -f "$cached" ] && echo "$sha  $cached" | sha256sum -c - >/dev/null 2>&1; then
  echo "=== $name $version (cached)"
else
  echo "=== fetching $name $version"
  tmp="$cached.part.$$"
  curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 20 -o "$tmp" "$url"
  got="$(sha256sum "$tmp" | cut -d' ' -f1)"
  if [ "$got" != "$sha" ]; then
    rm -f "$tmp"
    echo "FATAL: $name $version sha256 mismatch: expected $sha, got $got ($url)" >&2
    exit 1
  fi
  mv "$tmp" "$cached"
fi
cp "$cached" "$dest"
