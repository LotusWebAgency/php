#!/usr/bin/env bash
# Verify the signatures the merge job just made, before the list is recorded
# for promotion: on the manifest list and on every manifest it holds (the
# platform images and BuildKit's attestation manifests, all of which
# `cosign sign --recursive` signs), each with the identity in COSIGN_VERIFY_FLAGS.
#
#   COSIGN_VERIFY_FLAGS="--certificate-oidc-issuer ... --certificate-identity ..." \
#     ci/verify-signed.sh <repo> <list-digest>
#
# The same strict flags ci/attest-image.sh verifies the attestations with, the
# identity SECURITY.md documents: a signature made under any other identity
# fails the release here instead of a user's `cosign verify`. A registry
# 429/5xx goes through ci/retry.sh; a verify that finds no signature yet is
# repeated a few times (GHCR's fallback tag reads back at once, so the waits are
# insurance); anything else fails at once.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: $0 <repo> <list-digest>" >&2; exit 2; }
repo="$1" list="$2"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIGN="${COSIGN:-cosign}"
read -ra verify_flags <<<"${COSIGN_VERIFY_FLAGS:?COSIGN_VERIFY_FLAGS must say what identity to verify against}"
WAITS="${VERIFY_SIGNED_WAITS:-0 5 10 20}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

raw="$("$HERE/retry.sh" docker buildx imagetools inspect "$repo@$list" --raw)"
mapfile -t children < <(jq -r '.manifests[]?.digest' <<<"$raw")
[ "${#children[@]}" -gt 0 ] || { echo "FAIL: $repo@$list holds no manifests -- not a manifest list" >&2; exit 1; }

failed=0
for d in "$list" "${children[@]}"; do
  ok=0
  for wait in $WAITS; do
    sleep "$wait"
    if "$HERE/retry.sh" "$COSIGN" verify "${verify_flags[@]}" "$repo@$d" >/dev/null 2>"$work/err"; then
      ok=1
      break
    fi
    grep -Eqi 'no signatures found|no matching signatures' "$work/err" || break
    echo "  $d: no signature visible after ${wait}s"
  done
  if [ "$ok" -eq 1 ]; then
    echo "ok: signature on $repo@$d verifies"
  else
    cat "$work/err" >&2
    echo "FAIL: no signature on $repo@$d verifies" >&2
    failed=$((failed + 1))
  fi
done
[ "$failed" -eq 0 ] || { echo "FAIL: $failed of $((${#children[@]} + 1)) manifests have no verifying signature" >&2; exit 1; }
echo "ok: the list and its ${#children[@]} manifests are signed"
