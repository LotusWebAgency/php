#!/usr/bin/env bash
# Run the application suites across the whole matrix.
#
#   ./tests/apps/run-matrix.sh                    every built lotuswebagency/php target
#   ./tests/apps/run-matrix.sh --only 8.4,8.5 --flavor fpm
#   ./tests/apps/run-matrix.sh --stock            the stock baseline: every
#                                                 version of APPTEST_BUILDER_REPO,
#                                                 fpm suites and cli suites (the
#                                                 stock images have no cli tag for
#                                                 most versions, and their fpm
#                                                 image carries the same php CLI)
#   ./tests/apps/run-matrix.sh --jobs 4 --app wordpress
#   ./tests/apps/run-matrix.sh --list --only 8.4  print the planned cells, touch nothing
#   ./tests/apps/run-matrix.sh --prepare-only --only 8.4
#                                                 pull the service images and
#                                                 pull or build the fixtures
#                                                 the cells need, run nothing
#
# What runs is tests/apps/sets: each image runs the cells of its php version,
# flavor and variant (-v3 or not); an image with no cell is a SKIP row, not a
# run (and is not pulled). ext-builder images have no suites and are not
# planned.
#
# The prepare phase comes first: the service images (nginx, Redis, Memcached)
# are pulled under ci/retry.sh, then the fixtures are pulled or built, serially.
# Nothing after it fetches anything -- the stacks start with pull_policy: never
# on a network without a route out -- and --prepare-only stops there. Then the
# image runs fan out --jobs wide (default 3; each is its own compose project). A
# target whose image is not present locally is reported as MISSING rather
# than silently dropped, so a partial matrix can never read as a full pass.
set -euo pipefail
# shellcheck source=tests/apps/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

STOCK=0
JOBS=3
ONLY=""
FLAVORS=""
LIST=0
PREPARE_ONLY=0
APP_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stock) STOCK=1; shift ;;
    --jobs) JOBS="${2:?}"; shift 2 ;;
    --only) ONLY="${2:?}"; shift 2 ;;
    --flavor) FLAVORS="${2:?}"; shift 2 ;;
    --app) APP_ARGS+=(--app "${2:?}"); shift 2 ;;
    --list) LIST=1; shift ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) apptest_die "unknown argument $1" ;;
  esac
done

apptest_sets_check
for ((i = 1; i < ${#APP_ARGS[@]}; i += 2)); do
  [[ " ${APPTEST_APPS[*]} " == *" ${APP_ARGS[i]} "* ]] \
    || apptest_die "app '${APP_ARGS[i]}' is not in tests/apps/sets (${APPTEST_APPS[*]})"
done

# One line per image run: "<image> <flavor> <php> <variant>".
PLAN=()
if [ "$STOCK" -eq 1 ]; then
  while read -r v; do
    [ -z "$ONLY" ] || [[ ",$ONLY," == *",$v,"* ]] || continue
    for f in fpm cli; do
      [ -z "$FLAVORS" ] || [[ ",$FLAVORS," == *",$f,"* ]] || continue
      PLAN+=("${APPTEST_BUILDER_REPO}:${v}-fpm $f $v baseline")
    done
  done < <(apptest_matrix_versions)
else
  while IFS=$'\t' read -r php flavor tag variant; do
    [ -z "$ONLY" ] || [[ ",$ONLY," == *",$php,"* ]] || continue
    [ -z "$FLAVORS" ] || [[ ",$FLAVORS," == *",$flavor,"* ]] || continue
    # ext-builder is a flavor of the matrix with no app suites.
    case "$flavor" in fpm|cli|cli-builder) ;; *) continue ;; esac
    PLAN+=("$tag $flavor $php $variant")
  done < <(cd "$APPTEST_REPO" && python3 scripts/gen_matrix.py --github targets | python3 -c '
import json, sys
for t in json.load(sys.stdin)["include"]:
    print("\t".join([t["php"], t["flavor"], t["tags"][0], "v3" if t["uarch"] == "v3" else "baseline"]))
')
fi
[ "${#PLAN[@]}" -gt 0 ] || apptest_die "nothing selected"

# Cells per image, from tests/apps/sets alone: nothing below touches docker
# until --list is past.
declare -A CELLS_OF=()
cell_count=0
step_count=0
for row in "${PLAN[@]}"; do
  read -r image flavor php variant <<<"$row"
  args=(--php "$php" --flavor "$flavor" --variant "$variant" "${APP_ARGS[@]}")
  [ "$STOCK" -eq 0 ] || args+=(--stock)
  CELLS_OF["$row"]="$(apptest_cells "${args[@]}")"
  n="$(grep -c . <<<"${CELLS_OF[$row]}" || true)"
  cell_count=$((cell_count + n))
  # A cell is one app release on one image; its steps are the fpm configs, or
  # cli, or builder then cli: the RESULT rows run.sh will write for it.
  while IFS=$'\t' read -r _app _set _php cflavor _variant configs; do
    [ -n "$_app" ] || continue
    case "$cflavor" in
      fpm) step_count=$((step_count + $(tr ',' '\n' <<<"$configs" | grep -c .))) ;;
      cli-builder) step_count=$((step_count + 2)) ;;
      *) step_count=$((step_count + 1)) ;;
    esac
  done <<<"${CELLS_OF[$row]}"
done

if [ "$LIST" -eq 1 ]; then
  for row in "${PLAN[@]}"; do
    read -r image flavor php variant <<<"$row"
    if [ -z "${CELLS_OF[$row]}" ]; then
      printf '%-44s %-11s %-8s no cell\n' "$image" "$flavor" "$variant"
      continue
    fi
    printf '%-44s %-11s %-8s %s\n' "$image" "$flavor" "$variant" \
      "$(awk -F'\t' '{ printf "%s%s %s(%s)", (n++ ? ", " : ""), $1, $2, $6 }' <<<"${CELLS_OF[$row]}")"
  done
  echo
  echo "plan: ${#PLAN[@]} image(s), $cell_count cell(s), $step_count step(s)"
  exit 0
fi

LOG_ROOT="${APPTEST_LOG_DIR:-${TMPDIR:-/tmp}/apptest}"
mkdir -p "$LOG_ROOT"
APPTEST_RESULTS="$LOG_ROOT/results-$(date +%Y%m%d-%H%M%S).tsv"
export APPTEST_RESULTS
: >"$APPTEST_RESULTS"
echo "plan: ${#PLAN[@]} image(s), $cell_count cell(s), $step_count step(s), $JOBS at a time, results $APPTEST_RESULTS"

apptest_ensure_service_images

# Fixtures: every set any planned cell needs, pulled or built serially so
# parallel runs never race to build the same one. --prepare-only does not look
# at the php images (tests/extended.sh pull is theirs): it covers every planned cell.
declare -A NEED=()
MISSING=()
RUNNABLE=()
for row in "${PLAN[@]}"; do
  read -r image flavor php variant <<<"$row"
  if [ -z "${CELLS_OF[$row]}" ]; then
    printf 'RESULT\t-\t-\t%s\t%s\t%s\t-\tSKIP\tno app cell for php %s, %s, %s\n' "$image" "$php" "$flavor" "$php" "$flavor" "$variant" >>"$APPTEST_RESULTS"
    continue
  fi
  if [ "$PREPARE_ONLY" -eq 0 ] && ! docker image inspect "$image" >/dev/null 2>&1 && ! apptest_retry registry docker pull -q "$image" >/dev/null 2>&1; then
    MISSING+=("$image")
    printf 'RESULT\t-\t-\t%s\t-\t%s\t-\tMISSING\timage not present\n' "$image" "$flavor" >>"$APPTEST_RESULTS"
    continue
  fi
  RUNNABLE+=("$row")
  while IFS=$'\t' read -r app set _rest; do
    NEED["$app $set"]=1
  done <<<"${CELLS_OF[$row]}"
done
for key in "${!NEED[@]}"; do
  read -r app set <<<"$key"
  "$APPTEST_ROOT/build-fixture.sh" "$app" "$set" || apptest_die "fixture $app $set failed -- nothing tested"
done

if [ "$PREPARE_ONLY" -eq 1 ]; then
  echo "prepared: service images and ${#NEED[@]} fixture set(s)"
  exit 0
fi

# xargs gives each run its own process; run.sh keeps its own logs, so the
# console only carries the RESULT lines and failures.
if [ "${#RUNNABLE[@]}" -gt 0 ]; then
  printf '%s\n' "${RUNNABLE[@]}" | xargs -P "$JOBS" -I{} bash -c '
    read -r image flavor _php variant <<<"{}"
    "$0/run.sh" "$image" --flavor "$flavor" --variant "$variant" --no-build "${@}" 2>&1 | grep -E "^(RESULT|FAIL|===)" || true
  ' "$APPTEST_ROOT" "${APP_ARGS[@]}"
fi

echo
echo "=== summary ($APPTEST_RESULTS)"
python3 - "$APPTEST_RESULTS" <<'EOF'
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.startswith("RESULT")]
fmt = "{:<44} {:<12} {:<11} {:<9} {:<8} {}"
print(fmt.format("IMAGE", "FLAVOR", "APP", "SET", "STEP", "STATUS"))
bad = skipped = 0
# One row per (app, set, image, step): several sets of one app share a php version.
for _, app, set_, image, php, flavor, step, status, detail in sorted(rows, key=lambda r: (r[4], r[3], r[5], r[1], r[2], r[6])):
    print(fmt.format(image[-44:], flavor, app, set_, step, status if status in ("ok", "SKIP") else f"{status}  {detail}"))
    bad += status not in ("ok", "SKIP")
    skipped += status == "SKIP"
print(f"\n{len(rows) - bad - skipped}/{len(rows) - skipped} ok" + (f", {skipped} skipped (no app cell)" if skipped else ""))
sys.exit(1 if bad else 0)
EOF
