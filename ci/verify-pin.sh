#!/usr/bin/env bash
# Fail unless one platform of an index is the platform manifest a release candidate recorded.
#
#   ci/verify-pin.sh <repo>@<index-digest> <amd64|arm64> <sha256:platform-digest>
#
# tests/extended.sh pull pulls a candidate's images as <repo>@<index digest>, which
# names its bytes exactly; this reads that index's linux/<arch> manifest
# (ci/platform-digest.sh) and compares it with the platform digest the candidate
# holds (from the signed test-result predicate), so a candidate that does not
# describe the index it points at is a failure, not a pull.
set -euo pipefail
[ "$#" -eq 3 ] || { echo "usage: $0 <repo>@<index-digest> <arch> <platform-digest>" >&2; exit 2; }
ref="$1" arch="$2" want="$3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "$ref" =~ @sha256:[0-9a-f]{64}$ ]] || { echo "FAIL: $ref is not a digest reference" >&2; exit 1; }
[[ "$want" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "FAIL: '$want' is not a sha256 digest" >&2; exit 1; }
got="$("$HERE/platform-digest.sh" "$ref" "$arch")"
if [ "$got" != "$want" ]; then
  echo "FAIL: $ref linux/$arch is platform $got, the candidate recorded $want" >&2
  exit 1
fi
echo "ok: $ref linux/$arch is $got"
