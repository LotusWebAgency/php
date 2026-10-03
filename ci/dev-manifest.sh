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
# exist, so a failure while the lists are built never touches a floating tag. The
# window in which the floating set can span two commits is narrowed to pass 2
# (a handful of calls); a cancellation or crash inside it can still leave it
# split, which is why the prune keeps every sha a floating tag points at.
# The floating tags are only moved when GITHUB_SHA is still the head of develop,
# so a re-run of an older run cannot move them backwards.
# A missing arch fails the job when verify says it succeeded (a bug: the push is
# the last step of every leg); otherwise it is only reported, verify already
# failed the run.
# Only a "not found" answer from the registry counts as a missing image; any
# other error is retried and then fails the job.
set -euo pipefail

repo="${DEV_REPO:-ghcr.io/lotuswebagency/php/dev}"
sha="${GITHUB_SHA:?GITHUB_SHA is not set}"
sha="${sha:0:12}"
verify_result="${VERIFY_RESULT:?VERIFY_RESULT is not set}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

# Rows of $GITHUB_STEP_SUMMARY come from the EXIT trap, so a failure half way
# still leaves the table (unreached cells read "?").
declare -A has_amd64 has_arm64 list floating
tags=()
note=""
write_summary() {
  {
    echo "### dev images ${sha}"
    echo
    [ -z "$note" ] || { echo "$note"; echo; }
    echo "| target | amd64 | arm64 | list | floating |"
    echo "|---|---|---|---|---|"
    for tag in "${tags[@]}"; do
      echo "| ${tag} | ${has_amd64[$tag]} | ${has_arm64[$tag]} | ${list[$tag]} | ${floating[$tag]} |"
    done
  } >> "$summary"
}
trap write_summary EXIT

# exists <ref>: 0 when the manifest is there, 1 when the registry says it is not.
# Anything else (network, auth, 5xx) is retried 3 times and then ends the job.
exists() {
  local out attempt
  for attempt in 1 2 3; do
    if out=$(docker buildx imagetools inspect "$1" 2>&1); then
      return 0
    fi
    if grep -qiE 'not found|manifest unknown|name unknown' <<<"$out"; then
      return 1
    fi
    echo "inspect $1 failed (attempt $attempt/3): $out" >&2
    [ "$attempt" -eq 3 ] || sleep $((attempt * 5))
  done
  echo "FAIL: cannot tell whether $1 exists" >&2
  exit 1
}

# develop_head: the current head of develop on the remote, retried like exists().
develop_head() {
  local out attempt
  for attempt in 1 2 3; do
    if out=$(git ls-remote origin refs/heads/develop 2>&1) && [ -n "$out" ]; then
      echo "${out%%[[:space:]]*}"
      return 0
    fi
    echo "git ls-remote origin refs/heads/develop failed (attempt $attempt/3): $out" >&2
    [ "$attempt" -eq 3 ] || sleep $((attempt * 5))
  done
  echo "FAIL: cannot read the head of develop" >&2
  exit 1
}

mapfile -t tags < <(python3 scripts/gen_matrix.py --github targets | jq -r '.include[].tags[0] | split(":")[1]')
[ "${#tags[@]}" -gt 0 ] || { echo "FAIL: no targets from gen_matrix.py" >&2; exit 1; }

for tag in "${tags[@]}"; do
  has_amd64[$tag]='?'
  has_arm64[$tag]='?'
  list[$tag]='?'
  floating[$tag]='?'
done
missing=0
for tag in "${tags[@]}"; do
  base="${repo}:${tag}-${sha}"
  if exists "${base}-amd64"; then has_amd64[$tag]=yes; else has_amd64[$tag]=no; fi
  if exists "${base}-arm64"; then has_arm64[$tag]=yes; else has_arm64[$tag]=no; fi
  list[$tag]=no
  floating[$tag]=no
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
  head_sha="$(develop_head)"
  if [ "$head_sha" != "$GITHUB_SHA" ]; then
    echo "develop is at ${head_sha:0:12}, this run is ${sha}: a re-run of an older run, floating tags not moved"
    note="Floating tags not moved: develop has moved on to \`${head_sha:0:12}\`, this is a run of \`${sha}\`."
    for tag in "${tags[@]}"; do floating[$tag]=no; done
  else
    for tag in "${tags[@]}"; do
      docker buildx imagetools create -t "${repo}:${tag}" "${repo}:${tag}-${sha}"
      floating[$tag]=yes
    done
    echo "floating tags moved to ${sha} for ${#tags[@]} targets"
  fi
fi

if [ "$verify_result" = success ] && [ "$missing" -gt 0 ]; then
  echo "FAIL: verify reported success but $missing target(s) are missing an arch" >&2
  exit 1
fi
