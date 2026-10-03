#!/usr/bin/env bash
# Build one corpus image per tier. Tiers, builder images and tags all come from
# scripts/pgo_tiers.py, which derives them from matrix.json -- so this needs no
# argument and gains a tier the moment corpus/tiers does.
#
#   ./tests/build-corpus.sh           every tier
#   ./tests/build-corpus.sh 8.2       one tier
#
# Nothing here pushes. The tags are the names CI will publish under (tasks
# 23/25); locally they are just labels on images the training build mounts.
#
# Does not stop at the first tier that fails -- same reasoning as
# tests/build-all.sh: five tiers is little enough that "which ones broke and
# how" is more useful than dying on the first one.
#
# A tier's real cli-builder (lotuswebagency/php:<floor>-cli-builder) may not exist
# yet -- from a from-zero daemon, none do. Task 37c: falls back to an existing
# bootstrap cli-builder (lotuswebagency/php:<floor>-cli-builder-bootstrap), or
# builds one (docker-bake.hcl's php-cli-builder-bootstrap) when neither
# exists, rather than skipping the tier.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
ONLY_TIER="${1:-}"

python3 "${ROOT}/scripts/pgo_tiers.py" check

# The bootstrap cli-builder below has to be built for the host's own
# architecture: it runs natively (no QEMU) on whichever runner/machine this
# script executes on, amd64 or arm64. `uname -m` gives the kernel's own name
# for that (x86_64/aarch64), not Docker's platform string, hence the map.
case "$(uname -m)" in
  x86_64) NATIVE_PLATFORM=linux/amd64 ;;
  aarch64|arm64) NATIVE_PLATFORM=linux/arm64 ;;
  *) echo "FATAL: unsupported host architecture '$(uname -m)' for the bootstrap build" >&2; exit 1 ;;
esac
# BUILD_CORPUS_PLATFORM=linux/arm64 on an amd64 host builds the other arch's
# bootstrap and corpus under QEMU binfmt instead -- slow (several times a
# native build), but the only way to exercise an arm64 tier without an arm64
# machine. Local tags carry no arch, so every "already built" shortcut below
# also requires the existing image to be of the wanted arch; otherwise an
# amd64 image left over from a native run would be reused for arm64.
PLATFORM="${BUILD_CORPUS_PLATFORM:-$NATIVE_PLATFORM}"
case "$PLATFORM" in
  linux/amd64|linux/arm64) ;;
  *) echo "FATAL: BUILD_CORPUS_PLATFORM='$PLATFORM' -- expected linux/amd64 or linux/arm64" >&2; exit 1 ;;
esac
[ "$PLATFORM" = "$NATIVE_PLATFORM" ] \
  || echo "note: building for $PLATFORM on a $NATIVE_PLATFORM host -- emulated, expect it to be slow"
WANT_ARCH="${PLATFORM#linux/}"
have_image() {  # have_image <ref>: exists locally AND is of the wanted arch
  [ "$(docker image inspect --format '{{.Architecture}}' "$1" 2>/dev/null || true)" = "$WANT_ARCH" ]
}

# CF-47/T15-P, same instrument tests/build-all.sh and tests/smoke.sh already
# use: a content hash of the build-context inputs, baked in as a label, so a
# stale corpus (built before some unrelated tree change) can be told apart
# from a current one instead of trusted by timestamp. One hash for the whole
# tree, same as the php images -- a corpus's own inputs (php/pgo/corpus/*,
# corpus.lock) are a subset of what scripts/inputs-hash.sh already covers, so
# this is not a second measurement to keep in sync, just a coarser one: an
# unrelated php/ change also invalidates a corpus that never reads it, which
# costs an unnecessary rebuild, never a stale one that looks fresh.
export INPUTS_HASH
INPUTS_HASH="$(bash "${ROOT}/scripts/inputs-hash.sh")"
echo "inputs-hash: $INPUTS_HASH"

# --network host used to be committed on unconditionally: Dockerfile.corpus
# apt-get installs mariadb-server and runs PrestaShop's installer (task 29a/
# 29b) inside a RUN step, and on a host whose default bridge network has no
# outbound, the build cannot reach anything without it. That is a property of
# this particular host, not of every host this script might run on -- a CI
# runner or a host with working bridge networking does not need it and should
# not carry the extra trust it implies (host networking during a build sees
# every interface, not just egress). Opt-in, off by default; the message below
# names the flag when a network-dependent step is about to need it.
NETWORK_ARGS=()
if [ "${BUILD_CORPUS_NETWORK_HOST:-0}" = "1" ]; then
  NETWORK_ARGS=(--network host)
  echo "note: BUILD_CORPUS_NETWORK_HOST=1 -- building with --network host"
else
  echo "note: BUILD_CORPUS_NETWORK_HOST is unset/0 -- building with the default bridge network." \
       "Set BUILD_CORPUS_NETWORK_HOST=1 if the build fails to reach GitHub/Packagist/npm (mariadb-server" \
       "install, PrestaShop's installer, composer/npm installs all need outbound access)."
fi

results=()  # "tier<TAB>status<TAB>detail" rows, printed as a table at the end
while IFS=$'\t' read -r tier _release builder tag _versions; do
  [ -z "$ONLY_TIER" ] || [ "$tier" = "$ONLY_TIER" ] || continue

  # Task 37c: from a daemon with no images at all, $builder (the tier floor's
  # *release* cli-builder, e.g. lotuswebagency/php:7.0-cli-builder) does not exist
  # yet either -- it is itself a full php build this run should not have to
  # do first. Three-step fallback, cheapest first: the real cli-builder if
  # someone already built one, else a bootstrap cli-builder if one was built
  # in an earlier run, else build the bootstrap one now (docker-bake.hcl's
  # php-cli-builder-bootstrap, PGO=false against the placeholder corpus in
  # php/pgo/Dockerfile.bootstrap-corpus) -- the only one of the three this
  # script ever builds on its own, since it is what makes the rest of this
  # loop possible from zero. Once the tier's real cli-builder is built later
  # (tests/build-all.sh phase 2), it wins on the next run: this check always
  # prefers the release image over the bootstrap one.
  bootstrap_tag="lotuswebagency/php:${tier}-cli-builder-bootstrap"
  bootstrap_target="php-${tier//./_}-cli-builder-bootstrap"
  if have_image "$builder"; then
    : # release cli-builder already built -- use it, nothing to do here
  elif have_image "$bootstrap_tag"; then
    echo "=== tier $tier: $builder not built yet -- using existing bootstrap $bootstrap_tag"
    builder="$bootstrap_tag"
  else
    echo "=== tier $tier: neither $builder nor $bootstrap_tag exist -- bootstrapping $bootstrap_tag"
    if ! (cd "$ROOT" && RETRY_ATTEMPTS=5 "$ROOT/ci/retry.sh" docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl "$bootstrap_target" \
           --set '*.platform='"$PLATFORM" --load); then
      echo "=== tier $tier -> $tag: FAIL -- bootstrap build of $bootstrap_tag failed" >&2
      results+=("$tier"$'\t'"FAIL"$'\t'"bootstrap build of $bootstrap_tag failed")
      continue
    fi
    builder="$bootstrap_tag"
  fi

  # Resumable: skip a tier whose corpus image already matches this tree.
  label_hash=$(docker inspect --format '{{index .Config.Labels "com.lotuswebagency.inputs-hash"}}' "$tag" 2>/dev/null || true)
  if [ -n "$label_hash" ] && [ "$label_hash" != "<no value>" ] && [ "$label_hash" = "$INPUTS_HASH" ] && have_image "$tag"; then
    echo "=== tier $tier -> $tag: up to date (inputs-hash matches), skipping"
    results+=("$tier"$'\t'"skip"$'\t'"up to date")
    continue
  fi

  echo "=== tier $tier -> $tag (from $builder)"
  if RETRY_ATTEMPTS=5 "$ROOT/ci/retry.sh" docker build "${NETWORK_ARGS[@]}" --platform "$PLATFORM" -f "${ROOT}/php/pgo/Dockerfile.corpus" \
       --build-arg "BUILDER_IMAGE=${builder}" --build-arg "TIER=${tier}" \
       --build-arg "INPUTS_HASH=${INPUTS_HASH}" \
       -t "$tag" "${ROOT}/php/pgo"; then
    results+=("$tier"$'\t'"built"$'\t'"$tag")
  else
    results+=("$tier"$'\t'"FAIL"$'\t'"build failed, see above")
  fi
done < <(python3 "${ROOT}/scripts/pgo_tiers.py" list)

echo
echo "=== corpus summary"
printf '%-6s %-6s %s\n' TIER RESULT DETAIL
failed=0
for row in "${results[@]}"; do
  IFS=$'\t' read -r tier status detail <<<"$row"
  printf '%-6s %-6s %s\n' "$tier" "$status" "$detail"
  [ "$status" = "FAIL" ] && failed=$((failed + 1))
done

echo
echo "Now: ./tests/test-corpus.sh <tag> for each, then ./tests/test-corpus-tiers.sh"
[ "$failed" -eq 0 ] || { echo "FAILED: $failed tier(s)"; exit 1; }
