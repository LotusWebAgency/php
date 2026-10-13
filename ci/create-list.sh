#!/usr/bin/env bash
# Assemble the per-arch pushes into one multi-arch manifest list and push it
# by digest only -- no tag. The merge job tags it in the staging repository
# only once it is signed, its signatures and attestations verified, so nothing
# that reads a staging tag (the corpus job's release cli-builders) can pull an
# unsigned list.
#
#   LIST_RUN_ID=<id> LIST_RUN_ATTEMPT=<n> LIST_REVISION=<git sha> \
#     ci/create-list.sh <repo> <source-digest>...
#
# Prints the list digest on stdout. The list carries the run that made it as
# annotations (com.lotuswebagency.ci.run-id, com.lotuswebagency.ci.run-attempt,
# org.opencontainers.image.revision): ci/promote-image.sh reads them to refuse
# a stale record and to never move a Docker Hub tag back to an older run's list.
#
# `imagetools create --dry-run` builds the list (per-arch indexes flattened
# into their platform and attestation manifests). Its output carries a trailing
# newline imagetools itself would not push, so the digest differs from an
# `imagetools create -t` of the same sources -- harmless, nothing compares the
# two. regctl pushes those bytes by their own sha256, so the printed digest is the
# list's digest by construction, and a HEAD confirms the registry agrees.
# Idempotent: the same sources and annotations give the same bytes.
set -euo pipefail
[ "$#" -ge 2 ] || { echo "usage: $0 <repo> <source-digest>..." >&2; exit 2; }
repo="$1"
shift
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGCTL="${REGCTL:-regctl}"
: "${LIST_RUN_ID:?}" "${LIST_RUN_ATTEMPT:?}" "${LIST_REVISION:?}"
case "$LIST_RUN_ID$LIST_RUN_ATTEMPT" in *[!0-9]*) echo "FAIL: run id and attempt must be numbers" >&2; exit 2 ;; esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sources=()
for d in "$@"; do sources+=("$repo@$d"); done
"$HERE/retry.sh" docker buildx imagetools create --dry-run \
  --annotation "index:com.lotuswebagency.ci.run-id=$LIST_RUN_ID" \
  --annotation "index:com.lotuswebagency.ci.run-attempt=$LIST_RUN_ATTEMPT" \
  --annotation "index:org.opencontainers.image.revision=$LIST_REVISION" \
  "${sources[@]}" >"$work/list.json"
media_type="$(jq -r '.mediaType // empty' "$work/list.json")"
[ "$(jq '.manifests | length' "$work/list.json")" -gt 0 ] && [ -n "$media_type" ] \
  || { echo "FAIL: imagetools did not produce a manifest list" >&2; exit 1; }
digest="sha256:$(sha256sum "$work/list.json" | cut -d' ' -f1)"

"$HERE/retry.sh" "$REGCTL" manifest put --by-digest --content-type "$media_type" "$repo@$digest" <"$work/list.json" >/dev/null
got="$("$HERE/retry.sh" "$REGCTL" manifest head "$repo@$digest")"
[ "$got" = "$digest" ] || { echo "FAIL: $repo@$digest reads back as ${got:-nothing}" >&2; exit 1; }
echo "$digest"
