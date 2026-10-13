#!/usr/bin/env bash
# Print the Debian packages providing every shared library the given trees link
# against. Avoids hardcoding version-suffixed package names like libicu76.
set -euo pipefail

libs=$(
  for dir in "$@"; do
    # ldd exits non-zero on static binaries and exec-bit scripts; xargs would
    # turn that into exit 123 and pipefail would abort, so swallow per file.
    find "$dir" -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null \
      | xargs -0 -r -n1 sh -c 'ldd "$1" 2>/dev/null || true' _ \
      | awk '/=>/ && $3 ~ /^\// { print $3 }'
  done | sort -u
)

[ -n "$libs" ] || { echo "no linked libraries found in: $*" >&2; exit 1; }

# Query per path rather than in one `dpkg -S` call: libs that belong to no
# Debian package (e.g. vendored under /opt/php-deps/lib) would fail the whole
# pipeline under pipefail.
while IFS= read -r lib; do
  real="$(readlink -f "$lib")" || continue
  dpkg -S "$real" 2>/dev/null || true
done <<<"$libs" \
  | cut -d: -f1 \
  | tr ',' '\n' \
  | sed 's/^ *//; s/ *$//' \
  | sort -u
