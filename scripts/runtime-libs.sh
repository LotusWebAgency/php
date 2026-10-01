#!/usr/bin/env bash
# Print the Debian packages providing every shared library the given trees link
# against. Avoids hardcoding version-suffixed package names like libicu76.
set -euo pipefail

libs=$(
  for dir in "$@"; do
    # ldd exits non-zero on plenty of files this legitimately matches (static
    # binaries, shell scripts with the exec bit set); xargs then reports that
    # as its own exit 123, which pipefail would otherwise treat as a hard
    # failure of the whole script. Swallow per-file failures individually.
    find "$dir" -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null \
      | xargs -0 -r -n1 sh -c 'ldd "$1" 2>/dev/null || true' _ \
      | awk '/=>/ && $3 ~ /^\// { print $3 }'
  done | sort -u
)

[ -n "$libs" ] || { echo "no linked libraries found in: $*" >&2; exit 1; }

# Query per-path rather than passing the whole list to one `dpkg -S` call: the
# legacy era's vendored libs under /opt/php-deps/lib belong to no debian
# package, and a single failing path would otherwise kill the whole pipeline
# under pipefail. Each miss is skipped instead of aborting the script.
while IFS= read -r lib; do
  real="$(readlink -f "$lib")" || continue
  dpkg -S "$real" 2>/dev/null || true
done <<<"$libs" \
  | cut -d: -f1 \
  | tr ',' '\n' \
  | sed 's/^ *//; s/ *$//' \
  | sort -u
