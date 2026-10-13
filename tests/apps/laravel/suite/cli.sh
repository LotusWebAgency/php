#!/usr/bin/env bash
# Laravel on the CLI: artisan, the queue worker, the scheduler, the fixture's
# own verification command and the app's PHPUnit suite. Runs inside the image
# under test with the fixture tree at /srv/app.
set -uo pipefail
. /apptest/cli-lib.sh
cd /srv/app || exit 1

art() { php artisan "$@"; }
mf() {
  php -r '$v = json_decode(file_get_contents(".apptest/manifest.json"), true);
    foreach (explode(".", $argv[1]) as $k) { $v = $v[$k]; } echo is_array($v) ? json_encode($v) : $v;' "$1"
}
ev() { art apptest:eval "$1"; }
LFULL="$(mf app_version)"
LV="${LFULL%%.*}"
# laravel_at_least N -- true when the fixture's framework is at least major N.
laravel_at_least() { [ "$LV" -ge "$1" ]; }
# laravel_since X.Y -- the same for a minor release (5.5, 5.6, ... predate 6).
laravel_since() { [ "$(printf '%s\n%s\n' "$1" "$LFULL" | sort -V | head -n1)" = "$1" ]; }
RUN="cli$$$(date +%s)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

echo "cli: $(php -r 'echo PHP_VERSION, " ", PHP_SAPI;') as $(id -un) ($(id -u))"
check "app tree is writable for this user" bash -c 'touch storage/.probe && rm storage/.probe'
check_out "artisan --version is the fixture's release" "Laravel Framework $(mf app_version)" art --version
HAVE_PROC_OPEN=0
php -r 'exit(function_exists("proc_open") ? 0 : 1);' && HAVE_PROC_OPEN=1
if ! laravel_at_least 9; then
  skip "artisan about" "Laravel $LV has no about command"
  skip "artisan about: environment" "Laravel $LV has no about command"
elif [ "$HAVE_PROC_OPEN" = 1 ]; then
  check_out "artisan about" "Laravel Version" art about
  check_out "artisan about: environment" "production" art about
else
  skip "artisan about" "it asks composer for its version through Symfony Process; proc_open is disabled in this image"
fi
check_out "artisan env" "production" art env
check_out "artisan list has the app's commands" "apptest:verify" art list
check_out "artisan inspire" "" art inspire
check_out "key:generate --show" "base64:" art key:generate --show

# ---- migrations, routes, config caches (into scratch paths, the fixture's stay)
check_out "migrate:status: everything ran" "create_blog_tables" art migrate:status
# Before 8 the table's column says Y or N, 8 and 9 print Yes or No under "Ran?", 10+ one line per migration.
if laravel_at_least 10; then
  check "migrate:status: nothing pending" bash -c '! php artisan migrate:status | grep -q Pending'
else
  check "migrate:status: nothing pending" bash -c '! php artisan migrate:status | grep -qE "^\| (No|N) "'
fi
check_out "route:list" "redis-session/hit" art route:list
if laravel_since 5.8; then
  check "route:list --json parses and is not small" bash -c 'php artisan route:list --json | php -r "exit(count(json_decode(stream_get_contents(STDIN), true)) > 30 ? 0 : 1);"'
else
  skip "route:list --json parses and is not small" "Laravel $LFULL has no route:list --json"
fi
# The cache paths follow APP_CONFIG_CACHE / APP_ROUTES_CACHE from 6 (5.8 reads them
# from $_ENV, which a variables_order without E would empty); before that the
# caches live in bootstrap/cache and these checks work on the run's own copy.
if laravel_at_least 6; then
  CFG="$SCRATCH/config.php"; RTS="$SCRATCH/routes.php"
  CFGENV=(env APP_CONFIG_CACHE="$CFG"); RTSENV=(env APP_ROUTES_CACHE="$RTS")
else
  CFG=bootstrap/cache/config.php; RTS=bootstrap/cache/routes.php
  CFGENV=(env APPTEST_NO_CACHE_PATH=1); RTSENV=(env APPTEST_NO_CACHE_PATH=1)
fi
check "config:cache writes a scratch cache" "${CFGENV[@]}" php artisan config:cache
check "cached config is a loadable array" php -r 'exit(is_array(require $argv[1]) ? 0 : 1);' "$CFG"
check "cached config carries the app's values" grep -qF "'timezone' => 'UTC'" "$CFG"
check "config:clear removes it" bash -c '"$@" php artisan config:clear && [ ! -f "$0" ]' "$CFG" "${CFGENV[@]}"
check "route:cache writes a scratch cache" "${RTSENV[@]}" php artisan route:cache
check "route cache exists" test -s "$RTS"
check "route:clear removes it" bash -c '"$@" php artisan route:clear && [ ! -f "$0" ]' "$RTS" "${RTSENV[@]}"
if laravel_since 5.6; then
  check "view:clear then view:cache compiles the templates" bash -c 'php artisan view:clear && php artisan view:cache && [ "$(ls storage/framework/views/*.php | wc -l)" -ge 8 ]'
else
  skip "view:clear then view:cache compiles the templates" "Laravel $LFULL has no view:cache"
fi
if laravel_since 5.8; then
  check "event:list" art event:list
else
  skip "event:list" "Laravel $LFULL has no event:list"
fi
check "storage:link" bash -c 'php artisan storage:link && [ -L public/storage ]'
check "down and up (maintenance mode file)" bash -c 'php artisan down --retry=60 && [ -f storage/framework/down ] && php artisan up && [ ! -f storage/framework/down ]'
if laravel_at_least 10; then
  check_out "config:show" "apptest" art config:show cache.prefix
  check_out "db:show reaches the database" "posts" art db:show
  check_out "model:show" "posts" art model:show Post
else
  skip "config:show" "Laravel $LV has no config:show"
  skip "db:show reaches the database" "Laravel $LV has no db:show"
  skip "model:show" "Laravel $LV has no model:show"
fi
if laravel_at_least 6; then
  check_out "tinker --execute (psysh)" "3" env HOME="$SCRATCH" XDG_CONFIG_HOME="$SCRATCH" php artisan tinker --execute='echo collect([1, 2])->sum();'
else
  skip "tinker --execute (psysh)" "tinker 1.x (Laravel $LFULL) has no --execute"
fi

# ---- the app's own verification, relayed line by line
verify="$(art apptest:verify 2>&1)"
vrc=$?
while IFS= read -r line; do
  case "$line" in
    "ok: "*) ok "${line#ok: }" ;;
    "FAIL: "*) fail "${line#FAIL: }" ;;
  esac
done <<<"$verify"
[ "$vrc" -eq 0 ] || { [ "$APPTEST_FAILED" -gt 0 ] || fail "apptest:verify exited $vrc"; echo "$verify" | tail -5; }
check_out "verify covered every golden" "golden: no extra keys" bash -c 'echo "$0"' "$verify"

# ---- eval command (tinker-free)
check_out "eval: collection" "12" ev 'return collect([1, 2, 3])->map(function ($x) { return $x * 2; })->sum();'
check_out "eval: Str::slug on Cyrillic" '"privet-mir"' ev 'return Illuminate\Support\Str::slug("Привет мир");'
check_out "eval: seeded row count" "true" ev 'return App\Models\Post::count() >= 2000 && App\Models\Comment::count() >= 10000;'
check_out "eval: user model" "user41@apptest.test" ev 'return App\Models\User::find(41)->email;'
check_out "eval: utf8 through the database" '"Привет 😀 日本語"' ev 'return DB::selectOne("SELECT ? AS v", ["Привет 😀 日本語"])->v;'
check_out "eval: mail renders to the array transport" "1" ev 'return count(App\Apptest\Mailbox::deliver("a@apptest.test", new App\Mail\PostDigest(App\Models\Post::forApi()->limit(2)->get())));'
for store in redis memcached database file redis_igbinary; do
  check_out "cache store $store" '"värde ✓"' ev "Cache::store('$store')->put('$RUN', 'värde ✓', 60); return Cache::store('$store')->get('$RUN');"
done
if laravel_since 5.6; then
  check_out "cache lock on redis" "true" ev '$l = Cache::store("redis")->lock("cli-lock-'"$RUN"'", 10); $got = $l->get(); $l->release(); return $got;'
else
  skip "cache lock on redis" "Laravel $LFULL has no cache locks"
fi
check_out "redis ping through phpredis" "true" ev 'return (bool) Illuminate\Support\Facades\Redis::connection()->ping();'
check "cache:clear" art cache:clear

# ---- queue: dispatch, drain with the worker, verify the side effect
# 5.5 has no --stop-when-empty: one --once per waiting job instead.
drain() {
  if php artisan queue:work --help | grep -q -- '--stop-when-empty'; then
    php artisan queue:work --queue="$1" --stop-when-empty --tries=1 --sleep=0
    return
  fi
  local n
  for _ in $(seq 1 20); do
    n="$(php artisan apptest:eval 'return DB::table("jobs")->where("queue", "'"$1"'")->count();')"
    [ "$n" != 0 ] || return 0
    php artisan queue:work --queue="$1" --once --tries=1 --sleep=0 || return 1
  done
  return 1
}
check_out "dispatch onto the database queue" "dispatched $RUN" art apptest:dispatch "$RUN" --queue=cli --fail
check_out "the job is waiting" "2" ev 'return DB::table("jobs")->where("queue", "cli")->count();'
check "queue:work drains the queue" drain cli
check_out "queued job's side effect exists" "1" ev 'return App\Models\JobLog::where("kind", "queued")->where("token", "'"$RUN"'")->count();'
check_out "queued job carried model, Carbon and array" '2025-06-07T08:09:10Z' ev 'return App\Models\JobLog::where("token", "'"$RUN"'")->first()->payload;'
check_out "the queue is empty" "0" ev 'return DB::table("jobs")->where("queue", "cli")->count();'
check_out "failed job is listed" "FailingJob" art queue:failed
check_out "dispatch a second job" "dispatched $RUN-once" art apptest:dispatch "$RUN-once" --queue=cli
check "queue:work --once handles exactly one job" art queue:work --queue=cli --once --tries=1
check_out "…and it ran" "1" ev 'return App\Models\JobLog::where("kind", "queued")->where("token", "'"$RUN"'-once")->count();'
check "queue:work drains the job the stock PHP queued" drain stock
check_out "stock-queued job payload decoded" '2024-01-02T03:04:05Z' ev 'return App\Models\JobLog::where("token", "stock-queued")->first()->payload;'
check "queue:retry all" art queue:retry all
check "queue:flush" art queue:flush

# ---- scheduler
if laravel_at_least 8; then
  check_out "schedule:list" "apptest:heartbeat" art schedule:list
else
  skip "schedule:list" "Laravel $LFULL has no schedule:list"
fi
# A command event runs through Symfony Process. From 8 the scheduler reports that
# failure and carries on; before, it aborts the run, so there the scheduler alone
# gets proc_open back where the image disables it (the child php needs none).
SCHED_PROC="$HAVE_PROC_OPEN"
SCHED=(php artisan)
if [ "$HAVE_PROC_OPEN" = 0 ] && ! laravel_at_least 8; then SCHED=(php -d disable_functions= artisan); SCHED_PROC=1; fi
check "schedule:run" "${SCHED[@]}" schedule:run
check_out "scheduled closure ran in-process" "true" ev 'return App\Models\JobLog::where("token", "scheduled-closure")->count() >= 1;'
if [ "$SCHED_PROC" = 1 ]; then
  check_out "scheduled command ran as a subprocess" "true" ev 'return App\Models\JobLog::where("token", "scheduled-command")->count() >= 1;'
else
  skip "scheduled command ran as a subprocess" "proc_open is disabled in this image"
fi

# ---- the app's PHPUnit suite, against its own database
php -r '
$pdo = new PDO("mysql:host=db", "root", getenv("APPTEST_DB_PASSWORD") ?: "apptest");
$pdo->exec("CREATE DATABASE IF NOT EXISTS laravel_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");' \
  && ok "test database exists" || fail "test database could not be created"
# Cached config would hide phpunit.xml's environment; point the caches at
# paths that do not exist so the app boots from .env plus phpunit's overrides.
# Before 6 the paths are fixed, so the caches are dropped (this run's own copy).
laravel_at_least 6 || { php artisan config:clear >/dev/null; php artisan route:clear >/dev/null; }
out="$(APP_CONFIG_CACHE="$SCRATCH/none-config.php" APP_ROUTES_CACHE="$SCRATCH/none-routes.php" vendor/bin/phpunit 2>&1)"
rc=$?
summary="$(printf '%s\n' "$out" | grep -E '^(OK|Tests:|FAILURES|ERRORS)' | head -3 | tr '\n' ' ')"
if [ "$rc" -eq 0 ]; then ok "phpunit: $summary"; else fail "phpunit exit $rc -- $summary"; printf '%s\n' "$out" | tail -60 | sed 's/^/    | /'; fi
printf '%s\n' "$out" | grep -qE 'Tests: [0-9]+|OK \([0-9]+ tests' && ok "phpunit ran tests" || fail "phpunit ran no tests"

finish laravel-cli
