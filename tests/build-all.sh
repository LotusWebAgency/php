#!/usr/bin/env bash
# Build the PGO corpus tiers, then every bake target in matrix.gen.hcl, and run
# tests/smoke.sh against each image with the flavor-correct invocation
# (test-pgo.sh/test-fpm-health.sh/test-entrypoint.sh/test-readonly.sh/
# test-snuffleupagus.sh are all reached through it). Phase 3 then runs
# tests/test-ext-builder.sh for every version whose ext-builder, fpm and cli
# images all built and passed.
#
#   ./tests/build-all.sh                              every target, amd64
#   ./tests/build-all.sh --only 8.5                    one version, every flavor
#   ./tests/build-all.sh --only 8.4,8.5 --flavor fpm   comma list or repeat both work
#   ./tests/build-all.sh --platform linux/amd64,linux/arm64
#   ./tests/build-all.sh --dry-run                     print the ordered plan, build nothing
#   ./tests/build-all.sh --no-reuse                    build everything, pull nothing from GHCR
#   ./tests/build-all.sh --no-pgo                      dev build without PGO, corpus phase skipped
#
# Local namespace: every image this script builds, pulls or retags is tagged
# under $PHP_LOCAL_REPO (default lwa-php-local; corpus tiers under
# $PHP_LOCAL_REPO-corpus, --no-pgo images under $PHP_LOCAL_REPO-nopgo), never
# lotuswebagency/php:* or ghcr.io/lotuswebagency/php/corpus:* -- see
# tests/matrix-lib.sh. The bake targets keep their canonical tags in
# matrix.gen.hcl; --set overrides them here.
#
# Reuse (default): before phase 1, the selection's images and corpus tiers are
# pulled from GHCR, where develop CI pushed them (tests/extended.sh pull
# --best-effort: the tree's HEAD, else its merge-base with origin/develop, else
# the last green develop run), for this host's platform only. Whatever is
# missing or comes from another tree is a note and gets built; whatever matches
# this tree's inputs-hash is then skipped by the resume check below and only
# smoke-tested. --no-reuse turns the pull off.
#
# --no-pgo is a developer shortcut, not a release gate: bake runs with PGO=false
# and the empty bootstrap corpus (docker-bake.hcl's bootstrap-empty-corpus), so
# phase 1 does not run, and the images carry com.lotuswebagency.pgo=false.
# tests/smoke.sh skips the PGO assertions for such an image with a
# "SKIP (no-pgo dev build)" line and enforces everything else. They live under
# their own repository, so a no-PGO image can never satisfy a PGO run's resume
# check (which compares that label as well). It implies --no-reuse.
#
# --only and --flavor take a comma-separated list, or repeat the flag; both
# are validated against matrix.json before anything builds, so a typo is a
# loud error rather than a run that quietly builds a smaller matrix than
# intended and still reports a pass. --platform defaults to linux/amd64
# alone -- arm64 is opt-in: a from-source PGO build is already the slow part of
# this script, and QEMU emulation would add to it.
#
# Corpus tiers first, images second, in that order and not interleaved:
# every php target's build mounts its tier's corpus unconditionally
# (docker-bake.hcl's `contexts`, scripts/gen_matrix.py's corpus_tags), so an
# image build for a version whose tier corpus is missing or stale fails deep
# inside the Dockerfile instead of at a stage that names the real problem.
# tests/build-corpus.sh bootstraps a tier's cli-builder itself when neither the
# tier floor's release cli-builder nor a bootstrap one exists yet, which is what
# lets a from-zero daemon reach phase 1 at all.
#
# Deliberately does not stop at the first failure, in any phase. With this many
# targets the useful output is the full list of which ones broke and how, not
# the first one -- a run that dies on 7.0 tells you nothing about 7.1-8.5, and
# each build is expensive enough that finding out one target per run is not
# workable.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
REUSE=1
NO_PGO=0
ONLY=()
FLAVORS=()
PLATFORMS="linux/amd64"

usage() {
  cat <<'EOF'
usage: build-all.sh [--only V[,V...]] [--flavor F[,F...]] [--platform P[,P...]] [--dry-run] [--no-reuse] [--no-pgo]

  --only V[,V...]      only these matrix.json versions, e.g. --only 8.4,8.5 (repeatable)
  --flavor F[,F...]    only these flavors: fpm, cli, cli-builder, ext-builder, fpm-slim, cli-slim (repeatable)
  --platform P[,P...]  bake platform(s) to build for, default linux/amd64 (arm64 is opt-in)
  --dry-run            print the ordered plan (corpus tiers -> images) and build nothing
  --no-reuse           do not pull the develop CI images from GHCR first (default: pull what matches this tree)
  --no-pgo             dev build: PGO=false, no corpus phase, PGO checks skipped in smoke; implies --no-reuse,
                       tags under $PHP_LOCAL_REPO-nopgo, never a release gate

Images are tagged under $PHP_LOCAL_REPO (default lwa-php-local), never lotuswebagency/php:*.
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
    --no-reuse) REUSE=0; shift ;;
    --no-pgo) NO_PGO=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "FAIL: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

# matrix.json's versions and flavors, the --only/--flavor validation and the
# target selection live in tests/matrix-lib.sh (shared with tests/extended.sh).
# shellcheck source=tests/matrix-lib.sh
. "$HERE/matrix-lib.sh"
export PHP_LOCAL_REPO
if [ "$NO_PGO" -eq 1 ]; then
  [ -n "$PHP_LOCAL_REPO" ] || { echo "FAIL: --no-pgo needs a local repository (PHP_LOCAL_REPO is empty); a no-PGO image must never carry a published name" >&2; exit 1; }
  export PHP_LOCAL_NOPGO=1
  if [ "$REUSE" -eq 1 ]; then echo "note: --no-pgo builds its own images; not pulling the (PGO) develop images"; REUSE=0; fi
else
  export PHP_LOCAL_NOPGO=0
fi
matrix_load
matrix_validate_selection
matrix_select
ext_versions_selected() { matrix_ext_versions; }

# Bake the current tree's content hash into every image built here as a label,
# so tests/smoke.sh can tell "built from this tree" from "built from some earlier
# tree" instead of trusting a timestamp. Computed once -- it is a property of the
# whole build context, not of any one target.
export INPUTS_HASH
INPUTS_HASH="$(bash "$ROOT/scripts/inputs-hash.sh")"
echo "inputs-hash: $INPUTS_HASH"
echo "targets: ${#SELECTED[@]}/${ALL_TARGET_COUNT}, platform(s): $PLATFORMS"
if [ "$NO_PGO" -eq 1 ]; then
  echo "local repo: $(local_image_repo) -- NO-PGO DEV BUILD (PGO=false, no corpus phase, smoke skips the PGO checks); not a release gate"
else
  echo "local repo: $(local_image_repo), corpus: $(local_corpus_repo)"
fi

# label_hash_of <image> -> the image's com.lotuswebagency.inputs-hash label,
# or empty if the image does not exist or carries none. Same instrument
# tests/smoke.sh and tests/build-corpus.sh use, so "already built from this
# tree" means the same thing everywhere it is asked.
label_hash_of() {
  docker inspect --format '{{index .Config.Labels "com.lotuswebagency.inputs-hash"}}' "$1" 2>/dev/null || true
}

# image_current <image> -> 0 when its inputs-hash label is this tree's AND its
# com.lotuswebagency.pgo label (absent = a PGO build) is the one this run builds,
# so a no-PGO image can never stand in for a PGO one or the other way round.
WANT_PGO=true
[ "$NO_PGO" -eq 0 ] || WANT_PGO=false
image_current() {
  local h p
  h="$(label_hash_of "$1")"
  [ -n "$h" ] && [ "$h" != "<no value>" ] && [ "$h" = "$INPUTS_HASH" ] || return 1
  p="$(docker inspect --format '{{index .Config.Labels "com.lotuswebagency.pgo"}}' "$1" 2>/dev/null || true)"
  { [ -z "$p" ] || [ "$p" = "<no value>" ]; } && p=true
  [ "$p" = "$WANT_PGO" ]
}

# tier_needed <versions csv from pgo_tiers.py list> -> 0 when a selected target
# runs one of them: a filtered run trains and bootstraps only the tiers it mounts.
tier_needed() {
  local row _n _f v
  for row in "${SELECTED[@]}"; do
    IFS=$'\t' read -r _n _f v _ <<<"$row"
    case ",$1," in *",$v,"*) return 0 ;; esac
  done
  return 1
}

# bake_sets <target> <local tag> -> BAKE_SETS: the --set overrides that move one
# target into the local namespace (and, for --no-pgo, onto the empty corpus).
bake_sets() {
  BAKE_SETS=(--set "*.platform=$PLATFORMS" --set "$1.tags=$2")
  if [ "$NO_PGO" -eq 1 ]; then
    BAKE_SETS+=(--set "$1.args.PGO=false" --set "$1.labels.com.lotuswebagency.pgo=false"
      --set "$1.contexts.corpus=target:bootstrap-empty-corpus"
      --set "bootstrap-empty-corpus.tags=$(local_tag lotuswebagency/php:bootstrap-empty-corpus)")
  else
    BAKE_SETS+=(--set "$1.contexts.corpus=docker-image://$(matrix_target_corpus "$1")")
  fi
}

# ------------------------------------------------------------------- dry run
if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "=== dry run -- printing the ordered plan, building nothing"

  echo
  if [ "$REUSE" -eq 1 ]; then
    echo "-- reuse: tests/extended.sh pull --best-effort for this selection (HEAD, else merge-base with origin/develop, else the last green develop run); would pull, retag into $(local_image_repo) and skip what matches --"
  else
    echo "-- reuse: off --"
  fi

  if [ "$NO_PGO" -eq 1 ]; then
    echo
    echo "-- phases 0 and 1: skipped (--no-pgo: every image mounts the empty bootstrap corpus) --"
  else
  echo
  echo "-- phase 0: corpus-tier cli-builder bootstrap (tests/build-corpus.sh, per tier, only when needed) --"
  while IFS=$'\t' read -r tier _release builder tag _versions; do
    tier_needed "$_versions" || continue
    builder="$(local_tag "$builder")"
    bootstrap_tag="$(local_tag "lotuswebagency/php:${tier}-cli-builder-bootstrap")"
    bootstrap_target="php-${tier//./_}-cli-builder-bootstrap"
    if docker image inspect "$builder" >/dev/null 2>&1; then
      echo "  tier $tier: $builder already built -- no bootstrap needed"
    elif docker image inspect "$bootstrap_tag" >/dev/null 2>&1; then
      echo "  tier $tier: $builder missing -- would reuse existing $bootstrap_tag"
    else
      echo "  tier $tier: neither $builder nor $bootstrap_tag exist -- would build:"
      echo "    docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl $bootstrap_target --set '*.platform=linux/amd64' --set '$bootstrap_target.tags=$bootstrap_tag' --set 'bootstrap-empty-corpus.tags=$(local_tag lotuswebagency/php:bootstrap-empty-corpus)' --load"
    fi
  done < <(python3 "$ROOT/scripts/pgo_tiers.py" list)

  echo
  echo "-- phase 1: corpus tiers (tests/build-corpus.sh) --"
  while IFS=$'\t' read -r tier _release builder tag _versions; do
    tier_needed "$_versions" || continue
    # Same resolution order as tests/build-corpus.sh's own fallback, so this
    # preview names the builder phase 1 will actually use, not always the
    # release one phase 0 may have just replaced.
    builder="$(local_tag "$builder")"
    tag="$(local_tag "$tag")"
    bootstrap_tag="$(local_tag "lotuswebagency/php:${tier}-cli-builder-bootstrap")"
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
  fi

  echo
  echo "-- phase 2: ${#SELECTED[@]} image target(s), platform(s) $PLATFORMS --"
  for row in "${SELECTED[@]}"; do
    IFS=$'\t' read -r name flavor php tag <<<"$row"
    if image_current "$tag"; then
      echo "  $name ($tag): up to date -- would skip build, would still run: ./tests/smoke.sh $tag $php $flavor"
    else
      bake_sets "$name" "$tag"
      echo "  $name ($tag): would build (docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl $name ${BAKE_SETS[*]} --load) then: ./tests/smoke.sh $tag $php $flavor"
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

# ------------------------------------------------------------------- reuse
# Best effort by construction: tests/extended.sh pull --best-effort exits 0 and
# retags only what it verified (this tree's inputs-hash, the host's
# architecture); the resume checks below decide what is still built. Only the
# host's platform can be reused -- the pulled images run here.
if [ "$REUSE" -eq 1 ]; then
  echo
  echo "=== reuse: develop CI images from GHCR"
  host_arch="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || true)"
  if [ "$PLATFORMS" != "linux/$host_arch" ]; then
    echo "note: --platform $PLATFORMS is not this daemon's linux/$host_arch; nothing reused, everything is built"
  else
    reuse_args=(pull --best-effort)
    [ -z "$ONLY_CSV" ] || reuse_args+=(--only "$ONLY_CSV")
    [ -z "$FLAVOR_CSV" ] || reuse_args+=(--flavor "$FLAVOR_CSV")
    reuse_refs=(HEAD)
    if _base="$(git merge-base HEAD origin/develop 2>/dev/null)"; then reuse_refs+=("$_base"); fi
    reuse_refs+=(--latest)
    for _ref in "${reuse_refs[@]}"; do
      case "$_ref" in --latest) _sel=(--latest) ;; *) _sel=(--sha "$_ref") ;; esac
      echo "pull: ${_sel[*]}"
      EXTENDED_LOG_DIR="$LOG_DIR/reuse" bash "$ROOT/tests/extended.sh" "${reuse_args[@]}" "${_sel[@]}" > "$LOG_DIR/reuse.log" 2>&1 || true
      grep -E '^(note:|  retag:|  tag:)' "$LOG_DIR/reuse.log" || true
      if grep -q '^=== pull result' "$LOG_DIR/reuse.log"; then
        sed -n '/^=== pull result/,$p' "$LOG_DIR/reuse.log"
        break
      fi
    done
    grep -q '^=== pull result' "$LOG_DIR/reuse.log" || echo "note: no develop image of this tree to reuse; building (log $LOG_DIR/reuse.log)"
  fi
fi

# ------------------------------------------------------------- phase 1: corpus
echo
corpus_failed=0
if [ "$NO_PGO" -eq 1 ]; then
  echo "=== phase 1: corpus tiers -- skipped (--no-pgo)"
else
  echo "=== phase 1: corpus tiers (only those the selection mounts)"
  : > "$LOG_DIR/corpus.log"
  while IFS=$'\t' read -r tier _release _builder _tag _versions; do
    tier_needed "$_versions" || continue
    if bash "$ROOT/tests/build-corpus.sh" "$tier" >> "$LOG_DIR/corpus.log" 2>&1; then
      echo "ok: corpus tier $tier"
    else
      corpus_failed=1
      echo "CORPUS BUILD FAILED for tier $tier -- see $LOG_DIR/corpus.log (an image build below may fail" \
           "the same way if it needs this tier)"
    fi
  done < <(python3 "$ROOT/scripts/pgo_tiers.py" list)
  grep -E '^(tier|[0-9]+\.[0-9]+ +(skip|built|FAIL))' "$LOG_DIR/corpus.log" || true
fi

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
  bake_sets "$name" "$tag"
  if image_current "$tag"; then
    echo "    skip build: $tag already matches this tree's inputs-hash ($INPUTS_HASH)"
    BUILD_STATUS[$name]="skip"
  elif docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl "$name" \
         "${BAKE_SETS[@]}" --load > "$LOG_DIR/$name.build.log" 2>&1; then
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
    grep -m1 'SKIP (no-pgo dev build)' "$LOG_DIR/$name.check.log" | sed 's/^/    /' || true
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
declare -A EXT_STATUS=()
ext_failed=0
for php in $(ext_versions_selected); do
  blocked=""
  for flavor in ext-builder fpm cli; do
    t="$(matrix_ext_target "$php" "$flavor")"
    case "${BUILD_STATUS[$t]:-FAIL}${SMOKE_STATUS[$t]:-FAIL}" in
      *FAIL*) blocked="$blocked $t" ;;
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
  if [ "$NO_PGO" -eq 1 ]; then
    echo "NO-PGO DEV RUN ok: ${NAMES[*]} -- built with PGO=false under $(local_image_repo); the PGO checks were skipped. Not a release gate."
  elif [ "$FULL_RUN" -eq 1 ] && [ "${#SELECTED[@]}" -eq "$ALL_TARGET_COUNT" ]; then
    echo "ALL ${ALL_TARGET_COUNT} TARGETS BUILD"
  else
    echo "subset ok: ${NAMES[*]}"
  fi
else
  [ "$corpus_failed" -eq 0 ] || echo "corpus: FAILED (see $LOG_DIR/corpus.log)"
  [ "$image_failed" -eq 0 ] || echo "images: $image_failed target(s) FAILED (see table above)"
  [ "$ext_failed" -eq 0 ] || echo "ext-builder end to end: $ext_failed version(s) FAILED (see phase 3 above)"
  [ "$NO_PGO" -eq 0 ] || echo "(a NO-PGO DEV RUN: PGO checks skipped, not a release gate)"
  exit 1
fi
