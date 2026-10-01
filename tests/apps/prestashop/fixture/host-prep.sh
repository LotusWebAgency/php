#!/usr/bin/env bash
# Runs on the host, before build.sh: streams the release tree out of the
# vendor's pinned image into the builder container as /srv/src/prestashop.
# docker cp on both ends, no bind mount, so nothing lands on the host owned by
# the image's uid 33.
#
#   host-prep.sh <set> <builder-container>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set_name="${1:?usage: host-prep.sh <set> <builder-container>}"
builder="${2:?usage: host-prep.sh <set> <builder-container>}"

read -r digest tag < <(awk -v s="$set_name" '$1 == "prestashop-image" && $2 == s { print $4, $5 }' "$HERE/../../apps.lock")
[ -n "${digest:-}" ] || { echo "FATAL: no prestashop-image row for set $set_name in apps.lock" >&2; exit 1; }
tag="${tag#docker://}"
ref="${tag%%:*}@sha256:$digest"

docker image inspect "$ref" >/dev/null 2>&1 || docker pull -q "$ref" >/dev/null
cid="$(docker create "$ref")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

docker exec "$builder" mkdir -p /srv/src
# The image keeps the tree at /var/www/html and docker cp names the top
# directory after it, hence the rename.
docker cp "$cid:/var/www/html" - | docker cp - "$builder:/srv/src/"
docker exec "$builder" mv /srv/src/html /srv/src/prestashop
docker exec "$builder" test -f /srv/src/prestashop/install/index_cli.php
echo "ok: $tag ($ref) unpacked at /srv/src/prestashop"
