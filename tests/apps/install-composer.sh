#!/usr/bin/env bash
# Install the pinned composer that runs on this PHP as /usr/local/bin/composer:
# the 2.2 LTS below 7.2.5 (2.3+ refuses to start there), current 2.x above.
# Runs inside a fixture builder or a cli-builder suite container.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${1:-/usr/local/bin/composer}"
if php -r 'exit(PHP_VERSION_ID >= 70205 ? 0 : 1);'; then name=composer; else name=composer-lts; fi
bash "$HERE/fetch.sh" "$name" - "$dest"
chmod 0755 "$dest"
"$dest" --version --no-ansi
