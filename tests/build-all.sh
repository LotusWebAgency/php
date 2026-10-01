#!/usr/bin/env bash
# Build the PGO corpus tiers, then every bake target in matrix.gen.hcl (all
# 50: 4 flavors x 11 versions + v3 of fpm/cli/cli-builder for 8.4/8.5), and run
# tests/smoke.sh against each image with the flavor-correct invocation
# (test-pgo.sh/test-fpm-health.sh/test-entrypoint.sh/test-snuffleupagus.sh are
# all reached through it). Phase 3 then runs tests/test-ext-builder.sh for
# every version whose ext-builder, fpm and cli images all built and passed.
#
#   ./tests/build-all.sh                              every target, amd64
#   ./tests/build-all.sh --only 8.5                    one version, every flavor
#   ./tests/build-all.sh --only 8.4,8.5 --flavor fpm   comma list or repeat both work
#   ./tests/build-all.sh --platform linux/amd64,linux/arm64
#   ./tests/build-all.sh --dry-run                     print the ordered plan, build nothing
#
# --only and --flavor take a comma-separated list, or repeat the flag; both
# are validated against matrix.json before anything builds, so a typo is a
# loud error rather than a run that quietly builds a smaller matrix than
# intended and still reports a pass. --platform defaults to linux/amd64
# alone -- arm64 is opt-in, not free: this project has never run a matrix
# build under QEMU emulation, and a from-source PGO build is already the
# slow part of this script without adding emulation on top.
#
# Corpus tiers first, images second, in that order and not interleaved:
# every php target's build mounts its tier's corpus unconditionally
# (docker-bake.hcl's `contexts`, scripts/gen_matrix.py's corpus_tags), so an
# image build for a version whose tier corpus is missing or stale fails deep
# inside the Dockerfile instead of at a stage that names the real problem.
# tests/build-corpus.sh bootstraps a tier's cli-builder itself (task 37c) when
# neither the tier floor's release cli-builder nor a bootstrap one exists yet
# -- the only reason a from-zero daemon can reach phase 1 at all.
#
# Deliberately does not stop at the first failure, in any phase. With up
# to 50 targets the useful output is the full list of which ones broke and
# how, not the first one -- a run that dies on 7.0 tells you nothing about
# 7.1-8.5, and each build is expensive enough that finding out one target per
# run is not workable.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
ONLY=()
FLAVORS=()
PLATFORMS="linux/amd64"

usage() {
  cat <<'EOF'
usage: build-all.sh [--only V[,V...]] [--flavor F[,F...]] [--platform P[,P...]] [--dry-run]

  --only V[,V...]      only these matrix.json versions, e.g. --only 8.4,8.5 (repeatable)
  --flavor F[,F...]    only these flavors: fpm, cli, cli-builder, ext-builder (repeatable)
  --platform P[,P...]  bake platform(s) to build for, default linux/amd64 (arm64 is opt-in)
  --dry-run            print the ordered plan (corpus tiers -> images) and build nothing
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --only)
      [ "$#" -ge 2 ] || { echo "FAIL: --only needs an argument" >&2; exit 1; }
      IFS=',' read -ra _parts <<<"$2"; ONLY+=("${_parts[@]}"); shift 2 ;;
    --flavor)
      [ "$#" -ge 2 ] || { echo "FAIL: --flavor needs an argument" >&2; exit 1; }
      IFS=',' read -ra _parts <<<"$2"; FLAVORS+=("${_parts[@]}"); shift 2 ;;
    --platform)
      [ "$#" -ge 2 ] || { echo "FAIL: --platform needs an argument" >&2; exit 1; }
      PLATFORMS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "FAIL: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

# Versions and flavors come from matrix.json, never a literal list here --
# same reasoning as smoke.sh deriving its expected extension set instead of
# naming it: a list copied into this file would keep passing while silently
# not covering a version that was added, and start failing on one that was
# removed.
mapfile -t ALL_VERSIONS < <(python3 -c '
import json
m = json.load(open("matrix.json"))
for v in sorted(m["versions"], key=lambda s: tuple(int(x) for x in s.split("."))):
    print(v)
')
[ "${#ALL_VERSIONS[@]}" -gt 0 ] || { echo "FAIL: matrix.json yielded no versions"; exit 1; }
mapfile -t ALL_FLAVORS < <(python3 -c 'import json; print("\n".join(json.load(open("matrix.json"))["flavors"]))')

for want in "${ONLY[@]:-}"; do
  [ -n "$want" ] || continue
  found=0
  for have in "${ALL_VERSIONS[@]}"; do [ "$want" = "$have" ] && { found=1; break; }; done
  [ "$found" -eq 1 ] || { echo "FAIL: '$want' is not a version in matrix.json (${ALL_VERSIONS[*]})"; exit 1; }
done
for want in "${FLAVORS[@]:-}"; do
  [ -n "$want" ] || continue
  found=0
  for have in "${ALL_FLAVORS[@]}"; do [ "$want" = "$have" ] && { found=1; break; }; done
  [ "$found" -eq 1 ] || { echo "FAIL: '$want' is not a flavor in matrix.json (${ALL_FLAVORS[*]})"; exit 1; }
done

ONLY_CSV="$(IFS=,; echo "${ONLY[*]:-}")"
FLAVOR_CSV="$(IFS=,; echo "${FLAVORS[*]:-}")"
FULL_RUN=0
[ -z "$ONLY_CSV" ] && [ -z "$FLAVOR_CSV" ] && FULL_RUN=1

# scripts/gen_matrix.py --github targets is the same 50-entry list that feeds
# matrix.gen.hcl's TARGETS variable -- never a second copy of it here. See
# tests/preflight.sh's check that this list and `bake --print`'s target list
# can never drift apart.
TARGETS_JSON="$(python3 scripts/gen_matrix.py --github targets)"
ALL_TARGET_COUNT="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["include"]))' "$TARGETS_JSON")"

# One line per selected target: name<TAB>flavor<TAB>php<TAB>tag (the first,
# canonical tag -- the one CF-47's inputs-hash label check and tests/smoke.sh
# both key off of).
mapfile -t SELECTED < <(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
only = [v for v in sys.argv[2].split(",") if v]
flavors = [f for f in sys.argv[3].split(",") if f]
for t in data["include"]:
    if only and t["php"] not in only:
        continue
    if flavors and t["flavor"] not in flavors:
        continue
    print("\t".join([t["name"], t["flavor"], t["php"], t["tags"][0]]))
' "$TARGETS_JSON" "$ONLY_CSV" "$FLAVOR_CSV")
[ "${#SELECTED[@]}" -gt 0 ] || { echo "FAIL: no target matched --only/--flavor"; exit 1; }

# ext_versions_selected -> the versions (one per line) whose baseline
# ext-builder, fpm and cli targets are all in SELECTED. tests/test-ext-builder.sh
# copies an extension built in the first into the other two, so it needs all
# three images of one version; a --flavor filter that drops one skips it.
ext_versions_selected() {
  local row name flavor php tag
  declare -A have=()
  for row in "${SELECTED[@]}"; do
    IFS=$'\t' read -r name flavor php tag <<<"$row"
    case "$name" in *-v3) continue ;; esac
    have["$php/$flavor"]=1
  done
  for php in "${ALL_VERSIONS[@]}"; do
    [ -n "${have["$php/ext-builder"]:-}" ] && [ -n "${have["$php/fpm"]:-}" ] && [ -n "${have["$php/cli"]:-}" ] && echo "$php"
  done
  return 0
}

# CF-47/T15-P: bake the current tree's content hash into every image built
# here as a label, so tests/smoke.sh can tell "built from this tree" from
# "built from some earlier tree" instead of trusting a timestamp. Computed
# once -- it is a property of the whole build context, not of any one target.
export INPUTS_HASH
INPUTS_HASH="$(bash "$ROOT/scripts/inputs-hash.sh")"
echo "inputs-hash: $INPUTS_HASH"
echo "targets: ${#SELECTED[@]}/${ALL_TARGET_COUNT}, platform(s): $PLATFORMS"

# label_hash_of <image> -> the image's com.lotuswebagency.inputs-hash label,
# or empty if the image does not exist or carries none. Same instrument
# tests/smoke.sh and tests/build-corpus.sh use, so "already built from this
# tree" means the same thing everywhere it is asked.
label_hash_of() {
  docker inspect --format '{{index .Config.Labels "com.lotuswebagency.inputs-hash"}}' "$1" 2>/dev/null || true
}

# ------------------------------------------------------------------- dry run
if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "=== dry run -- printing the ordered plan, building nothing"

  echo
  echo "-- phase 0: corpus-tier cli-builder bootstrap (tests/build-corpus.sh, per tier, only when needed) --"
  while IFS=$'\t' read -r tier _release builder tag _versions; do
    bootstrap_tag="lotuswebagency/php:${tier}-cli-builder-bootstrap"
    bootstrap_target="php-${tier//./_}-cli-builder-bootstrap"
    if docker image inspect "$builder" >/dev/null 2>&1; then
      echo "  tier $tier: $builder already built -- no bootstrap needed"
    elif docker image inspect "$bootstrap_tag" >/dev/null 2>&1; then
      echo "  tier $tier: $builder missing -- would reuse existing $bootstrap_tag"
    else
      echo "  tier $tier: neither $builder nor $bootstrap_tag exist -- would build:"
      echo "    docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl $bootstrap_target --set '*.platform=linux/amd64' --load"
    fi
  done < <(python3 "$ROOT/scripts/pgo_tiers.py" list)

  echo
  echo "-- phase 1: corpus tiers (tests/build-corpus.sh) --"
  while IFS=$'\t' read -r tier _release builder tag _versions; do
    # Same resolution order as tests/build-corpus.sh's own fallback, so this
    # preview names the builder phase 1 will actually use, not always the
    # release one phase 0 may have just replaced.
    bootstrap_tag="lotuswebagency/php:${tier}-cli-builder-bootstrap"
    if ! docker image inspect "$builder" >/dev/null 2>&1; then
      builder="$bootstrap_tag"
    fi
    label_hash="$(label_hash_of "$tag")"
    if [ -n "$label_hash" ] && [ "$label_hash" != "<no value>" ] && [ "$label_hash" = "$INPUTS_HASH" ]; then
      echo "  tier $tier -> $tag: up to date (inputs-hash matches) -- would skip"
    else
      echo "  tier $tier -> $tag: would build from $builder (docker build -f php/pgo/Dockerfile.corpus --build-arg BUILDER_IMAGE=$builder --build-arg TIER=$tier -t $tag php/pgo)"
    fi
  done < <(python3 "$ROOT/scripts/pgo_tiers.py" list)

  echo
  echo "-- phase 2: ${#SELECTED[@]} image target(s), platform(s) $PLATFORMS --"
  for row in "${SELECTED[@]}"; do
    IFS=$'\t' read -r name flavor php tag <<<"$row"
    existing_hash="$(label_hash_of "$tag")"
    if [ -n "$existing_hash" ] && [ "$existing_hash" != "<no value>" ] && [ "$existing_hash" = "$INPUTS_HASH" ]; then
      echo "  $name ($tag): up to date -- would skip build, would still run: ./tests/smoke.sh $tag $php $flavor"
    else
      echo "  $name ($tag): would build (docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl $name --set '*.platform=$PLATFORMS' --load) then: ./tests/smoke.sh $tag $php $flavor"
    fi
  done

  echo
  echo "-- phase 3: ext-builder end to end (tests/test-ext-builder.sh) --"
  for php in $(ext_versions_selected); do
    echo "  $php: would run ./tests/test-ext-builder.sh $php once its ext-builder, fpm and cli images are built and smoke-tested"
  done
  exit 0
fi

LOG_DIR="${BUILD_ALL_LOG_DIR:-$(mktemp -d)}"
mkdir -p "$LOG_DIR"
echo "logs: $LOG_DIR"

# ------------------------------------------------------------- phase 1: corpus
echo
echo "=== phase 1: corpus tiers"
corpus_failed=0
if bash "$ROOT/tests/build-corpus.sh" > "$LOG_DIR/corpus.log" 2>&1; then
  echo "ok: corpus tiers"
else
  corpus_failed=1
  echo "CORPUS BUILD HAD FAILURES -- see $LOG_DIR/corpus.log (an image build below may fail" \
       "the same way if it needs a tier that did not build)"
fi
sed -n '/=== corpus summary/,$p' "$LOG_DIR/corpus.log"

# -------------------------------------------------------------- phase 2: images
echo
echo "=== phase 2: images (${#SELECTED[@]} target(s))"
declare -A BUILD_STATUS SMOKE_STATUS NOTE ELAPSED
for row in "${SELECTED[@]}"; do
  IFS=$'\t' read -r name flavor php tag <<<"$row"
  echo "=== $name"
  t0=$(date +%s)

  # Resumable: an image whose inputs-hash label already matches this tree was
  # built from exactly this tree already -- rebuilding it would reproduce the
  # same bytes at real cost (each of these is a from-source PGO build). Skip
  # straight to smoke, which is what proves the skip was safe rather than
  # merely convenient.
  existing_hash="$(label_hash_of "$tag")"
  if [ -n "$existing_hash" ] && [ "$existing_hash" != "<no value>" ] && [ "$existing_hash" = "$INPUTS_HASH" ]; then
    echo "    skip build: $tag already matches this tree's inputs-hash ($INPUTS_HASH)"
    BUILD_STATUS[$name]="skip"
  elif docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl "$name" \
         --set "*.platform=$PLATFORMS" --load > "$LOG_DIR/$name.build.log" 2>&1; then
    BUILD_STATUS[$name]="built"
  else
    BUILD_STATUS[$name]="FAIL"
    NOTE[$name]="build log: $LOG_DIR/$name.build.log"
    echo "    BUILD FAILED"
    tail -30 "$LOG_DIR/$name.build.log"
  fi

  if [ "${BUILD_STATUS[$name]}" = "FAIL" ]; then
    SMOKE_STATUS[$name]="-"
    ELAPSED[$name]=$(( $(date +%s) - t0 ))
    continue
  fi

  if ./tests/smoke.sh "$tag" "$php" "$flavor" > "$LOG_DIR/$name.check.log" 2>&1; then
    SMOKE_STATUS[$name]="ok"
    echo "    ok"
  else
    SMOKE_STATUS[$name]="FAIL"
    NOTE[$name]="check log: $LOG_DIR/$name.check.log"
    echo "    CHECK FAILED"
    tail -20 "$LOG_DIR/$name.check.log"
  fi
  ELAPSED[$name]=$(( $(date +%s) - t0 ))
done

# ----------------------------------------------- phase 3: ext-builder end to end
echo
echo "=== phase 3: ext-builder end to end"
declare -A EXT_STATUS
ext_failed=0
for php in $(ext_versions_selected); do
  e="php-${php//./_}"
  blocked=""
  for flavor in ext-builder fpm cli; do
    case "${BUILD_STATUS[$e-$flavor]:-FAIL}${SMOKE_STATUS[$e-$flavor]:-FAIL}" in
      *FAIL*) blocked="$blocked $e-$flavor" ;;
    esac
  done
  if [ -n "$blocked" ]; then
    EXT_STATUS[$php]="FAIL"
    ext_failed=$((ext_failed + 1))
    echo "    $php: not run, a prerequisite build or smoke failed:$blocked"
    continue
  fi
  if ./tests/test-ext-builder.sh "$php" > "$LOG_DIR/ext-builder-$php.log" 2>&1; then
    EXT_STATUS[$php]="ok"
    echo "    $php: ok"
  else
    EXT_STATUS[$php]="FAIL"
    ext_failed=$((ext_failed + 1))
    echo "    $php: FAILED -- $LOG_DIR/ext-builder-$php.log"
    tail -20 "$LOG_DIR/ext-builder-$php.log"
  fi
done
[ "${#EXT_STATUS[@]}" -gt 0 ] || echo "    nothing to run: no selected version has ext-builder, fpm and cli together"

echo
echo "=== summary"
printf '%-28s %-6s %-6s %-8s %-8s %s\n' TARGET VERSION BUILD SMOKE WALL NOTE
image_failed=0
NAMES=()
for row in "${SELECTED[@]}"; do
  IFS=$'\t' read -r name flavor php tag <<<"$row"
  NAMES+=("$name")
  wall="${ELAPSED[$name]:-0}s"
  printf '%-28s %-6s %-6s %-8s %-8s %s\n' "$name" "$php" "${BUILD_STATUS[$name]}" "${SMOKE_STATUS[$name]:-}" "$wall" "${NOTE[$name]:-}"
  case "${BUILD_STATUS[$name]}${SMOKE_STATUS[$name]:-}" in
    *FAIL*) image_failed=$((image_failed + 1)) ;;
  esac
done

echo
for php in "${!EXT_STATUS[@]}"; do echo "ext-builder end to end, php $php: ${EXT_STATUS[$php]}"; done
if [ "$corpus_failed" -eq 0 ] && [ "$image_failed" -eq 0 ] && [ "$ext_failed" -eq 0 ]; then
  # Only a full, unfiltered run may claim the headline. A filtered run that
  # printed it would be the same vacuous pass this script exists to avoid.
  if [ "$FULL_RUN" -eq 1 ] && [ "${#SELECTED[@]}" -eq "$ALL_TARGET_COUNT" ]; then
    echo "ALL ${ALL_TARGET_COUNT} TARGETS BUILD"
  else
    echo "subset ok: ${NAMES[*]}"
  fi
else
  [ "$corpus_failed" -eq 0 ] || echo "corpus: FAILED (see $LOG_DIR/corpus.log)"
  [ "$image_failed" -eq 0 ] || echo "images: $image_failed target(s) FAILED (see table above)"
  [ "$ext_failed" -eq 0 ] || echo "ext-builder end to end: $ext_failed version(s) FAILED (see phase 3 above)"
  exit 1
fi
