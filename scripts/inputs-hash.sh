#!/usr/bin/env bash
# Hash the content of every build-context input as the working tree has it
# right now -- tracked files plus untracked-but-not-ignored ones, under the
# paths the build context actually contains (see .dockerignore: php/,
# scripts/, deps/, conf/, rootfs/, shim/, plus the top-level files the
# Dockerfile/bake need). Content, not mtime -- CF-47/T15-P: build-then-commit
# is the normal order here, so an image being older than the latest commit is
# routine and means nothing, but an image built from a tree that has since
# changed is a real defect a timestamp comparison cannot distinguish from the
# routine case.
#
# Prints one sha256 hex digest to stdout and exits 0, or a diagnostic to
# stderr and exits non-zero. No docker involved -- this only ever looks at
# the working tree, so it can run before an image exists at all.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

# Keep this list in sync with .dockerignore's inverse (the paths it does NOT
# exclude) plus the top-level files the Dockerfile/bake read directly.
PATHS=(php scripts deps conf rootfs shim Dockerfile matrix.json docker-bake.hcl matrix.gen.hcl)

command -v git >/dev/null 2>&1 || { echo "FAIL: git not found -- cannot enumerate build-context inputs" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "FAIL: $ROOT is not a git work tree" >&2; exit 1; }

# --cached: every tracked path (the working-tree *content* is read below, not
# the index, so an uncommitted edit to a tracked file is seen).
# --others --exclude-standard: untracked files .gitignore does not hide --
# an untracked file the build genuinely reads (COPY inside these paths) has
# to move the hash too, or a change nobody committed yet would build clean.
# LC_ALL=C: the aggregate hash depends on line order, and a locale-aware sort
# collates mixed-case paths (Dockerfile vs deps/) differently per host, which
# would make an identical tree look stale on a runner with another locale.
# core.quotepath=off keeps non-ASCII names as raw bytes instead of C-quoted.
files=$(git -c core.quotepath=off ls-files --cached --others --exclude-standard -- "${PATHS[@]}" | LC_ALL=C sort)
[ -n "$files" ] || { echo "FAIL: no build-context input files found under ${PATHS[*]}" >&2; exit 1; }

# `sha256sum` folds both the path and the content into each line, so a rename
# (same bytes, new path) still changes the aggregate hash. A path git listed
# that no longer exists on disk (e.g. staged for deletion but not committed)
# is skipped rather than failing the whole measurement -- its absence is what
# a rebuild would also see.
while IFS= read -r f; do
  if [ -f "$f" ]; then sha256sum "$f"; fi
done <<<"$files" | sha256sum | cut -d' ' -f1
