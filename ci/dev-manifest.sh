#!/usr/bin/env bash
# Join the per-arch develop images into manifest lists and move the floating tags.
#
#   VERIFY_RESULT=<needs.verify.result> ci/dev-manifest.sh
#
# For every target of `scripts/gen_matrix.py --github targets`, <tag> being what
# follows the colon of its tags[0] and <sha> the first 12 chars of GITHUB_SHA:
#
#   dev:<tag>-<sha>-amd64, dev:<tag>-<sha>-arm64   pushed by the verify legs
#   dev:<tag>-<sha>                                 created here, when both exist
#   dev:<tag>                                       moved onto the list here, only
#                                                   when every verify leg succeeded
#
# Two passes: all lists first, floating tags only once every list is known to
# exist, so a failure half way never leaves floating tags on two commits.
# A missing arch fails the job when verify says it succeeded (a bug: the push is
# the last step of every leg); otherwise it is only reported, verify already
# failed the run.
set -euo pipefail

repo="${DEV_REPO:-ghcr.io/lotuswebagency/php/dev}"
sha="${GITHUB_SHA:?GITHUB_SHA is not set}"
sha="${sha:0:12}"
verify_result="${VERIFY_RESULT:?VERIFY_RESULT is not set}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

exists() { docker buildx imagetools inspect "$1" >/dev/null 2>&1; }

mapfile -t tags < <(python3 scripts/gen_matrix.py --github targets | jq -r '.include[].tags[0] | split(":")[1]')
[ "${#tags[@]}" -gt 0 ] || { echo "FAIL: no targets from gen_matrix.py" >&2; exit 1; }

declare -A has_amd64 has_arm64 list floating
missing=0
for tag in "${tags[@]}"; do
  base="${repo}:${tag}-${sha}"
  has_amd64[$tag]=no
  has_arm64[$tag]=no
  list[$tag]=no
  floating[$tag]=no
  exists "${base}-amd64" && has_amd64[$tag]=yes
  exists "${base}-arm64" && has_arm64[$tag]=yes
  if [ "${has_amd64[$tag]}" = yes ] && [ "${has_arm64[$tag]}" = yes ]; then
    docker buildx imagetools create -t "$base" "${base}-amd64" "${base}-arm64"
    list[$tag]=yes
  else
    missing=$((missing + 1))
    echo "missing: ${tag} amd64=${has_amd64[$tag]} arm64=${has_arm64[$tag]}"
  fi
done

if [ "$verify_result" != success ]; then
  echo "verify result is '$verify_result': floating tags not moved ($missing of ${#tags[@]} targets lack an arch, the rest got their ${sha} list)"
elif [ "$missing" -gt 0 ]; then
  echo "verify succeeded but $missing target(s) lack an arch: floating tags not moved"
else
  for tag in "${tags[@]}"; do
    docker buildx imagetools create -t "${repo}:${tag}" "${repo}:${tag}-${sha}"
    floating[$tag]=yes
  done
  echo "floating tags moved to ${sha} for ${#tags[@]} targets"
fi

{
  echo "### dev images ${sha}"
  echo
  echo "| target | amd64 | arm64 | list | floating |"
  echo "|---|---|---|---|---|"
  for tag in "${tags[@]}"; do
    echo "| ${tag} | ${has_amd64[$tag]} | ${has_arm64[$tag]} | ${list[$tag]} | ${floating[$tag]} |"
  done
} >> "$summary"

if [ "$verify_result" = success ] && [ "$missing" -gt 0 ]; then
  echo "FAIL: verify reported success but $missing target(s) are missing an arch" >&2
  exit 1
fi
