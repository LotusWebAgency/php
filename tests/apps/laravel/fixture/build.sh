#!/usr/bin/env bash
# Laravel fixture: runs as root inside the stock builder container (see
# tests/apps/build-fixture.sh for the environment and the services on the net).
#
# Layout: fixture/overlay is the application code shared by every set;
# fixture/<set> holds what differs (composer.json + composer.lock, files that
# follow the framework's own structure: bootstrap/app.php on 11+, the HTTP
# kernel before that, and an optional patch.sh for a skeleton setting that has
# to become env-driven).
set -euo pipefail

SET="${APPTEST_SET:?}"
HERE="/apptest/laravel/fixture"
APP=/srv/app
DB_PASS="${APPTEST_DB_PASSWORD:?}"
PORT=8099

cd /
bash /apptest/install-composer.sh /usr/local/bin/composer

rm -rf "$APP"
mkdir -p "$APP"
tmp="$(mktemp -d)"
bash /apptest/fetch.sh laravel-app "$SET" "$tmp/laravel.tar.gz"
tar -xzf "$tmp/laravel.tar.gz" -C "$APP" --strip-components=1
# Upstream's notes for coding agents are not part of the application under test.
rm -f "$APP/AGENTS.md" "$APP/CLAUDE.md" "$APP/tests/Feature/ExampleTest.php" "$APP/tests/Unit/ExampleTest.php"

cp "$HERE/$SET/composer.json" "$HERE/$SET/composer.lock" "$APP/"
cp -a "$HERE/overlay/." "$APP/"
[ ! -d "$HERE/$SET/overlay" ] || cp -a "$HERE/$SET/overlay/." "$APP/"
[ ! -f "$HERE/$SET/patch.sh" ] || (cd "$APP" && bash "$HERE/$SET/patch.sh")

cat > "$APP/.env" <<ENV
APP_NAME=Apptest
APP_ENV=production
APP_KEY=base64:$(printf 'apptest-fixture-key-0123456789ab' | base64)
APP_DEBUG=false
APP_URL=http://${APPTEST_HOST:-apptest.test}
APP_LOCALE=en
APP_FALLBACK_LOCALE=en

LOG_CHANNEL=single
LOG_LEVEL=warning

DB_CONNECTION=mysql
DB_HOST=${APPTEST_DB_HOST:-db}
DB_PORT=3306
DB_DATABASE=laravel
DB_USERNAME=root
DB_PASSWORD=$DB_PASS

BCRYPT_ROUNDS=10

SESSION_DRIVER=database
SESSION_LIFETIME=525600
SESSION_ENCRYPT=false
SESSION_COOKIE=apptest-session

# 11+ reads CACHE_STORE and BROADCAST_CONNECTION, 8-10 the older names; before
# 7 the mailer is MAIL_DRIVER, and 5.5 names its queue and log settings
# QUEUE_DRIVER, APP_LOG and APP_LOG_LEVEL.
CACHE_STORE=redis
CACHE_DRIVER=redis
CACHE_PREFIX=apptest
QUEUE_CONNECTION=database
QUEUE_DRIVER=database
FILESYSTEM_DISK=local
MAIL_MAILER=log
MAIL_DRIVER=log
BROADCAST_CONNECTION=log
BROADCAST_DRIVER=log
APP_LOG=single
APP_LOG_LEVEL=warning

REDIS_CLIENT=phpredis
REDIS_HOST=redis
REDIS_PORT=6379
MEMCACHED_HOST=memcached

APPTEST_PHP_MIN=${APPTEST_PHP_MIN:?}
ENV

cd "$APP"
php -r '
$pdo = new PDO("mysql:host=db", "root", getenv("APPTEST_DB_PASSWORD"));
foreach (["laravel", "laravel_test"] as $name) {
    $pdo->exec("CREATE DATABASE IF NOT EXISTS `$name` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
}'

# The committed lock is the whole dependency set; nothing resolves here. The
# stock image disables proc_open even for the CLI, and composer's script runner
# (package:discover) needs it, so composer alone gets it back.
composer() { php -d disable_functions= /usr/local/bin/composer "$@"; }
composer install --no-interaction --no-progress --prefer-dist
composer validate --no-check-publish --no-check-lock >/dev/null

php artisan migrate --force
# The seeders are namespaced (Database\Seeders); before 8 the command's default is a global DatabaseSeeder.
time php artisan db:seed --force --class='Database\Seeders\DatabaseSeeder'

# A logged-in session written by this PHP through the real login form, over
# HTTP: the suites present it to the PHP under test.
# The router script by absolute path: 7.0 resolves a relative one against the document root.
php -S "127.0.0.1:$PORT" -t public "$APP/public/index.php" >"$tmp/server.log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/up" >/dev/null 2>&1 && break; sleep 0.2; done
jar="$tmp/cookies.txt"
csrf="$(curl -fsS -c "$jar" -b "$jar" "http://127.0.0.1:$PORT/login" | sed -n 's/.*name="_token" value="\([^"]*\)".*/\1/p' | head -n1)"
[ -n "$csrf" ] || { echo "FATAL: no CSRF token on /login"; exit 1; }
code="$(curl -sS -c "$jar" -b "$jar" -o /dev/null -w '%{http_code}' -d "_token=$csrf" \
  --data-urlencode 'email=user1@apptest.test' --data-urlencode 'password=Password-1!' "http://127.0.0.1:$PORT/login")"
[ "$code" = 302 ] || { echo "FATAL: login answered $code"; exit 1; }
code="$(curl -sS -c "$jar" -b "$jar" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/dashboard")"
[ "$code" = 200 ] || { echo "FATAL: dashboard answered $code after login"; exit 1; }
cookie="$(awk -F'\t' '$6 == "apptest-session" { print $6 "=" $7 }' "$jar" | tail -n1)"
[ -n "$cookie" ] || { echo "FATAL: no session cookie in the jar"; cat "$jar"; exit 1; }
kill "$server"; trap - EXIT

mkdir -p .apptest
php artisan apptest:manifest --session-cookie="$cookie"

php artisan config:cache
php artisan route:cache
# view:cache is 5.6+.
if php artisan list --raw | grep -q '^view:cache '; then php artisan view:cache; fi
php artisan apptest:verify | tee "$tmp/verify.txt"
! grep -q '^FAIL' "$tmp/verify.txt" || { echo "FATAL: the fixture does not verify against itself"; exit 1; }

# The file cache store creates data/xx/yy on first write. Laravel 8's mkdir
# races when many workers write fresh keys at once and one loses the shared
# parent (file_put_contents: No such file or directory), which the burst tests
# provoke; with the first level present, only the leaf can collide, and that
# one is harmless.
for n in $(seq 0 255); do mkdir -p "storage/framework/cache/data/$(printf '%02x' "$n")"; done

rm -f storage/logs/*.log
rm -rf "$tmp"
echo "laravel $(php -r 'echo json_decode(file_get_contents(".apptest/manifest.json"))->app_version;') fixture built"
