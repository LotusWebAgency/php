#!/usr/bin/env bash
# End-to-end check of the publish-time attestations, without Docker Hub or
# Sigstore: a throwaway registry:3 on localhost, a local cosign key, and the same
# scripts the merge job runs (scripts/result_predicate.py, scripts/vex.py,
# scripts/platform-digest.sh, scripts/attest-image.sh).
#
#   COSIGN=/path/to/cosign ./tests/test-attest.sh        # cosign on PATH by default
#   ATTEST_TEST_PORT=5077                                 # registry port on 127.0.0.1
#   ATTEST_TEST_KEEP=1                                    # leave the registry running to poke at it
#
# It builds a two-platform image shaped like the CI one (per-arch pushes by
# digest with provenance, merged into a list), then checks that:
#   - a failed or unfinished smoke run cannot produce a result predicate;
#   - a platform with no result, or a result for another digest, attests nothing;
#   - both attestation types verify on the platform manifests and on the list,
#     and carry what the docs say they carry;
#   - a flavor with no applicable VEX statement gets only the test result.
#
# Not a Docker-image test: it needs docker (buildx), cosign, jq and python3, and
# never touches a registry other than its own. Containers carry the claude.adhoc
# label and are removed on exit.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

COSIGN="${COSIGN:-cosign}"
command -v "$COSIGN" >/dev/null || { echo "FAIL: cosign not found (set COSIGN=/path/to/cosign)"; exit 1; }
for tool in docker jq python3; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not found"; exit 1; }
done
export COSIGN

PORT="${ATTEST_TEST_PORT:-5077}"
REPO="localhost:${PORT}/php"
RESULT_TYPE="https://github.com/LotusWebAgency/php/attestation/test-result/v1"
SUFFIX="$$"
REG="attest-test-registry-${SUFFIX}"
BUILDER="attest-test-${SUFFIX}"
WORK="$(mktemp -d)"

cleanup() {
  docker rm -f "$REG" >/dev/null 2>&1 || true
  docker buildx rm "$BUILDER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
[ -n "${ATTEST_TEST_KEEP:-}" ] || trap cleanup EXIT

pass() { echo "ok: $*"; }
die()  { echo "FAIL: $*" >&2; exit 1; }

# A local key and no transparency log; the CI path is keyless and identical
# otherwise (see the header of scripts/attest-image.sh).
export COSIGN_PASSWORD=""
(cd "$WORK" && "$COSIGN" generate-key-pair >/dev/null 2>&1) || die "cosign generate-key-pair"
export COSIGN_ATTEST_FLAGS="--key $WORK/cosign.key --use-signing-config=false --tlog-upload=false"
export COSIGN_VERIFY_FLAGS="--key $WORK/cosign.pub --insecure-ignore-tlog"

docker run -d --rm --init --label claude.adhoc=1 --name "$REG" -p "127.0.0.1:${PORT}:5000" registry:3 >/dev/null
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:${PORT}/v2/" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:${PORT}/v2/" >/dev/null || die "registry did not come up on port $PORT"
docker buildx create --name "$BUILDER" --driver docker-container --driver-opt network=host >/dev/null

build_arch() {  # build_arch <content> <arch> -> the pushed index digest
  docker buildx build --builder "$BUILDER" --platform "linux/$2" --provenance=mode=max \
    --output "type=image,name=$REPO,push=true,push-by-digest=true,name-canonical=true" \
    --metadata-file "$WORK/meta-$1-$2.json" "$WORK/ctx-$1" >/dev/null 2>&1 || return 1
  jq -r '."containerimage.digest"' "$WORK/meta-$1-$2.json"
}

# publish_list <content> -> sets LIST and IDX_amd64/IDX_arm64; per-arch pushes
# by digest with provenance (so each is an index with an attestation manifest),
# then merged into one list, as build + merge do.
publish_list() {
  local content="$1"
  mkdir -p "$WORK/ctx-$content"
  echo "$content" > "$WORK/ctx-$content/f"
  printf 'FROM scratch\nCOPY f /f\n' > "$WORK/ctx-$content/Dockerfile"
  IDX_amd64="$(build_arch "$content" amd64)" || die "building $content for amd64"
  IDX_arm64="$(build_arch "$content" arm64)" || die "building $content for arm64"
  docker buildx imagetools create -t "$REPO:$content" "$REPO@$IDX_amd64" "$REPO@$IDX_arm64" >/dev/null 2>&1 \
    || die "imagetools create"
  LIST="sha256:$(docker buildx imagetools inspect "$REPO:$content" --raw | sha256sum | cut -d' ' -f1)"
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
  python3 scripts/result_predicate.py platform \
    --repository docker.io/lotuswebagency/php --php 8.2 --flavor "$FLAVOR" --uarch baseline \
    --arch "$1" --image-digest "$2" --inputs-hash "$(./scripts/inputs-hash.sh)" \
    --git-sha 0123456789abcdef0123456789abcdef01234567 --git-ref refs/heads/main \
    --run-url https://github.com/LotusWebAgency/php/actions/runs/1/attempts/1 \
    --smoke-log "$3" --out "$4"
}

attested() {  # attested <ref> <type> -> predicate JSON lines on stdout, non-zero when none verify
  local out
  out="$("$COSIGN" verify-attestation $COSIGN_VERIFY_FLAGS --type "$2" "$1" 2>/dev/null)" || return 1
  jq -r '.payload' <<<"$out" | while IFS= read -r p; do base64 -d <<<"$p"; echo; done
}

# ------------------------------------------------ 1. a bad smoke run writes nothing
FLAVOR=cli-builder
publish_list cli-builder
PLAT_amd64="$("$ROOT/scripts/platform-digest.sh" "$REPO@$IDX_amd64" amd64)"
PLAT_arm64="$("$ROOT/scripts/platform-digest.sh" "$REPO@$IDX_arm64" arm64)"
[ "$PLAT_amd64" != "$PLAT_arm64" ] || die "both platforms resolved to one digest"
[ "$PLAT_amd64" != "$IDX_amd64" ] || die "platform-digest.sh returned the index digest"
pass "platform-digest.sh resolves the platform manifest out of a per-arch index ($PLAT_amd64)"
LIST_ARCHES="$(docker buildx imagetools inspect "$REPO@$LIST" --raw | jq -r '.manifests[].digest')"
grep -q "$PLAT_amd64" <<<"$LIST_ARCHES" || die "the platform manifest is not in the merged list"
! grep -q "$IDX_amd64" <<<"$LIST_ARCHES" || die "the per-arch index digest is in the merged list (expected only its children)"
pass "the merged list holds the platform manifests, not the per-arch indexes"

mkdir -p "$WORK/results"
smoke_log "$WORK/smoke-fail.log" failing
smoke_log "$WORK/smoke-unfinished.log" unfinished
smoke_log "$WORK/smoke-pass.log" passing
if predicate amd64 "$PLAT_amd64" "$WORK/smoke-fail.log" "$WORK/results/bad.json" 2>/dev/null; then die "a failing smoke log produced a predicate"; fi
[ ! -e "$WORK/results/bad.json" ] || die "a failing smoke log left a file behind"
if predicate amd64 "$PLAT_amd64" "$WORK/smoke-unfinished.log" "$WORK/results/bad.json" 2>/dev/null; then die "an unfinished smoke log produced a predicate"; fi
[ ! -e "$WORK/results/bad.json" ] || die "an unfinished smoke log left a file behind"
pass "failed and unfinished smoke runs produce no predicate"

predicate amd64 "$PLAT_amd64" "$WORK/smoke-pass.log" "$WORK/results/amd64.test-result.json"
predicate arm64 "$PLAT_arm64" "$WORK/smoke-pass.log" "$WORK/results/arm64.test-result.json"

# ------------------------------------------------ 2. refusals leave no attestation
mkdir -p "$WORK/partial"
cp "$WORK/results/amd64.test-result.json" "$WORK/partial/"
if scripts/attest-image.sh "$REPO" "$LIST" cli-builder "$WORK/partial" >/dev/null 2>&1; then die "attested a list with an untested platform"; fi
mkdir -p "$WORK/swapped"
cp "$WORK/results/amd64.test-result.json" "$WORK/swapped/amd64.test-result.json"
cp "$WORK/results/amd64.test-result.json" "$WORK/swapped/arm64.test-result.json"
if scripts/attest-image.sh "$REPO" "$LIST" cli-builder "$WORK/swapped" >/dev/null 2>&1; then die "attested a result recorded for another digest"; fi
for ref in "$REPO@$LIST" "$REPO@$PLAT_amd64" "$REPO@$PLAT_arm64"; do
  for type in "$RESULT_TYPE" openvex; do
    ! attested "$ref" "$type" >/dev/null || die "refused runs still left a $type attestation on $ref"
  done
done
pass "a missing platform result or a result for another digest attests nothing"

# ------------------------------------------------ 3. cli-builder: both types, everywhere
scripts/attest-image.sh "$REPO" "$LIST" cli-builder "$WORK/results" >"$WORK/attest.log" 2>&1 || { cat "$WORK/attest.log"; die "attest-image.sh failed"; }
grep -c '^ok: .* attestation on ' "$WORK/attest.log" | grep -qx 6 || { cat "$WORK/attest.log"; die "expected 6 verified attestations (2 types x 2 platforms + list)"; }
pass "attest-image.sh attached and verified 6 attestations (test-result and openvex on each platform and on the list)"

for ref in "$REPO:cli-builder" "$REPO@$PLAT_amd64" "$REPO@$PLAT_arm64"; do
  attested "$ref" "$RESULT_TYPE" >/dev/null || die "no verifying test-result attestation on $ref"
  attested "$ref" openvex >/dev/null || die "no verifying openvex attestation on $ref"
done
pass "cosign verify-attestation succeeds for both types on the tag and on each platform digest"

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
  and (.predicate.platforms | all(.ext_builder_e2e.ran == false))
  and (.predicate.platforms | all(.trivy.verdict == "pass" and (.trivy.ignorefile_sha256 | startswith("sha256:"))))
  and .predicate.platforms[0].image_digest == "'"$PLAT_amd64"'"
  and .predicate.platforms[1].image_digest == "'"$PLAT_arm64"'"' <<<"$list_result" >/dev/null \
  || { jq . <<<"$list_result"; die "the list's test-result predicate is not what the docs promise"; }
pass "list test-result predicate: subject, versions, hashes, run URL, both platforms' passed checks and digests"

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

# ------------------------------------------------ 4. a flavor with no statement gets only the result
FLAVOR=fpm
publish_list fpm
FPM_amd64="$("$ROOT/scripts/platform-digest.sh" "$REPO@$IDX_amd64" amd64)"
FPM_arm64="$("$ROOT/scripts/platform-digest.sh" "$REPO@$IDX_arm64" arm64)"
mkdir -p "$WORK/results-fpm"
predicate amd64 "$FPM_amd64" "$WORK/smoke-pass.log" "$WORK/results-fpm/amd64.test-result.json"
predicate arm64 "$FPM_arm64" "$WORK/smoke-pass.log" "$WORK/results-fpm/arm64.test-result.json"
scripts/attest-image.sh "$REPO" "$LIST" fpm "$WORK/results-fpm" >"$WORK/attest-fpm.log" 2>&1 || { cat "$WORK/attest-fpm.log"; die "attest-image.sh failed for fpm"; }
attested "$REPO:fpm" "$RESULT_TYPE" >/dev/null || die "fpm has no test-result attestation"
! attested "$REPO:fpm" openvex >/dev/null || die "fpm got an openvex attestation although no statement applies"
grep -q '^skip: no VEX statement applies to fpm' "$WORK/attest-fpm.log" || die "no skip line for fpm"
pass "fpm: test-result attested, no openvex attestation (no applicable statement)"

echo "ATTEST TESTS PASSED"
