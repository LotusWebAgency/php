#!/usr/bin/env bash
# Report the real uncompressed size of one or more images.
#
#   tests/image-size.sh <image>...
#   tests/image-size.sh --bytes <image>      (bare byte count, for scripts)
#   tests/image-size.sh --breakdown <image>
#
# A separate script rather than a bench.sh section: size is a build-output
# property, not a timing measurement, and its consumer (smoke.sh's budget
# assertion) has no reason to also pull the official image and run timed
# containers.
#
# ---- which "size" -------------------------------------------------------
# The number is the sum of the layer sizes `docker history` reports: the real
# uncompressed rootfs a container sees. It is NOT `docker image inspect
# --format '{{.Size}}'`. Under the containerd image store (`docker info` says
# "io.containerd.snapshotter.v1") .Size is the unpacked snapshots PLUS the
# compressed blobs kept next to them, so it overstates by roughly the content
# size. `docker images` shows the same split as DISK USAGE / CONTENT SIZE, and
# the classic overlay2 store reports yet another figure. `docker history
# --human=false` gives per-layer uncompressed byte counts under both stores, so
# a sum over it is the one definition that does not change with the daemon's
# storage backend.
# (Metadata-only entries -- ENV, CMD -- report 0 and drop out of the sum.)
#
# The per-flavor size budgets are against this number; tests/smoke.sh calls
# `image-size.sh --bytes` rather than computing it again, so the two cannot
# drift.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v docker >/dev/null || fail "docker not found on this host"

human() {  # human <bytes> -> "123.4 MB"
  awk -v b="$1" 'BEGIN { printf "%.1f MB", b / 1000 / 1000 }'
}

size_of() {  # size_of <image> -> bytes (sum of uncompressed layers, see header)
  local sizes
  sizes="$(docker history --human=false --no-trunc --format '{{.Size}}' "$1" 2>/dev/null)" \
    || fail "docker history $1 failed -- is it pulled/built locally?"
  [ -n "$sizes" ] || fail "docker history $1 listed no layers"
  awk 'BEGIN { s = 0 } $1 ~ /^[0-9]+$/ { s += $1 } END { printf "%d\n", s }' <<<"$sizes"
}

breakdown() {  # breakdown <image> -- installed packages by size, largest /usr/local paths
  # dpkg's Installed-Size and du's default block size are both in KiB (1024-byte
  # units). Convert to bytes first (*1024), then apply the same decimal-MB
  # divisor as size_of()/human(), so every number on this page is in one unit.
  local image="$1"
  echo
  echo "=== $image: top 15 installed packages by size ==="
  docker run --rm --entrypoint sh "$image" -c \
    "dpkg-query -W -f='\${Installed-Size}\t\${Package}\n' 2>/dev/null | sort -rn | head -15" \
    | awk 'BEGIN{FS="\t"} {printf "%8.1f MB  %s\n", $1*1024/1000/1000, $2}'
  echo
  echo "=== $image: largest paths under /usr/local ==="
  docker run --rm --entrypoint sh "$image" -c \
    "du -x -d 3 /usr/local 2>/dev/null | sort -rn | head -20" \
    | awk '{printf "%8.1f MB  ", $1*1024/1000/1000; $1=""; print}'
}

if [ "${1:-}" = "--bytes" ]; then
  size_of "${2:?usage: image-size.sh --bytes <image>}"
  exit 0
fi

if [ "${1:-}" = "--breakdown" ]; then
  image="${2:?usage: image-size.sh --breakdown <image>}"
  breakdown "$image"
  exit 0
fi

[ $# -ge 1 ] || fail "usage: image-size.sh <image>... | image-size.sh --bytes <image> | image-size.sh --breakdown <image>"

printf '%-45s %14s\n' "image" "uncompressed"
for image in "$@"; do
  bytes="$(size_of "$image")"
  printf '%-45s %14s\n' "$image" "$(human "$bytes")"
done
