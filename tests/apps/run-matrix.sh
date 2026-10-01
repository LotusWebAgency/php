#!/usr/bin/env bash
# Run the application suites across the whole matrix.
#
#   ./tests/apps/run-matrix.sh                    every built lotuswebagency/php target
#   ./tests/apps/run-matrix.sh --only 8.4,8.5 --flavor fpm
#   ./tests/apps/run-matrix.sh --stock            the stock baseline: every
#                                                 version of APPTEST_BUILDER_REPO,
#                                                 fpm suites and cli suites (the
#                                                 predecessor has no cli tag for
#                                                 most versions, and its fpm
#                                                 image carries the same php CLI)
#   ./tests/apps/run-matrix.sh --jobs 4 --app wordpress
#
# Fixtures are built (or confirmed current) first, serially, then the image
# runs fan out --jobs wide (default 3; each is its own compose project). A
# target whose image is not present locally is reported as MISSING rather
# than silently dropped, so a partial matrix can never read as a full pass.
set -euo pipefail
# shellcheck source=tests/apps/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

STOCK=0
JOBS=3
ONLY=""
FLAVORS=""
APP_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stock) STOCK=1; shift ;;
    --jobs) JOBS="${2:?}"; shift 2 ;;
    --only) ONLY="${2:?}"; shift 2 ;;
    --flavor) FLAVORS="${2:?}"; shift 2 ;;
    --app) APP_ARGS+=(--app "${2:?}"); shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) apptest_die "unknown argument $1" ;;
  esac
done

apptest_sets_check

# One line per run: "<image> <flavor>".
PLAN=()
if [ "$STOCK" -eq 1 ]; then
  while read -r v; do
    [ -z "$ONLY" ] || [[ ",$ONLY," == *",$v,"* ]] || continue
    for f in fpm cli; do
      [ -z "$FLAVORS" ] || [[ ",$FLAVORS," == *",$f,"* ]] || continue
      PLAN+=("${APPTEST_BUILDER_REPO}:${v}-fpm $f")
    done
  done < <(apptest_matrix_versions)
else
  while IFS=$'\t' read -r php flavor tag; do
    [ -z "$ONLY" ] || [[ ",$ONLY," == *",$php,"* ]] || continue
    [ -z "$FLAVORS" ] || [[ ",$FLAVORS," == *",$flavor,"* ]] || continue
    PLAN+=("$tag $flavor")
  done < <(cd "$APPTEST_REPO" && python3 scripts/gen_matrix.py --github targets | python3 -c '
import json, sys
for t in json.load(sys.stdin)["include"]:
    print("\t".join([t["php"], t["flavor"], t["tags"][0]]))
')
fi
[ "${#PLAN[@]}" -gt 0 ] || apptest_die "nothing selected"

LOG_ROOT="${APPTEST_LOG_DIR:-$APPTEST_REPO/.claude/tmp/apptest}"
mkdir -p "$LOG_ROOT"
APPTEST_RESULTS="$LOG_ROOT/results-$(date +%Y%m%d-%H%M%S).tsv"
export APPTEST_RESULTS
: >"$APPTEST_RESULTS"
echo "plan: ${#PLAN[@]} run(s), $JOBS at a time, results $APPTEST_RESULTS"

# Fixtures first: every set any planned image resolves to, built serially so
# parallel runs never race to build the same one.
declare -A NEED=()
MISSING=()
RUNNABLE=()
for row in "${PLAN[@]}"; do
  read -r image flavor <<<"$row"
  if ! docker image inspect "$image" >/dev/null 2>&1 && ! docker pull -q "$image" >/dev/null 2>&1; then
    MISSING+=("$image")
    printf 'RESULT\t-\t-\t%s\t-\t%s\t-\tMISSING\timage not present\n' "$image" "$flavor" >>"$APPTEST_RESULTS"
    continue
  fi
  RUNNABLE+=("$row")
  php="$(apptest_image_php "$image")"
  for app in "${APPTEST_APPS[@]}"; do
    if [ "${#APP_ARGS[@]}" -gt 0 ] && [[ " ${APP_ARGS[*]} " != *" $app "* ]]; then continue; fi
    NEED["$app $(apptest_resolve_set "$app" "$php")"]=1
  done
done
for key in "${!NEED[@]}"; do
  read -r app set <<<"$key"
  "$APPTEST_ROOT/build-fixture.sh" "$app" "$set" || apptest_die "fixture $app $set failed -- nothing tested"
done

# xargs gives each run its own process; run.sh keeps its own logs, so the
# console only carries the RESULT lines and failures.
printf '%s\n' "${RUNNABLE[@]}" | xargs -P "$JOBS" -I{} bash -c '
  read -r image flavor <<<"{}"
  "$0/run.sh" "$image" --flavor "$flavor" --no-build "${@}" 2>&1 | grep -E "^(RESULT|FAIL|===)" || true
' "$APPTEST_ROOT" "${APP_ARGS[@]}"

echo
echo "=== summary ($APPTEST_RESULTS)"
python3 - "$APPTEST_RESULTS" <<'EOF'
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.startswith("RESULT")]
fmt = "{:<44} {:<12} {:<11} {:<9} {:<8} {}"
print(fmt.format("IMAGE", "FLAVOR", "APP", "SET", "STEP", "STATUS"))
bad = 0
for _, app, set_, image, php, flavor, step, status, detail in sorted(rows, key=lambda r: (r[4], r[3], r[5], r[1], r[6])):
    print(fmt.format(image[-44:], flavor, app, set_, step, status if status == "ok" else f"{status}  {detail}"))
    bad += status != "ok"
print(f"\n{len(rows) - bad}/{len(rows)} ok")
sys.exit(1 if bad else 0)
EOF
