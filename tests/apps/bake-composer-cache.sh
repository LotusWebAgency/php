#!/usr/bin/env bash
# Fill a composer cache with every dist archive a committed lock needs, then
# prove that the same install works with the network off, so a suite can run
# composer with COMPOSER_DISABLE_NETWORK=1. Runs inside the fixture builder
# (composer at /usr/local/bin/composer, ci/retry.sh as `retry`).
#
#   bake-composer-cache.sh <cache-dir> <project-dir> [composer install options...]
#
# <project-dir> holds composer.json and composer.lock; only those two are read.
# The options are the install's own (--no-dev, ...): the install runs once with
# the network, filling <cache-dir>, and again in a fresh directory without it.
# Neither runs scripts or builds the autoloader, which the cache does not depend on.
set -euo pipefail
cache="${1:?usage: bake-composer-cache.sh <cache-dir> <project-dir> [composer install options...]}"
project="${2:?usage: bake-composer-cache.sh <cache-dir> <project-dir> [composer install options...]}"
shift 2

composer=(php -d memory_limit=-1 -d disable_functions= /usr/local/bin/composer)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$cache"
export COMPOSER_HOME="$work/home" COMPOSER_CACHE_DIR="$cache" COMPOSER_NO_INTERACTION=1 COMPOSER_ALLOW_SUPERUSER=1

install_opts=(install --no-progress --no-scripts --no-autoloader --prefer-dist "$@")
mkdir "$work/online" "$work/offline"
cp "$project/composer.json" "$project/composer.lock" "$work/online/"
cp "$project/composer.json" "$project/composer.lock" "$work/offline/"

echo "=== baking $cache from $project/composer.lock ($*)"
(cd "$work/online" && RETRY_KIND=composer retry "${composer[@]}" "${install_opts[@]}")
(cd "$work/offline" && COMPOSER_DISABLE_NETWORK=1 "${composer[@]}" "${install_opts[@]}") \
  || { echo "FATAL: the baked cache in $cache is not enough for an offline install of $project/composer.lock" >&2; exit 1; }
chmod -R a+rX "$cache"
echo "baked: $(du -sh "$cache" | cut -f1) in $cache"
