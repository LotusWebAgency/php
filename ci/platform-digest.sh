#!/usr/bin/env bash
# The digest of one platform's image manifest inside a multi-platform index.
#
#   ci/platform-digest.sh <repo>@<index-digest> <amd64|arm64>
#
# A buildx push with provenance/SBOM is an index (image manifest plus
# attestation manifests, which carry platform unknown/unknown), so the digest
# the build job gets back is not the digest a pulled image runs from. The
# platform manifest is, and it is the same bytes inside the published manifest
# list, which is why test results and VEX are attached to it.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: $0 <repo>@<index-digest> <arch>" >&2; exit 2; }
ref="$1" arch="$2"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
raw="$("$HERE/retry.sh" docker buildx imagetools inspect "$ref" --raw)"
digests="$(jq -r --arg arch "$arch" \
  '.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest' <<<"$raw")"
[ -n "$digests" ] && [ "$(wc -l <<<"$digests")" -eq 1 ] || {
  echo "FAIL: expected exactly one linux/$arch manifest in $ref, got: ${digests:-none}" >&2
  exit 1
}
echo "$digests"
