#!/usr/bin/env bash
# Attach the OpenVEX statements and the test results to a published image, in
# two phases around `docker buildx imagetools create`:
#
#   ci/attest-image.sh platforms <repo> <flavor> <results-dir>
#   ci/attest-image.sh list      <repo> <list-digest> <flavor> <results-dir>
#
#   repo          docker.io/lotuswebagency/php
#   list-digest   the multi-platform manifest list the tags point at
#   flavor        fpm | cli | cli-builder | ext-builder (selects the VEX statements)
#   results-dir   holds, per architecture, <arch> (the index digest the build job
#                 pushed) and <arch>.test-result.json (written by the build job's
#                 ci/result_predicate.py once smoke and Trivy passed)
#
# platforms runs BEFORE the list exists. A platform manifest is addressable from
# the per-arch index digest the build job pushed (and is the same bytes the list
# will hold), so every platform attestation goes on before any tag is created.
# Everything is checked first -- every architecture has a result, and each result
# was recorded for the manifest its index resolves to -- so a missing or foreign
# result stops the release before a tag exists, with nothing attested.
#
# list runs after create. It checks that the list holds exactly the tested
# platform manifests, then attaches the aggregated results and the VEX statements
# to the list digest -- the digest a tag resolves to, so
# `cosign verify-attestation lotuswebagency/php:8.5-fpm` works.
#
# Each attestation is verified once, right after it is made, with the identity
# the docs tell users to verify against: that is the only place a wrong identity
# fails a release instead of a user. A re-run attests again (cosign adds, it does
# not replace), so a digest can carry several; readers take the first.
#
# CI runs this keyless (cosign's defaults, plus COSIGN_VERIFY_FLAGS naming the
# workflow identity). tests/test-attest.sh runs the same script with a local
# key and registry through COSIGN, COSIGN_ATTEST_FLAGS and COSIGN_VERIFY_FLAGS.
set -euo pipefail
usage() { echo "usage: $0 platforms <repo> <flavor> <results-dir> | $0 list <repo> <list-digest> <flavor> <results-dir>" >&2; exit 2; }
[ "$#" -ge 1 ] || usage
mode="$1"
case "$mode" in
  platforms) [ "$#" -eq 4 ] || usage; repo="$2" flavor="$3" dir="$4" ;;
  list)      [ "$#" -eq 5 ] || usage; repo="$2" list="$3" flavor="$4" dir="$5" ;;
  *)         usage ;;
esac
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIGN="${COSIGN:-cosign}"
read -ra attest_flags <<<"${COSIGN_ATTEST_FLAGS:-}"
read -ra verify_flags <<<"${COSIGN_VERIFY_FLAGS:?COSIGN_VERIFY_FLAGS must say what identity to verify against}"
TEST_RESULT_TYPE="https://github.com/LotusWebAgency/php/attestation/test-result/v1"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Docker Hub's referrers listing lags a fresh push by seconds: the first
# release's verify, ~3s after its attest, found nothing ("no matching
# attestations: "), and the same command passed minutes later against the same
# digest. Only the verify is retried -- attesting again would stack a duplicate.
VERIFY_WAITS="${ATTEST_VERIFY_WAITS:-5 10 20 30 45 60}"

attest() {  # attest <digest> <type> <predicate-file>
  echo "attest $2 -> $repo@$1"
  "$COSIGN" attest --yes "${attest_flags[@]}" --type "$2" --predicate "$3" "$repo@$1"
  local wait err
  for wait in $VERIFY_WAITS ""; do
    if err="$("$COSIGN" verify-attestation "${verify_flags[@]}" --type "$2" "$repo@$1" 2>&1 >/dev/null)"; then
      echo "ok: $2 attestation on $1 verifies"
      return 0
    fi
    [ -n "$wait" ] || break
    echo "  not visible yet, retrying in ${wait}s: $(printf '%s' "$err" | tail -n1)"
    sleep "$wait"
  done
  printf '%s\n' "$err" >&2
  echo "FAIL: $2 attestation on $1 does not verify" >&2
  return 1
}

attest_vex() {  # attest_vex <digest>
  local out="$work/vex-${1#sha256:}.json" rc=0
  python3 "$HERE/vex.py" emit --digest "$1" --flavor "$flavor" --out "$out" || rc=$?
  case "$rc" in
    0) attest "$1" openvex "$out" ;;
    3) echo "skip: no VEX statement applies to $flavor, nothing to attest on $1" ;;
    *) echo "FAIL: vex.py emit failed ($rc) for $1" >&2; exit 1 ;;
  esac
}

# The architectures the build job produced a result for, sorted.
result_arches() {
  local f
  for f in "$dir"/*.test-result.json; do
    [ -e "$f" ] || continue
    basename "$f" .test-result.json
  done | sort
}

if [ "$mode" = platforms ]; then
  # An architecture is expected wherever the build job left an index digest.
  expected=()
  for f in "$dir"/*; do
    case "$f" in *.json) continue ;; esac
    [ -f "$f" ] && expected+=("$(basename "$f")")
  done
  [ "${#expected[@]}" -gt 0 ] || { echo "FAIL: no per-arch index digests in $dir" >&2; exit 1; }
  mapfile -t expected < <(printf '%s\n' "${expected[@]}" | sort)
  mapfile -t have < <(result_arches)
  [ "${expected[*]}" = "${have[*]:-}" ] || {
    echo "FAIL: index digests for (${expected[*]}) but test results for (${have[*]:-none}) -- not attesting an untested platform" >&2
    exit 1
  }

  # Resolve each platform manifest once; everything below reads these arrays.
  digests=()
  for arch in "${expected[@]}"; do
    want="$(jq -r '.platforms[0].image_digest' "$dir/$arch.test-result.json")"
    got="$("$HERE/platform-digest.sh" "$repo@$(cat "$dir/$arch")" "$arch")"
    [ "$want" = "$got" ] || { echo "FAIL: $arch was tested as $want but its index holds $got" >&2; exit 1; }
    digests+=("$got")
  done

  for i in "${!expected[@]}"; do
    attest "${digests[$i]}" "$TEST_RESULT_TYPE" "$dir/${expected[$i]}.test-result.json"
    attest_vex "${digests[$i]}"
  done
  exit 0
fi

# list: the list must hold exactly the manifests that were tested and attested.
mapfile -t have < <(result_arches)
[ "${#have[@]}" -gt 0 ] || { echo "FAIL: no test results in $dir" >&2; exit 1; }
raw="$(docker buildx imagetools inspect "$repo@$list" --raw)"
for arch in "${have[@]}"; do
  held="$(jq -r --arg arch "$arch" '.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest' <<<"$raw")"
  want="$(jq -r '.platforms[0].image_digest' "$dir/$arch.test-result.json")"
  [ "$held" = "$want" ] || { echo "FAIL: $arch was tested as $want but the list holds ${held:-nothing}" >&2; exit 1; }
done
list_arches="$(jq -r '.manifests[] | select(.platform.os == "linux" and .platform.architecture != "unknown") | .platform.architecture' <<<"$raw" | sort)"
[ "$list_arches" = "$(printf '%s\n' "${have[@]}")" ] || {
  echo "FAIL: $repo@$list holds (${list_arches//$'\n'/ }) but results exist for (${have[*]})" >&2
  exit 1
}

preds=()
for arch in "${have[@]}"; do preds+=("$dir/$arch.test-result.json"); done
python3 "$HERE/result_predicate.py" aggregate "${preds[@]}" --out "$work/list.test-result.json"
attest "$list" "$TEST_RESULT_TYPE" "$work/list.test-result.json"
attest_vex "$list"
