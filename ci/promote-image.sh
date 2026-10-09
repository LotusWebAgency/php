#!/usr/bin/env bash
# Copy one tested, signed and attested manifest list from the staging
# repository (GHCR) to the published one (Docker Hub), and only then tag it.
# This is the only write a publish run makes to Docker Hub, and it reads
# nothing there that counts as a pull.
#
#   ci/promote-image.sh <src-repo> <list-digest> <dst-repo> <tag>...
#
#   src-repo     ghcr.io/lotuswebagency/php/release
#   list-digest  the manifest list the merge job signed and attested there
#   dst-repo     docker.io/lotuswebagency/php
#   tag          the tags the list gets on dst, bare (8.5-fpm) or as
#                <dst-repo>:<tag>; at least one
#
# 0. Checks, before anything is written:
#    - the list carries the run annotations the merge job puts on it
#      (com.lotuswebagency.ci.run-id, com.lotuswebagency.ci.run-attempt,
#      org.opencontainers.image.revision), and, when PROMOTE_RUN_ID,
#      PROMOTE_RUN_ATTEMPT and PROMOTE_REVISION are set (CI sets them to the
#      run, attempt and commit the merge job's record names), that they match
#      -- the record and the list it names belong together;
#    - every tag already points at the list in src: the merge job moves its
#      staging tags only onto a list it has signed and verified, so a tag
#      there that has moved on means a later merge (a re-run attempt, or a
#      later run) superseded this list, and the record is stale;
#    - the list and every manifest it holds have a referrer annotated as a
#      cosign signature bundle (merge signs with --recursive). This reads the
#      bundle annotations only: keyless `cosign attest` on its signing-config
#      path (the one CI takes) annotates its bundles with the same sign
#      predicate type, so an attestation can still pass for a signature here.
#      Reading the DSSE payload's predicateType instead would close that gap;
#    - every tag that already exists on dst (HEAD) either points at this list
#      already (left alone) or at a list from an older run. The order comes from
#      the run annotations of both lists on src (nothing prunes the staging
#      repository, and a list on dst has the same digest as its src copy), so it
#      costs no GET on dst. A tag held by a newer or equal run is refused:
#      re-running an old run's promote must not move `latest` back. A tag held by
#      a digest src does not know, or by a list without run annotations, is
#      refused as well, unless PROMOTE_ALLOW_UNKNOWN=1 (needed once for tags that
#      predate this pipeline).
#    Any refusal ends the run with nothing copied and nothing tagged.
# 1. `regctl image copy --referrers src@list dst@list`: the list, every manifest
#    it holds, and every referrer of each of them -- the cosign signature and
#    attestation bundles, which cosign v3 attaches as OCI 1.1 referrers. GHCR has
#    no referrers API, so regctl reads them from the `sha256-<hex>` fallback
#    tags there; Docker Hub has one, so they land as plain manifests with a
#    `subject` that Hub indexes, and no fallback tag is written. Copied by
#    digest: nothing is tagged yet.
# 2. Checked on dst by HEAD only (a HEAD is not a pull to Docker Hub's rate
#    limit): the list, every manifest it holds and every referrer the source
#    has for each are present on dst under the same digests -- which, digests
#    being content hashes, means the same bytes.
# 3. Every tag that does not already point at the list, each copied from the
#    source by digest (re-tagging inside Docker Hub would GET the manifest
#    there), then every tag HEAD-checked to resolve to the list digest. So a tag
#    can only ever appear once the signatures and attestations it is documented
#    to carry are in place.
#
# Idempotent: a re-run finds everything present and only re-checks it.
# Registry calls go through ci/retry.sh (429/5xx/network only); a lookup that
# fails for any other reason than "not found" is a failure, never an absence.
#
# Credentials: regctl reads $DOCKER_CONFIG/config.json (and its own
# $REGCTL_CONFIG). CI points DOCKER_CONFIG at a directory that exists only for
# the promote step, so the Docker Hub token is never in a config any other step
# or job reads. tests/test-attest.sh runs this against two local registries.
set -euo pipefail
[ "$#" -ge 4 ] || { echo "usage: $0 <src-repo> <list-digest> <dst-repo> <tag>..." >&2; exit 2; }
src="$1" list="$2" dst="$3"
shift 3
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGCTL="${REGCTL:-regctl}"
retry() { "$HERE/retry.sh" "$@"; }

RUN_ID_KEY=com.lotuswebagency.ci.run-id
RUN_ATTEMPT_KEY=com.lotuswebagency.ci.run-attempt
REVISION_KEY=org.opencontainers.image.revision
BUNDLE_TYPE=application/vnd.dev.sigstore.bundle.v0.3+json
SIGNATURE_PREDICATE=https://sigstore.dev/cosign/sign/v1

case "$list" in
  sha256:*) [ "${#list}" -eq 71 ] || { echo "FAIL: not a digest: $list" >&2; exit 2; } ;;
  *) echo "FAIL: not a digest: $list" >&2; exit 2 ;;
esac

tags=()
for t in "$@"; do
  t="${t#"$dst":}"
  case "$t" in
    ''|*[:@/]*) echo "FAIL: '$t' is not a tag of $dst" >&2; exit 2 ;;
  esac
  tags+=("$t")
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# head_digest <ref>: the digest dst serves for <ref>, by HEAD; empty when absent.
# Only for the checks after the copy, where "absent" fails the run anyway.
head_digest() { retry "$REGCTL" manifest head "$1" 2>/dev/null || true; }

# lookup <head|get> <ref>: the digest (head) or the raw manifest (get) on stdout;
# returns 3 when the registry answered 404, 1 on any other failure.
lookup() {
  local rc=0
  if [ "$1" = head ]; then
    retry "$REGCTL" manifest head "$2" >"$work/out" 2>"$work/err" || rc=$?
  else
    retry "$REGCTL" manifest get "$2" --format raw-body >"$work/out" 2>"$work/err" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then cat "$work/out"; return 0; fi
  grep -q '\[http 404\]' "$work/err" && return 3
  cat "$work/err" >&2
  return 1
}

# run_of <raw-manifest>: "<run-id> <run-attempt> <revision>" from its annotations,
# empty when any of them is missing or malformed.
run_of() {
  jq -r --arg i "$RUN_ID_KEY" --arg a "$RUN_ATTEMPT_KEY" --arg r "$REVISION_KEY" '
    .annotations // {} | [.[$i], .[$a], .[$r]]
    | if (.[0] // "" | test("^[0-9]+$")) and (.[1] // "" | test("^[0-9]+$")) and (.[2] // "" | length > 0)
      then join(" ") else empty end' <<<"$1"
}

# ------------------------------------------------------------------ 0. checks
raw="$(lookup get "$src@$list")" || { echo "FAIL: cannot read $src@$list" >&2; exit 1; }
mapfile -t children < <(jq -r '.manifests[]?.digest' <<<"$raw")
[ "${#children[@]}" -gt 0 ] || { echo "FAIL: $src@$list holds no manifests -- not a manifest list" >&2; exit 1; }

own_run="$(run_of "$raw")"
[ -n "$own_run" ] || {
  echo "FAIL: $src@$list has no $RUN_ID_KEY/$RUN_ATTEMPT_KEY/$REVISION_KEY annotations -- not a list the merge job made, and it cannot be ordered against what dst carries" >&2
  exit 1
}
read -r own_id own_attempt own_rev <<<"$own_run"
if [ -n "${PROMOTE_RUN_ID:-}${PROMOTE_RUN_ATTEMPT:-}${PROMOTE_REVISION:-}" ]; then
  want="${PROMOTE_RUN_ID:-?} ${PROMOTE_RUN_ATTEMPT:-?} ${PROMOTE_REVISION:-?}"
  [ "$own_run" = "$want" ] || {
    echo "FAIL: $src@$list was made by run $own_id attempt $own_attempt at $own_rev, the record says run ${PROMOTE_RUN_ID:-?} attempt ${PROMOTE_RUN_ATTEMPT:-?} at ${PROMOTE_REVISION:-?}" >&2
    exit 1
  }
fi

# The staging tags must still name this list.
stale=0
for t in "${tags[@]}"; do
  rc=0; staged="$(lookup head "$src:$t")" || rc=$?
  case "$rc" in
    0) [ "$staged" = "$list" ] || { echo "FAIL: $src:$t is $staged now, not $list -- a later merge superseded this list; promote that one" >&2; stale=$((stale + 1)); } ;;
    3) echo "FAIL: $src:$t does not exist -- the merge job tags the staging repository before it records a list" >&2; stale=$((stale + 1)) ;;
    *) echo "FAIL: cannot tell where $src:$t points" >&2; stale=$((stale + 1)) ;;
  esac
done
[ "$stale" -eq 0 ] || { echo "FAIL: stale list record; nothing copied, nothing tagged" >&2; exit 1; }

# Referrers of the list and of each manifest it holds, and the signature check.
# A registry without the referrers API (GHCR) lists them from the fallback tag,
# which carries neither their artifactType nor their annotations: each referrer
# manifest is read from src to tell a signature from an attestation.
declare -A referrers_of
referrer_count=0
unsigned=0
for subject in "$list" "${children[@]}"; do
  referrers_of[$subject]="$(retry "$REGCTL" artifact list "$src@$subject" --format raw-body | jq -r '.manifests[]?.digest')"
  referrer_count=$((referrer_count + $(grep -c . <<<"${referrers_of[$subject]}" || true)))
  if [ "$subject" = "$list" ] && [ -z "${referrers_of[$subject]}" ]; then
    echo "FAIL: $src@$list has no referrers -- the merge job signs and attests every list before it is promoted" >&2
    exit 1
  fi
  signed=0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if retry "$REGCTL" manifest get "$src@$r" --format raw-body \
        | jq -e --arg t "$BUNDLE_TYPE" --arg p "$SIGNATURE_PREDICATE" \
            '.artifactType == $t and .annotations["dev.sigstore.bundle.predicateType"] == $p' >/dev/null; then
      signed=1
      break
    fi
  done <<<"${referrers_of[$subject]}"
  [ "$signed" -eq 1 ] || { echo "FAIL: $src@$subject has no cosign signature bundle among its referrers" >&2; unsigned=$((unsigned + 1)); }
done
[ "$unsigned" -eq 0 ] || { echo "FAIL: $unsigned of the list and its ${#children[@]} manifests are unsigned; nothing copied" >&2; exit 1; }
echo "source: $src@$list (run $own_id attempt $own_attempt, $own_rev), ${#children[@]} manifests, $referrer_count referrers, every one of them signed"

# Where each tag stands on dst now, and whether it may move to the list.
move=()
refused=0
for t in "${tags[@]}"; do
  rc=0; cur="$(lookup head "$dst:$t")" || rc=$?
  case "$rc" in
    0) ;;
    3) move+=("$t"); echo "tag $t: new on $dst"; continue ;;
    *) echo "FAIL: cannot tell where $dst:$t points" >&2; refused=$((refused + 1)); continue ;;
  esac
  if [ "$cur" = "$list" ]; then
    echo "tag $t: already $list"
    continue
  fi
  rc=0; cur_raw="$(lookup get "$src@$cur")" || rc=$?
  cur_run=""
  case "$rc" in
    0) cur_run="$(run_of "$cur_raw")" ;;
    3) ;;
    *) echo "FAIL: cannot read $src@$cur, which $dst:$t points at" >&2; refused=$((refused + 1)); continue ;;
  esac
  if [ -z "$cur_run" ]; then
    if [ "${PROMOTE_ALLOW_UNKNOWN:-}" = 1 ]; then
      echo "tag $t: $dst:$t is $cur, which $src has no run record of; moving it anyway (PROMOTE_ALLOW_UNKNOWN=1)"
      move+=("$t")
    else
      echo "FAIL: $dst:$t is $cur, which $src has no run record of (not a list this pipeline staged, or one made before lists carried run annotations): cannot tell whether $list is newer. Set PROMOTE_ALLOW_UNKNOWN=1 to move it anyway" >&2
      refused=$((refused + 1))
    fi
    continue
  fi
  read -r cur_id cur_attempt cur_rev <<<"$cur_run"
  if [ "$cur_id" -lt "$own_id" ] || { [ "$cur_id" -eq "$own_id" ] && [ "$cur_attempt" -lt "$own_attempt" ]; }; then
    echo "tag $t: moves from $cur (run $cur_id attempt $cur_attempt) to the newer list"
    move+=("$t")
  else
    echo "FAIL: $dst:$t is $cur, from run $cur_id attempt $cur_attempt ($cur_rev) -- not older than this list (run $own_id attempt $own_attempt); refusing to roll it back" >&2
    refused=$((refused + 1))
  fi
done
[ "$refused" -eq 0 ] || { echo "FAIL: $refused of ${#tags[@]} tags refused; nothing copied, nothing tagged" >&2; exit 1; }

# ------------------------------------------------- 1. copy by digest, referrers included
retry "$REGCTL" image copy --referrers "$src@$list" "$dst@$list" >/dev/null
echo "copied: $dst@$list"

# ------------------------------------------------- 2. HEAD every digest the source has on dst
missing=0
for d in "$list" "${children[@]}"; do
  [ "$(head_digest "$dst@$d")" = "$d" ] || { echo "FAIL: $dst@$d missing after the copy" >&2; missing=$((missing + 1)); }
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$(head_digest "$dst@$r")" = "$r" ] || {
      echo "FAIL: referrer $r of $d missing on $dst after the copy" >&2
      missing=$((missing + 1))
    }
  done <<<"${referrers_of[$d]}"
done
[ "$missing" -eq 0 ] || { echo "FAIL: $missing manifests did not arrive on $dst; nothing tagged" >&2; exit 1; }
echo "ok: the list, its ${#children[@]} manifests and $referrer_count referrers are on $dst under the same digests"

# A registry without a referrers API gets regctl's sha256-<hex> fallback tag;
# Docker Hub has the API, so one there means its behavior changed. Not fatal
# (cosign reads the fallback tag too), but worth seeing.
if [ -n "$(head_digest "$dst:sha256-${list#sha256:}")" ]; then
  echo "note: $dst carries the referrers fallback tag sha256-${list#sha256:} -- the registry did not index the referrers itself"
fi

# ------------------------------------------------- 3. tags last
for t in ${move[@]+"${move[@]}"}; do
  retry "$REGCTL" image copy "$src@$list" "$dst:$t" >/dev/null
done
for t in "${tags[@]}"; do
  got="$(head_digest "$dst:$t")"
  [ "$got" = "$list" ] || { echo "FAIL: $dst:$t resolves to ${got:-nothing}, expected $list" >&2; exit 1; }
  echo "ok: $dst:$t -> $list"
done
