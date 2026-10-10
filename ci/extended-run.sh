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

args=()
[ -z "${EXT_ONLY:-}" ] || args+=(--only "$EXT_ONLY")
[ -z "${EXT_FLAVOR:-}" ] || args+=(--flavor "$EXT_FLAVOR")
[ "$sub" != pull ] || args+=(--sha "${EXT_SHA:?EXT_SHA is not set}")

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
exit "$rc"
