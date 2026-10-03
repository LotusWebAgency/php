#!/usr/bin/env bash
# The tests CI does not run, against the images develop CI already tested and
# pushed to GHCR (ghcr.io/lotuswebagency/php/dev), instead of a from-source
# rebuild of all 50 targets on this machine.
#
#   tests/extended.sh pull [--sha REF | --latest] [--only V,..] [--flavor F,..] [--platform P] [--no-corpus]
#   tests/extended.sh uarch | ext-builder | corpus-tiers | smoke [--only V,..] [--flavor F,..]
#   tests/extended.sh apps [--only V,..] [--flavor F,..] [run-matrix.sh args, e.g. --jobs 2 --app laravel]
#   tests/extended.sh bench [--only V,..] [--flavor F,..]        report only, never fails the run
#   tests/extended.sh all [pull flags] [--skip-pull] [run-matrix.sh args]   pull, uarch, ext-builder, corpus-tiers, apps
#                                                                  (not smoke, not bench: those are separate subcommands)
#
# Typical use:  tests/extended.sh pull && tests/extended.sh all
#
# What pull does. Every target's multi-arch list is
# $EXTENDED_DEV_REPO:<tag>-<first 12 of the sha>, where <tag> is what follows
# the colon in the target's first tag (8.5-fpm, 8.4-cli-builder-v3, ...), the
# same list tests/build-all.sh iterates. It is pulled for one explicit
# --platform (default: this daemon's architecture), checked against what a
# green develop run promises -- org.opencontainers.image.revision is the full
# sha, com.lotuswebagency.inputs-hash is this working tree's
# scripts/inputs-hash.sh, the architecture is the one asked for -- and only
# then retagged to the canonical lotuswebagency/php:<tag> every other script in
# this directory expects. Each retag is printed with the image it replaces. The
# PGO corpus tier of each target is pulled by its hash-pinned tag from
# $EXTENDED_CORPUS_REPO (also under --latest), checked the same way and tagged as the floating
# ghcr.io/lotuswebagency/php/corpus:php<tier> that tests/test-pgo.sh reads,
# which is what ci.yml's verify job does too.
#
# The inputs-hash rule has no override. tests/smoke.sh and tests/test-pgo.sh
# fail an image whose label disagrees with the tree (CF-47), and
# SMOKE_ALLOW_STALE would turn that into a green run that proved nothing, so a
# tree that differs from the images' commit is a refusal, with the worktree
# command that fixes it:
#
#   git worktree add ../php-<sha12> <sha>      then run tests/extended.sh from there
#
# --no-corpus leaves the corpus tiers out of the pull, for a run that only tests
# the images (uarch, ext-builder, apps); corpus-tiers and smoke need them.
#
# --latest pulls the floating <tag> refs (the last fully green develop run)
# instead, and then requires every pulled image to agree on one revision and to
# match the tree. A target that cannot be pulled is reported as MISSING, in the
# table and in the exit code: a partial pull never reads as a complete one.
# --platform other than this daemon's architecture is refused -- those images
# cannot run here (arm64 under QEMU crashes in opcache; GitHub's arm64 runner
# is where it is tested), and retagging them would replace the ones that can.
#
# The other subcommands are stateless: nothing remembers what pull fetched, so
# give them the same --only/--flavor. Each one checks the canonical images it is
# about to use for the tree's inputs-hash first (tests/test-uarch.sh,
# test-ext-builder.sh, test-corpus-tiers.sh and apps/run-matrix.sh check no
# label of their own, and this daemon may hold images from older local builds),
# and reports an image that is absent as MISSING and a stale one as STALE
# without running anything against it. A selection a subcommand does not apply
# to (uarch on --only 8.2: there is no 8.2 -v3 target) is SKIP, not a pass; a
# corpus-tiers run that covers only some of a tier's versions is PARTIAL.
#
# Sharding: a run is split across machines (or sessions) with --only/--flavor,
# giving pull and every test step the same selection, e.g.
#   tests/extended.sh pull --only 8.0,8.1 && tests/extended.sh all --skip-pull --only 8.0,8.1
# extended.yml does the same, one job per version.
#
# apps drops the ext-builder flavor: apps/run.sh has no suites for it and
# run-matrix.sh does not count the resulting failure. It also compares the
# RESULT rows run-matrix wrote against the images it was asked to run, so a
# target whose run died before reporting is a FAIL here, not an absence.
#
# Environment:
#   EXTENDED_DEV_REPO      default ghcr.io/lotuswebagency/php/dev
#   EXTENDED_CORPUS_REPO   default ghcr.io/lotuswebagency/php/corpus
#   EXTENDED_LOG_DIR       logs; default a fresh mktemp -d
#
# Exit status: 0 everything that ran passed (SKIP and PARTIAL included) and at
# least one step really ran (a run whose every row is SKIP proved nothing and
# fails), 1 any FAIL/MISSING/STALE/REFUSED or nothing ran, 2 usage error. A step
# whose script exited 0 but skipped its main check (test-uarch.sh on a non-amd64
# pair, test-corpus-tiers.sh with no control image) is recorded PARTIAL. All of `all` runs even after a
# failure; the summary table at the end is the verdict. Needs a docker login
# for ghcr.io with read:packages (see README.md, "Testing develop images
# locally").
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

DEV_REPO="${EXTENDED_DEV_REPO:-ghcr.io/lotuswebagency/php/dev}"
CORPUS_REPO="${EXTENDED_CORPUS_REPO:-ghcr.io/lotuswebagency/php/corpus}"

usage() {
  cat <<'EOF'
usage: tests/extended.sh <subcommand> [options]

  pull [--sha REF | --latest] [--only V,..] [--flavor F,..] [--platform P] [--jobs N] [--no-corpus]
  uarch | ext-builder | corpus-tiers | smoke [--only V,..] [--flavor F,..]
  apps [--only V,..] [--flavor F,..] [run-matrix.sh args, e.g. --jobs 2 --app laravel]
  bench [--only V,..] [--flavor F,..]          report only, never fails the run
  all [pull options] [--skip-pull] [run-matrix.sh args]   pull, uarch, ext-builder, corpus-tiers, apps

  --sha REF          pull: the commit whose images to pull (default: git rev-parse HEAD)
  --latest           pull: the floating tags, i.e. the last fully green develop run
  --only V[,V...]    only these matrix.json versions (repeatable)
  --flavor F[,F...]  only these flavors: fpm, cli, cli-builder, ext-builder (repeatable)
  --platform P       pull: linux/amd64 or linux/arm64, must be this daemon's architecture
  --jobs N           pull: parallel pulls (default 4)
  --skip-pull        all: do not pull first
  --no-corpus        pull, all: do not pull the PGO corpus tiers (corpus-tiers and smoke need them)
EOF
}
usage_die() { echo "FAIL: $*" >&2; echo "(tests/extended.sh --help for usage)" >&2; exit 2; }
die() { echo "FAIL: $*" >&2; exit 1; }

# ------------------------------------------------------------------- options
CMD="${1:-}"
case "$CMD" in
  pull|uarch|ext-builder|corpus-tiers|smoke|apps|bench|all) shift ;;
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
  *) usage_die "unknown subcommand '$CMD'" ;;
esac

ONLY=()
FLAVORS=()
PLATFORM=""
SHA_REF=""
LATEST=0
JOBS=4
SKIP_PULL=0
NO_CORPUS=0
PASSTHRU=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --only) [ "$#" -ge 2 ] || usage_die "--only needs an argument"; IFS=',' read -ra _parts <<<"$2"; ONLY+=("${_parts[@]}"); shift 2 ;;
    --flavor) [ "$#" -ge 2 ] || usage_die "--flavor needs an argument"; IFS=',' read -ra _parts <<<"$2"; FLAVORS+=("${_parts[@]}"); shift 2 ;;
    --platform) [ "$#" -ge 2 ] || usage_die "--platform needs an argument"; PLATFORM="$2"; shift 2 ;;
    --sha) [ "$#" -ge 2 ] || usage_die "--sha needs an argument"; SHA_REF="$2"; shift 2 ;;
    --jobs)
      [ "$#" -ge 2 ] || usage_die "--jobs needs an argument"
      # run-matrix.sh has a --jobs of its own; for apps that is the one meant
      # (and for all it is the pull's, apps keeps its default).
      if [ "$CMD" = apps ]; then PASSTHRU+=("$1" "$2"); else JOBS="$2"; fi
      shift 2 ;;
    --latest) LATEST=1; shift ;;
    --skip-pull) SKIP_PULL=1; shift ;;
    --no-corpus) NO_CORPUS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      [ "$CMD" = apps ] || [ "$CMD" = all ] || usage_die "unknown argument '$1' for $CMD"
      # Anything else belongs to run-matrix.sh; a following word that is not
      # itself an option is that option's value (--jobs 4, --app laravel).
      PASSTHRU+=("$1"); shift
      if [ "$#" -gt 0 ] && [[ "$1" != -* ]]; then PASSTHRU+=("$1"); shift; fi ;;
  esac
done
case "$JOBS" in ''|*[!0-9]*|0) usage_die "--jobs needs a positive integer" ;; esac
case "$CMD" in
  pull|all) ;;
  *) { [ -z "$PLATFORM" ] && [ -z "$SHA_REF" ] && [ "$LATEST" -eq 0 ] && [ "$SKIP_PULL" -eq 0 ] && [ "$NO_CORPUS" -eq 0 ]; } \
       || usage_die "--platform/--sha/--latest/--skip-pull/--no-corpus apply to pull and all only" ;;
esac
[ "$CMD" = all ] || [ "$SKIP_PULL" -eq 0 ] || usage_die "--skip-pull applies to all only"
{ [ "$LATEST" -eq 0 ] || [ -z "$SHA_REF" ]; } || usage_die "--sha and --latest are exclusive"

# Selection: same validation as tests/build-all.sh (tests/matrix-lib.sh).
# shellcheck source=tests/matrix-lib.sh
. "$HERE/matrix-lib.sh"
matrix_load
matrix_validate_selection
matrix_select

for tool in docker python3 git; do
  command -v "$tool" >/dev/null || die "$tool not found on this host"
done
TREE_HASH="$(bash "$ROOT/scripts/inputs-hash.sh")"
HOST_ARCH="$(docker version --format '{{.Server.Arch}}')"
LOG_DIR="${EXTENDED_LOG_DIR:-$(mktemp -d)}"
mkdir -p "$LOG_DIR"
RESULTS="$LOG_DIR/results.tsv"
: >"$RESULTS"

echo "tests/extended.sh $CMD -- inputs-hash $TREE_HASH, logs $LOG_DIR"
[ "$FULL_RUN" -eq 1 ] || echo "selection: ${#SELECTED[@]}/$ALL_TARGET_COUNT targets (--only '${ONLY_CSV}' --flavor '${FLAVOR_CSV}')"

# ------------------------------------------------------------------- helpers
# record <step> <subject> <status> <secs> <note>
record() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >>"$RESULTS"; }

img_label() {  # img_label <image> <label> -> "" when absent
  local v
  v="$(docker image inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true)"
  [ "$v" = "<no value>" ] && v=""
  echo "$v"
}

# image_state <image> -> ok | missing | nolabel | stale:<label>. The tree's
# inputs-hash is the only evidence an image is the one under test (CF-47).
image_state() {
  local h
  docker image inspect "$1" >/dev/null 2>&1 || { echo missing; return; }
  h="$(img_label "$1" com.lotuswebagency.inputs-hash)"
  if [ -z "$h" ]; then echo nolabel
  elif [ "$h" != "$TREE_HASH" ]; then echo "stale:$h"
  else echo ok
  fi
}

# gate <step> <subject> <image> [<image>...] -> 0 when every image is present
# and carries the tree's inputs-hash; otherwise records why (MISSING or STALE)
# against <subject>, prints it, and returns 1 so the caller skips the test.
gate() {
  local step="$1" subject="$2" img state bad=0 note=""
  shift 2
  for img in "$@"; do
    state="$(image_state "$img")"
    case "$state" in
      ok) ;;
      missing) bad=1; note="${note:+$note; }$img is not present locally" ;;
      nolabel) bad=1; note="${note:+$note; }$img has no inputs-hash label" ;;
      stale:*) bad=1; note="${note:+$note; }$img is from another tree (inputs-hash ${state:6:12}, this tree ${TREE_HASH:0:12})" ;;
    esac
  done
  [ "$bad" -eq 0 ] && return 0
  case "$note" in
    *"not present"*) record "$step" "$subject" MISSING 0 "$note -- tests/extended.sh pull" ;;
    *) record "$step" "$subject" STALE 0 "$note -- tests/extended.sh pull from a worktree at the images' commit" ;;
  esac
  echo "--- $step: $subject"
  echo "    NOT RUN: $note"
  return 1
}

# note_revisions <image>... -> which commit(s) the images under test came from.
note_revisions() {
  local revs n
  revs="$(for i in "$@"; do img_label "$i" org.opencontainers.image.revision; done | sort -u | grep . || true)"
  n="$(grep -c . <<<"$revs" || true)"
  case "$n" in
    0) echo "note: no org.opencontainers.image.revision label on the images under test (built locally?)" ;;
    1) echo "revision under test: ${revs:0:12}" ;;
    *) echo "WARNING: the images under test come from $n different revisions: $(tr '\n' ' ' <<<"$revs" | cut -c1-200)" ;;
  esac
}

# run_step <step> <subject> <logname> <command...>: run, time and record one
# test. STEP_OK is the status a zero exit records (PARTIAL for a partial run).
STEP_OK=ok
# Lines a test script prints when it exits 0 without having run its main check.
PARTIAL_MARKERS='note: skipping the x86-64-v3 instruction-mix check|UARCH TESTS PASSED \(partial|no runtime image below floor'
run_step() {
  local step="$1" subject="$2" log="$LOG_DIR/$3.log" t0 rc=0 secs
  shift 3
  echo "--- $step: $subject"
  t0=$(date +%s)
  "$@" >"$log" 2>&1 || rc=$?
  secs=$(( $(date +%s) - t0 ))
  if [ "$rc" -eq 0 ]; then
    # A zero exit from a script that skipped its main check is a pass nobody
    # should read as full coverage: record it PARTIAL, with the line that says so.
    local status="$STEP_OK" note="$log" marker
    marker="$(grep -m1 -E "$PARTIAL_MARKERS" "$log" || true)"
    if [ -n "$marker" ]; then
      status=PARTIAL
      note="partial: $(printf '%s' "$marker" | sed 's/^ *//; s/^note: //' | cut -c1-110) -- $log"
    fi
    echo "    $status (${secs}s)"
    [ -z "$marker" ] || echo "    | $marker"
    record "$step" "$subject" "$status" "$secs" "$note"
  else
    tail -15 "$log" | sed 's/^/    | /'
    echo "    FAILED, exit $rc (${secs}s)"
    record "$step" "$subject" FAIL "$secs" "exit $rc, $log"
  fi
  STEP_OK=ok
}

summary() {  # prints the table; returns 1 when anything failed
  echo
  echo "=== summary (logs: $LOG_DIR)"
  awk -F'\t' '
    BEGIN { printf "%-13s %-44s %-8s %-6s %s\n", "STEP", "SUBJECT", "STATUS", "WALL", "NOTE" }
    { printf "%-13s %-44s %-8s %-6s %s\n", $1, substr($2, 1, 44), $3, ($4 "s"), $5
      n[$3]++ }
    END {
      out = ""
      for (s in n) out = out (out == "" ? "" : ", ") n[s] " " s
      print ""
      print (out == "" ? "nothing recorded" : out)
    }' "$RESULTS"
  if grep -qE $'\t(FAIL|MISSING|STALE|REFUSED)\t' "$RESULTS"; then
    echo "EXTENDED: FAILED"
    return 1
  fi
  if [ ! -s "$RESULTS" ]; then
    echo "EXTENDED: nothing ran"
    return 1
  fi
  # At least one row must be a test that really ran. SKIP says a selection did
  # not apply; pull's own ok row only says images were fetched (except for the
  # pull subcommand, where that is the whole job). Only `all` is held to this:
  # one subcommand that does not apply to its selection (uarch on a version
  # with no -v3 target) is an honest SKIP, and extended.yml runs uarch on every
  # version job -- ci/extended-summary.sh holds each job to at least one test
  # that really ran.
  if ! awk -F'\t' -v cmd="$CMD" '$3 ~ /^(ok|PARTIAL|report)$/ && ($1 != "pull" || cmd == "pull") { f = 1 } END { exit !f }' "$RESULTS"; then
    if [ "$CMD" = all ]; then
      echo "EXTENDED: FAILED (nothing ran: no step recorded ok, PARTIAL or report; every row is SKIP)"
      return 1
    fi
    echo "EXTENDED: ok (nothing applicable: every row is SKIP)"
    return 0
  fi
  if [ "$FULL_RUN" -eq 1 ]; then echo "EXTENDED: ok"
  else echo "EXTENDED: ok (subset: --only '${ONLY_CSV}' --flavor '${FLAVOR_CSV}')"
  fi
}

declare -A TAG_OF=()     # target name -> canonical tag
declare -A PHP_OF=()
declare -A FLAVOR_OF=()
for _row in "${SELECTED[@]}"; do
  IFS=$'\t' read -r _n _f _p _t <<<"$_row"
  TAG_OF[$_n]="$_t"; PHP_OF[$_n]="$_p"; FLAVOR_OF[$_n]="$_f"
done

# corpus_floating <target-name> -> the floating corpus ref its target mounts.
corpus_floating() { matrix_target_field "$1" corpus; }

# ---------------------------------------------------------------------- pull
PULL_DIR=""

# pull_one <key> <ref> <kind: image|corpus> -> writes $PULL_DIR/<key>.status:
# status<TAB>detail<TAB>revision<TAB>image id. A status other than ok is a
# problem the caller reports; nothing here retags.
pull_one() {
  local ref="$2" kind="$3" out="$PULL_DIR/$1.status" log="$PULL_DIR/$1.log" arch rev hash id info
  rm -f "$out"
  if ! docker pull --platform "$PLATFORM" "$ref" >"$log" 2>&1; then
    if grep -qiE 'not found|manifest unknown|no matching manifest|name unknown' "$log"; then
      printf 'MISSING\t%s\t\t\n' "$ref is not in the registry for $PLATFORM" >"$out"
    else
      printf 'PULL-FAILED\t%s\t\t\n' "$(tail -1 "$log" | cut -c1-160)" >"$out"
    fi
    return 0
  fi
  if ! info="$(docker image inspect --format \
    '{{.Architecture}}|{{index .Config.Labels "org.opencontainers.image.revision"}}|{{index .Config.Labels "com.lotuswebagency.inputs-hash"}}|{{.Id}}' "$ref" 2>/dev/null)"; then
    printf 'PULL-FAILED\tinspect failed\t\t\n' >"$out"
    return 0
  fi
  IFS='|' read -r arch rev hash id <<<"$info"
  [ "$rev" = "<no value>" ] && rev=""
  [ "$hash" = "<no value>" ] && hash=""
  if [ "$arch" != "${PLATFORM#linux/}" ]; then
    printf 'WRONG-ARCH\t%s\t\t\n' "image is $arch, asked for ${PLATFORM#linux/}" >"$out"
  elif [ "$hash" != "$TREE_HASH" ]; then
    printf 'INPUTS-MISMATCH\t%s\t%s\t\n' "label '${hash:-none}', this tree $TREE_HASH" "$rev" >"$out"
  elif [ "$kind" = image ] && [ -z "$rev" ]; then
    printf 'NO-REVISION\t%s\t\t\n' "no org.opencontainers.image.revision label" >"$out"
  elif [ "$kind" = image ] && [ "$LATEST" -eq 0 ] && [ "$rev" != "$SHA_FULL" ]; then
    printf 'REVISION-MISMATCH\t%s\t%s\t\n' "label ${rev:0:12}, asked for ${SHA_FULL:0:12}" "$rev" >"$out"
  else
    printf 'ok\t%s\t%s\t%s\n' "" "$rev" "$id" >"$out"
  fi
}

# A job that died without writing its status file is a failed pull, recorded
# like any other, not an abort of the whole run.
status_of() {
  local f="$PULL_DIR/$1.status"
  if [ -s "$f" ]; then cut -f1 "$f"; else echo PULL-FAILED; fi
}
field_of() {
  local f="$PULL_DIR/$1.status"
  if [ -s "$f" ]; then cut -f"$2" "$f"
  elif [ "$2" = 2 ]; then echo "pull job died before writing a status"
  else echo
  fi
}

retag() {  # retag <ref> <canonical>
  local ref="$1" canonical="$2" old new prev
  old="$(docker image inspect --format '{{.Id}}' "$canonical" 2>/dev/null || true)"
  new="$(docker image inspect --format '{{.Id}}' "$ref")"
  old="${old#sha256:}"; new="${new#sha256:}"
  if [ "$old" = "$new" ]; then
    echo "  tag: $canonical already is ${new:0:12}"
  else
    prev="nothing"
    [ -z "$old" ] || prev="${old:0:12}"
    echo "  retag: $canonical <- $ref (${new:0:12}; replaces $prev)"
    docker tag "$ref" "$canonical"
  fi
  # Drop the registry-named tag so the daemon does not list every image twice
  # and dev: refs do not pile up across runs. Only the tag goes: the canonical
  # one keeps the layers (and only after proving it names the same image).
  if [ "$(docker image inspect --format '{{.Id}}' "$canonical" 2>/dev/null)" = "sha256:$new" ]; then
    docker rmi "$ref" >/dev/null 2>&1 || echo "  note: could not untag $ref"
  fi
}

cmd_pull() {
  [ -n "$PLATFORM" ] || PLATFORM="linux/$HOST_ARCH"
  case "$PLATFORM" in linux/amd64|linux/arm64) ;; *) usage_die "--platform must be linux/amd64 or linux/arm64" ;; esac
  if [ "${PLATFORM#linux/}" != "$HOST_ARCH" ]; then
    record pull "$PLATFORM" REFUSED 0 "daemon is $HOST_ARCH"
    echo "REFUSED: $PLATFORM images cannot run on this $HOST_ARCH daemon, and retagging them to lotuswebagency/php:* would replace the ones that can. Pull them where the daemon is ${PLATFORM#linux/} (GitHub's runner does)." >&2
    return 3
  fi
  SHA_FULL=""
  local suffix="" row name flavor php tag n=0 tier_tag
  if [ "$LATEST" -eq 0 ]; then
    SHA_FULL="$(git rev-parse --verify --quiet "${SHA_REF:-HEAD}^{commit}")" || usage_die "'${SHA_REF:-HEAD}' is not a commit in this repository"
    suffix="-${SHA_FULL:0:12}"
    echo "pull: $PLATFORM images of ${SHA_FULL:0:12} from $DEV_REPO"
  else
    echo "pull: $PLATFORM images of the floating tags (last green develop run) from $DEV_REPO"
  fi
  PULL_DIR="$LOG_DIR/pull"
  mkdir -p "$PULL_DIR"

  local -a keys=() refs=() canon=() kinds=()
  for row in "${SELECTED[@]}"; do
    IFS=$'\t' read -r name flavor php tag <<<"$row"
    keys+=("$name"); refs+=("$DEV_REPO:${tag#*:}$suffix"); canon+=("$tag"); kinds+=(image)
  done
  declare -A seen_tier=()
  for row in "${SELECTED[@]}"; do
    [ "$NO_CORPUS" -eq 0 ] || break
    IFS=$'\t' read -r name flavor php tag <<<"$row"
    tier_tag="$(corpus_floating "$name")"
    [ -z "${seen_tier[$tier_tag]:-}" ] || continue
    seen_tier[$tier_tag]=1
    keys+=("corpus-${tier_tag#*:}")
    # Hash-pinned even under --latest, as ci.yml mounts it: the floating corpus
    # tag is repointed before a run is green and can lag a revert. The images
    # are required to match this tree's hash, so the corpus has to as well.
    refs+=("$CORPUS_REPO:${tier_tag#*:}-$TREE_HASH")
    canon+=("$tier_tag"); kinds+=(corpus)
  done

  # The first image alone, before the other ~50: every image of a commit shares
  # one inputs-hash, so a tree that differs from it differs from all of them.
  pull_one "${keys[0]}" "${refs[0]}" "${kinds[0]}"
  local first_status
  first_status="$(status_of "${keys[0]}")"
  if [ "$first_status" = MISSING ] || [ "$first_status" = PULL-FAILED ]; then
    record pull "${keys[0]}" "$([ "$first_status" = MISSING ] && echo MISSING || echo FAIL)" 0 "$first_status: $(field_of "${keys[0]}" 2)"
    {
      echo "ABORTED: the first image, ${refs[0]}, could not be pulled ($first_status: $(field_of "${keys[0]}" 2))."
      echo "Not trying the other $((${#keys[@]} - 1)) refs; nothing was retagged. Log: $PULL_DIR/${keys[0]}.log"
      if [ "$first_status" = MISSING ]; then
        echo "HEAD may have no images: its develop run was cancelled, failed or pruned, or it is not a develop commit."
        echo "  --latest   pulls the last fully green run; it works when that run's inputs-hash equals this tree's (an earlier commit with the same inputs)"
        echo "  --sha REF  names another commit"
      else
        echo "Check 'docker login ghcr.io' (a token with read:packages) and the repository name (EXTENDED_DEV_REPO, now $DEV_REPO)."
      fi
    } >&2
    return 3
  fi
  if [ "$first_status" = INPUTS-MISMATCH ]; then
    local wt_sha
    wt_sha="${SHA_FULL:-$(field_of "${keys[0]}" 3)}"
    record pull "${keys[0]}" REFUSED 0 "inputs-hash differs from this tree"
    {
      echo "REFUSED: ${refs[0]} does not match this working tree ($(field_of "${keys[0]}" 2))."
      echo "tests/smoke.sh and tests/test-pgo.sh fail every image on that mismatch (CF-47), and SMOKE_ALLOW_STALE would only hide it."
      echo "Nothing was retagged. Check the images' commit out in its own worktree and run tests/extended.sh from there:"
      echo "  git worktree add ../php-${wt_sha:0:12} ${wt_sha:-<sha>}"
      echo "Or the tree is not the commit it looks like: uncommitted changes in a hashed path (scripts/inputs-hash.sh) change the hash too -- check 'git status'."
      echo "If HEAD has no images (its develop run was cancelled), --latest pulls the last green run, which has the same inputs-hash when only unhashed files changed since."
    } >&2
    return 3
  fi

  local i
  for ((i = 1; i < ${#keys[@]}; i++)); do
    pull_one "${keys[$i]}" "${refs[$i]}" "${kinds[$i]}" &
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
  done
  wait

  # --latest: the floating tags are only a snapshot if they all name one commit.
  if [ "$LATEST" -eq 1 ]; then
    local revs
    revs="$(for ((i = 0; i < ${#keys[@]}; i++)); do
      [ "${kinds[$i]}" = image ] && [ "$(status_of "${keys[$i]}")" = ok ] && field_of "${keys[$i]}" 3
    done | sort -u)"
    if [ "$(grep -c . <<<"$revs" || true)" -gt 1 ]; then
      record pull "floating tags" REFUSED 0 "images disagree on their revision"
      echo "REFUSED: the floating tags name more than one commit (a develop run was mid-publish, or one target is behind):" >&2
      for ((i = 0; i < ${#keys[@]}; i++)); do
        [ "${kinds[$i]}" = image ] && [ "$(status_of "${keys[$i]}")" = ok ] && printf '  %-28s %s\n' "${keys[$i]}" "$(field_of "${keys[$i]}" 3 | cut -c1-12)" >&2
      done
      echo "Nothing was retagged. Retry once the run has finished, or pull a fixed commit with --sha." >&2
      return 3
    fi
    echo "floating tags agree on revision ${revs:0:12}"
  fi

  echo
  echo "=== retagging"
  local bad=0
  for ((i = 0; i < ${#keys[@]}; i++)); do
    if [ "$(status_of "${keys[$i]}")" = ok ]; then
      retag "${refs[$i]}" "${canon[$i]}"
      n=$((n + 1))
    fi
  done

  echo
  echo "=== pull result: $PLATFORM"
  printf '%-30s %-18s %s\n' TARGET STATUS DETAIL
  for ((i = 0; i < ${#keys[@]}; i++)); do
    local st
    st="$(status_of "${keys[$i]}")"
    printf '%-30s %-18s %s\n' "${keys[$i]}" "$st" "$(field_of "${keys[$i]}" 2)"
    if [ "$st" != ok ]; then
      bad=$((bad + 1))
      record pull "${keys[$i]}" "$([ "$st" = MISSING ] && echo MISSING || echo FAIL)" 0 "$st: $(field_of "${keys[$i]}" 2)"
    fi
  done
  if [ "$bad" -eq 0 ]; then
    echo "PULL COMPLETE: ${#keys[@]}/${#keys[@]} (${#SELECTED[@]} images, $((${#keys[@]} - ${#SELECTED[@]})) corpus tiers)"
    record pull "${#keys[@]} refs" ok 0 "$PLATFORM"
  else
    echo "PULL INCOMPLETE: $bad of ${#keys[@]} refs not usable (see above); $n retagged" >&2
  fi
  return 0
}

# ---------------------------------------------------------------- the tests
cmd_smoke() {
  local row name flavor php tag
  for row in "${SELECTED[@]}"; do
    IFS=$'\t' read -r name flavor php tag <<<"$row"
    gate smoke "$name" "$tag" "$(corpus_floating "$name")" || continue
    run_step smoke "$name" "smoke-$name" ./tests/smoke.sh "$tag" "$php" "$flavor"
  done
}

cmd_uarch() {
  local row name flavor php tag base pairs=0
  for row in "${SELECTED[@]}"; do
    IFS=$'\t' read -r name flavor php tag <<<"$row"
    case "$name" in *-v3) ;; *) continue ;; esac
    base="${name%-v3}"
    pairs=$((pairs + 1))
    [ -n "${TAG_OF[$base]:-}" ] || { record uarch "$name" FAIL 0 "baseline target $base is not in the selection"; continue; }
    gate uarch "$name" "${TAG_OF[$base]}" "$tag" || continue
    run_step uarch "$name" "uarch-$name" ./tests/test-uarch.sh "${TAG_OF[$base]}" "$tag"
  done
  [ "$pairs" -gt 0 ] || { record uarch "-" SKIP 0 "no -v3 target in this selection"; echo "--- uarch: SKIP, no -v3 target in this selection"; }
}

cmd_ext_builder() {
  local v e="" versions
  mapfile -t versions < <(matrix_ext_versions)
  if [ "${#versions[@]}" -eq 0 ]; then
    record ext-builder "-" SKIP 0 "no version has ext-builder, fpm and cli all selected"
    echo "--- ext-builder: SKIP, no version has ext-builder, fpm and cli all selected"
    return 0
  fi
  for v in "${versions[@]}"; do
    e="php-${v//./_}"
    gate ext-builder "$v" "${TAG_OF[$e-ext-builder]}" "${TAG_OF[$e-fpm]}" "${TAG_OF[$e-cli]}" || continue
    run_step ext-builder "$v" "ext-builder-$v" ./tests/test-ext-builder.sh "$v"
  done
}

cmd_corpus_tiers() {
  local floor _release _builder ctag versions v e touched=0 partial control
  local -a tier_versions in_sel sel_fpm control_img
  declare -A fpm_sel=()
  for e in "${!FLAVOR_OF[@]}"; do
    [ "${FLAVOR_OF[$e]}" = fpm ] && [[ "$e" != *-v3 ]] && fpm_sel["${PHP_OF[$e]}"]="${TAG_OF[$e]}"
  done
  while IFS=$'\t' read -r floor _release _builder ctag versions; do
    IFS=',' read -ra tier_versions <<<"$versions"
    in_sel=()
    for v in "${tier_versions[@]}"; do [ -z "${fpm_sel[$v]:-}" ] || in_sel+=("$v"); done
    [ "${#in_sel[@]}" -gt 0 ] || continue
    touched=1
    partial=0
    [ "${#in_sel[@]}" -eq "${#tier_versions[@]}" ] || partial=1
    sel_fpm=()
    for v in "${in_sel[@]}"; do sel_fpm+=("${fpm_sel[$v]}"); done
    # The below-floor control test-corpus-tiers.sh picks up by itself, when it
    # is on this daemon, has to be this tree's as well; a stale one would be
    # used as if it proved something.
    control="$(python3 "$ROOT/scripts/pgo_tiers.py" control-of "$floor")"
    control_img=()
    if [ -n "$control" ] && [ "$(image_state "lotuswebagency/php:$control-fpm")" != missing ]; then
      control_img=("lotuswebagency/php:$control-fpm")
    fi
    gate corpus-tiers "tier $floor" "$ctag" "${sel_fpm[@]}" "${control_img[@]}" || continue
    if [ "$partial" -eq 1 ]; then
      # test-corpus-tiers.sh replays every tier version it finds locally and
      # takes no version filter; say so when that includes images outside the
      # selection (a stale one fails the replay, or proves nothing).
      for v in "${tier_versions[@]}"; do
        [ -z "${fpm_sel[$v]:-}" ] || continue
        e="lotuswebagency/php:$v-fpm"
        [ "$(image_state "$e")" = missing ] \
          || echo "    note: $e is outside the selection but present, and test-corpus-tiers.sh replays it anyway ($(image_state "$e"))"
      done
      STEP_OK=PARTIAL
      run_step corpus-tiers "tier $floor (${in_sel[*]} of ${versions//,/ })" "corpus-tiers-$floor" \
        env CORPUS_TIER_SKIP_MISSING=1 ./tests/test-corpus-tiers.sh "$floor"
    else
      run_step corpus-tiers "tier $floor (${versions//,/ })" "corpus-tiers-$floor" ./tests/test-corpus-tiers.sh "$floor"
    fi
  done < <(python3 "$ROOT/scripts/pgo_tiers.py" list)
  [ "$touched" -eq 1 ] || { record corpus-tiers "-" SKIP 0 "no fpm image of a tier in this selection"; echo "--- corpus-tiers: SKIP, no fpm image of a tier in this selection"; }
}

# apps: run-matrix.sh over the selection, minus ext-builder (see the header).
# The selection is narrowed for the run and put back afterwards.
cmd_apps() {
  local stock=0 a
  for a in "${PASSTHRU[@]:-}"; do [ "$a" = --stock ] && stock=1; done
  if [ "$stock" -eq 1 ]; then
    [ "${#FLAVORS[@]}" -eq 0 ] || usage_die "apps --stock runs the stock baseline images, which have no flavors; --flavor does not apply"
    apps_run 1
    return 0
  fi

  local -a keep_sel=("${SELECTED[@]}") keep_flavors=("${FLAVORS[@]:-}") fl=()
  local keep_full="$FULL_RUN" keep_only="$ONLY_CSV" keep_flavor_csv="$FLAVOR_CSV"
  if [ "${#FLAVORS[@]}" -eq 0 ]; then
    fl=(fpm cli cli-builder)
  else
    for a in "${FLAVORS[@]}"; do [ "$a" = ext-builder ] || fl+=("$a"); done
  fi
  if [ "${#fl[@]}" -eq 0 ]; then
    record apps "-" SKIP 0 "ext-builder has no app suites"
    echo "--- apps: SKIP, ext-builder has no app suites"
    return 0
  fi
  FLAVORS=("${fl[@]}")
  matrix_select
  apps_run 0
  SELECTED=("${keep_sel[@]}"); FLAVORS=("${keep_flavors[@]}")
  FULL_RUN="$keep_full"; ONLY_CSV="$keep_only"; FLAVOR_CSV="$keep_flavor_csv"
}

apps_run() {  # apps_run <stock 0|1>
  local stock="$1" row name flavor php tag log="$LOG_DIR/apps.log" rc=0 bad=0 t0 secs results
  local -a tags=() args=()
  if [ "$stock" -eq 0 ]; then
    for row in "${SELECTED[@]}"; do
      IFS=$'\t' read -r name flavor php tag <<<"$row"
      tags+=("$tag")
      gate apps "$tag" "$tag" || bad=1
    done
    # Without this run-matrix.sh would docker-pull a missing lotuswebagency/php:*
    # tag from Docker Hub and test whatever answers.
    [ "$bad" -eq 0 ] || { echo "--- apps: NOT RUN, images above are missing or stale"; return 0; }
    note_revisions "${tags[@]}"
  fi

  mkdir -p "$LOG_DIR/apps"
  [ -z "$ONLY_CSV" ] || args+=(--only "$ONLY_CSV")
  [ "$stock" -eq 1 ] || args+=(--flavor "$FLAVOR_CSV")
  args+=("${PASSTHRU[@]}")
  echo "--- apps: tests/apps/run-matrix.sh ${args[*]} (log $log)"
  [ -z "${APPTEST_FIXTURE_REPO:-}" ] || echo "    fixtures: $APPTEST_FIXTURE_REPO"
  t0=$(date +%s)
  set +e
  APPTEST_LOG_DIR="$LOG_DIR/apps" bash "$ROOT/tests/apps/run-matrix.sh" "${args[@]}" 2>&1 | tee "$log"
  rc="${PIPESTATUS[0]}"
  set -e
  secs=$(( $(date +%s) - t0 ))
  if [ "$stock" -eq 1 ]; then
    if [ "$rc" -eq 0 ]; then record apps "stock baseline" ok "$secs" "$log"
    else record apps "stock baseline" FAIL "$secs" "exit $rc, $log"
    fi
    return 0
  fi
  # The results file of THIS run, named on run-matrix.sh's plan line; a glob
  # would also find the files of earlier runs in a reused EXTENDED_LOG_DIR.
  results="$(sed -n 's/^plan: .* results //p' "$log" | tail -1)"
  if [ -z "$results" ] || [ ! -e "$results" ]; then
    record apps "run-matrix.sh" FAIL "$secs" "exit $rc, wrote no results file for this run, $log"
    return 0
  fi
  # run-matrix.sh's exit status comes from its RESULT rows alone. Compare them
  # with the images it was asked to run, so a run that died before reporting is
  # a FAIL here rather than an absence.
  python3 - "$results" "$secs" "$log" "$RESULTS" "${SELECTED[@]}" <<'EOF'
import sys

results, secs, log, out = sys.argv[1:5]
expected = []
for row in sys.argv[5:]:
    _name, flavor, _php, tag = row.split("\t")
    expected.append((tag, flavor))
rows = [l.rstrip("\n").split("\t") for l in open(results) if l.startswith("RESULT")]
with open(out, "a") as f:
    for tag, flavor in expected:
        mine = [r for r in rows if r[3] == tag and r[5] == flavor]
        bad = [r for r in mine if r[7] != "ok"]
        if not mine:
            note = "no RESULT row: run.sh died before reporting (%s)" % log
            status = "FAIL"
        elif bad:
            first = bad[0]
            note = "%d/%d steps ok; %s %s %s: %s" % (len(mine) - len(bad), len(mine), first[1], first[2], first[6], first[8][:70])
            status = "FAIL"
        else:
            note = "%d steps" % len(mine)
            status = "ok"
        f.write("\t".join(["apps", tag, status, secs, note]) + "\n")
EOF
}

cmd_bench() {
  local row name flavor php tag rc t0 secs
  local -a want_flavors=("${FLAVORS[@]:-cli}")
  for row in "${SELECTED[@]}"; do
    IFS=$'\t' read -r name flavor php tag <<<"$row"
    [[ " ${want_flavors[*]} " == *" $flavor "* ]] || continue
    if [ "$(image_state "$tag")" != ok ]; then
      record bench "$name" SKIP 0 "NOT RUN: $tag is missing or from another tree"
      echo "--- bench: $name NOT RUN, $tag is missing or from another tree"
      continue
    fi
    echo "--- bench: $name (report only; noisy, never a verdict)"
    rc=0
    t0=$(date +%s)
    ./tests/bench.sh "$tag" auto "$php" >"$LOG_DIR/bench-$name.log" 2>&1 || rc=$?
    secs=$(( $(date +%s) - t0 ))
    tail -40 "$LOG_DIR/bench-$name.log"
    record bench "$name" report "$secs" "exit $rc (not a verdict), $LOG_DIR/bench-$name.log"
  done
}

rc=0
case "$CMD" in
  pull) cmd_pull || rc=$? ;;
  smoke) cmd_smoke ;;
  uarch) cmd_uarch ;;
  ext-builder) cmd_ext_builder ;;
  corpus-tiers) cmd_corpus_tiers ;;
  apps) cmd_apps ;;
  bench) cmd_bench ;;
  all)
    pull_rc=0
    if [ "$SKIP_PULL" -eq 0 ]; then cmd_pull || pull_rc=$?; fi
    if [ "$pull_rc" -eq 3 ]; then
      echo "pull was refused; not running the tests against images that cannot be the ones under test" >&2
    else
      cmd_uarch
      cmd_ext_builder
      cmd_corpus_tiers
      cmd_apps
    fi ;;
esac
[ "$rc" -ne 3 ] || { summary || true; exit 1; }
summary
