#!/usr/bin/env bash
# Unit-level proof for deps/fetch-verified.sh (task 31), no Docker involved:
# a local HTTP server stands in for GitHub/php.net/pecl.php.net, and a plain
# directory stands in for the /var/cache/src BuildKit cache mount. T17-L
# discipline -- a positive path proven working is not enough on its own, so
# this also proves the negative: a corrupted cache entry is never served, and
# an outage with a cold cache is a real, loud failure, not a silent pass.
#
#   tests/test-fetch-verified.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
HELPER="${ROOT}/deps/fetch-verified.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

ORIGIN="$WORK/origin"
CACHE="$WORK/cache"
DEST="$WORK/dest"
mkdir -p "$ORIGIN" "$CACHE"

echo "hello from the real origin" > "$ORIGIN/thing.txt"
SHA="$(sha256sum "$ORIGIN/thing.txt" | awk '{print $1}')"

PORT=$(( (RANDOM % 20000) + 20000 ))
( cd "$ORIGIN" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -sf -o /dev/null "http://127.0.0.1:${PORT}/thing.txt" && break
  sleep 0.1
done
URL="http://127.0.0.1:${PORT}/thing.txt"

run_fetch() {  # run_fetch <url> <sha> <dest>
  FETCH_VERIFIED_CACHE_DIR="$CACHE" bash "$HELPER" "$1" "$2" "$3"
}

# --- 1. cold fetch: nothing cached, server up -------------------------------
run_fetch "$URL" "$SHA" "$DEST" || fail "cold fetch failed"
[ -f "$DEST" ] || fail "cold fetch produced no dest file"
diff -q "$ORIGIN/thing.txt" "$DEST" >/dev/null || fail "cold fetch dest content differs from origin"
[ -f "$CACHE/$SHA" ] || fail "cold fetch did not populate the cache at \$CACHE/\$SHA"
diff -q "$ORIGIN/thing.txt" "$CACHE/$SHA" >/dev/null || fail "cache entry content differs from origin"
echo "ok: cold fetch populates the cache"

# --- 2. warm fetch with the origin gone: the whole point of this helper ----
rm -f "$DEST"
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
run_fetch "$URL" "$SHA" "$DEST" || fail "warm fetch failed even though the cache had a valid entry -- the origin being down should not matter"
diff -q "$ORIGIN/thing.txt" "$DEST" >/dev/null || fail "warm (cache-hit) dest content is wrong"
echo "ok: a cache hit serves the right content with the origin unreachable (the github-outage case)"

# --- 3. negative control: a corrupted cache entry is never used, origin up -
( cd "$ORIGIN" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -sf -o /dev/null "$URL" && break
  sleep 0.1
done
echo "corrupted bytes, not the real content" > "$CACHE/$SHA"
rm -f "$DEST"
run_fetch "$URL" "$SHA" "$DEST" || fail "fetch failed outright after a corrupt cache entry, with the origin reachable -- it should have refetched"
diff -q "$ORIGIN/thing.txt" "$DEST" >/dev/null || fail "fetch served the corrupted cache entry instead of refetching"
diff -q "$ORIGIN/thing.txt" "$CACHE/$SHA" >/dev/null || fail "the corrupt entry was not replaced with a verified one after the refetch"
echo "ok: a corrupted cache entry is discarded and refetched, never served"

# --- 4. negative control: corrupted cache AND origin unreachable -> hard fail
echo "corrupted again" > "$CACHE/$SHA"
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
rm -f "$DEST"
if run_fetch "$URL" "$SHA" "$DEST" 2>/dev/null; then
  fail "fetch reported success with a corrupt cache entry and no reachable origin -- it must fail loudly instead"
fi
[ -f "$DEST" ] && fail "a failed fetch left a dest file behind"
echo "ok: corrupt cache + unreachable origin fails the build instead of silently succeeding"

# --- 5. sha256 mismatch on a genuine fetch is a hard failure, cache untouched
( cd "$ORIGIN" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -sf -o /dev/null "$URL" && break
  sleep 0.1
done
WRONG_SHA="$(printf '%064d' 0)"  # 64 zeros: a well-formed but wrong sha256
rm -f "$DEST" "$CACHE/$WRONG_SHA"
if run_fetch "$URL" "$WRONG_SHA" "$DEST" 2>/dev/null; then
  fail "fetch reported success although the downloaded content did not match the given sha256"
fi
[ -f "$CACHE/$WRONG_SHA" ] && fail "a failed-verification fetch must not populate the cache under the wrong hash"
echo "ok: a sha256 mismatch on a fresh fetch fails and never poisons the cache"

# --- 6. missing cache dir: plain fetch, no error (works outside BuildKit) --
rm -f "$DEST"
if ! FETCH_VERIFIED_CACHE_DIR="$WORK/does-not-exist" bash "$HELPER" "$URL" "$SHA" "$DEST"; then
  fail "fetch failed with a missing cache directory -- it must fall back to a plain fetch"
fi
diff -q "$ORIGIN/thing.txt" "$DEST" >/dev/null || fail "plain (no-cache-dir) fetch produced the wrong content"
[ -d "$WORK/does-not-exist" ] && fail "a missing cache dir must not be created by this helper"
echo "ok: a missing cache directory is a plain, uncached fetch, not an error"

# --- 7. file:// URLs work too (the other transport the brief calls out) ----
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
rm -rf "$CACHE"; mkdir -p "$CACHE"
rm -f "$DEST"
run_fetch "file://${ORIGIN}/thing.txt" "$SHA" "$DEST" || fail "file:// fetch failed"
diff -q "$ORIGIN/thing.txt" "$DEST" >/dev/null || fail "file:// fetch produced the wrong content"
[ -f "$CACHE/$SHA" ] || fail "file:// fetch did not populate the cache"
echo "ok: file:// URLs are cached and verified the same way"

# --- 8. entries are stored 0644; an unwritable cache dir is a plain fetch --
[ "$(stat -c %a "$CACHE/$SHA")" = 644 ] || fail "cache entry stored as $(stat -c %a "$CACHE/$SHA"), expected 644"
if [ "$(id -u)" = 0 ]; then
  echo "note: running as root, the unwritable-cache case can't be staged (root ignores the mode) -- skipped"
else
  rm -rf "$CACHE"; mkdir -p "$CACHE"; chmod 0555 "$CACHE"
  rm -f "$DEST"
  run_fetch "file://${ORIGIN}/thing.txt" "$SHA" "$DEST" || fail "fetch failed because the cache dir is not writable -- storing must be best effort"
  diff -q "$ORIGIN/thing.txt" "$DEST" >/dev/null || fail "fetch with an unwritable cache produced the wrong content"
  [ -z "$(ls -A "$CACHE")" ] || fail "something was written into a read-only cache dir"
  chmod 0755 "$CACHE"
  echo "ok: an unwritable cache dir degrades to a plain fetch; entries are stored 0644"
fi

echo "PASS: tests/test-fetch-verified.sh (8 checks)"
