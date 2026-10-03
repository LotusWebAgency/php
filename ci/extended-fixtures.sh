#!/usr/bin/env bash
# Make sure every app fixture the selected versions need is in the registry,
# current for this tree, for this daemon's architecture.
#
#   APPTEST_FIXTURE_REPO=ghcr.io/lotuswebagency/php/apptest [EXT_ONLY=csv] ci/extended-fixtures.sh
#
# Run once per architecture before the jobs that run the app suites, so those
# jobs only ever pull a fixture and never race to build the same one. A fixture
# whose com.lotuswebagency.apptest-hash label already equals this tree's recipe
# hash is left alone (checked on the registry, nothing is pulled); a missing or
# stale one is built by tests/apps/build-fixture.sh --push, and its local copy
# removed afterwards (14 fixtures do not fit a runner's disk together).
# Results go to $EXT_LOG_ROOT/fixtures/results.tsv in extended.sh's format.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=tests/apps/lib.sh
. tests/apps/lib.sh

apptest_repo_is_registry || apptest_die "APPTEST_FIXTURE_REPO ($APPTEST_FIXTURE_REPO) is not a registry repository"
root="${EXT_LOG_ROOT:-${RUNNER_TEMP:-/tmp}/extended-logs}/fixtures"
mkdir -p "$root"
results="$root/results.tsv"
: >"$results"
export APPTEST_LOG_DIR="$root"

mapfile -t versions < <(
  if [ -n "${EXT_ONLY:-}" ]; then tr ',' '\n' <<<"$EXT_ONLY"; else apptest_matrix_versions; fi | grep .
)
declare -A need=()
bad=0
for v in "${versions[@]}"; do
  for app in "${APPTEST_APPS[@]}"; do
    if set="$(apptest_resolve_set "$app" "$v")"; then need["$app $set"]=1; else bad=1; fi
  done
done
[ "$bad" -eq 0 ] || apptest_die "a selected version has no fixture set (tests/apps/sets)"

# registry_hash <ref> -> the fixture's recipe hash label, or "" when the image
# is absent or unreadable (the caller then lets build-fixture.sh decide).
registry_hash() {
  docker buildx imagetools inspect "$1" --format '{{json .Image}}' 2>/dev/null \
    | jq -r 'if has("config") then . else (to_entries | map(select(.key | startswith("linux/"))) | .[0].value) end
             | .config.Labels["com.lotuswebagency.apptest-hash"] // empty' 2>/dev/null || true
}

failed=0
while read -r app set; do
  tag="$(apptest_fixture_tag "$app" "$set")"
  want="$(apptest_recipe_hash "$app" "$set")"
  t0=$(date +%s)
  if [ "$(registry_hash "$tag")" = "$want" ]; then
    echo "ok: $tag is current in the registry (apptest-hash $want)"
    printf 'fixtures\t%s\tok\t0\tcurrent\n' "$tag" >>"$results"
    continue
  fi
  echo "=== $tag: missing or stale in the registry, building"
  if tests/apps/build-fixture.sh "$app" "$set" --push </dev/null; then
    printf 'fixtures\t%s\tok\t%s\tbuilt and pushed\n' "$tag" "$(( $(date +%s) - t0 ))" >>"$results"
  else
    failed=$((failed + 1))
    printf 'fixtures\t%s\tFAIL\t%s\tbuild or push failed, log %s/fixtures/%s-%s.log\n' "$tag" "$(( $(date +%s) - t0 ))" "$root" "$app" "$set" >>"$results"
  fi
  docker image rm -f "$tag" >/dev/null 2>&1 || true
done < <(printf '%s\n' "${!need[@]}" | sort)

echo
echo "fixtures: $failed failed of ${#need[@]}"
{
  echo "<details><summary>fixtures $(apptest_arch) (${failed} failed of ${#need[@]})</summary>"
  echo
  echo '```'
  awk -F'\t' '{ printf "%-48s %-6s %5ss  %s\n", $2, $3, $4, $5 }' "$results"
  echo '```'
  echo "</details>"
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
[ "$failed" -eq 0 ]
