#!/usr/bin/env bash
# End-to-end check of the publish-time attestations and the promotion, without
# Docker Hub, GHCR or Sigstore: a throwaway registry:3 on localhost standing in
# for the GHCR staging repository (no referrers API, like GHCR), a zot registry
# with password auth and anonymous reads standing in for Docker Hub (referrers
# API, like Hub), a local cosign key, and the same scripts the merge and promote
# jobs run (ci/result_predicate.py, ci/vex.py, ci/platform-digest.sh,
# ci/attest-image.sh, ci/create-list.sh, ci/verify-signed.sh,
# ci/promote-image.sh), in their order: platform manifests are attested before
# the manifest list exists, the list is pushed untagged, signed, its signatures
# verified and attested before any staging tag points at it, and only then
# promoted.
#
#   COSIGN=/path/to/cosign ./tests/test-attest.sh        # cosign on PATH by default
#   REGCTL=/path/to/regctl                                # regctl on PATH by default
#   ATTEST_TEST_PORT=5077                                 # registry ports on 127.0.0.1: this one and the next
#   ATTEST_TEST_KEEP=1                                    # leave the registries running to poke at them
#
# It builds a two-platform image shaped like the CI one (per-arch pushes by
# digest with provenance, merged into a list), then checks that:
#   - a failed or unfinished smoke run, or a Trivy step that did not succeed,
#     cannot produce a result predicate;
#   - a platform with no result, or a result for another digest, attests nothing
#     and stops the release before a tag exists;
#   - both attestation types verify on the platform manifests (attested before
#     the list is created) and on the list, and carry what the docs say;
#   - the list exists untagged until it is signed, verified and attested, and
#     verify-signed.sh fails an unsigned list or one signed by another key;
#   - re-running adds duplicates that `| head -n1` reads past;
#   - a flavor with no applicable VEX statement gets only the test result;
#   - promotion needs the destination credentials from its own DOCKER_CONFIG,
#     copies the list, its manifests and every signature and attestation under
#     the same digests, tags only after that, issues no GET to the destination
#     (a GET is what Docker Hub counts as a pull), is idempotent, and leaves
#     everything verifiable anonymously on the destination with the same
#     identity and the documented commands;
#   - promotion refuses, copying and tagging nothing: a list whose run
#     annotations differ from the record, a list with no referrers, an attested
#     but unsigned list, a list whose staging tag has moved on, a destination
#     tag held by a newer run's list (no rollback) or by a digest the staging
#     repository does not know (unless PROMOTE_ALLOW_UNKNOWN=1); and when the
#     copy leaves something missing on the destination, it tags nothing.
#
# Not a Docker-image test: it needs docker (buildx), cosign, regctl, jq and
# python3, and never touches a registry other than its own once the four images
# below are on the daemon (digest-pinned, pulled anonymously in a block at the
# top). Containers carry the claude.adhoc label and are removed on exit.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

COSIGN="${COSIGN:-cosign}"
command -v "$COSIGN" >/dev/null || { echo "FAIL: cosign not found (set COSIGN=/path/to/cosign)"; exit 1; }
REGCTL="${REGCTL:-regctl}"
command -v "$REGCTL" >/dev/null || { echo "FAIL: regctl not found (set REGCTL=/path/to/regctl)"; exit 1; }
for tool in docker jq python3; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not found"; exit 1; }
done
export COSIGN REGCTL

# Digest-pinned and pulled anonymously from mirrors, never from Docker Hub with
# anyone's credentials. BUILDKIT_IMAGE is ci.yml's env when CI runs this.
REGISTRY_IMAGE="mirror.gcr.io/library/registry:3@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8"
ZOT_IMAGE="ghcr.io/project-zot/zot-minimal:v2.1.21@sha256:c8090a5e34627e306b9464f5e7c69ad8cdb5948d4476e9cde0eb1a8e2181e3fa"
HTPASSWD_IMAGE="mirror.gcr.io/library/httpd:2.4-alpine@sha256:3440c39d8d6f54fa9ad2549e5a60c19ddd435faadc29c1ad28aa795f71888889"
BUILDKIT_IMAGE="${BUILDKIT_IMAGE:-mirror.gcr.io/moby/buildkit:v0.33.1@sha256:cec9f139f45e93c5c69c60f8b07cfad9f43f4ef6b6a6cd917527fea5ff2e3dea}"

PORT="${ATTEST_TEST_PORT:-5077}"
REPO="localhost:${PORT}/lotuswebagency/php/release"
RESULT_TYPE="https://github.com/LotusWebAgency/php/attestation/test-result/v1"
GIT_SHA=0123456789abcdef0123456789abcdef01234567
SUFFIX="$$"
REG="attest-test-registry-${SUFFIX}"
HUB="attest-test-hub-${SUFFIX}"
HUB_PORT="$((PORT + 1))"
HUB_REPO="localhost:${HUB_PORT}/lotuswebagency/php"
BUILDER="attest-test-${SUFFIX}"
WORK="$(mktemp -d)"

cleanup() {
  docker rm -f "$REG" "$HUB" >/dev/null 2>&1 || true
  docker buildx rm "$BUILDER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
[ -n "${ATTEST_TEST_KEEP:-}" ] || trap cleanup EXIT

pass() { echo "ok: $*"; }
die()  { echo "FAIL: $*" >&2; exit 1; }

# A local key and no transparency log; the CI path is keyless (see the header
# of ci/attest-image.sh). Not identical in one way that matters: CI's attest
# takes cosign's signing-config path, which annotates attestation bundles with
# the sign predicate type, so the "attested but unsigned list" refusal below
# holds here but not in CI (see the header of ci/promote-image.sh).
export COSIGN_PASSWORD=""
(cd "$WORK" && "$COSIGN" generate-key-pair >/dev/null 2>&1) || die "cosign generate-key-pair"
export COSIGN_ATTEST_FLAGS="--key $WORK/cosign.key --use-signing-config=false --tlog-upload=false"
export COSIGN_VERIFY_FLAGS="--key $WORK/cosign.pub --insecure-ignore-tlog"

# Every fetch from outside happens here, before the first assertion: the four
# images (retried on a registry 429/5xx/network error) and the BuildKit
# container the builder starts from its image. Afterwards the containers run
# with --pull never and a missing image fails instead of fetching.
for image in "$REGISTRY_IMAGE" "$ZOT_IMAGE" "$HTPASSWD_IMAGE" "$BUILDKIT_IMAGE"; do
  "$ROOT/ci/retry.sh" docker pull --quiet "$image" >/dev/null || die "cannot pull $image"
done

docker run -d --rm --init --pull never --label claude.adhoc=1 --name "$REG" -p "127.0.0.1:${PORT}:5000" "$REGISTRY_IMAGE" >/dev/null
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:${PORT}/v2/" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:${PORT}/v2/" >/dev/null || die "registry did not come up on port $PORT"
# Plain HTTP for both local registries, in a regctl config of this run's own.
export REGCTL_CONFIG="$WORK/regctl.json"
"$REGCTL" registry set "localhost:${PORT}" --tls disabled >/dev/null 2>&1 || true
"$REGCTL" registry set "localhost:${HUB_PORT}" --tls disabled >/dev/null 2>&1 || true
jq -e --arg a "localhost:${PORT}" --arg b "localhost:${HUB_PORT}" '.hosts[$a].tls == "disabled" and .hosts[$b].tls == "disabled"' \
  "$REGCTL_CONFIG" >/dev/null || die "regctl did not record the local registries"
docker buildx create --name "$BUILDER" --driver docker-container --driver-opt network=host --driver-opt "image=$BUILDKIT_IMAGE" >/dev/null
"$ROOT/ci/retry.sh" docker buildx inspect --bootstrap "$BUILDER" >/dev/null || die "cannot bootstrap the BuildKit builder"

build_arch() {  # build_arch <content> <arch> -> the pushed index digest
  docker buildx build --builder "$BUILDER" --platform "linux/$2" --provenance=mode=max \
    --output "type=image,name=$REPO,push=true,push-by-digest=true,name-canonical=true" \
    --metadata-file "$WORK/meta-$1-$2.json" "$WORK/ctx-$1" >/dev/null 2>&1 || return 1
  jq -r '."containerimage.digest"' "$WORK/meta-$1-$2.json"
}

# push_arches <content> -> sets IDX_amd64/IDX_arm64 and PLAT_amd64/PLAT_arm64;
# per-arch pushes by digest with provenance (so each is an index with an
# attestation manifest), as the build job does. No tag exists afterwards.
push_arches() {
  local content="$1"
  mkdir -p "$WORK/ctx-$content"
  echo "$content" > "$WORK/ctx-$content/f"
  printf 'FROM scratch\nCOPY f /f\n' > "$WORK/ctx-$content/Dockerfile"
  IDX_amd64="$(build_arch "$content" amd64)" || die "building $content for amd64"
  IDX_arm64="$(build_arch "$content" arm64)" || die "building $content for arm64"
  PLAT_amd64="$("$ROOT/ci/platform-digest.sh" "$REPO@$IDX_amd64" amd64)"
  PLAT_arm64="$("$ROOT/ci/platform-digest.sh" "$REPO@$IDX_arm64" arm64)"
}

# create_list <run-id> -> sets LIST; merges the per-arch pushes into one list,
# untagged and annotated with the run, as the merge job does.
create_list() {
  LIST="$(LIST_RUN_ID="$1" LIST_RUN_ATTEMPT=1 LIST_REVISION="$GIT_SHA" \
    ci/create-list.sh "$REPO" "$IDX_amd64" "$IDX_arm64" 2>"$WORK/create-list.err")" \
    || { cat "$WORK/create-list.err"; die "create-list.sh"; }
}

# stage_tags <list> <tag>...: the merge job's last step, tagging the verified
# list in the staging repository.
stage_tags() {
  local list="$1" t
  shift
  for t in "$@"; do
    "$REGCTL" image copy "$REPO@$list" "$REPO:$t" >/dev/null || die "tagging $REPO:$t"
    [ "$("$REGCTL" manifest head "$REPO:$t")" = "$list" ] || die "$REPO:$t does not resolve to $list"
  done
}

smoke_log() {  # smoke_log <file> <passing|failing|unfinished>
  {
    echo "docker-php-entrypoint: noise that is not a check"
    echo "ok: php 8.2.30"
    echo "ok: opcache present"
    echo "ok: uid 33"
    [ "$2" = failing ] && echo "FAIL: pecl extension missing"
    [ "$2" = passing ] && echo "SMOKE PASSED"
  } > "$1"
  return 0
}

predicate() {  # predicate <arch> <image-digest> <smoke-log> <out>
  python3 ci/result_predicate.py platform \
    --repository docker.io/lotuswebagency/php --php 8.2 --flavor "$FLAVOR" --uarch baseline \
    --arch "$1" --image-digest "$2" --inputs-hash "$(./scripts/inputs-hash.sh)" \
    --git-sha "$GIT_SHA" --git-ref refs/heads/main \
    --run-url https://github.com/LotusWebAgency/php/actions/runs/1/attempts/1 \
    --smoke-log "$3" --trivy-outcome "${TRIVY_OUTCOME:-success}" --trivy-severity CRITICAL,HIGH \
    --trivy-info "$WORK/trivy-info.json" --out "$4"
}

# index_files <dir>: writes the per-arch index digest files the build job
# uploads (<arch>), next to the <arch>.test-result.json files.
index_files() {
  printf '%s' "$IDX_amd64" > "$1/amd64"
  printf '%s' "$IDX_arm64" > "$1/arm64"
}

tag_exists() { docker buildx imagetools inspect "$1" >/dev/null 2>&1; }

no_attestations() {  # no_attestations <what> <ref>...
  local what="$1" ref type
  shift
  for ref in "$@"; do
    for type in "$RESULT_TYPE" openvex; do
      ! attested "$ref" "$type" >/dev/null || die "$what still left a $type attestation on $ref"
    done
  done
}

attested_raw() {  # attested_raw <ref> <type> -> cosign's verify-attestation output, non-zero when none verify
  local -a flags
  read -ra flags <<<"$COSIGN_VERIFY_FLAGS"
  "$COSIGN" verify-attestation "${flags[@]}" --type "$2" "$1" 2>/dev/null
}

signed() {  # signed <ref>: 0 when a signature on <ref> verifies
  local -a flags
  read -ra flags <<<"$COSIGN_VERIFY_FLAGS"
  "$COSIGN" verify "${flags[@]}" "$1" >/dev/null 2>&1
}

attested() {  # attested <ref> <type> -> predicate JSON lines on stdout, non-zero when none verify
  local out
  out="$(attested_raw "$1" "$2")" || return 1
  jq -r '.payload' <<<"$out" | while IFS= read -r p; do base64 -d <<<"$p"; echo; done
}

printf '%s\n' '{"Version":"0.70.0","VulnerabilityDB":{"Version":2,"UpdatedAt":"2026-10-03T06:00:00Z"}}' > "$WORK/trivy-info.json"

# ------------------------------------------------ 1. a bad smoke run or Trivy outcome writes nothing
FLAVOR=cli-builder
push_arches cli-builder
[ "$PLAT_amd64" != "$PLAT_arm64" ] || die "both platforms resolved to one digest"
[ "$PLAT_amd64" != "$IDX_amd64" ] || die "platform-digest.sh returned the index digest"
pass "platform-digest.sh resolves the platform manifest out of a per-arch index ($PLAT_amd64)"
! tag_exists "$REPO:cli-builder" || die "the tag exists before the list was created"

mkdir -p "$WORK/results"
smoke_log "$WORK/smoke-fail.log" failing
smoke_log "$WORK/smoke-unfinished.log" unfinished
smoke_log "$WORK/smoke-pass.log" passing
if predicate amd64 "$PLAT_amd64" "$WORK/smoke-fail.log" "$WORK/results/bad.json" 2>/dev/null; then die "a failing smoke log produced a predicate"; fi
[ ! -e "$WORK/results/bad.json" ] || die "a failing smoke log left a file behind"
if predicate amd64 "$PLAT_amd64" "$WORK/smoke-unfinished.log" "$WORK/results/bad.json" 2>/dev/null; then die "an unfinished smoke log produced a predicate"; fi
[ ! -e "$WORK/results/bad.json" ] || die "an unfinished smoke log left a file behind"
for outcome in failure cancelled skipped; do
  if TRIVY_OUTCOME="$outcome" predicate amd64 "$PLAT_amd64" "$WORK/smoke-pass.log" "$WORK/results/bad.json" 2>/dev/null; then die "a Trivy outcome of $outcome produced a predicate"; fi
  [ ! -e "$WORK/results/bad.json" ] || die "a Trivy outcome of $outcome left a file behind"
done
pass "failed and unfinished smoke runs, and a Trivy step that did not succeed, produce no predicate"

predicate amd64 "$PLAT_amd64" "$WORK/smoke-pass.log" "$WORK/results/amd64.test-result.json"
predicate arm64 "$PLAT_arm64" "$WORK/smoke-pass.log" "$WORK/results/arm64.test-result.json"
index_files "$WORK/results"

# ------------------------------------------------ 2. refusals leave no attestation, and no tag
mkdir -p "$WORK/partial"
cp "$WORK/results/amd64.test-result.json" "$WORK/partial/"
index_files "$WORK/partial"
if ci/attest-image.sh platforms "$REPO" cli-builder "$WORK/partial" >/dev/null 2>&1; then die "attested with an untested platform"; fi
mkdir -p "$WORK/swapped"
cp "$WORK/results/amd64.test-result.json" "$WORK/swapped/amd64.test-result.json"
cp "$WORK/results/amd64.test-result.json" "$WORK/swapped/arm64.test-result.json"
index_files "$WORK/swapped"
if ci/attest-image.sh platforms "$REPO" cli-builder "$WORK/swapped" >/dev/null 2>&1; then die "attested a result recorded for another digest"; fi
no_attestations "refused runs" "$REPO@$PLAT_amd64" "$REPO@$PLAT_arm64"
pass "a missing platform result or a result for another digest attests nothing"

# ------------------------------------------------ 3. platforms are attested before the list exists
attest_log="$WORK/attest-platforms.log"
ci/attest-image.sh platforms "$REPO" cli-builder "$WORK/results" >"$attest_log" 2>&1 || { cat "$attest_log"; die "attest-image.sh platforms failed"; }
grep -c '^ok: .* attestation on ' "$attest_log" | grep -qx 4 || { cat "$attest_log"; die "expected 4 verified attestations (2 types x 2 platforms)"; }
! tag_exists "$REPO:cli-builder" || die "the tag exists although only platforms were attested"
for ref in "$REPO@$PLAT_amd64" "$REPO@$PLAT_arm64"; do
  attested "$ref" "$RESULT_TYPE" >/dev/null || die "no verifying test-result attestation on $ref"
  attested "$ref" openvex >/dev/null || die "no verifying openvex attestation on $ref"
done
pass "both attestation types verify on each platform manifest before any tag or list exists"

create_list 100
LIST_CB="$LIST" PLAT_CB_amd64="$PLAT_amd64" PLAT_CB_arm64="$PLAT_arm64"
! tag_exists "$REPO:cli-builder" || die "create-list.sh tagged the list"
[ "$("$REGCTL" manifest get "$REPO@$LIST" --format raw-body | jq -r '.annotations["com.lotuswebagency.ci.run-id"]')" = 100 ] \
  || die "the list does not carry its run annotation"
[ "$(create_list 100; echo "$LIST")" = "$LIST_CB" ] || die "create-list.sh is not idempotent"
pass "create-list.sh pushes the list by digest, untagged, annotated with its run, idempotently"
LIST_ARCHES="$(docker buildx imagetools inspect "$REPO@$LIST" --raw | jq -r '.manifests[].digest')"
grep -q "$PLAT_amd64" <<<"$LIST_ARCHES" || die "the platform manifest is not in the merged list"
! grep -q "$IDX_amd64" <<<"$LIST_ARCHES" || die "the per-arch index digest is in the merged list (expected only its children)"
pass "the merged list holds the platform manifests, not the per-arch indexes"
no_attestations "creating the list" "$REPO@$LIST"
for ref in "$REPO@$PLAT_amd64" "$REPO@$PLAT_arm64"; do
  attested "$ref" "$RESULT_TYPE" >/dev/null || die "the platform attestation on $ref did not survive the list"
done

if ci/attest-image.sh list "$REPO" "$LIST" cli-builder "$WORK/partial" >/dev/null 2>&1; then die "attested a list that holds an untested platform"; fi
no_attestations "a refused list run" "$REPO@$LIST"
pass "a list holding a platform without a result attests nothing"

# The merge job's order: sign recursively, verify every signature, attest the
# list, and only then tag it in the staging repository.
read -ra sign_flags <<<"$COSIGN_ATTEST_FLAGS"
if VERIFY_SIGNED_WAITS=0 ci/verify-signed.sh "$REPO" "$LIST" >"$WORK/verify-unsigned.log" 2>&1; then die "verify-signed.sh passed an unsigned list"; fi
"$COSIGN" sign --yes "${sign_flags[@]}" --recursive "$REPO@$LIST" >/dev/null 2>&1 || die "cosign sign --recursive"
ci/verify-signed.sh "$REPO" "$LIST" >"$WORK/verify-signed.log" 2>&1 || { cat "$WORK/verify-signed.log"; die "verify-signed.sh failed on the signed list"; }
grep -c '^ok: signature on ' "$WORK/verify-signed.log" | grep -qx 5 || { cat "$WORK/verify-signed.log"; die "expected 5 verified signatures (the list and its 4 manifests)"; }
mkdir -p "$WORK/other-key"
(cd "$WORK/other-key" && "$COSIGN" generate-key-pair >/dev/null 2>&1) || die "cosign generate-key-pair (other key)"
if COSIGN_VERIFY_FLAGS="--key $WORK/other-key/cosign.pub --insecure-ignore-tlog" VERIFY_SIGNED_WAITS=0 \
    ci/verify-signed.sh "$REPO" "$LIST" >/dev/null 2>&1; then die "verify-signed.sh accepted signatures made by another key"; fi
! tag_exists "$REPO:cli-builder" || die "a staging tag exists before the list is attested"
pass "verify-signed.sh fails an unsigned list and another signer, passes the list and its 4 manifests after cosign sign --recursive"

attest_log="$WORK/attest-list.log"
ci/attest-image.sh list "$REPO" "$LIST" cli-builder "$WORK/results" >"$attest_log" 2>&1 || { cat "$attest_log"; die "attest-image.sh list failed"; }
stage_tags "$LIST" cli-builder 8.2.30-cli-builder
grep -c '^ok: .* attestation on ' "$attest_log" | grep -qx 2 || { cat "$attest_log"; die "expected 2 verified attestations on the list"; }
for ref in "$REPO:cli-builder" "$REPO@$LIST"; do
  attested "$ref" "$RESULT_TYPE" >/dev/null || die "no verifying test-result attestation on $ref"
  attested "$ref" openvex >/dev/null || die "no verifying openvex attestation on $ref"
done
pass "attest-image.sh attached and verified both types on the list; cosign verify-attestation works on the tag"

list_result="$(attested "$REPO:cli-builder" "$RESULT_TYPE")"
jq -e --arg list "$LIST" --arg rt "$RESULT_TYPE" '
  .predicateType == $rt
  and .subject[0].digest.sha256 == ($list | ltrimstr("sha256:"))
  and .predicate.php_version == "8.2" and .predicate.flavor == "cli-builder" and .predicate.uarch == "baseline"
  and (.predicate.inputs_hash | test("^[0-9a-f]{64}$"))
  and (.predicate.git_sha | length == 40)
  and (.predicate.workflow_run_url | startswith("https://github.com/"))
  and (.predicate.platforms | map(.arch) == ["amd64","arm64"])
  and (.predicate.platforms | all(.smoke.verdict == "pass" and .smoke.check_count == 3 and (.smoke.passed_checks | length == 3)))
  and (.predicate.platforms | all(has("ext_builder_e2e") | not))
  and (.predicate.platforms | all(.trivy.verdict == "pass" and .trivy.severity == "CRITICAL,HIGH" and .trivy.version == "0.70.0" and .trivy.db_updated_at == "2026-10-03T06:00:00Z" and (.trivy.ignorefile_sha256 | startswith("sha256:"))))
  and .predicate.platforms[0].image_digest == "'"$PLAT_amd64"'"
  and .predicate.platforms[1].image_digest == "'"$PLAT_arm64"'"' <<<"$list_result" >/dev/null \
  || { jq . <<<"$list_result"; die "the list's test-result predicate is not what the docs promise"; }
pass "list test-result predicate: subject, versions, hashes, run URL, Trivy scanner/db, both platforms' passed checks and digests"

plat_result="$(attested "$REPO@$PLAT_arm64" "$RESULT_TYPE")"
jq -e --arg d "$PLAT_arm64" '.subject[0].digest.sha256 == ($d | ltrimstr("sha256:")) and (.predicate.platforms | length == 1 and .[0].arch == "arm64")' \
  <<<"$plat_result" >/dev/null || { jq . <<<"$plat_result"; die "the arm64 platform attestation is wrong"; }
pass "platform test-result predicate covers only its own architecture"

vex="$(attested "$REPO@$PLAT_amd64" openvex)"
jq -e --arg d "$PLAT_amd64" '
  .predicateType | test("^https://openvex.dev/ns")' <<<"$vex" >/dev/null || die "openvex predicateType is $(jq -r .predicateType <<<"$vex")"
jq -e --arg d "$PLAT_amd64" '
  .predicate["@context"] == "https://openvex.dev/ns/v0.2.0"
  and (.predicate.statements | length == 3)
  and (.predicate.statements | all(.status == "affected" and (.status_notes | test("review-by: [0-9-]{10}")) and (.action_statement | length > 0)))
  and (.predicate.statements | all(.products | length == 1 and (.[0]["@id"] == "pkg:oci/php@" + $d + "?repository_url=index.docker.io/lotuswebagency/php")))
  and ([.predicate.statements[].vulnerability.name] | sort == ["CVE-2026-102276","CVE-2026-102278","CVE-2026-19534"])
  and ([.predicate.statements[].products[0].subcomponents[0]["@id"]] | sort == ["pkg:npm/brace-expansion@5.0.9","pkg:npm/brace-expansion@5.0.9","pkg:npm/undici@6.28.0"])' \
  <<<"$vex" >/dev/null || { jq . <<<"$vex"; die "the openvex predicate is not scoped to the platform digest"; }
pass "openvex predicate: 3 affected statements, product = the platform digest purl, review-by and action present"

# ------------------------------------------------ 4. a re-run adds duplicates; the documented read takes the first
ci/attest-image.sh list "$REPO" "$LIST" cli-builder "$WORK/results" >/dev/null 2>&1 || die "re-running attest-image.sh list failed"
dupes="$(attested_raw "$REPO:cli-builder" "$RESULT_TYPE" | wc -l)"
[ "$dupes" -ge 2 ] || die "expected the re-run to leave two test-result attestations, saw $dupes"
# the exact pipeline the docs give (head closes the pipe early, so no pipefail here)
first="$(set +o pipefail; attested_raw "$REPO:cli-builder" "$RESULT_TYPE" | jq -r .payload | head -n1 | base64 -d | jq -r .predicate.flavor)"
[ "$first" = cli-builder ] || die "the documented '| jq -r .payload | head -n1 | base64 -d' did not decode the first attestation"
pass "after a re-run ($dupes attestations) the documented verify | head -n1 read still decodes"

# ------------------------------------------------ 5. a flavor with no statement gets only the result
FLAVOR=fpm
push_arches fpm
mkdir -p "$WORK/results-fpm"
predicate amd64 "$PLAT_amd64" "$WORK/smoke-pass.log" "$WORK/results-fpm/amd64.test-result.json"
predicate arm64 "$PLAT_arm64" "$WORK/smoke-pass.log" "$WORK/results-fpm/arm64.test-result.json"
index_files "$WORK/results-fpm"
ci/attest-image.sh platforms "$REPO" fpm "$WORK/results-fpm" >"$WORK/attest-fpm.log" 2>&1 || { cat "$WORK/attest-fpm.log"; die "attest-image.sh platforms failed for fpm"; }
# A later run's list (run 200); attested but not signed: section 6
# promotes it unsigned first, and signs it before it moves a tag.
create_list 200
LIST_FPM="$LIST"
ci/attest-image.sh list "$REPO" "$LIST" fpm "$WORK/results-fpm" >>"$WORK/attest-fpm.log" 2>&1 || { cat "$WORK/attest-fpm.log"; die "attest-image.sh list failed for fpm"; }
stage_tags "$LIST" fpm
attested "$REPO:fpm" "$RESULT_TYPE" >/dev/null || die "fpm has no test-result attestation"
! attested "$REPO:fpm" openvex >/dev/null || die "fpm got an openvex attestation although no statement applies"
grep -q '^skip: no VEX statement applies to fpm' "$WORK/attest-fpm.log" || die "no skip line for fpm"
pass "fpm: test-result attested, no openvex attestation (no applicable statement)"

# ------------------------------------------------ 6. promotion: staging registry -> "Docker Hub"
# The cli-builder list was signed in section 3, the merge job's way; promote it
# the way the promote job does.
for ref in "$REPO@$LIST_CB" "$REPO@$PLAT_CB_amd64" "$REPO@$PLAT_CB_arm64"; do
  signed "$ref" || die "no verifying signature on $ref in the staging registry"
done

# The destination: password auth for writes, anonymous reads, the referrers API.
docker run --rm --init --pull never --label claude.adhoc=1 --entrypoint timeout "$HTPASSWD_IMAGE" 20 \
  htpasswd -Bbn promoter s3cret >"$WORK/htpasswd"
cat >"$WORK/zot.json" <<'EOF'
{"distSpecVersion": "1.1.1",
 "storage": {"rootDirectory": "/var/lib/registry"},
 "http": {"address": "0.0.0.0", "port": "5000",
          "auth": {"htpasswd": {"path": "/etc/zot/htpasswd"}},
          "accessControl": {"repositories": {"**": {
            "anonymousPolicy": ["read"],
            "policies": [{"users": ["promoter"], "actions": ["read", "create", "update"]}]}}}},
 "log": {"level": "info"}}
EOF
chmod 644 "$WORK/htpasswd" "$WORK/zot.json"
docker run -d --rm --init --pull never --label claude.adhoc=1 --name "$HUB" -p "127.0.0.1:${HUB_PORT}:5000" \
  -v "$WORK/zot.json:/etc/zot/config.json:ro" -v "$WORK/htpasswd:/etc/zot/htpasswd:ro" "$ZOT_IMAGE" >/dev/null
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:${HUB_PORT}/v2/" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:${HUB_PORT}/v2/" >/dev/null || die "zot did not come up on port $HUB_PORT"

# The destination credentials exist only in this DOCKER_CONFIG, as in the promote job.
mkdir -p "$WORK/promote-docker"
printf '{"auths":{"localhost:%s":{"auth":"%s"}}}\n' "$HUB_PORT" "$(printf promoter:s3cret | base64)" >"$WORK/promote-docker/config.json"
mkdir -p "$WORK/no-creds"
echo '{}' >"$WORK/no-creds/config.json"

hub_gets() {  # hub_gets: GET requests the destination served so far (Docker Hub counts a manifest GET as a pull)
  docker logs "$HUB" 2>&1 | jq -Rr 'fromjson? | select(.message == "HTTP API" and .method == "GET") | .path' \
    | grep -cE '/v2/.+/(manifests|referrers|blobs)/' || true
}
hub_tags() { { curl -fsS "http://127.0.0.1:${HUB_PORT}/v2/lotuswebagency/php/tags/list" 2>/dev/null || echo "{}"; } | jq -r '.tags[]?' | sort; }

if DOCKER_CONFIG="$WORK/no-creds" ci/promote-image.sh "$REPO" "$LIST_CB" "$HUB_REPO" cli-builder >"$WORK/promote-nocreds.log" 2>&1; then
  die "promotion succeeded without the destination credentials"
fi
grep -qi 'unauthorized' "$WORK/promote-nocreds.log" || { cat "$WORK/promote-nocreds.log"; die "promotion without credentials failed, but not on authorization"; }
[ -z "$(hub_tags)" ] || die "a promotion that could not write left tags: $(hub_tags | tr '\n' ' ')"
pass "without the credentials in its own DOCKER_CONFIG, promotion writes nothing and tags nothing"

rc=0; ci/promote-image.sh "$REPO" "$REPO" "$HUB_REPO" cli-builder >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || die "promote-image.sh took a repository for a digest (exit $rc)"
rc=0; DOCKER_CONFIG="$WORK/promote-docker" ci/promote-image.sh "$REPO" "$LIST_CB" "$HUB_REPO" "other/repo:x" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || die "promote-image.sh accepted a tag of another repository (exit $rc)"
[ -z "$(hub_tags)" ] || die "a refused promotion left tags: $(hub_tags | tr '\n' ' ')"
pass "promote-image.sh refuses a non-digest list and a tag outside the destination repository"

# promote_as <log> <list> <tag>...: promote-image.sh with the destination
# credentials; PROMOTE_* from the caller's environment.
promote_as() {
  local log="$1"
  shift
  DOCKER_CONFIG="$WORK/promote-docker" ci/promote-image.sh "$REPO" "$1" "$HUB_REPO" "${@:2}" >"$log" 2>&1
}
hub_has() { [ -n "$(DOCKER_CONFIG="$WORK/no-creds" "$REGCTL" manifest head "$HUB_REPO@$1" 2>/dev/null)" ]; }
# refused <log> <pattern> <what> <list> <expected tags>: the run failed for the
# expected reason, the list is not on the destination, the tags are as expected.
refused() {
  grep -q -- "$2" "$1" || { cat "$1"; die "$3: refused, but not with '$2'"; }
  [ -z "${4:-}" ] || ! hub_has "$4" || die "$3: the list was copied to the destination although it was refused"
  [ "$(hub_tags | tr '\n' ' ')" = "$5" ] || die "$3: destination tags are '$(hub_tags | tr '\n' ' ')', expected '$5'"
}

# The record names another attempt than the one that made the list.
if PROMOTE_RUN_ID=100 PROMOTE_RUN_ATTEMPT=2 PROMOTE_REVISION="$GIT_SHA" promote_as "$WORK/promote-attempt.log" "$LIST_CB" cli-builder; then
  die "promoted a list whose run annotations differ from the record"
fi
refused "$WORK/promote-attempt.log" 'the record says run 100 attempt 2' "a stale record" "$LIST_CB" ""
pass "a list whose run annotations differ from the record (another attempt) is refused, nothing copied"

# A list with no referrers at all: built, listed and staged, never signed or attested.
push_arches bare
create_list 300
LIST_BARE="$LIST"
stage_tags "$LIST_BARE" bare
if promote_as "$WORK/promote-bare.log" "$LIST_BARE" bare; then die "promoted a list without referrers"; fi
refused "$WORK/promote-bare.log" 'has no referrers' "a list without referrers" "$LIST_BARE" ""
pass "a list with no referrers is refused, nothing copied or tagged"

# Attested (section 5) but not signed.
if promote_as "$WORK/promote-unsigned.log" "$LIST_FPM" fpm; then die "promoted an attested but unsigned list"; fi
refused "$WORK/promote-unsigned.log" 'no cosign signature bundle' "an unsigned list" "$LIST_FPM" ""
pass "a list with attestations but no signature is refused, nothing copied or tagged"

gets_before="$(hub_gets)"
PROMOTE_RUN_ID=100 PROMOTE_RUN_ATTEMPT=1 PROMOTE_REVISION="$GIT_SHA" promote_as "$WORK/promote.log" "$LIST_CB" \
  cli-builder "$HUB_REPO:8.2.30-cli-builder" || { cat "$WORK/promote.log"; die "promote-image.sh failed"; }
gets_after="$(hub_gets)"
[ "$gets_after" = "$gets_before" ] || { cat "$WORK/promote.log"; die "promotion issued $((gets_after - gets_before)) GETs to the destination (expected none)"; }
pass "promotion issued no GET to the destination (HEADs and writes only)"

[ "$(hub_tags | tr '\n' ' ')" = "8.2.30-cli-builder cli-builder " ] || die "destination tags are '$(hub_tags | tr '\n' ' ')' (expected the two promoted tags and no sha256-* fallback tag)"
pass "the destination carries exactly the promoted tags, no referrers fallback tag"

for t in cli-builder 8.2.30-cli-builder; do
  [ "$(DOCKER_CONFIG="$WORK/no-creds" "$REGCTL" manifest head "$HUB_REPO:$t")" = "$LIST_CB" ] || die "$HUB_REPO:$t does not resolve to $LIST_CB"
done
mapfile -t src_children < <("$REGCTL" manifest get "$REPO@$LIST_CB" --format raw-body | jq -r '.manifests[].digest')
mapfile -t dst_children < <(DOCKER_CONFIG="$WORK/no-creds" "$REGCTL" manifest get "$HUB_REPO@$LIST_CB" --format raw-body | jq -r '.manifests[].digest')
[ "${src_children[*]}" = "${dst_children[*]}" ] || die "the destination list holds other manifests than the source"
for d in "$LIST_CB" "${src_children[@]}"; do
  src_refs="$("$REGCTL" artifact list "$REPO@$d" --format raw-body | jq -r '[.manifests[]?.digest] | sort | join(" ")')"
  # A registry with the referrers API also lists BuildKit's provenance manifest
  # (a manifest of the list itself, carrying a subject) as a referrer of its
  # platform manifest; the fallback tag on the source does not. Those are the
  # only extras allowed.
  dst_refs="$(curl -fsS "http://127.0.0.1:${HUB_PORT}/v2/lotuswebagency/php/referrers/$d" \
    | jq -r --arg children "${src_children[*]}" '[.manifests[]?.digest | select(. as $r | $children | split(" ") | index($r) | not)] | sort | join(" ")')"
  [ -n "$src_refs" ] || die "the source has no referrers for $d (cosign sign --recursive signs every manifest)"
  [ "$src_refs" = "$dst_refs" ] || die "referrers of $d differ: source ($src_refs), destination API ($dst_refs)"
done
pass "same list digest on both sides; the destination's referrers API lists the source's signatures and attestations for the list and each of its ${#src_children[@]} manifests"

# Everything a user is told to verify, anonymously, against the destination name.
for ref in "$HUB_REPO:cli-builder" "$HUB_REPO@$PLAT_CB_amd64" "$HUB_REPO@$PLAT_CB_arm64"; do
  DOCKER_CONFIG="$WORK/no-creds" signed "$ref" || die "the signature does not verify anonymously on $ref"
  DOCKER_CONFIG="$WORK/no-creds" attested "$ref" "$RESULT_TYPE" >/dev/null || die "the test-result attestation does not verify anonymously on $ref"
  DOCKER_CONFIG="$WORK/no-creds" attested "$ref" openvex >/dev/null || die "the openvex attestation does not verify anonymously on $ref"
done
hub_result="$(set +o pipefail; DOCKER_CONFIG="$WORK/no-creds" attested_raw "$HUB_REPO:cli-builder" "$RESULT_TYPE" | jq -r .payload | head -n1 | base64 -d)"
jq -e --arg list "$LIST_CB" '.subject[0].digest.sha256 == ($list | ltrimstr("sha256:")) and .predicate.flavor == "cli-builder"' <<<"$hub_result" >/dev/null \
  || { jq . <<<"$hub_result"; die "the promoted list's test-result predicate is not about the list"; }
pass "signature, test-result and openvex verify anonymously on the destination tag and both platform manifests; the documented read decodes"
[ "$(hub_gets)" -gt "$gets_after" ] || die "the destination log shows no GETs even for the verifications above: the GET count measures nothing"

# The hub-verify job's check, on what the merge job records for the list.
jq -n --arg list "$LIST_CB" --arg a "$PLAT_CB_amd64" --arg b "$PLAT_CB_arm64" \
  '{list: $list, platforms: {amd64: $a, arm64: $b}, tags: ["cli-builder", "8.2.30-cli-builder"]}' >"$WORK/release.json"
ci/hub-verify.sh "$HUB_REPO" "$WORK/release.json" >"$WORK/hub-verify.log" 2>&1 || { cat "$WORK/hub-verify.log"; die "hub-verify.sh failed on the promoted list"; }
jq '.tags += ["fpm"]' "$WORK/release.json" >"$WORK/release-wrong.json"
if ci/hub-verify.sh "$HUB_REPO" "$WORK/release-wrong.json" >/dev/null 2>&1; then die "hub-verify.sh passed a tag that does not resolve to the list"; fi
jq --arg l "$PLAT_CB_amd64" '.list = $l' "$WORK/release.json" >"$WORK/release-wrong.json"
if ci/hub-verify.sh "$HUB_REPO" "$WORK/release-wrong.json" >/dev/null 2>&1; then die "hub-verify.sh passed with another digest as the list"; fi
pass "hub-verify.sh passes the promoted list anonymously and fails a wrong tag or list"

gets_before="$(hub_gets)"
DOCKER_CONFIG="$WORK/promote-docker" ci/promote-image.sh "$REPO" "$LIST_CB" "$HUB_REPO" cli-builder 8.2.30-cli-builder \
  >"$WORK/promote-again.log" 2>&1 || { cat "$WORK/promote-again.log"; die "re-running promote-image.sh failed"; }
gets_after="$(hub_gets)"
[ "$gets_after" = "$gets_before" ] || die "the re-run issued $((gets_after - gets_before)) GETs to the destination"
[ "$(hub_tags | tr '\n' ' ')" = "8.2.30-cli-builder cli-builder " ] || die "the re-run changed the destination tags"
pass "a re-run of the promotion succeeds, changes nothing and issues no GET"

# Every run after the first: a tag that already exists on the destination moves
# to a new list (here the fpm list of section 5, from the later run 200, signed
# the merge job's way, its merge having moved the staging tag onto it).
LIST_NEXT="$LIST_FPM"
[ "$LIST_NEXT" != "$LIST_CB" ] || die "section 5 left no second list"
"$COSIGN" sign --yes "${sign_flags[@]}" --recursive "$REPO@$LIST_NEXT" >/dev/null 2>&1 || die "cosign sign --recursive (second list)"
stage_tags "$LIST_NEXT" cli-builder

# A copy that leaves something behind: the same regctl, except that its
# `image copy --referrers` copies without the referrers, as a copy that
# reported success and did not deliver would. Nothing may be tagged.
cat >"$WORK/regctl-drop-referrers" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2 \$3" = "image copy --referrers" ]; then shift 3; exec "$(command -v "$REGCTL")" image copy "\$@"; fi
exec "$(command -v "$REGCTL")" "\$@"
EOF
chmod +x "$WORK/regctl-drop-referrers"
if REGCTL="$WORK/regctl-drop-referrers" promote_as "$WORK/promote-dropped.log" "$LIST_NEXT" cli-builder; then
  die "promotion succeeded although the referrers never reached the destination"
fi
refused "$WORK/promote-dropped.log" 'missing on .* after the copy' "a copy that dropped the referrers" "" "8.2.30-cli-builder cli-builder "
grep -q 'nothing tagged' "$WORK/promote-dropped.log" || { cat "$WORK/promote-dropped.log"; die "no 'nothing tagged' after missing referrers"; }
hub_has "$LIST_NEXT" || die "the fault injection did not even copy the list: it tests nothing"
[ "$(DOCKER_CONFIG="$WORK/no-creds" "$REGCTL" manifest head "$HUB_REPO:cli-builder")" = "$LIST_CB" ] || die "a promotion with missing referrers moved the tag"
pass "when the copy leaves referrers missing on the destination, nothing is tagged"

gets_before="$(hub_gets)"
DOCKER_CONFIG="$WORK/promote-docker" ci/promote-image.sh "$REPO" "$LIST_NEXT" "$HUB_REPO" cli-builder \
  >"$WORK/promote-move.log" 2>&1 || { cat "$WORK/promote-move.log"; die "promoting a second list under an existing tag failed"; }
gets_after="$(hub_gets)"
[ "$gets_after" = "$gets_before" ] || die "moving a tag issued $((gets_after - gets_before)) GETs to the destination"
[ "$(DOCKER_CONFIG="$WORK/no-creds" "$REGCTL" manifest head "$HUB_REPO:cli-builder")" = "$LIST_NEXT" ] || die "the moved tag does not resolve to the new list"
[ "$(DOCKER_CONFIG="$WORK/no-creds" "$REGCTL" manifest head "$HUB_REPO:8.2.30-cli-builder")" = "$LIST_CB" ] || die "a tag that was not promoted again moved"
DOCKER_CONFIG="$WORK/no-creds" signed "$HUB_REPO:cli-builder" || die "the moved tag's new list does not verify anonymously"
pass "moving an existing tag to a newly signed list issues no GET either, and the new list verifies"

# Re-running the older run's promote (run 100) after run 200 published: the
# staging tag has moved on, so the record is stale.
if promote_as "$WORK/promote-stale.log" "$LIST_CB" cli-builder; then die "re-promoting an older list over a newer one succeeded"; fi
refused "$WORK/promote-stale.log" 'a later merge superseded this list' "a superseded record" "" "8.2.30-cli-builder cli-builder "
[ "$(DOCKER_CONFIG="$WORK/no-creds" "$REGCTL" manifest head "$HUB_REPO:cli-builder")" = "$LIST_NEXT" ] || die "the stale promotion moved the tag"
# And even with the staging tag pointed back at the older list, the destination
# tag is not rolled back: run 200 holds it, and 100 is not newer.
stage_tags "$LIST_CB" cli-builder
gets_before="$(hub_gets)"
if promote_as "$WORK/promote-rollback.log" "$LIST_CB" cli-builder; then die "rolled a destination tag back to an older run's list"; fi
refused "$WORK/promote-rollback.log" 'refusing to roll it back' "a rollback" "" "8.2.30-cli-builder cli-builder "
[ "$(DOCKER_CONFIG="$WORK/no-creds" "$REGCTL" manifest head "$HUB_REPO:cli-builder")" = "$LIST_NEXT" ] || die "the refused rollback moved the tag"
[ "$(hub_gets)" = "$gets_before" ] || die "deciding the order issued GETs to the destination"
pass "an older run's list cannot take a tag back: refused as stale, and refused by run order with no GET to the destination"

# A destination tag on a digest the staging repository has never seen (a release
# pushed to the destination directly): refused unless overridden.
"$REGCTL" manifest get "$REPO@$LIST_CB" --format raw-body | jq -c '.annotations = {"legacy": "pushed directly"}' >"$WORK/legacy.json"
DOCKER_CONFIG="$WORK/promote-docker" "$REGCTL" manifest put --content-type application/vnd.oci.image.index.v1+json \
  "$HUB_REPO:legacy" <"$WORK/legacy.json" >/dev/null 2>"$WORK/legacy.err" || { cat "$WORK/legacy.err"; die "putting the legacy list on the destination"; }
LEGACY="$(DOCKER_CONFIG="$WORK/no-creds" "$REGCTL" manifest head "$HUB_REPO:legacy")"
[ -z "$("$REGCTL" manifest head "$REPO@$LEGACY" 2>/dev/null)" ] || die "the legacy digest exists in the staging repository"
stage_tags "$LIST_NEXT" legacy
if promote_as "$WORK/promote-unknown.log" "$LIST_NEXT" legacy; then die "moved a tag held by a digest the staging repository does not know"; fi
refused "$WORK/promote-unknown.log" 'PROMOTE_ALLOW_UNKNOWN=1' "an unknown destination digest" "" "8.2.30-cli-builder cli-builder legacy "
[ "$(DOCKER_CONFIG="$WORK/no-creds" "$REGCTL" manifest head "$HUB_REPO:legacy")" = "$LEGACY" ] || die "the refused promotion moved the legacy tag"
PROMOTE_ALLOW_UNKNOWN=1 promote_as "$WORK/promote-unknown-ok.log" "$LIST_NEXT" legacy || { cat "$WORK/promote-unknown-ok.log"; die "PROMOTE_ALLOW_UNKNOWN=1 did not move the legacy tag"; }
[ "$(DOCKER_CONFIG="$WORK/no-creds" "$REGCTL" manifest head "$HUB_REPO:legacy")" = "$LIST_NEXT" ] || die "the legacy tag did not move"
pass "a tag held by a digest the staging repository does not know is refused, and moves with PROMOTE_ALLOW_UNKNOWN=1"

echo "ATTEST TESTS PASSED"
