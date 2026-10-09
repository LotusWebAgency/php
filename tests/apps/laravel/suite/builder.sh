#!/usr/bin/env bash
# cli-builder flavor: composer against the committed lock, on the image's own
# PHP, as the image's default user. check-platform-reqs is the point: it proves
# the image carries every extension the lock's packages ask for.
set -uo pipefail
. /apptest/cli-lib.sh

COMPOSER_HOME="$(mktemp -d)"
export COMPOSER_CACHE_DIR=/composer-cache COMPOSER_NO_INTERACTION=1 COMPOSER_HOME
WORK="$(mktemp -d /tmp/apptest-builder.XXXXXX)"
NODEV="$(mktemp -d /tmp/apptest-builder-nodev.XXXXXX)"
trap 'rm -rf "$WORK" "$NODEV" "$COMPOSER_HOME"' EXIT

echo "builder: $(php -r 'echo PHP_VERSION, " ", PHP_SAPI;') as $(id -un) ($(id -u))"
# Only the stock cli-builder images carry composer; on the other stock images
# (and there only) the suite fetches the pinned one, like the fixture build does.
if ! command -v composer >/dev/null && [ "${APPTEST_STOCK:-0}" = 1 ]; then
  APPTEST_CACHE="$(mktemp -d)"
  export APPTEST_CACHE
  mkdir -p "$COMPOSER_HOME/bin"
  bash /apptest/install-composer.sh "$COMPOSER_HOME/bin/composer" >/dev/null 2>&1 && export PATH="$COMPOSER_HOME/bin:$PATH"
fi
command -v composer >/dev/null || { fail "composer is not on PATH in a cli-builder image"; finish laravel-builder; exit 1; }
check_out "composer runs" "Composer version" composer --version --no-ansi

# Composer's script runner (package:discover) needs proc_open. Older stock
# cli-builder images disable it, so there composer alone gets it back.
if ! php -r 'exit(function_exists("proc_open") ? 0 : 1);'; then
  COMPOSER_BIN="$(command -v composer)"
  export COMPOSER_BIN
  composer() { php -d disable_functions= "$COMPOSER_BIN" "$@"; }
  export -f composer
  skip "composer scripts with the image's own disable_functions" "proc_open is disabled in this image; composer runs with it re-enabled"
fi

# A copy of the app without vendor/ and without anything cached against /srv/app.
fresh() {
  cp -a /srv/app/. "$1/"
  rm -rf "$1/vendor" "$1"/bootstrap/cache/*.php "$1"/storage/framework/views/*.php "$1"/storage/logs/*
}
fresh "$WORK"
cd "$WORK" || exit 1

check "composer validate" composer validate --no-check-publish --no-ansi
check "composer install from the committed lock" composer install --no-progress --no-ansi --prefer-dist
check "vendor/ holds every locked package" php -r '
$lock = json_decode(file_get_contents("composer.lock"), true);
$installed = json_decode(file_get_contents("vendor/composer/installed.json"), true);
$want = count($lock["packages"]) + count($lock["packages-dev"]);
$have = count($installed["packages"] ?? $installed);
fwrite(STDERR, "locked $want, installed $have\n");
exit($want === $have ? 0 : 1);'
check "check-platform-reqs (installed)" composer check-platform-reqs --no-ansi
check "check-platform-reqs (lock)" composer check-platform-reqs --lock --no-ansi
check "second install has nothing to do" bash -c 'composer install --no-progress --no-ansi 2>&1 | grep -q "Nothing to install"'
check_out "composer show sees the framework" "$(php -r '$m = json_decode(file_get_contents("/srv/app/.apptest/manifest.json"), true); echo $m["app_version"];')" composer show laravel/framework --no-ansi
check "dump-autoload --classmap-authoritative" composer dump-autoload --classmap-authoritative --no-ansi
check "authoritative classmap resolves the app's classes" php -r '
require "vendor/autoload.php";
foreach (["App\Models\Post", "App\Apptest\Goldens", "Illuminate\Foundation\Application", "Carbon\Carbon", "PHPUnit\Framework\TestCase"] as $c) {
    if (!class_exists($c)) { fwrite(STDERR, "cannot load $c\n"); exit(1); }
}'
check_out "artisan boots from the fresh vendor" "Laravel Framework" php artisan --version
check "package discovery ran" test -s bootstrap/cache/packages.php
check_out "artisan route:list from the fresh vendor" "api/features/hash" php artisan route:list
check "the app verifies itself from the fresh vendor" php artisan apptest:verify
check "phpunit runs from the fresh vendor" php vendor/bin/phpunit --version

# The production install: no dev packages, authoritative classmap, as a deploy does it.
fresh "$NODEV"
cd "$NODEV" || exit 1
check "composer install --no-dev --classmap-authoritative" composer install --no-dev --classmap-authoritative --no-progress --no-ansi --prefer-dist
check "no dev packages in the production vendor" bash -c '[ ! -d vendor/phpunit ] && [ ! -d vendor/mockery ]'
check "check-platform-reqs (no-dev)" composer check-platform-reqs --no-dev --no-ansi
check_out "artisan boots from the production vendor" "Laravel Framework" php artisan --version
check "the app verifies itself from the production vendor" php artisan apptest:verify

finish laravel-builder
