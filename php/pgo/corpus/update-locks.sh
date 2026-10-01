#!/usr/bin/env bash
# Regenerate the committed composer.lock files, one per app per tier.
#
#   ./php/pgo/corpus/update-locks.sh            # every app, every tier
#   ./php/pgo/corpus/update-locks.sh symfony    # one app, every tier
#
# Tiers, and the builder image each resolves in, come from
# scripts/pgo_tiers.py, which derives them from matrix.json. Resolution runs
# inside the tier's own cli-builder image so the platform Composer resolves
# against is the PHP the corpus will actually run on -- and each tier's
# composer.json pins config.platform.php to that tier's *floor* release, so the
# lock (and the vendor/composer/platform_check.php Composer generates from it)
# stays installable on every version the tier serves, not just the newest.
# --no-install because only the lock is wanted here; the corpus build installs.
#
# The 7.2 and 7.0 composer.json files carry config.policy.advisories.block =
# false. That is not laziness: Composer 2.10 refuses by default to select a
# release with an open security advisory, and every stable release of Laravel 6
# and 5.5, and of twig/twig on the branches Symfony 5.4 and 3.4 require, has
# one -- their branches are EOL, so the advisories will never be cleared. Left
# blocked, Composer either fails outright (Symfony) or silently escapes onto
# untagged dev branches (Laravel 6 locked "laravel/framework 6.x-dev" the first
# time this ran). A corpus for PHP 7.x exists precisely to profile the code
# PHP 7.x users ran; pinning stable tags and saying so beats an unpinnable dev
# snapshot. Nothing from this corpus is installed into a published image.
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
