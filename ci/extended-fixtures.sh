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
# removed afterwards (the fixtures do not fit a runner's disk together). Which
# fixtures the selection needs is tests/apps/sets: the sets whose PHP list
# holds a selected version (flavors do not narrow it).
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

needed="$(apptest_appsets sets ${EXT_ONLY:+--php "$EXT_ONLY"})" || apptest_die "tests/apps/sets is not usable for EXT_ONLY='${EXT_ONLY:-}'"
declare -A need=()
while read -r app set; do
  [ -z "$app" ] || need["$app $set"]=1
done <<<"$needed"
if [ "${#need[@]}" -eq 0 ]; then
  echo "fixtures: none needed for the selected versions"
  exit 0
fi

# registry_hash <ref> -> the fixture's recipe hash label on stdout, or nothing
# when the image is absent or unreadable for a lasting reason (the caller then
# lets build-fixture.sh decide). Returns 1 when the registry stayed unreachable
# through every retry: that says nothing about the fixture, so it is not
# rebuilt on the strength of it.
registry_hash() {
  local raw err rc=0
  err="$(mktemp)"
  raw="$(./ci/retry.sh docker buildx imagetools inspect "$1" --format '{{json .Image}}' 2>"$err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -q 'retry.sh: giving up' "$err"; then
      cat "$err" >&2
      rm -f "$err"
      return 1
    fi
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  jq -r 'if has("config") then . else (to_entries | map(select(.key | startswith("linux/"))) | .[0].value) end
         | .config.Labels["com.lotuswebagency.apptest-hash"] // empty' <<<"$raw" 2>/dev/null || true
}

failed=0
while read -r app set; do
  tag="$(apptest_fixture_tag "$app" "$set")"
  want="$(apptest_recipe_hash "$app" "$set")"
  t0=$(date +%s)
  if ! have="$(registry_hash "$tag")"; then
    failed=$((failed + 1))
    echo "FAIL: $tag: the registry could not be read, not rebuilding on a guess" >&2
    printf 'fixtures\t%s\tFAIL\t%s\tregistry unreachable\n' "$tag" "$(( $(date +%s) - t0 ))" >>"$results"
    continue
  fi
  if [ "$have" = "$want" ]; then
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
