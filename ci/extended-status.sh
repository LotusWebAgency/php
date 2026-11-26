#!/usr/bin/env bash
# Post the `release/extended` commit status of an extended.yml run, and unstick
# the promote PR that was waiting for it.
#
#   NEEDS_JSON='<toJson(needs)>' EXT_VERDICT=<outcome of the verdict step> \
#     GH_TOKEN=... GITHUB_REPOSITORY=... GITHUB_RUN_ID=... ci/extended-status.sh
#
# The status goes on plan.outputs.sha, the commit whose images were tested, and
# only when the run says something about that commit's release:
#
#   - plan succeeded, and plan.outputs.own is true: the images are the commit's
#     own dev:<tag>-<sha12>, not the floating fallback of another commit;
#   - plan.outputs.full is true: no `only`, no `flavor`, apps on. A subset run
#     proves less than the gate asks for and posts nothing;
#   - plan.outputs.checkout equals plan.outputs.sha: the tests and scripts that
#     ran are the commit's own tree. A dispatch that tests the commit's images
#     with another ref's tests/ and ci/ says nothing about the commit's release;
#   - no job was cancelled, and EXT_VERDICT (the verdict step's outcome) is
#     `success` or `failure`: success posts state success, failure posts failure.
#     A cancelled run posts nothing, so it neither passes nor fails the commit.
#
# Context `release/extended`, target the run. The status is only a pointer to
# the run: ci/release_source.py trusts the run (its event, path and title), not
# the status or its creator. The latest status of a context
# wins, so a green re-run after a red one replaces it. After a success, an open
# pull request develop -> main of this repository whose head is that commit has
# its failed ci run re-run (failed jobs only): its pr-gate looked for this
# status, did not find it and failed. The re-run needs `actions: write`.
#
# The workflow's token needs statuses: write, actions: write, pull-requests: read.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

needs="${NEEDS_JSON:?NEEDS_JSON is not set}"
verdict="${EXT_VERDICT:?EXT_VERDICT is not set}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
run_id="${GITHUB_RUN_ID:?GITHUB_RUN_ID is not set}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
context="release/extended"
url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/$run_id"

say() { echo "$*"; echo "$*" >>"$summary"; }
gh_retry() { RETRY_KIND=http,net ci/retry.sh gh "$@"; }

plan() { jq -r --arg k "$1" '.plan.outputs[$k] // ""' <<<"$needs"; }
if [ "$(jq -r '.plan.result // "absent"' <<<"$needs")" != success ]; then
  say "$context: no status, plan did not succeed"; exit 0
fi
sha="$(plan sha)"
if [ "$(plan own)" != true ] || [ "$(plan full)" != true ]; then
  say "$context: no status (own images: '$(plan own)', full selection: '$(plan full)'): only a full run on a commit's own images speaks for its release"
  exit 0
fi
if [ "$(plan checkout)" != "$sha" ]; then
  say "$context: no status, the tests ran from '$(plan checkout)', not from the tree of ${sha:0:12}"
  exit 0
fi
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "FAIL: plan.outputs.sha '$sha' is not a full commit sha" >&2; exit 1; }
if jq -e '[.[].result] | any(. == "cancelled")' <<<"$needs" >/dev/null; then
  say "$context: no status, the run was cancelled"; exit 0
fi
case "$verdict" in
  success) state=success; description="extended tests passed" ;;
  failure) state=failure; description="extended tests failed" ;;
  *) say "$context: no status, the verdict step ended '$verdict'"; exit 0 ;;
esac

gh_retry api -X POST "repos/$repo/statuses/$sha" \
  -f state="$state" -f context="$context" -f description="$description" -f target_url="$url" >/dev/null
say "$context: $state on ${sha:0:12}"
[ "$state" = success ] || exit 0

owner="${repo%%/*}"
prs="$(gh_retry api "repos/$repo/pulls?state=open&base=main&head=$owner:develop&per_page=20" \
  --jq "[.[] | select(.head.sha == \"$sha\" and .head.repo.full_name == \"$repo\") | .number]")"
for pr in $(jq -r '.[]' <<<"$prs"); do
  # The newest ci run of the PR's head: a pull_request run, so the gate that looked for the status.
  run="$(gh_retry api "repos/$repo/actions/workflows/ci.yml/runs?head_sha=$sha&event=pull_request&per_page=10" \
    --jq '[.workflow_runs[]] | sort_by(.created_at) | last // empty | "\(.id) \(.status) \(.conclusion)"')"
  if [ -z "$run" ]; then say "PR #$pr: no ci run of ${sha:0:12} to re-run"; continue; fi
  read -r id st conclusion <<<"$run"
  if [ "$st" = completed ] && [ "$conclusion" = failure ]; then
    gh_retry api -X POST "repos/$repo/actions/runs/$id/rerun-failed-jobs" >/dev/null
    say "PR #$pr: re-ran the failed jobs of ci run $id"
  else
    say "PR #$pr: ci run $id is $st/${conclusion:-none}, left alone"
  fi
done
