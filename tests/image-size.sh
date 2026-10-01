#!/usr/bin/env bash
# Report the declared uncompressed size of one or more images (CF-12).
#
#   tests/image-size.sh <image>...
#   tests/image-size.sh --breakdown <image>
#
# A separate script rather than a bench.sh section: size is a build-output
# property, not a timing measurement, it has its own consumer (smoke.sh's
# budget assertion, spec section 13) that has no reason to also pull the
# official image and run timed containers, and its own negative-control
# shape (a budget argument, not a mismatched runtime flag). Sharing it with
# bench.sh would make both scripts' usage lines lie about what a caller
# needs to have on hand to run them.
#
# ---- which "size" -------------------------------------------------------
# Under the containerd image store (this host's default snapshotter -- see
# `docker info`'s "driver-type: io.containerd.snapshotter.v1"), `docker
# images` prints two different numbers that both look like "the size":
#
#   DISK USAGE    the uncompressed size of every layer once unpacked onto
#                 disk -- i.e. the rootfs a running container actually sees.
#                 This is `docker image inspect --format '{{.Size}}'`.
#   CONTENT SIZE  the compressed size of the layer blobs as stored in the
#                 content-addressable store (what actually got pulled over
#                 the wire, and what's shared/deduplicated with other
#                 images referencing the same blobs).
#
# Verified on this host: `docker images lotuswebagency/php:8.5-fpm` prints
# "428MB / 104MB" for DISK USAGE / CONTENT SIZE, and `docker image inspect
# --format '{{.Size}}'` prints 427939069 -- matching DISK USAGE, not CONTENT
# SIZE. Spec section 13's budgets ("uncompressed image size") mean the
# rootfs a container runs with, so this script uses `docker image inspect
# --format '{{.Size}}'` throughout, exclusively -- never CONTENT SIZE and
# never the old overlay2-driver "SIZE" column from a pre-containerd host,
# which is not directly comparable to either of the above.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v docker >/dev/null || fail "docker not found on this host"

human() {  # human <bytes> -> "123.4 MB"
  awk -v b="$1" 'BEGIN { printf "%.1f MB", b / 1000 / 1000 }'
}

size_of() {  # size_of <image> -> bytes (uncompressed rootfs, see header)
  docker image inspect "$1" --format '{{.Size}}' 2>/dev/null \
    || fail "docker image inspect $1 failed -- is it pulled/built locally?"
}

breakdown() {  # breakdown <image> -- installed packages by size, largest /usr/local paths
  # dpkg's Installed-Size and du's default block size are both reported in
  # KiB (1024-byte units), not the decimal KB the old `/1000` here assumed --
  # that made this table's "MB" a different, slightly inflated unit from
  # size_of()/human()'s decimal MB (bytes/1000/1000, per the header). Convert
  # to bytes first (*1024) then apply the same decimal-MB divisor as
  # everywhere else in this script, so every number on this page means the
  # same thing (finding 3).
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

if [ "${1:-}" = "--breakdown" ]; then
  image="${2:?usage: image-size.sh --breakdown <image>}"
  breakdown "$image"
  exit 0
fi

[ $# -ge 1 ] || fail "usage: image-size.sh <image>... | image-size.sh --breakdown <image>"

printf '%-45s %14s\n' "image" "uncompressed"
for image in "$@"; do
  bytes="$(size_of "$image")"
  printf '%-45s %14s\n' "$image" "$(human "$bytes")"
done
