#!/usr/bin/env bash
# One tests/extended.sh subcommand of an extended.yml job, with its own log
# directory (extended.sh truncates results.tsv per invocation) and its summary
# table appended to the job summary.
#
#   EXT_SHA=<full sha> [EXT_ONLY=csv] [EXT_FLAVOR=csv] ci/extended-run.sh <name> <subcommand> [extra args]
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

tests/extended.sh "$sub" "${args[@]}" "$@" 2>&1 | tee "$EXTENDED_LOG_DIR/console.log"
rc="${PIPESTATUS[0]}"

{
  echo "<details><summary>${name} (exit ${rc})</summary>"
  echo
  echo '```'
  awk '/^=== (summary|pull result)/ { f = 1 } f' "$EXTENDED_LOG_DIR/console.log" | tail -80
  echo '```'
  echo "</details>"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit "$rc"
