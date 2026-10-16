#!/usr/bin/env bash
# Print a short hash of Wolfi's APKINDEX.tar.gz for both architectures. It
# changes whenever Wolfi publishes a package, and feeds the WOLFI_INDEX_STATE
# build arg that re-runs the runtime-base `apk upgrade` layer.
#
# Never fails the build: when an index cannot be read it prints the UTC date, so
# the layer re-runs at most daily instead of at most weekly.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ok=1
for arch in x86_64 aarch64; do
  # Into a file rather than a pipe: a transfer that dies half way must not leave
  # a truncated body for the hash.
  RETRY_KIND=http RETRY_ATTEMPTS=3 "$here/retry.sh" \
    curl -fsS --max-time 60 -o "$tmp/$arch" "https://packages.wolfi.dev/os/$arch/APKINDEX.tar.gz" || ok=0
  [ -s "$tmp/$arch" ] || ok=0
done

if [ "$ok" -eq 1 ]; then
  cat "$tmp/x86_64" "$tmp/aarch64" | sha256sum | cut -c1-16
else
  echo "::warning::wolfi-index-state: could not read every APKINDEX; falling back to the date" >&2
  date -u +%F
fi
