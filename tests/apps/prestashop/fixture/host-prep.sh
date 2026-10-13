#!/usr/bin/env bash
# Runs on the host, before build.sh: for a set whose tree is the vendor's pinned
# image (apps.lock prestashop-image: 9.2), streams it out of the image into the
# builder container as /srv/src/prestashop. docker cp on both ends, no bind
# mount, so nothing lands on the host owned by the image's uid 33. A set with a
# prestashop-zip row has nothing to do here: build.sh fetches and unpacks the
# release zip itself, inside the container.
#
#   host-prep.sh <set> <builder-container>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set_name="${1:?usage: host-prep.sh <set> <builder-container>}"
builder="${2:?usage: host-prep.sh <set> <builder-container>}"

if awk -v s="$set_name" '$1 == "prestashop-zip" && $2 == s { found = 1 } END { exit !found }' "$HERE/../../apps.lock"; then
  echo "ok: set $set_name is a release zip, unpacked by build.sh"
  exit 0
fi

read -r digest tag < <(awk -v s="$set_name" '$1 == "prestashop-image" && $2 == s { print $4, $5 }' "$HERE/../../apps.lock")
[ -n "${digest:-}" ] || { echo "FATAL: no prestashop-image or prestashop-zip row for set $set_name in apps.lock" >&2; exit 1; }
tag="${tag#docker://}"
ref="${tag%%:*}@sha256:$digest"

# linux/amd64 explicitly: nothing here executes the image, it is only unpacked
# with docker cp, so the daemon's own architecture is no reason to pull a
# different variant. `docker image inspect --platform` needs Docker 28;
# comparing .Architecture works on every version.
[ "$(docker image inspect --format '{{.Architecture}}' "$ref" 2>/dev/null || true)" = amd64 ] \
  || RETRY_KIND=registry "$HERE/../../../../ci/retry.sh" docker pull -q --platform linux/amd64 "$ref" >/dev/null
cid="$(docker create --pull never --platform linux/amd64 "$ref")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

docker exec "$builder" mkdir -p /srv/src
# The image keeps the tree at /var/www/html and docker cp names the top
# directory after it, hence the rename.
docker cp "$cid:/var/www/html" - | docker cp - "$builder:/srv/src/"
docker exec "$builder" mv /srv/src/html /srv/src/prestashop
docker exec "$builder" test -f /srv/src/prestashop/install/index_cli.php
echo "ok: $tag ($ref) unpacked at /srv/src/prestashop"
