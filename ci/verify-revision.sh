#!/usr/bin/env bash
# Fail unless an image's revision label names the commit the run tests, or a commit that built the same images.
#
#   ci/verify-revision.sh <label revision> <expected commit>
#
# A ci run that reused an earlier commit D's images for E (ci/reuse_plan.py) leaves
# dev:<tag>-<E sha12> pointing at images whose label says D. That is right when D is an
# ancestor of E and no build-context input differs between them. Anything else (another
# lineage, a commit not in this history, changed inputs) is a wrong image and fails.
# Run from a full-history checkout. The path list is scripts/inputs-hash.sh's PATHS and
# EXCLUDE (ci/test_verify_revision.py keeps them in sync); it cannot live there, since
# editing anything under scripts/ changes every image's inputs-hash.
set -euo pipefail
[ "$#" -eq 2 ] || { echo "usage: $0 <label revision> <expected commit>" >&2; exit 2; }
rev="$1" want="$2"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PATHS=(php scripts deps conf rootfs shim Dockerfile matrix.json docker-bake.hcl matrix.gen.hcl)
EXCLUDE=(':(exclude,glob)scripts/test_*.py')

[[ "$want" =~ ^[0-9a-f]{40}$ ]] || { echo "FAIL: expected commit '$want' is not a full sha" >&2; exit 1; }
[ "$rev" != "$want" ] || exit 0
[[ "$rev" =~ ^[0-9a-f]{40}$ ]] || { echo "FAIL: revision label '$rev' is not a full sha" >&2; exit 1; }
git cat-file -e "$rev^{commit}" 2>/dev/null || { echo "FAIL: ${rev:0:12} is not in this repository's history" >&2; exit 1; }
git merge-base --is-ancestor "$rev" "$want" || { echo "FAIL: ${rev:0:12} is not an ancestor of ${want:0:12}" >&2; exit 1; }
git diff --quiet "$rev" "$want" -- "${PATHS[@]}" "${EXCLUDE[@]}" \
  || { echo "FAIL: build inputs differ between ${rev:0:12} and ${want:0:12}" >&2; exit 1; }
echo "ok: ${rev:0:12} is an ancestor of ${want:0:12} with identical build inputs"
