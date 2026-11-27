#!/usr/bin/env bash
# Plan one extended.yml run: which images, which tree, which versions.
#
#   EXT_RUN_SHA=<workflow_run head sha, or the pushed sha of an extended-run push>
#   | EXT_SHA_INPUT=<dispatch sha> | neither
#   EXT_ONLY=<csv of versions> EXT_FLAVOR=<csv of flavors>
#   EXT_APPS=<true|false> EXT_BENCH=<true|false>   (empty = default: true / false)
#   EXT_EVENT=<github.event_name>
#   EXT_CANDIDATE=<release-candidate.json of the triggering ci run> EXT_CI_RUN=<its run id>
#                            (workflow_run only; extended.yml downloads it by run id)
#   ci/extended-plan.sh
#
# For a workflow_run, plan refuses to go on unless that candidate is for the
# commit under test, this tree's inputs-hash and that ci run (ci/candidate.py
# check), and extended.yml then freezes the file as the extended-candidate
# artifact: every leg pulls the images of that file by digest. dev:<tag>-<sha12>
# is mutable (a develop rebuild of the commit re-points it), so a tag pull can
# test other images than the ones main copies. A dispatch or an extended-run
# push has no candidate: its legs pull by tag, and plan logs that this run
# cannot qualify a copy (ci/release_source.py needs the workflow_run title).
# A workflow_run whose extended.yml predates the candidate (main's, until the
# next promotion) leaves EXT_CANDIDATE unset: plan warns and the legs pull by
# tag too, and that run, titled the old way, cannot qualify a copy either. An
# EXT_CANDIDATE that is set but names no file is still fatal.
#
# For a push to extended-run (EXT_EVENT=push) with no dev:<tag>-<sha12> images
# of the pushed commit, plan falls back to the floating dev:<tag> images when
# their inputs-hash equals this tree's, tested from the pushed commit (a
# commit that only changed tests/ or ci/ has no images of its own); it logs
# which path was taken. sha is then the floating images' revision.
#
# Writes to $GITHUB_OUTPUT, for every later job to use unchanged:
#
#   sha       the commit whose images are tested; jobs pull exactly
#             dev:<tag>-<sha12>, so one run can never mix two commits
#   checkout  the ref whose tests/ and ci/ run. The images' own commit for a
#             workflow_run, an extended-run push, or an explicit sha whose
#             inputs-hash differs from the dispatched ref's. Otherwise the
#             dispatched ref, which may carry newer test scripts than the
#             images: tests/ and ci/ are outside scripts/inputs-hash.sh, so an
#             equal inputs-hash proves the tree still matches the images. It is
#             checked here once rather than in every job (extended.sh pull
#             checks again per job).
#   versions  JSON array of the shards to run, longest first: a matrix.json
#             version (`8.2`) or half of one (`8.4~fpm`, `8.4~cli`, see
#             ci/extended_shards.py). extended.yml expands it as the versions
#             matrix; ci/extended-run.sh resolves a shard id from EXT_ONLY. A
#             tree without ci/extended_shards.py (an older commit tested from
#             its own tree) gets whole versions, as does a run without apps.
#   only, flavor  the validated selections, no spaces
#   fpm       true when the selection has the fpm flavor (corpus-tiers needs it)
#   apps      EXT_APPS, forced to false when the selection has no fpm, cli or
#             cli-builder flavor (an ext-builder-only run has no app to test,
#             so no fixture should be built) or when tests/apps/sets has no
#             cell for any selected version and flavor (a gap in the matrix:
#             cli-builder on a version no builder row covers)
#   bench
#   own       true when the images are the commit's own dev:<tag>-<sha12> (not
#             the floating fallback)
#   full      true when the selection is everything (no only, no flavor, apps
#             on and planned). own, full and checkout == sha are what
#             ci/extended-status.sh needs before it posts the `release/extended`
#             commit status (a pointer: release_source.py trusts the run).
#
# fpm and apps are also what ci/extended-summary.sh reads (from the needs
# context) to decide which jobs had to succeed.
#
# An explicit sha tested from its own tree (its images' inputs-hash differs
# from the dispatched ref's) only works for a commit that already contains
# ci/extended-run.sh, ci/extended-fixtures.sh and ci/extended-summary.sh (the
# commit that added extended.yml, or later): the jobs run that commit's own
# copies. An older one fails here, with a message, not later in a job.
#
# With no sha the images are those the floating dev:<tag> points at (the last
# fully green develop run). The first target's floating tag stands for all of
# them; a target that lacks that commit's tag is reported by pull as MISSING.
# Run from a full-history checkout (git rev-parse of the image commit).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

repo="${EXTENDED_DEV_REPO:-ghcr.io/lotuswebagency/php/dev}"
out="${GITHUB_OUTPUT:-/dev/stdout}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
die() { echo "FAIL: $*" >&2; exit 1; }

sel="$(python3 - "${EXT_ONLY:-}" "${EXT_FLAVOR:-}" <<'PY'
import json, sys
m = json.load(open("matrix.json"))
def key(s): return tuple(int(x) for x in s.split("."))
all_versions = sorted(m["versions"], key=key)
def csv(s): return [x.strip() for x in s.split(",") if x.strip()]
only, flavor = csv(sys.argv[1]), csv(sys.argv[2])
for v in only:
    if v not in all_versions: sys.exit("'%s' is not a version in matrix.json (%s)" % (v, " ".join(all_versions)))
for f in flavor:
    if f not in m["flavors"]: sys.exit("'%s' is not a flavor in matrix.json (%s)" % (f, " ".join(m["flavors"])))
print(json.dumps({
    "versions": [v for v in all_versions if not only or v in only],
    "only": ",".join(only), "flavor": ",".join(flavor),
    "fpm": "true" if not flavor or "fpm" in flavor else "false",
    "apps": "true" if not flavor or {"fpm", "cli", "cli-builder"} & set(flavor) else "false",
}))
PY
)" || die "bad only/flavor input"

first_tag="$(python3 scripts/gen_matrix.py --github targets | jq -r '.include[0].tags[0] | split(":")[1]')"
[ -n "$first_tag" ] || die "no targets from gen_matrix.py"

# image_config <ref> -> the config JSON of the image (its linux/amd64 one for a list).
image_config() {
  local raw
  # Retried on a registry 429/5xx/network error; a missing tag fails at once.
  raw="$(./ci/retry.sh docker buildx imagetools inspect "$1" --format '{{json .Image}}')" || return 1
  jq -c 'if has("config") then . else .["linux/amd64"] end' <<<"$raw"
}

want="${EXT_RUN_SHA:-${EXT_SHA_INPUT:-}}"
floating=0
fallback_note=""
if [ -z "$want" ]; then
  floating=1
else
  sha="$(git rev-parse --verify --quiet "${want}^{commit}" || true)"
  if [ -z "$sha" ]; then
    # Not in the checked-out history (e.g. only on a ref the checkout did not fetch).
    # Retried on a transient git/network error; an unknown ref still falls through
    # to the "not a commit" failure below.
    RETRY_KIND=git ./ci/retry.sh git fetch --no-tags --quiet origin "$want" || true
    sha="$(git rev-parse --verify --quiet "${want}^{commit}" || git rev-parse --verify --quiet 'FETCH_HEAD^{commit}' || true)"
  fi
  [ -n "$sha" ] || die "'$want' is not a commit in this repository"
  if cfg="$(image_config "$repo:${first_tag}-${sha:0:12}")"; then
    echo "plan: found the images of ${sha:0:12} ($repo:${first_tag}-${sha:0:12}): own images"
  elif [ "${EXT_EVENT:-}" = push ] && [ -n "${EXT_RUN_SHA:-}" ]; then
    # A push to extended-run: tests/ and ci/ are outside the inputs-hash, so a
    # commit that only changed them has no images of its own. Test it against
    # the last green develop images when their inputs-hash is this tree's.
    echo "plan: no images of ${sha:0:12} in $repo; trying the floating images of the last green develop run"
    floating=1
    fallback_note=" (no images of its own: ${sha:0:12})"
  else
    die "cannot read $repo:${first_tag}-${sha:0:12} (develop CI has not pushed images for ${sha:0:12}: not a develop commit, still running, failed or pruned; or no read access)"
  fi
fi

if [ "$floating" -eq 0 ]; then
  img_hash="$(jq -r '.config.Labels["com.lotuswebagency.inputs-hash"] // empty' <<<"$cfg")"
  if [ -n "${EXT_RUN_SHA:-}" ]; then
    checkout="$sha"
  elif [ "$img_hash" = "$(bash scripts/inputs-hash.sh)" ]; then
    # Same inputs as the dispatched ref: run its (newer) test scripts. pull
    # --sha only needs the commit in history and a matching inputs-hash.
    checkout="${GITHUB_SHA:?GITHUB_SHA is not set}"
  else
    checkout="$sha"
  fi
  mode="images of ${sha:0:12}, tests from ${checkout:0:12}"
  if [ "$checkout" = "$sha" ]; then
    for f in ci/extended-run.sh ci/extended-fixtures.sh ci/extended-summary.sh tests/apps/appsets.py; do
      git cat-file -e "$sha:$f" 2>/dev/null \
        || die "commit ${sha:0:12} has no $f. A dispatch with sha= whose inputs-hash differs from the ref's tests that commit from its own tree, which only works for commits that already contain the extended workflow and the app cell planner (tests/apps/appsets.py)."
    done
  fi
else
  cfg="$(image_config "$repo:${first_tag}")" || die "cannot read $repo:${first_tag} (no green develop run yet, or no read access to the package)"
  sha="$(jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' <<<"$cfg")"
  img_hash="$(jq -r '.config.Labels["com.lotuswebagency.inputs-hash"] // empty' <<<"$cfg")"
  [ -n "$sha" ] || die "$repo:${first_tag} has no org.opencontainers.image.revision label"
  checkout="${GITHUB_SHA:?GITHUB_SHA is not set}"
  tree_hash="$(bash scripts/inputs-hash.sh)"
  [ "$img_hash" = "$tree_hash" ] \
    || die "the floating images are from ${sha:0:12} (inputs-hash ${img_hash:0:12}); this checkout, ${checkout:0:12}, has inputs-hash ${tree_hash:0:12}. Dispatch with sha=${sha} to test them from their own tree, or wait for develop CI to push images of this commit."
  mode="the floating images from develop commit ${sha:0:12}, tests from ${checkout:0:12}${fallback_note}"
  echo "plan: using the floating images, built from ${sha:0:12} (inputs-hash matches this tree's): not own images"
fi

if [ "${EXT_EVENT:-}" = workflow_run ]; then
  [ "$floating" -eq 0 ] || die "a workflow_run run tests its ci run's images, not the floating ones"
  if [ -z "${EXT_CANDIDATE+x}" ]; then
    # The extended.yml on main (it runs every workflow_run until the next promotion) does not
    # pass a candidate, give the run a name or freeze one for the legs.
    echo "::warning::EXT_CANDIDATE is not set (the extended.yml of the default branch predates the release candidate): the legs pull dev:<tag>-<sha12> by tag, and this run is not titled for ci/release_source.py, so it never qualifies a copy"
    echo "plan: by tag, no release candidate (an older extended.yml): the legs pull dev:<tag>-<sha12>, which a develop rebuild may re-point"
  else
    [ -n "$EXT_CANDIDATE" ] && [ -f "$EXT_CANDIDATE" ] || die "no release candidate of ci run ${EXT_CI_RUN:-?} (the release-candidate artifact is missing or expired): without it the images cannot be pinned by digest"
    [ -n "${EXT_CI_RUN:-}" ] || die "EXT_CI_RUN is not set"
    python3 ci/candidate.py check --candidate "$EXT_CANDIDATE" --sha "$sha" --inputs-hash "$(bash scripts/inputs-hash.sh)" --run-id "$EXT_CI_RUN" \
      || die "the release candidate of ci run $EXT_CI_RUN is not for ${sha:0:12} and this tree"
    echo "plan: by digest, from the release candidate of ci run $EXT_CI_RUN: every leg pulls dev@<index digest>, not the mutable tag"
  fi
else
  echo "plan: by tag, no release candidate (a ${EXT_EVENT:-?} run): the legs pull dev:<tag>-<sha12>, which a develop rebuild may re-point. What this run tests is not what main copies, and it never qualifies a copy"
fi

apps="${EXT_APPS:-true}"
[ "$(jq -r .apps <<<"$sel")" = true ] || apps=false
apps_note=""
if [ "$apps" = true ]; then
  cells="$(python3 tests/apps/appsets.py cells --php "$(jq -r '.versions | join(",")' <<<"$sel")" --flavor "$(jq -r .flavor <<<"$sel")")" \
    || die "tests/apps/sets is not usable (python3 tests/apps/appsets.py check)"
  if [ -z "$cells" ]; then apps=false; apps_note=" (tests/apps/sets has no cell for this selection)"; fi
fi
bench="${EXT_BENCH:-false}"

only_csv="$(jq -r .only <<<"$sel")"
flavor_csv="$(jq -r .flavor <<<"$sel")"
versions_json="$(jq -c .versions <<<"$sel")"
shard_table=""
if git cat-file -e "$checkout:ci/extended_shards.py" 2>/dev/null; then
  versions_json="$(python3 ci/extended_shards.py plan --only "$only_csv" --flavor "$flavor_csv" --apps "$apps")" \
    || die "ci/extended_shards.py plan failed"
  shard_table="$(python3 ci/extended_shards.py plan --only "$only_csv" --flavor "$flavor_csv" --apps "$apps" --table)"
else
  echo "plan: $checkout has no ci/extended_shards.py: whole versions, no shards"
fi
own=false
[ "$floating" -eq 1 ] || own=true
full=false
[ "$own" = true ] && [ -z "$only_csv" ] && [ -z "$flavor_csv" ] && [ "$apps" = true ] && full=true
{
  echo "sha=$sha"
  echo "checkout=$checkout"
  echo "versions=$versions_json"
  echo "only=$(jq -r .only <<<"$sel")"
  echo "flavor=$(jq -r .flavor <<<"$sel")"
  echo "fpm=$(jq -r .fpm <<<"$sel")"
  echo "apps=$apps"
  echo "bench=$bench"
  echo "own=$own"
  echo "full=$full"
} >> "$out"

{
  echo "### extended tests: $mode"
  echo
  echo "versions: $(jq -r '.versions | join(", ")' <<<"$sel"); only '$only_csv', flavor '$flavor_csv', apps ${apps}${apps_note}, bench $bench"
  echo "own images: $own, full selection: $full, tests from the commit's own tree: $( [ "$checkout" = "$sha" ] && echo true || echo false ) ($( [ "$full" = true ] && [ "$checkout" = "$sha" ] && echo "posts release/extended" || echo "no release/extended status" ))"
  if [ -n "$shard_table" ]; then
    echo
    echo "$(jq length <<<"$versions_json") shards per arch, longest first (estimated minutes):"
    echo
    echo "$shard_table"
  fi
} | tee -a "$summary"
