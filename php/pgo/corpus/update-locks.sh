#!/usr/bin/env bash
# Regenerate the committed composer.lock files, one per app per tier.
#
#   ./php/pgo/corpus/update-locks.sh            # every app, every tier
#   ./php/pgo/corpus/update-locks.sh symfony    # one app, every tier
#
# Tiers, and the builder image each resolves in, come from scripts/pgo_tiers.py
# (derived from matrix.json). Resolution runs inside the tier's own cli-builder
# image so Composer resolves against the PHP the corpus runs on, and each tier's
# composer.json pins config.platform.php to the tier's floor release, so the lock
# (and the generated vendor/composer/platform_check.php) stays installable on
# every version the tier serves. --no-install because only the lock is wanted.
#
# The 7.2 and 7.0 composer.json files carry config.policy.advisories.block =
# false: Composer 2.10 refuses to select a release with an open security
# advisory, and every stable Laravel 6 and 5.5 release, and twig/twig on the
# branches Symfony 5.4 and 3.4 require, has one on an EOL branch that will never
# be cleared. Left blocked, Composer either fails (Symfony) or escapes onto
# untagged dev branches (Laravel 6 locked "laravel/framework 6.x-dev"). A PHP 7.x
# corpus exists to profile the code PHP 7.x users ran, and stable tags beat an
# unpinnable dev snapshot. Nothing from this corpus is installed into a published
# image.
#
# The 8.4 and 8.5 lockfiles share the 8.2 tier's package set and differ only in the
# root php constraint, config.platform.php and content-hash. Re-resolving every
# tier can move them apart, so compare those two locks against 8.2's after running.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../.." && pwd)"
ONLY_APP="${1:-}"

while IFS=$'\t' read -r tier release builder _tag _versions; do
  for appdir in "$HERE"/*/; do
    app="$(basename "$appdir")"
    [ -z "$ONLY_APP" ] || [ "$app" = "$ONLY_APP" ] || continue
    manifest="${appdir}${tier}/composer.json"
    [ -f "$manifest" ] || continue

    echo "=== $app / tier $tier (floor php $release, $builder)"
    work="$(mktemp -d)"
    cp "$manifest" "$work/composer.json"
    chmod -R a+rwX "$work"
    docker run --rm -v "$work:/app" -w /app "$builder" \
      composer update --no-dev --no-install --no-scripts --no-interaction
    cp "$work/composer.lock" "${appdir}${tier}/composer.lock"
    chmod u+w "${appdir}${tier}/composer.lock"
    rm -rf "$work"
  done
done < <(python3 "${ROOT}/scripts/pgo_tiers.py" list)

echo
echo "Now: ./tests/build-corpus.sh, then tests/test-corpus.sh per tag and tests/test-corpus-tiers.sh."
