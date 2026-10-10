#!/usr/bin/env bash
# Install the pinned composer that runs on this PHP as /usr/local/bin/composer:
# the 2.2 LTS below 7.2.5 (2.3+ refuses to start there), current 2.x above.
# Runs inside a fixture builder or a cli-builder suite container.
#
#   install-composer.sh [dest]          copy the phar baked into the fixture
#                                       (/srv/app/.apptest/bin, or $APPTEST_BAKED_BIN);
#                                       download it (fetch.sh, under retry) only when absent
#   install-composer.sh --bake <dir>    fetch both phars (composer, composer-lts) into <dir>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
baked="${APPTEST_BAKED_BIN:-/srv/app/.apptest/bin}"

if [ "${1:-}" = "--bake" ]; then
  dir="${2:?usage: install-composer.sh --bake <dir>}"
  mkdir -p "$dir"
  for name in composer composer-lts; do
    bash "$HERE/fetch.sh" "$name" - "$dir/$name"
    chmod 0755 "$dir/$name"
  done
  exit 0
fi

dest="${1:-/usr/local/bin/composer}"
if php -r 'exit(PHP_VERSION_ID >= 70205 ? 0 : 1);'; then name=composer; else name=composer-lts; fi
if [ -f "$baked/$name" ]; then
  cp "$baked/$name" "$dest"
else
  bash "$HERE/fetch.sh" "$name" - "$dest"
fi
chmod 0755 "$dest"
"$dest" --version --no-ansi
