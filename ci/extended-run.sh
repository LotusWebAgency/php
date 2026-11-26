#!/usr/bin/env bash
# One tests/extended.sh subcommand of an extended.yml job, with its own log
# directory (extended.sh truncates results.tsv per invocation) and its summary
# table appended to the job summary.
#
#   EXT_SHA=<full sha> [EXT_ONLY=csv] [EXT_FLAVOR=csv] ci/extended-run.sh <name> <subcommand> [extra args]
#
# The subcommand `apps-prepare` is not one of extended.sh's: it runs
# tests/apps/run-matrix.sh --prepare-only over the same selection, which pulls
# the service images and the fixtures under ci/retry.sh before the `apps` step
# runs anything.
#
# The subcommand `ext-builder` is followed by `jit-stress` (its own log directory and
# results.tsv) in the same step: workflow_run takes extended.yml from the default
# branch, so a jit-stress step added to the yml would not run until it is on main.
#
# EXT_ONLY may be a shard id, `X.Y~fpm` or `X.Y~cli` (ci/extended_shards.py): half of
# a version's app suites. The `fpm` shard carries the rest of the version's work
# (pull of every flavor, uarch, ext-builder, jit-stress), the `cli` shard pulls only
# cli and cli-builder; a step the shard does not carry is a SKIP row. The sharding
# is resolved here, not in extended.yml, because workflow_run takes that file from
# the default branch: the matrix there passes the id as EXT_ONLY, as it does a version.
#
# Logs go to ${EXT_LOG_ROOT:-$RUNNER_TEMP/extended-logs}/<name>/ (what the
# workflow uploads). Exits with extended.sh's own status.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
name="${1:?usage: extended-run.sh <name> <subcommand> [args]}"
sub="${2:?usage: extended-run.sh <name> <subcommand> [args]}"
shift 2

root="${EXT_LOG_ROOT:-${RUNNER_TEMP:-/tmp}/extended-logs}"
export EXTENDED_LOG_DIR="$root/$name"
mkdir -p "$EXTENDED_LOG_DIR"

if [[ "${EXT_ONLY:-}" == *~* ]]; then
  shard="$EXT_ONLY"
  info="$(python3 ci/extended_shards.py resolve "$shard" --flavor "${EXT_FLAVOR:-}")" || exit 1
  version="" pull_flavor="" apps_flavor="" extras=""
  while IFS='=' read -r k v; do
    case "$k" in
      version) version="$v" ;;
      pull_flavor) pull_flavor="$v" ;;
      apps_flavor) apps_flavor="$v" ;;
      extras) extras="$v" ;;
    esac
  done <<<"$info"
  [ -n "$version" ] || { echo "FAIL: cannot resolve shard '$shard'" >&2; exit 1; }
  EXT_ONLY="$version"
  case "$sub" in
    apps|apps-prepare) EXT_FLAVOR="$apps_flavor" ;;
    uarch|ext-builder|jit-stress)
      if [ "$extras" != true ]; then
        note="carried by the ${version}~fpm shard, not $shard"
        echo "$sub: SKIP, $note" | tee "$EXTENDED_LOG_DIR/console.log"
        printf '%s\t-\tSKIP\t0\t%s\n' "$sub" "$note" >"$EXTENDED_LOG_DIR/results.tsv"
        if [ "$sub" = ext-builder ]; then
          mkdir -p "$root/jit-stress"
          printf 'jit-stress\t-\tSKIP\t0\t%s\n' "$note" >"$root/jit-stress/results.tsv"
        fi
        echo "<details><summary>${name} (SKIP: $note)</summary></details>" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
        exit 0
      fi ;;
    *) EXT_FLAVOR="$pull_flavor" ;;
  esac
fi

args=()
[ -z "${EXT_ONLY:-}" ] || args+=(--only "$EXT_ONLY")
[ -z "${EXT_FLAVOR:-}" ] || args+=(--flavor "$EXT_FLAVOR")
[ "$sub" != pull ] || args+=(--sha "${EXT_SHA:?EXT_SHA is not set}")

# tests/test-uarch.sh runs the -v3 image's binaries on an emulated CPU without
# AVX2 and needs a statically linked qemu-x86_64. Ubuntu 26.04's qemu-user is
# static (qemu-user-static is only a virtual package there). It is installed
# here, not in extended.yml: workflow_run takes the workflow file from the
# default branch, so a step there lags the tree under test. The package manager is the Ubuntu
# runner's, not the image's; its own retries cover a flaky mirror, ci/retry.sh a
# dropped connection.
if [ "$sub" = uarch ] && [ -n "${GITHUB_ACTIONS:-}" ] && [ "$(uname -m)" = x86_64 ] \
  && ! command -v qemu-x86_64-static >/dev/null; then
  RETRY_KIND=net ci/retry.sh sudo sh -c 'apt-get -o Acquire::Retries=5 update && apt-get -o Acquire::Retries=5 install -y --no-install-recommends qemu-user' \
    || { echo "uarch: installing qemu-user failed" >&2; exit 1; }
fi

if [ "$sub" = apps-prepare ]; then
  # ext-builder has no app suites, and run-matrix.sh plans nothing for it.
  if [ -n "${EXT_FLAVOR:-}" ]; then
    flavors="$(tr ',' '\n' <<<"$EXT_FLAVOR" | grep -vx ext-builder | paste -sd, - || true)"
    if [ -z "$flavors" ]; then
      echo "apps-prepare: SKIP, ext-builder has no app suites" | tee "$EXTENDED_LOG_DIR/console.log"
      exit 0
    fi
    args=()
    [ -z "${EXT_ONLY:-}" ] || args+=(--only "$EXT_ONLY")
    args+=(--flavor "$flavors")
  fi
  APPTEST_LOG_DIR="$EXTENDED_LOG_DIR" tests/apps/run-matrix.sh --prepare-only "${args[@]}" "$@" 2>&1 | tee "$EXTENDED_LOG_DIR/console.log"
else
  tests/extended.sh "$sub" "${args[@]}" "$@" 2>&1 | tee "$EXTENDED_LOG_DIR/console.log"
fi
rc="${PIPESTATUS[0]}"

{
  echo "<details><summary>${name} (exit ${rc})</summary>"
  echo
  echo '```'
  if [ "$sub" = apps-prepare ]; then tail -40 "$EXTENDED_LOG_DIR/console.log"; else awk '/^=== (summary|pull result)/ { f = 1 } f' "$EXTENDED_LOG_DIR/console.log" | tail -80; fi
  echo '```'
  echo "</details>"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ "$sub" = ext-builder ] && [ -z "${EXT_RUN_CHAINED:-}" ]; then
  EXT_RUN_CHAINED=1 ci/extended-run.sh jit-stress jit-stress || rc=1
fi
exit "$rc"
