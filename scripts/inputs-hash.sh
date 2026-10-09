#!/usr/bin/env bash
# Hash the content of every build-context input as the working tree has it:
# tracked files plus untracked-but-not-ignored ones, under the paths the build
# context contains (see .dockerignore) plus the top-level files the
# Dockerfile/bake read. Content, not mtime: builds routinely precede the commit,
# so an image older than the latest commit is normal, but an image built from a
# tree that has since changed is a defect a timestamp cannot tell apart.
#
# Prints one sha256 hex digest and exits 0, or a diagnostic to stderr and exits
# non-zero. Docker is not involved, so it works before any image exists.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

# Keep this list in sync with .dockerignore's inverse (the paths it does NOT
# exclude) plus the top-level files the Dockerfile/bake read directly.
PATHS=(php scripts deps conf rootfs shim Dockerfile matrix.json docker-bake.hcl matrix.gen.hcl)

command -v git >/dev/null 2>&1 || { echo "FAIL: git not found -- cannot enumerate build-context inputs" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "FAIL: $ROOT is not a git work tree" >&2; exit 1; }

# --cached: every tracked path (content is read from the working tree below, so
# uncommitted edits count).
# --others --exclude-standard: untracked files the build may COPY must also
# move the hash.
# LC_ALL=C: the aggregate depends on line order, and locale-aware collation of
# mixed-case paths differs per host.
# core.quotepath=off keeps non-ASCII names as raw bytes instead of C-quoted.
files=$(git -c core.quotepath=off ls-files --cached --others --exclude-standard -- "${PATHS[@]}" | LC_ALL=C sort)
[ -n "$files" ] || { echo "FAIL: no build-context input files found under ${PATHS[*]}" >&2; exit 1; }

# sha256sum folds path and content into each line, so a rename changes the
# aggregate. A listed path missing on disk (staged deletion) is skipped: a
# rebuild would not see it either.
while IFS= read -r f; do
  if [ -f "$f" ]; then sha256sum "$f"; fi
done <<<"$files" | sha256sum | cut -d' ' -f1
