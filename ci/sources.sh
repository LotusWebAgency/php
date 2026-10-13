#!/usr/bin/env bash
# Warm BuildKit's php-src-cache mount from a CI-restored directory, so a fresh
# runner does not re-download the same source tarballs in every build leg.
#
#   ci/sources.sh list          print "<sha256> <url> <cache-entry>" for every sha-pinned download
#   ci/sources.sh fetch <dir>   download whatever <dir> lacks (verified, via deps/fetch-verified.sh), drop unlisted entries
#   ci/sources.sh seed <dir>    copy <dir> into the php-src-cache mount of the current buildx builder
#
# deps/fetch-verified.sh names a cache entry by its sha256 alone, so the third
# column is that sha256 again: it is the file name fetch-verified.sh looks up in
# /var/cache/src, and <dir> is laid out the same way.
#
# Enumerated from the lock files the build reads, nothing else:
#   php/php-src.lock    php.net tarball and its .asc, per PHP release (Dockerfile)
#   php/pecl.lock       every PECL row incl. name@X.Y overrides (fetch-pecl.sh, build-shared-ext.sh);
#                       source=github rows take their URL from php/ext.json
#   deps/versions.lock  vendored libraries (build-deps.sh, build-imagemagick.sh, build-netsnmp.sh)
#   php/pgo/corpus.lock PGO corpus sources (php/pgo/corpus/fetch.sh)
# Not listed: `latest` rows (prestashop-lang, not sha-pinned) and docker:// rows (images).
#
# The cache never changes what a build produces: fetch-verified.sh re-checks the
# sha256 of every entry it reads, and a mount's content is not part of a BuildKit
# step's cache key, so a stale or empty seed costs a download, never correctness.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

# Must match the Dockerfile's mounts byte for byte (id, target, sharing, uid, gid):
# any difference makes BuildKit mount a different cache. Dockerfile uses the root
# spec; php/pgo/Dockerfile.corpus mounts the same id as uid=33,gid=33.
CACHE_TARGET=/var/cache/src
CACHE_ID=php-src-cache
CACHE_SHARING=locked

usage() {
  echo "usage: ci/sources.sh list | fetch <dir> | seed <dir>" >&2
  exit 2
}

list() {
  local release tar_sha asc_sha name version sha url era tier
  {
    # php-src.lock: release, tar.xz sha256, .asc sha256
    while read -r release tar_sha asc_sha _; do
      case "$release" in ''|\#*) continue ;; esac
      echo "$tar_sha https://www.php.net/distributions/php-${release}.tar.xz"
      echo "$asc_sha https://www.php.net/distributions/php-${release}.tar.xz.asc"
    done < php/php-src.lock

    # pecl.lock: name[@X.Y], version, sha256, php-min, php-max. A github-sourced
    # extension has no PECL package; its URL (which pins the tag) is in ext.json.
    local github_urls
    github_urls="$(jq -r '.extensions[] | select(.source == "github") | "\(.name) \(.url)"' php/ext.json)"
    while read -r name version sha _; do
      case "$name" in ''|\#*) continue ;; esac
      url="$(awk -v n="$name" '$1 == n { print $2 }' <<<"$github_urls")"
      [ -n "$url" ] || url="https://pecl.php.net/get/${name%%@*}-${version}.tgz"
      echo "$sha $url"
    done < php/pecl.lock

    # versions.lock: era, name, version, applies-to, sha256, url
    while read -r era _ _ _ sha url; do
      case "$era" in ''|\#*) continue ;; esac
      echo "$sha $url"
    done < deps/versions.lock

    # corpus.lock: tier, name, version, sha256|latest, url
    while read -r tier _ _ sha url; do
      case "$tier" in ''|\#*) continue ;; esac
      case "$sha" in latest) continue ;; esac
      case "$url" in docker://*) continue ;; esac
      echo "$sha $url"
    done < php/pgo/corpus.lock
  } | awk '
    $1 !~ /^[0-9a-f]{64}$/ { print "ci/sources.sh: not a sha256: " $0 > "/dev/stderr"; bad = 1; next }
    !seen[$1]++ { print $1, $2, $1 }
    END { exit bad }
  '
}

need_dir() {
  [ -n "${1:-}" ] || usage
}

fetch() {
  local dir="$1" sha url entry scratch
  mkdir -p "$dir"
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' RETURN
  local rows
  rows="$(list)"
  local total fetched=0 skipped=0
  total="$(wc -l <<<"$rows")"
  # Entries whose pin is gone would otherwise ride along in every restored
  # cache and seed forever.
  local f keep
  keep="$(awk '{print $3}' <<<"$rows")"
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    grep -qxF "$(basename "$f")" <<<"$keep" || rm -f "$f"
  done
  while read -r sha url entry; do
    if [ -f "$dir/$entry" ] && echo "${sha}  ${dir}/${entry}" | sha256sum -c - >/dev/null 2>&1; then
      skipped=$((skipped + 1))
      continue
    fi
    rm -f "${dir:?}/${entry}"
    # fetch-verified.sh downloads, checks the sha256 and stores the entry in
    # FETCH_VERIFIED_CACHE_DIR; the copy it also writes to <dest> is discarded.
    FETCH_VERIFIED_CACHE_DIR="$dir" RETRY_KIND=http \
      "$ROOT/ci/retry.sh" bash "$ROOT/deps/fetch-verified.sh" "$url" "$sha" "$scratch/dl"
    rm -f "$scratch/dl"
    [ -f "$dir/$entry" ] || { echo "ci/sources.sh: $url was not stored in $dir" >&2; exit 1; }
    fetched=$((fetched + 1))
  done <<<"$rows"
  echo "ci/sources.sh: ${total} sources, ${fetched} fetched, ${skipped} already in ${dir}" >&2
}

seed() {
  local dir="$1" base_image
  [ -d "$dir" ] || { echo "ci/sources.sh: $dir is not a directory" >&2; exit 1; }
  base_image="$(sed -n 's/^ARG BASE_IMAGE=//p' Dockerfile | head -n 1)"
  case "$base_image" in *@sha256:*) ;; *) echo "ci/sources.sh: no digest-pinned BASE_IMAGE in Dockerfile" >&2; exit 1 ;; esac

  # Only the sha256-named entries; fetch-verified.sh's temp files are skipped.
  local seedctx entries=0 f
  seedctx="$(mktemp -d)"
  trap 'rm -rf "$seedctx"' RETURN
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    printf '%s\n' "$(basename "$f")" | grep -Eq '^[0-9a-f]{64}$' || continue
    cp "$f" "$seedctx/"
    entries=$((entries + 1))
  done
  [ "$entries" -gt 0 ] || { echo "ci/sources.sh: nothing to seed in $dir" >&2; exit 1; }

  # BuildKit keys a cache mount by its id plus the ref of its uid/gid base
  # directory, so the root spec (Dockerfile) and the uid=33 spec
  # (php/pgo/Dockerfile.corpus) are two stores: both are seeded. SEED_NONCE makes
  # every run re-execute the copy (a repeat run with the same files would
  # otherwise be a cache hit and skip it, even after the mount was pruned).
  # Not --no-cache: writes to a cache mount made under it are not kept. The
  # docker driver (the corpus job) gets no --output: it may not support
  # cacheonly, and an untagged image is harmless.
  local mount_root="type=cache,target=${CACHE_TARGET},id=${CACHE_ID},sharing=${CACHE_SHARING}"
  local mount_corpus="${mount_root},uid=33,gid=33"
  local output=(--output type=cacheonly)
  if docker buildx inspect | grep -Eq '^Driver:[[:space:]]+docker$'; then
    output=()
  fi
  docker buildx build --network none --progress=plain --build-arg "SEED_NONCE=$(date +%s%N)-$$" "${output[@]}" -f - "$seedctx" <<EOF
FROM ${base_image}
ARG SEED_NONCE
RUN --mount=type=bind,target=/seed --mount=${mount_corpus} \\
    echo "seed \$SEED_NONCE" && install -m 0644 -o 33 -g 33 -t ${CACHE_TARGET} /seed/*
RUN --mount=type=bind,target=/seed --mount=${mount_root} \\
    echo "seed \$SEED_NONCE" && install -m 0644 -t ${CACHE_TARGET} /seed/*
EOF
  echo "ci/sources.sh: seeded ${entries} entries into ${CACHE_ID}" >&2
}

case "${1:-}" in
  list) list ;;
  fetch) need_dir "${2:-}"; fetch "$2" ;;
  seed) need_dir "${2:-}"; seed "$2" ;;
  *) usage ;;
esac
