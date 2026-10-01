#!/usr/bin/env bash
# Content-addressed fetch cache (task 31): github.com/codeload is intermittently
# unreachable from this host, and losing a multi-hour build at the very last
# GitHub download (lz4, snuffleupagus, ImageMagick, ICU, the laravel skeleton --
# all seen dying this way) is a build-time cost this project can just remove,
# because every one of those downloads already carries a pinned sha256. The
# cache key is that hash, never the URL or the filename: a redirect or a CDN
# edge that ever served different bytes for the same pinned name would be
# caught the same way a first, uncached fetch already is.
#
#   fetch-verified.sh <url> <sha256> <dest>
#
# Callers pass --mount=type=cache,target=/var/cache/src,id=php-src-cache on the
# RUN that invokes this so the cache survives across BuildKit invalidations
# (a busted layer, a different build, a rebuild after `docker builder prune`);
# FETCH_VERIFIED_CACHE_DIR overrides the directory for the unit-level test.
#
# A missing cache directory -- no mount at all, e.g. running this outside
# BuildKit, or a stage that forgot to declare it -- is a plain, uncached fetch,
# not an error: creating one on the fly would silently hide the missing mount
# and the next stage that DOES mount the real cache would never see what this
# one fetched.
set -euo pipefail
url="${1:?usage: fetch-verified.sh <url> <sha256> <dest>}"
sha="${2:?usage: fetch-verified.sh <url> <sha256> <dest>}"
dest="${3:?usage: fetch-verified.sh <url> <sha256> <dest>}"

CACHE_DIR="${FETCH_VERIFIED_CACHE_DIR:-/var/cache/src}"
entry="${CACHE_DIR}/${sha}"

matches_sha() {  # matches_sha <file> -- true if its sha256 is $sha
  echo "${sha}  $1" | sha256sum -c - >/dev/null 2>&1
}

if [ -d "$CACHE_DIR" ] && [ -f "$entry" ] && [ ! -r "$entry" ]; then
  echo "fetch-verified: cache entry $sha is not readable by $(id -un), refetching" >&2
elif [ -d "$CACHE_DIR" ] && [ -f "$entry" ]; then
  if matches_sha "$entry"; then
    echo "fetch-verified: cache hit for $sha, skipping $url" >&2
    cp "$entry" "$dest"
    exit 0
  fi
  # A cache entry whose content doesn't match its own name is never used --
  # deleted and refetched, same as a fresh download that failed verification.
  echo "fetch-verified: cache entry $sha failed verification, discarding and refetching" >&2
  # An entry this uid can't delete is refetched regardless; the store below
  # replaces it if the cache is writable at all.
  rm -f "$entry" || true
fi

echo "fetch-verified: fetching $url" >&2
curl -fsSL --retry 20 --retry-all-errors --retry-delay 5 --connect-timeout 10 -o "$dest" "$url"
echo "${sha}  ${dest}" | sha256sum -c -

# Storing is best effort: the download above is already verified, so a cache
# directory this uid can't write only costs the next build a fetch. (BuildKit
# keys a cache mount by id *and* uid/gid, so Dockerfile's root stages and
# Dockerfile.corpus's uid=33 stages each get their own php-src-cache store;
# neither ever sees the other's entries.)
if [ -d "$CACHE_DIR" ] && [ -w "$CACHE_DIR" ]; then
  # Atomic: a reader that lists/opens $entry while this is in flight must
  # never see a partial file. mktemp in the same directory as $entry keeps the
  # final `mv` a rename on one filesystem, not a cross-device copy. mktemp
  # creates 0600; cached tarballs are public source, so 0644.
  tmp="$(mktemp "${CACHE_DIR}/.fetch-verified.XXXXXX")"
  cp "$dest" "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$entry"
fi
