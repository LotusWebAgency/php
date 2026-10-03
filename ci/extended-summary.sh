#!/usr/bin/env bash
# The verdict of an extended.yml run, from the jobs' results and the
# results.tsv files they uploaded.
#
#   NEEDS_JSON='<toJson(needs)>' ci/extended-summary.sh <artifacts-dir>
#
# <artifacts-dir> holds one directory per uploaded extended-logs-<job> artifact,
# each with <step>/results.tsv inside (tests/extended.sh's format: step,
# subject, status, wall seconds, note). Prints a markdown report to
# $GITHUB_STEP_SUMMARY and exits 1 when a required job failed, was cancelled,
# or reported a FAIL/MISSING/STALE/REFUSED row. The bench jobs are report-only
# and never count.
set -uo pipefail
dir="${1:?usage: extended-summary.sh <artifacts-dir>}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
needs="${NEEDS_JSON:?NEEDS_JSON is not set}"
required=(plan fixtures versions corpus-tiers)

rows="$(mktemp)"
while IFS= read -r f; do
  label="${f#"$dir"/}"
  label="${label%%/*}"
  label="${label#extended-logs-}"
  awk -F'\t' -v l="$label" '{ print l "\t" $0 }' "$f"
done < <(find "$dir" -name results.tsv 2>/dev/null | sort) >"$rows"

fail=0
report="$(mktemp)"
{
  echo "### extended tests: verdict"
  echo
  echo "| job | result |"
  echo "|---|---|"
  jq -r 'to_entries[] | "| \(.key) | \(.value.result) |"' <<<"$needs"
  echo
  for j in "${required[@]}"; do
    r="$(jq -r --arg j "$j" '.[$j].result // "absent"' <<<"$needs")"
    case "$r" in
      success|skipped) ;;
      *) fail=1; echo "- required job \`$j\`: $r" ;;
    esac
  done
  plan="$(jq -r '.plan.result // "absent"' <<<"$needs")"
  if [ "$plan" = success ] && [ ! -s "$rows" ]; then
    fail=1
    echo "- no results.tsv was uploaded by any job: nothing is known to have run"
  fi
  if [ -s "$rows" ]; then
    echo
    echo "| leg | step | subject | status | wall | note |"
    echo "|---|---|---|---|---|---|"
    # Failures first, then what is neither ok nor SKIP (partial runs, bench reports); at most 200 lines each.
    awk -F'\t' '$4 ~ /^(FAIL|MISSING|STALE|REFUSED)$/ && $1 !~ /^bench/ { printf "| %s | %s | %s | **%s** | %ss | %s |\n", $1, $2, $3, $4, $5, $6 }' "$rows" | head -200
    awk -F'\t' '$4 !~ /^(FAIL|MISSING|STALE|REFUSED|ok|SKIP)$/ || ($1 ~ /^bench/ && $4 != "SKIP") { printf "| %s | %s | %s | %s | %ss | %s |\n", $1, $2, $3, $4, $5, $6 }' "$rows" | head -200
    echo
    echo "$(awk -F'\t' '$4 == "ok"' "$rows" | wc -l) ok and $(awk -F'\t' '$4 == "SKIP"' "$rows" | wc -l) SKIP rows not listed; every row is in the uploaded extended-logs artifacts."
    if awk -F'\t' '$4 ~ /^(FAIL|MISSING|STALE|REFUSED)$/ && $1 !~ /^bench/ { f = 1 } END { exit !f }' "$rows"; then fail=1; fi
  fi
  echo
  if [ "$fail" -eq 0 ]; then echo "**EXTENDED: ok**"; else echo "**EXTENDED: FAILED**"; fi
} >"$report"
cat "$report" >>"$summary"
cat "$report"
rm -f "$rows" "$report"
exit "$fail"
