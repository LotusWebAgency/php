#!/usr/bin/env bash
# Content-addressed fetch cache: every download carries a pinned sha256, and
# github.com/codeload is intermittently unreachable, so a cache keyed by that
# hash saves a long build from dying at its last GitHub download. The key is
# the hash, never the URL or filename, so different bytes served for the same
# pinned name are rejected like on an uncached fetch.
#
#   fetch-verified.sh <url> <sha256> <dest>
#
# Callers pass --mount=type=cache,target=/var/cache/src,id=php-src-cache on the
# RUN that invokes this so the cache survives BuildKit layer invalidation;
# FETCH_VERIFIED_CACHE_DIR overrides the directory for the unit-level test.
#
# A missing cache directory (no mount, or a stage that did not declare it) is a
# plain uncached fetch, not an error: creating one on the fly would hide the
# missing mount, and a later stage that does mount the real cache would never
# see what this one fetched.
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
  # An entry whose content doesn't match its name is never used.
  echo "fetch-verified: cache entry $sha failed verification, discarding and refetching" >&2
  # An entry this uid can't delete is refetched regardless; the store below
  # replaces it if the cache is writable at all.
  rm -f "$entry" || true
fi

echo "fetch-verified: fetching $url" >&2
curl -fsSL --retry 20 --retry-all-errors --retry-delay 5 --connect-timeout 10 -o "$dest" "$url"
echo "${sha}  ${dest}" | sha256sum -c -

# Storing is best effort: the download is already verified, so a cache directory
# this uid can't write only costs the next build a fetch. (BuildKit keys a cache
# mount by id and uid/gid, so Dockerfile's root stages and Dockerfile.corpus's
# uid=33 stages keep separate php-src-cache stores.)
if [ -d "$CACHE_DIR" ] && [ -w "$CACHE_DIR" ]; then
  # Atomic: a concurrent reader must never see a partial file. mktemp beside
  # $entry keeps the final mv a same-filesystem rename. mktemp creates 0600;
  # cached tarballs are public source, so 0644.
  tmp="$(mktemp "${CACHE_DIR}/.fetch-verified.XXXXXX")"
  cp "$dest" "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$entry"
fi
