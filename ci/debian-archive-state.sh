#!/usr/bin/env bash
# Print a short hash of the Date: lines of trixie's, trixie-updates' and
# trixie-security's InRelease files. It changes whenever Debian publishes a
# point release, a stable update or a security fix, and feeds the
# DEBIAN_ARCHIVE_STATE build arg that re-runs the runtime apt-get upgrade layer.
#
# Never fails the build: when the archive cannot be read it prints the UTC date,
# so the layer re-runs at most daily instead of at most weekly.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dates="$(
  for url in \
    https://deb.debian.org/debian/dists/trixie/InRelease \
    https://deb.debian.org/debian/dists/trixie-updates/InRelease \
    https://deb.debian.org/debian-security/dists/trixie-security/InRelease; do
    body="$(RETRY_KIND=http RETRY_ATTEMPTS=3 "$here/retry.sh" curl -fsS --max-time 30 "$url")" || exit 1
    grep -m1 '^Date:' <<<"$body" || exit 1
  done
)"
if [ "$(grep -c '^Date:' <<<"$dates")" -eq 3 ]; then
  sha256sum <<<"$dates" | cut -c1-16
else
  echo "debian-archive-state: could not read every InRelease; falling back to the date" >&2
  date -u +%F
fi
