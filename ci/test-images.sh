#!/usr/bin/env bash
# Test every image of one build entry: one PHP version, one microarchitecture,
# one architecture (an element of `scripts/gen_matrix.py --github version`).
#
#   ci/test-images.sh --entry FILE|- --out DIR [--mode load|digest] [--digests FILE] [--arch amd64|arm64]
#
#   --entry    the matrix entry as JSON (php, uarch, arch, corpus, targets[name, flavor, tag]).
#   --mode     load (default): the images are in the local daemon under their target tags,
#              as `docker buildx bake --load` leaves them (tests/matrix-lib.sh's local_tag
#              names them outside GitHub Actions).
#              digest: the images are in a registry. --digests names a JSON object
#              {"<target name>": "<repo>@sha256:<index digest>"}; every ref is pulled back
#              (ci/retry.sh), tested by that digest, and fpm, cli and ext-builder are also
#              tagged with their local names for tests/test-ext-builder.sh. A passing
#              target gets its signed test-result predicate (ci/result_predicate.py).
#   --arch     defaults to the entry's; every image must be that architecture.
#   --out      per target <out>/<name>/{test.log,smoke.log,status}; digest mode also
#              <out>/<name>/artifact/{<arch>,<arch>.test-result.json} (the digest file and
#              the predicate the merge job attaches); <out>/results.json and passed.txt.
#
# Per target, stopping at its first failing step:
#   smoke           tests/smoke.sh <image> <php> <flavor>
#   slim parity     slim flavors only: fpm-slim against fpm, cli-slim against cli-builder
#                   (--full-is-builder)
#   ext-builder     ext-builder only: tests/test-ext-builder.sh against the entry's fpm and cli
#   trivy           vulnerability gate, KEV report + gate, OS package floor, AGPL license gate:
#                   the flags of the Trivy steps in ci.yml
#   predicate       digest mode only, once everything above passed
# Every target runs whatever the others do; the exit status is 0 when all passed, 1 when any
# target failed, 2 for a usage error. A summary per target goes to stdout and to
# $GITHUB_STEP_SUMMARY.
#
# Environment:
#   TEST_IMAGES_JOBS    targets tested at once (default 1; see "Concurrency" below)
#   CORPUS_REF          the PGO corpus image the build used; tagged as the entry's corpus ref,
#                       which smoke.sh's PGO check reads. Unset: that tag must already exist.
#   TRIVY_CACHE_DIR     the prepared Trivy DB (default <repo>/.cache/trivy; never updated here)
#   KEV_CATALOG         default <repo>/.cache/kev/known_exploited_vulnerabilities.json
#   TRIVY_SEVERITY      default CRITICAL,HIGH          TRIVY_MIN_PACKAGES   default 20
#   INPUTS_HASH, DOCKERHUB_IMAGE, GITHUB_SHA, GITHUB_REF, GITHUB_SERVER_URL, GITHUB_REPOSITORY,
#   GITHUB_RUN_ID   the predicate's provenance (defaults: scripts/inputs-hash.sh, the image
#                   named in matrix.json, git's HEAD, local)
#   SMOKE_ALLOW_STALE, SMOKE_SKIP_PGO   passed through to tests/smoke.sh
#
# Concurrency. Everything one target runs is private to it (container names carry the PID,
# derived images are named by version) except /tmp/php-ext-enable.err, which tests/smoke.sh
# writes and reads at a fixed path: two smoke runs at once can truncate each other's file.
# Trivy's default filesystem cache takes an exclusive lock, so above one job the scans use
# its in-memory cache (the verdict is the same; layers are only rescanned per image).
set -euo pipefail

CALLER="$PWD"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
# shellcheck source=tests/matrix-lib.sh
. "$ROOT/tests/matrix-lib.sh"

# absolute <path>: the path as seen from the directory the script was started in.
absolute() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$CALLER/$1" ;;
  esac
}

usage() {
  echo "usage: ci/test-images.sh --entry FILE|- --out DIR [--mode load|digest] [--digests FILE] [--arch amd64|arm64]" >&2
  exit 2
}

MODE=load ENTRY="" DIGESTS="" ARCH="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:?}"; shift 2 ;;
    --entry) ENTRY="${2:?}"; shift 2 ;;
    --digests) DIGESTS="${2:?}"; shift 2 ;;
    --arch) ARCH="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$ENTRY" ] && [ -n "$OUT" ] || usage
case "$MODE" in
  load) [ -z "$DIGESTS" ] || { echo "FAIL: --digests only applies to --mode digest" >&2; exit 2; } ;;
  digest) [ -n "$DIGESTS" ] || { echo "FAIL: --mode digest needs --digests" >&2; exit 2; } ;;
  *) usage ;;
esac
[ "$ENTRY" = - ] || ENTRY="$(absolute "$ENTRY")"
[ -z "$DIGESTS" ] || DIGESTS="$(absolute "$DIGESTS")"
OUT="$(absolute "$OUT")"
JOBS="${TEST_IMAGES_JOBS:-1}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: TEST_IMAGES_JOBS must be a positive integer, got '$JOBS'" >&2; exit 2; }

if [ "$ENTRY" = - ]; then entry_json="$(cat)"; else entry_json="$(cat "$ENTRY")"; fi
PHP="$(jq -er .php <<<"$entry_json")"
UARCH="$(jq -er .uarch <<<"$entry_json")"
CORPUS="$(jq -er .corpus <<<"$entry_json")"
[ -n "$ARCH" ] || ARCH="$(jq -er .arch <<<"$entry_json")"
[ "$ARCH" = amd64 ] || [ "$ARCH" = arm64 ] || { echo "FAIL: arch '$ARCH' is not amd64 or arm64" >&2; exit 2; }
SUFFIX=""
[ "$UARCH" = baseline ] || SUFFIX="-$UARCH"

SEVERITY="${TRIVY_SEVERITY:-CRITICAL,HIGH}"
MIN_PACKAGES="${TRIVY_MIN_PACKAGES:-20}"
TRIVY_CACHE_DIR="$(absolute "${TRIVY_CACHE_DIR:-$ROOT/.cache/trivy}")"
KEV_CATALOG="$(absolute "${KEV_CATALOG:-$ROOT/.cache/kev/known_exploited_vulnerabilities.json}")"
export SMOKE_ALLOW_STALE="${SMOKE_ALLOW_STALE:-}" SMOKE_SKIP_PGO="${SMOKE_SKIP_PGO:-}"
[ -n "$SMOKE_ALLOW_STALE" ] || unset SMOKE_ALLOW_STALE
[ -n "$SMOKE_SKIP_PGO" ] || unset SMOKE_SKIP_PGO

command -v trivy >/dev/null || { echo "FAIL: trivy is not on PATH" >&2; exit 2; }
[ -d "$TRIVY_CACHE_DIR/db" ] || { echo "FAIL: no Trivy DB in $TRIVY_CACHE_DIR (this script never downloads one)" >&2; exit 2; }
[ -f "$KEV_CATALOG" ] || { echo "FAIL: no KEV catalog at $KEV_CATALOG" >&2; exit 2; }

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# name, flavor, tag, ref (what is tested), local (the local tag), per target.
declare -A FLAVOR REF LOCAL BY_FLAVOR
NAMES=()
while IFS=$'\t' read -r name flavor tag; do
  NAMES+=("$name")
  FLAVOR[$name]="$flavor" LOCAL[$name]="$(local_tag "$tag")"
  BY_FLAVOR[$flavor]="$name"
  REF[$name]="${LOCAL[$name]}"
done < <(jq -r '.targets[] | [.name, .flavor, .tag] | @tsv' <<<"$entry_json")
[ "${#NAMES[@]}" -gt 0 ] || { echo "FAIL: the entry has no targets" >&2; exit 2; }
for name in "${NAMES[@]}"; do rm -rf "${OUT:?}/$name"; done
rm -f "$OUT/results.json" "$OUT/passed.txt"

# ----------------------------------------------------------------- setup
SETUP_FAIL=()   # name<TAB>reason
setup_fail() { SETUP_FAIL+=("$1"$'\t'"$2"); }

if [ "$MODE" = digest ]; then
  for name in "${NAMES[@]}"; do
    ref="$(jq -r --arg n "$name" '.[$n] // empty' "$DIGESTS")"
    if [[ "$ref" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
      REF[$name]="$ref"
    else
      REF[$name]=""
      setup_fail "$name" "no <repo>@sha256:<digest> for it in $DIGESTS (got '$ref')"
    fi
  done
  pids=()
  for name in "${NAMES[@]}"; do
    [ -n "${REF[$name]}" ] || continue
    "$HERE/retry.sh" docker pull --quiet "${REF[$name]}" >/dev/null &
    pids+=("$!:$name")
  done
  for p in "${pids[@]}"; do
    wait "${p%%:*}" || { setup_fail "${p#*:}" "docker pull ${REF[${p#*:}]} failed"; REF[${p#*:}]=""; }
  done
fi

for name in "${NAMES[@]}"; do
  [ -n "${REF[$name]}" ] || continue
  if ! got="$(docker image inspect --format '{{.Architecture}}' "${REF[$name]}" 2>/dev/null)"; then
    setup_fail "$name" "${REF[$name]} is not in the local daemon"
    REF[$name]=""
  elif [ "$got" != "$ARCH" ]; then
    setup_fail "$name" "${REF[$name]} is $got, this run tests $ARCH"
    REF[$name]=""
  fi
done

# test-ext-builder.sh finds its three images by their local tags, never by digest.
if [ "$MODE" = digest ]; then
  for flavor in fpm cli ext-builder; do
    name="${BY_FLAVOR[$flavor]:-}"
    [ -n "$name" ] && [ -n "${REF[$name]}" ] || continue
    if ! docker tag "${REF[$name]}" "${LOCAL[$name]}"; then
      setup_fail "$name" "docker tag ${REF[$name]} ${LOCAL[$name]} failed"
      REF[$name]=""
    fi
  done
fi

if [ -n "${CORPUS_REF:-}" ] && ! docker tag "$CORPUS_REF" "$(local_tag "$CORPUS")"; then
  for name in "${NAMES[@]}"; do
    setup_fail "$name" "docker tag $CORPUS_REF $(local_tag "$CORPUS") failed: the PGO corpus is not in the local daemon"
    REF[$name]=""
  done
fi

if [ "$MODE" = digest ]; then
  : "${INPUTS_HASH:=$("$ROOT/scripts/inputs-hash.sh")}"
  : "${DOCKERHUB_IMAGE:=docker.io/$(jq -r .image "$ROOT/matrix.json")}"
  GIT_SHA="${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
  if [ -n "${GITHUB_REF:-}" ]; then
    GIT_REF="$GITHUB_REF"
  elif branch="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD)"; then
    GIT_REF="refs/heads/$branch"
  else
    GIT_REF="HEAD"
  fi
  RUN_URL="${GITHUB_SERVER_URL:-local}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-0}"
  trivy --version --format json --cache-dir "$TRIVY_CACHE_DIR" >"$OUT/trivy-info.json" 2>/dev/null \
    || echo '{}' >"$OUT/trivy-info.json"
fi

# ----------------------------------------------------------------- one target
TRIVY_ENV=(TRIVY_CACHE_DIR="$TRIVY_CACHE_DIR" TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_VERSION_CHECK=true)
[ "$JOBS" -eq 1 ] || TRIVY_ENV+=(TRIVY_CACHE_BACKEND=memory)
# A loaded image is the one in the daemon, never a same-named tag on a registry.
[ "$MODE" != load ] || TRIVY_ENV+=(TRIVY_IMAGE_SRC=docker)

trivy_scan() {  # trivy_scan <image> <TRIVY_* assignments...>
  local image="$1"; shift
  env "${TRIVY_ENV[@]}" "$@" trivy image "$image"
}

kev_and_floor() {  # <image> <report>
  trivy_scan "$1" TRIVY_FORMAT=json TRIVY_OUTPUT="$2" TRIVY_EXIT_CODE=0 TRIVY_SCANNERS=vuln TRIVY_LIST_ALL_PKGS=true \
    TRIVY_SEVERITY=UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL || return 1
  python3 "$ROOT/ci/kev.py" "$2" --catalog "$KEV_CATALOG" || return 1
  local count
  count="$(jq '[.Results[]? | select(.Class == "os-pkgs") | .Packages[]?] | length' "$2")"
  echo "$(basename "$2"): $count OS packages (floor: more than $MIN_PACKAGES)"
  [ "$count" -gt "$MIN_PACKAGES" ] || {
    echo "FAIL: the Trivy scan behind $(basename "$2") saw $count OS packages; an empty scan proves nothing" >&2
    return 1
  }
}

host_of() {  # the image a slim flavor is compared against
  case "$1" in
    fpm-slim) echo fpm ;;
    cli-slim) echo cli-builder ;;
  esac
}

record_predicate() {  # <name> <tdir>
  local name="$1" tdir="$2" index platform
  index="${REF[$name]#*@}"
  platform="$("$HERE/platform-digest.sh" "${REF[$name]}" "$ARCH")" || return 1
  mkdir -p "$tdir/artifact"
  python3 "$ROOT/ci/result_predicate.py" platform \
    --repository "$DOCKERHUB_IMAGE" --php "$PHP" --flavor "${FLAVOR[$name]}" --uarch "$UARCH" \
    --arch "$ARCH" --image-digest "$platform" --inputs-hash "$INPUTS_HASH" \
    --git-sha "$GIT_SHA" --git-ref "$GIT_REF" --run-url "$RUN_URL" \
    --smoke-log "$tdir/smoke.log" --trivy-outcome success --trivy-severity "$SEVERITY" \
    --trivy-info "$OUT/trivy-info.json" --out "$tdir/artifact/$ARCH.test-result.json" || return 1
  printf '%s' "$index" >"$tdir/artifact/$ARCH"
}

run_steps() {  # <name>; the first failing step's name is left in $step
  local name="$1" flavor="${FLAVOR[$1]}" ref="${REF[$1]}" tdir="$OUT/$1" host host_name f
  local flags=()
  step=smoke
  "$ROOT/tests/smoke.sh" "$ref" "$PHP" "$flavor" 2>&1 | tee "$tdir/smoke.log" || return 1

  host="$(host_of "$flavor")"
  if [ -n "$host" ]; then
    step="slim parity"
    host_name="${BY_FLAVOR[$host]:-}"
    [ -n "$host_name" ] && [ -n "${REF[$host_name]}" ] || { echo "FAIL: the entry has no usable $host image to compare $flavor with" >&2; return 1; }
    [ "$flavor" != cli-slim ] || flags=(--full-is-builder)
    "$ROOT/tests/test-slim-parity.sh" "${flags[@]}" "$ref" "${REF[$host_name]}" || return 1
  fi

  if [ "$flavor" = ext-builder ]; then
    step="ext-builder end to end"
    for f in fpm cli; do
      [ -n "${BY_FLAVOR[$f]:-}" ] && [ -n "${REF[${BY_FLAVOR[$f]}]}" ] || { echo "FAIL: the entry has no usable $f image for the ext-builder test" >&2; return 1; }
    done
    "$ROOT/tests/test-ext-builder.sh" "$PHP$SUFFIX" || return 1
  fi

  step="trivy vulnerability gate"
  trivy_scan "$ref" TRIVY_EXIT_CODE=1 TRIVY_SEVERITY="$SEVERITY" TRIVY_IGNORE_UNFIXED=true || return 1
  step="trivy KEV gate and package floor"
  kev_and_floor "$ref" "$tdir/kev.json" || return 1
  step="trivy license gate"
  trivy_scan "$ref" TRIVY_CONFIG="$ROOT/ci/trivy-license.yaml" TRIVY_EXIT_CODE=1 TRIVY_SCANNERS=license TRIVY_SEVERITY=CRITICAL || return 1

  if [ "$MODE" = digest ]; then
    step="test-result predicate"
    record_predicate "$name" "$tdir" || return 1
  fi
  step=""
}

run_target() {  # <name>, in a background subshell; its status file is written last
  local name="$1" tdir="$OUT/$1" start=$SECONDS rc=0 step=""
  mkdir -p "$tdir"
  {
    echo "== $name ($ARCH) ${REF[$name]}"
    run_steps "$name" || rc=$?
  } >"$tdir/test.log" 2>&1 || rc=1
  if [ "$rc" -eq 0 ]; then
    printf 'pass\n%s\n' "$((SECONDS - start))" >"$tdir/status.tmp"
  else
    printf 'fail\n%s\n%s\n' "$((SECONDS - start))" "$step" >"$tdir/status.tmp"
  fi
  mv "$tdir/status.tmp" "$tdir/status"
}

# ----------------------------------------------------------------- schedule
# The long ones first: fpm images carry the php-fpm health suites.
ORDER=()
for flavor in fpm fpm-slim ext-builder cli-builder cli cli-slim; do
  [ -z "${BY_FLAVOR[$flavor]:-}" ] || ORDER+=("${BY_FLAVOR[$flavor]}")
done
for name in "${NAMES[@]}"; do
  [[ " ${ORDER[*]} " == *" $name "* ]] || ORDER+=("$name")
done

setup_failed() { local f; for f in "${SETUP_FAIL[@]}"; do [ "${f%%$'\t'*}" = "$1" ] && return 0; done; return 1; }
setup_reason() { local f; for f in "${SETUP_FAIL[@]}"; do [ "${f%%$'\t'*}" = "$1" ] && echo "${f#*$'\t'}"; done; }

REPORTED=" "
report_target() {
  local name="$1" tdir="$OUT/$1" st secs step
  mapfile -t st <"$tdir/status"
  secs="${st[1]}" step="${st[2]:-}"
  if [ "${st[0]}" = pass ]; then
    [ "${GITHUB_ACTIONS:-}" != true ] || echo "::group::$name passed (${secs}s)"
    cat "$tdir/test.log"
    [ "${GITHUB_ACTIONS:-}" != true ] || echo "::endgroup::"
  else
    cat "$tdir/test.log"
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
      echo "::error title=$name failed::$name failed at '$step' (see its log above)"
    else
      echo "FAIL: $name failed at '$step'" >&2
    fi
  fi
  REPORTED+="$name "
}

report_finished() {
  local name
  for name in "${ORDER[@]}"; do
    [[ "$REPORTED" == *" $name "* ]] || [ ! -f "$OUT/$name/status" ] || report_target "$name"
  done
}

for name in "${ORDER[@]}"; do
  if setup_failed "$name"; then
    mkdir -p "$OUT/$name"
    echo "FAIL: $(setup_reason "$name")" >"$OUT/$name/test.log"
    printf 'fail\n0\nsetup\n' >"$OUT/$name/status"
    continue
  fi
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do
    wait -n || true
    report_finished
  done
  run_target "$name" &
done
wait || true
report_finished

# ----------------------------------------------------------------- summary
failed=0
: >"$OUT/passed.txt"
results='{}'
summary="| target | result | seconds | failed at |"$'\n'"|---|---|---|---|"$'\n'
for name in "${ORDER[@]}"; do
  mapfile -t st <"$OUT/$name/status"
  results="$(jq --arg n "$name" --arg s "${st[0]}" --argjson t "${st[1]}" --arg f "${st[2]:-}" \
    '. + {($n): {status: $s, seconds: $t, failed_at: $f}}' <<<"$results")"
  summary+="| $name | ${st[0]} | ${st[1]} | ${st[2]:-} |"$'\n'
  if [ "${st[0]}" = pass ]; then echo "$name" >>"$OUT/passed.txt"; else failed=$((failed + 1)); fi
done
echo "$results" >"$OUT/results.json"
echo
echo "test-images: php $PHP$SUFFIX $ARCH ($MODE, jobs $JOBS)"
echo "$summary"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || {
  echo "### test-images php $PHP$SUFFIX $ARCH"
  echo
  echo "$summary"
} >>"$GITHUB_STEP_SUMMARY"
if [ "$failed" -gt 0 ]; then
  echo "FAIL: $failed of ${#ORDER[@]} targets failed" >&2
  exit 1
fi
echo "ok: all ${#ORDER[@]} targets passed"
