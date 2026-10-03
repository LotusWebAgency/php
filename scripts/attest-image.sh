#!/usr/bin/env bash
# Attach the OpenVEX statements and the test results to a published image.
#
#   scripts/attest-image.sh <repo> <index-digest> <flavor> <results-dir>
#
#   repo          docker.io/lotuswebagency/php
#   index-digest  the multi-platform manifest list the tags point at
#   flavor        fpm | cli | cli-builder | ext-builder (selects the VEX statements)
#   results-dir   holds <arch>.test-result.json, written by the build job's
#                 scripts/result_predicate.py once smoke and Trivy passed
#
# Every attestation goes onto the platform image manifest it describes (the
# bytes the tests ran) and, aggregated, onto the list digest -- the digest a tag
# resolves to, so `cosign verify-attestation lotuswebagency/php:8.5-fpm` works.
# Each one is verified right after it is made. Nothing is attested when a
# platform in the list has no passing result file.
#
# CI runs this keyless (cosign's defaults, plus COSIGN_VERIFY_FLAGS naming the
# workflow identity). tests/test-attest.sh runs the same script with a local
# key and registry through COSIGN, COSIGN_ATTEST_FLAGS and COSIGN_VERIFY_FLAGS.
set -euo pipefail
[ "$#" -eq 4 ] || { echo "usage: $0 <repo> <index-digest> <flavor> <results-dir>" >&2; exit 2; }
repo="$1" list="$2" flavor="$3" dir="$4"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIGN="${COSIGN:-cosign}"
read -ra attest_flags <<<"${COSIGN_ATTEST_FLAGS:-}"
read -ra verify_flags <<<"${COSIGN_VERIFY_FLAGS:?COSIGN_VERIFY_FLAGS must say what identity to verify against}"
TEST_RESULT_TYPE="https://github.com/LotusWebAgency/php/attestation/test-result/v1"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

attest() {  # attest <digest> <type> <predicate-file>
  echo "attest $2 -> $repo@$1"
  "$COSIGN" attest --yes "${attest_flags[@]}" --type "$2" --predicate "$3" "$repo@$1"
  "$COSIGN" verify-attestation "${verify_flags[@]}" --type "$2" "$repo@$1" >/dev/null
  echo "ok: $2 attestation on $1 verifies"
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

# Every platform in the list must have a result, and its tested digest must be
# the manifest the list actually holds.
list_arches="$(docker buildx imagetools inspect "$repo@$list" --raw \
  | jq -r '.manifests[] | select(.platform.os == "linux" and .platform.architecture != "unknown") | .platform.architecture' | sort)"
[ -n "$list_arches" ] || { echo "FAIL: no platform images in $repo@$list" >&2; exit 1; }

preds=()
for arch in $list_arches; do
  pred="$dir/$arch.test-result.json"
  [ -f "$pred" ] || { echo "FAIL: $repo@$list has a $arch image but $pred is missing -- not attesting an untested platform" >&2; exit 1; }
  want="$(jq -r '.platforms[0].image_digest' "$pred")"
  got="$("$HERE/platform-digest.sh" "$repo@$list" "$arch")"
  [ "$want" = "$got" ] || { echo "FAIL: $arch was tested as $want but the list holds $got" >&2; exit 1; }
  preds+=("$pred")
done
for pred in "$dir"/*.test-result.json; do
  arch="$(basename "$pred" .test-result.json)"
  grep -qx "$arch" <<<"$list_arches" || { echo "FAIL: $pred is for $arch, which is not in $repo@$list" >&2; exit 1; }
done

for pred in "${preds[@]}"; do
  arch="$(basename "$pred" .test-result.json)"
  digest="$("$HERE/platform-digest.sh" "$repo@$list" "$arch")"
  attest "$digest" "$TEST_RESULT_TYPE" "$pred"
  attest_vex "$digest"
done

python3 "$HERE/result_predicate.py" aggregate "${preds[@]}" --out "$work/list.test-result.json"
attest "$list" "$TEST_RESULT_TYPE" "$work/list.test-result.json"
attest_vex "$list"
