#!/usr/bin/env bash
# After a promotion: what a user is told to run, against the published
# repository, anonymously, for one promoted list.
#
#   COSIGN_VERIFY_FLAGS="--certificate-oidc-issuer ... --certificate-identity ..." \
#     ci/hub-verify.sh <repo> <release.json>
#
#   repo          docker.io/lotuswebagency/php
#   release.json  what the merge job recorded for the list:
#                 {"list": "sha256:..", "platforms": {"amd64": "sha256:..", ...},
#                  "tags": ["8.5-fpm", ...]}
#
# Checks that every tag resolves to the list (HEAD, not a pull), that the
# signature verifies on the list and on each platform manifest, and that the
# test-result attestation verifies on the list and is about the list -- with the
# identity in COSIGN_VERIFY_FLAGS, the one SECURITY.md documents.
#
# Runs with an empty DOCKER_CONFIG of its own, so nothing here can use an
# account's credentials: these reads count against the runner IP's anonymous
# limit, never the publishing account's. ci/promote-image.sh already proved by
# digest that every signature and attestation of every list is on the
# destination; this proves, for one list, that cosign finds and accepts them
# there. Docker Hub indexes referrers with a short lag, so a verify that finds
# none is repeated a few times before it counts as a failure.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: $0 <repo> <release.json>" >&2; exit 2; }
repo="$1" release="$2"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIGN="${COSIGN:-cosign}"
REGCTL="${REGCTL:-regctl}"
read -ra verify_flags <<<"${COSIGN_VERIFY_FLAGS:?COSIGN_VERIFY_FLAGS must say what identity to verify against}"
TEST_RESULT_TYPE="https://github.com/LotusWebAgency/php/attestation/test-result/v1"
WAITS="${HUB_VERIFY_WAITS:-0 10 30 60}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export DOCKER_CONFIG="$work/docker"
mkdir "$DOCKER_CONFIG"
echo '{}' >"$DOCKER_CONFIG/config.json"

list="$(jq -r '.list' "$release")"
mapfile -t platforms < <(jq -r '.platforms | to_entries[] | "\(.key) \(.value)"' "$release")
mapfile -t tags < <(jq -r '.tags[]' "$release")
[ "${#platforms[@]}" -gt 0 ] && [ "${#tags[@]}" -gt 0 ] || { echo "FAIL: $release names no platforms or no tags" >&2; exit 1; }

for t in "${tags[@]}"; do
  got="$("$HERE/retry.sh" "$REGCTL" manifest head "$repo:$t" 2>/dev/null || true)"
  [ "$got" = "$list" ] || { echo "FAIL: $repo:$t resolves to ${got:-nothing}, expected $list" >&2; exit 1; }
done
echo "ok: ${#tags[@]} tags resolve to $list"

# verify <what> <cosign args...>: repeated while cosign finds nothing to verify
# yet; a registry 429/5xx goes through ci/retry.sh; anything else fails at once.
# cosign's stdout is left in $work/out.
verify() {
  local what="$1" wait
  shift
  for wait in $WAITS; do
    sleep "$wait"
    if "$HERE/retry.sh" "$COSIGN" "$@" >"$work/out" 2>"$work/err"; then
      echo "ok: $what"
      return 0
    fi
    grep -Eqi 'no signatures found|no matching signatures|no matching attestations|none of the attestations matched' "$work/err" || break
    echo "  $what: nothing found yet after ${wait}s"
  done
  cat "$work/err" >&2
  echo "FAIL: $what" >&2
  return 1
}

verify "signature on the list $repo@$list" verify "${verify_flags[@]}" "$repo@$list"
for p in "${platforms[@]}"; do
  verify "signature on the ${p%% *} manifest $repo@${p#* }" verify "${verify_flags[@]}" "$repo@${p#* }"
done
verify "test-result attestation on the list" verify-attestation "${verify_flags[@]}" --type "$TEST_RESULT_TYPE" "$repo@$list"
subject="$(jq -rs '.[0].payload' "$work/out" | base64 -d | jq -r '.subject[0].digest.sha256')"
[ "sha256:$subject" = "$list" ] || { echo "FAIL: the test-result attestation on $list is about sha256:$subject" >&2; exit 1; }
echo "ok: the test-result attestation is about the list itself"
