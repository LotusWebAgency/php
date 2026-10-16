#!/usr/bin/env bash
# Print the Wolfi packages owning every shared library the given trees link
# against, one name per line. Avoids hardcoding version-suffixed package names
# like libicu78, and resolves the owner by path because a soname alone is
# ambiguous (libpq.so.5 comes from libpq-12 through libpq-18). Libraries under
# /opt and /usr/local are vendored or built here and belong to no package.
set -euo pipefail

# Wolfi ships no ldd; the dynamic loader lists a binary's libraries itself. The
# glob covers /lib64/ld-linux-x86-64.so.2 and /lib/ld-linux-aarch64.so.1.
loader=""
for candidate in /lib64/ld-linux-*.so.* /lib/ld-linux-*.so.*; do
  [ -e "$candidate" ] && { loader="$candidate"; break; }
done
[ -n "$loader" ] || { echo "no dynamic loader found under /lib64 or /lib" >&2; exit 1; }

libs=$(
  for dir in "$@"; do
    # The loader exits non-zero on static binaries and exec-bit scripts; xargs
    # would turn that into exit 123 and pipefail would abort, so swallow per file.
    find "$dir" -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null \
      | xargs -0 -r -n1 sh -c '"$0" --list "$1" 2>/dev/null || true' "$loader" \
      | awk '/=>/ && $3 ~ /^\// && $3 !~ /^\/(opt|usr\/local)\// { print $3 }'
  done | sort -u
)

[ -n "$libs" ] || { echo "no linked libraries found in: $*" >&2; exit 1; }

# `apk info -W` prints "<path> is owned by <name>-<version>-r<N>". Query per path
# so a library that no package owns warns instead of failing the whole pipeline,
# then cut the version: it starts at the last "-<digit>...-r<N>" suffix, which
# keeps names that contain digits (libpq-17, openssl-4.0-libssl) intact. The apk
# database records a few packages (libffi) under /usr/lib64 while /usr/lib64 and
# /usr/lib are the same directory, so a path that finds no owner is retried under
# the other spelling.
owner_of() {
  local path="$1" alt
  case "$path" in
    /usr/lib64/*) alt="/usr/lib/${path#/usr/lib64/}" ;;
    /usr/lib/*)   alt="/usr/lib64/${path#/usr/lib/}" ;;
    *)            alt="" ;;
  esac
  local candidate owner
  for candidate in "$path" $alt; do
    owner="$(apk info -W "$candidate" 2>/dev/null | awk '/ is owned by / { print $NF }' || true)"
    if [ -n "$owner" ]; then echo "$owner"; return 0; fi
  done
  return 1
}

while IFS= read -r lib; do
  real="$(readlink -f "$lib")" || continue
  if ! owner="$(owner_of "$real")"; then
    echo "warning: no package owns $real" >&2
    continue
  fi
  echo "$owner"
done <<<"$libs" \
  | sed -E 's/-[0-9][^-]*-r[0-9]+$//' \
  | sort -u
