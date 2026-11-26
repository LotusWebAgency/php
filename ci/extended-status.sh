#!/usr/bin/env bash
# Post the `release/extended` commit status of an extended.yml run.
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
# the run: ci/release_source.py trusts the run (its event, path and title, and
# the candidate digests it tested), not the status or its creator. The latest
# status of a context wins, so a green re-run after a red one replaces it.
# Nothing else reads the status: the promote PR's ci run does not wait for it,
# so there is no run to re-run once it is posted.
#
# The workflow's token needs statuses: write.
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
