#!/usr/bin/env bash
# Tag every target that passed ci/test-images.sh --mode digest with its per-arch
# develop tag, the input of ci/dev-manifest.sh.
#
#   GITHUB_SHA=<sha> [DEV_REPO=ghcr.io/lotuswebagency/php/dev] ci/dev-tag.sh <entry.json> <test-out-dir>
#
# For each name in <test-out-dir>/passed.txt: dev:<tag>-<sha12>-<arch> is a
# server-side copy (regctl image copy, no blob transfer within the repository) of
# the per-arch index digest the build pushed, <tag> being what follows the colon
# of the target's tag. A target that did not pass is not in passed.txt and gets no
# tag, so dev-manifest reports its arch as missing.
#
# An existing dev:<tag>-<sha12>-<arch> is never moved to another digest unless
# DEV_TAG_FORCE=1: a tag that a later run silently re-points would let a run
# that tested the old image and a release that copies the new one both pass for
# one commit. ci.yml sets it for a develop dispatch and for a re-run attempt of a
# run; a dispatch of a commit makes the earlier ci run of it no copy source
# (ci/release_source.py rejects a commit with a newer develop run). The tag
# already naming the digest is left alone.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: $0 <entry.json> <test-out-dir>" >&2; exit 2; }
entry="$1" out="$2"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${DEV_REPO:-ghcr.io/lotuswebagency/php/dev}"
sha="${GITHUB_SHA:?GITHUB_SHA is not set}"
sha="${sha:0:12}"
REGCTL="${REGCTL:-regctl}"
arch="$(jq -er .arch "$entry")"
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
[ -f "$out/passed.txt" ] || { echo "FAIL: $out/passed.txt does not exist: test-images.sh did not finish" >&2; exit 1; }
while IFS= read -r name; do
  [ -n "$name" ] || continue
  tag="$(jq -er --arg n "$name" '.targets[] | select(.name == $n) | .tag | split(":")[1]' "$entry")"
  digest="$(tr -d '[:space:]' <"$out/$name/artifact/$arch")"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "FAIL: $name has no index digest in $out/$name/artifact/$arch" >&2; exit 1; }
  dest="${repo}:${tag}-${sha}-${arch}"
  if [ "${DEV_TAG_FORCE:-}" != 1 ]; then
    if existing="$("$HERE/retry.sh" "$REGCTL" image digest "$dest" 2>"$err")"; then
      existing="$(tr -d '[:space:]' <<<"$existing")"
      if [ "$existing" = "$digest" ]; then
        echo "ok: $dest already is $digest"
        continue
      fi
      echo "FAIL: $dest already names $existing, this run built $digest. Moving it would change the image an earlier extended run tested; dispatch ci with rebuild=true to rebuild this commit on purpose." >&2
      exit 1
    elif ! grep -qiE 'not found|manifest unknown|404' "$err"; then
      # Anything but an absent tag (registry down, no access) is not a licence to overwrite.
      echo "FAIL: cannot tell whether $dest exists: $(tail -n 1 "$err")" >&2
      exit 1
    fi
  fi
  "$HERE/retry.sh" "$REGCTL" image copy "${repo}@${digest}" "$dest"
  echo "ok: $dest -> $digest"
done <"$out/passed.txt"
