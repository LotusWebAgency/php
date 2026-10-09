#!/usr/bin/env bash
# Resolve one pinned corpus source from php/pgo/corpus.lock, fetch it, verify its
# sha256. Same shape as deps/build-deps.sh: one lock file, one fetch helper, no
# unpinned URL anywhere in the build.
#
# The fetch goes through fetch-verified.sh, which caches by sha256 in
# /var/cache/src so a GitHub/wordpress.org outage mid-build can be served from a
# previous fetch. It is a byte-identical copy of deps/fetch-verified.sh
# (scripts/test_fetch_verified_sync.py enforces it) because this Dockerfile's build
# context is php/pgo, which cannot reach deps/.
#
#   fetch.sh <tier> <name> <dest>   fetch and verify
#   fetch.sh --pin <tier> <name>    print the pinned version and exit
#
# --pin lets tests/test-corpus.sh compare an image against the version corpus.lock
# pins without transcribing it into a second place.
#
# Lookup is an exact tier match: corpus.lock names one tier per row, so no broader
# row can shadow a specific one, and a duplicate (tier, name) is a hard error.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="${CORPUS_LOCK:-${HERE}/../corpus.lock}"

lookup() {  # lookup <tier> <name> -> "version sha url" on stdout
  local want_tier="$1" want_name="$2" tier name version sha url hits=0 out=""
  while read -r tier name version sha url; do
    case "$tier" in ''|\#*) continue ;; esac
    [ "$name" = "$want_name" ] || continue
    [ "$tier" = "$want_tier" ] || continue
    hits=$((hits + 1))
    out="$version $sha $url"
  done < "$LOCK"
  [ "$hits" -le 1 ] || { echo "FATAL: $LOCK has $hits rows for tier $want_tier name $want_name" >&2; return 2; }
  [ "$hits" -eq 1 ] || return 1
  printf '%s\n' "$out"
}

if [ "${1:-}" = "--pin" ]; then
  tier="${2:?usage: fetch.sh --pin <tier> <name>}"
  name="${3:?usage: fetch.sh --pin <tier> <name>}"
  row="$(lookup "$tier" "$name")" || { echo "FATAL: no $name row for tier $tier in $LOCK" >&2; exit 1; }
  echo "${row%% *}"
  exit 0
fi

tier="${1:?usage: fetch.sh <tier> <name> <dest>}"
name="${2:?usage: fetch.sh <tier> <name> <dest>}"
dest="${3:?usage: fetch.sh <tier> <name> <dest>}"

row="$(lookup "$tier" "$name")" || { echo "FATAL: no $name row for tier $tier in $LOCK" >&2; exit 1; }
read -r version sha url <<<"$row"

# `latest` in the sha column is the one row kind allowed to float: PrestaShop's
# en-US translation pack (corpus.lock has why). With no hash to hold it to, it is
# held to its shape (a small zip of en-US/*.xlf and nothing else) and not cached.
if [ "$sha" = latest ]; then
  [ "$name" = prestashop-lang ] || { echo "FATAL: $name: only prestashop-lang rows may be 'latest', everything else pins a sha256" >&2; exit 1; }
  echo "=== fetching $name $version (latest)"
  curl -fsSL --retry 20 --retry-all-errors --retry-delay 5 --connect-timeout 10 -o "$dest.part" "$url"
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

echo "=== fetching $name $version"
bash "${HERE}/fetch-verified.sh" "$url" "$sha" "$dest"
