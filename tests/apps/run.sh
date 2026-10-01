#!/usr/bin/env bash
# Run the application suites against one PHP image.
#
#   ./tests/apps/run.sh lotuswebagency/php:8.4-fpm
#   ./tests/apps/run.sh lotuswebagency/php:7.2-cli --app laravel
#   ./tests/apps/run.sh dementev/php-fpm-with-ext:8.3-fpm --flavor cli   stock baseline, CLI suites
#   ./tests/apps/run.sh lotuswebagency/php:8.5-fpm --app wordpress --keep
#
# Options:
#   --app A          laravel, wordpress, prestashop (repeatable; default all)
#   --flavor F       fpm, cli or cli-builder; default is read from the tag
#   --config C       fpm only: default, hardened (repeatable; default both
#                    where the image supports hardened, i.e. ours on >=7.2)
#   --keep           leave the last stack running and print how to reach it
#   --no-build       fail instead of building a missing or stale fixture
#
# What runs, per app, against the set tests/apps/sets resolves the image's
# php version to:
#   fpm          the fixture behind nginx; <app>/suite/web.py over HTTP,
#                once per config, php-fpm restarted between configs
#   cli          <app>/suite/cli.sh inside the image
#   cli-builder  <app>/suite/builder.sh (composer against the real lock),
#                then cli.sh
# and after every step the php container's own log is scanned: a signal
# death, a heap corruption message or a PHP fatal fails the step even when
# every request looked fine.
#
# Every result is one RESULT line on stdout (tab-separated), appended to
# $APPTEST_RESULTS as well when it is set -- run-matrix.sh collects those.
set -euo pipefail
# shellcheck source=tests/apps/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

IMAGE=""
APPS=()
FLAVOR=""
CONFIGS=()
KEEP=0
NO_BUILD=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) APPS+=("${2:?}"); shift 2 ;;
    --flavor) FLAVOR="${2:?}"; shift 2 ;;
    --config) CONFIGS+=("${2:?}"); shift 2 ;;
    --keep) KEEP=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) apptest_die "unknown option $1" ;;
    *) [ -z "$IMAGE" ] || apptest_die "one image per run ($IMAGE, $1)"; IMAGE="$1"; shift ;;
  esac
done
[ -n "$IMAGE" ] || apptest_die "usage: run.sh <image> [--app A] [--flavor F] [--config C] [--keep] [--no-build]"
[ "${#APPS[@]}" -gt 0 ] || APPS=("${APPTEST_APPS[@]}")

docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null || apptest_die "no such image $IMAGE"

if [ -z "$FLAVOR" ]; then
  case "$IMAGE" in
    *-cli-builder*) FLAVOR=cli-builder ;;
    *-cli*) FLAVOR=cli ;;
    *-fpm*) FLAVOR=fpm ;;
    *) apptest_die "cannot tell the flavor of $IMAGE from its tag -- pass --flavor" ;;
  esac
fi
case "$FLAVOR" in fpm|cli|cli-builder) ;; *) apptest_die "flavor '$FLAVOR' is not fpm, cli or cli-builder" ;; esac

PHP="$(apptest_image_php "$IMAGE")"
STOCK=0
apptest_is_stock "$IMAGE" && STOCK=1
IDS="$(apptest_image_ids "$IMAGE")"

if [ "$FLAVOR" = fpm ] && [ "${#CONFIGS[@]}" -eq 0 ]; then
  CONFIGS=(default)
  # Snuffleupagus ships from 7.2 (php/ext.json); the stock image has none.
  if [ "$STOCK" -eq 0 ] && apptest_ver_le 7.2 "$PHP"; then CONFIGS+=(hardened); fi
fi
[ "$FLAVOR" = fpm ] || CONFIGS=(default)

slug="$(printf '%s' "$IMAGE" | tr -c 'a-z0-9' '-' | tr -s '-' | cut -c1-40)"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
LOG_ROOT="${APPTEST_LOG_DIR:-$APPTEST_REPO/.claude/tmp/apptest}"
RUN_DIR="$LOG_ROOT/runs/${slug}-${FLAVOR}-${RUN_ID}"
mkdir -p "$RUN_DIR"
echo "=== $IMAGE: php $PHP, $FLAVOR, $([ "$STOCK" -eq 1 ] && echo stock || echo ours), www-data $IDS, logs $RUN_DIR"

export APPTEST_ROOT APPTEST_HOST PHP_IMAGE="$IMAGE" APPTEST_PHP="$PHP" APPTEST_FLAVOR="$FLAVOR" APPTEST_STOCK="$STOCK"
export APP_UID="${IDS%%:*}" APP_GID="${IDS##*:}"

# APPTEST_SP_RULES=<dir> mounts a working-tree ruleset directory over the
# image's baked /usr/local/etc/php/snuffleupagus, to try rule changes across
# the matrix before rebuilding. The result then says so: it is not a verdict
# on the image as built.
SP_NOTE=""
if [ -n "${APPTEST_SP_RULES:-}" ]; then
  [ -d "$APPTEST_SP_RULES" ] || apptest_die "APPTEST_SP_RULES: no such directory: $APPTEST_SP_RULES"
  APPTEST_SP_SRC="$(realpath "$APPTEST_SP_RULES")"
  export APPTEST_SP_SRC APPTEST_SP_DST=/usr/local/etc/php/snuffleupagus
  SP_NOTE=" [rules overridden from $APPTEST_SP_SRC]"
  echo "!!! snuffleupagus rules overridden from $APPTEST_SP_SRC"
else
  export APPTEST_SP_SRC="$APPTEST_ROOT" APPTEST_SP_DST=/apptest-sp-rules-unused
fi

# Composer's cache is shared by every stack and written by whichever uid the
# image under test runs as.
docker volume create apptest-composer-cache >/dev/null
docker run --rm -v apptest-composer-cache:/c --entrypoint sh "$APPTEST_REDIS_IMAGE" -c 'chmod 1777 /c' >/dev/null

TOTAL_FAIL=0
result() {  # result <app> <set> <config> <ok|FAIL> <detail>
  local line
  line="$(printf 'RESULT\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$IMAGE" "$PHP" "$FLAVOR" "$3" "$4" "$5$SP_NOTE")"
  echo "$line"
  [ -z "${APPTEST_RESULTS:-}" ] || echo "$line" >>"$APPTEST_RESULTS"
  [ "$4" = ok ] || TOTAL_FAIL=$((TOTAL_FAIL + 1))
}

# scan_log <file> -> prints the lines that fail a run; returns 1 when any.
# These are the markers of a broken build rather than a broken request: the
# request that tripped them may well have answered 200.
scan_log() {
  local hits
  # The hardened suites upload suite-<run>.php on purpose; snuffleupagus
  # refusing it is the expected outcome, not a marker.
  hits="$(grep -aE 'exited on signal|SIGSEGV|SIGBUS|SIGILL|SIGABRT|Segmentation fault|core dumped|zend_mm_heap corrupted|double free|free\(\): invalid|malloc\(\)|corrupted size|stack smashing|AddressSanitizer|PHP Fatal error|PHP Parse error' "$1" \
    | grep -avE '\[upload_validation\]\[drop\] The upload of suite-[0-9a-f]+\.php ' || true)"
  [ -z "$hits" ] && return 0
  printf '%s\n' "$hits" | head -20
  return 1
}

compose() { docker compose -f "$APPTEST_ROOT/compose.yml" "$@"; }

# A run that dies half way (timeout, ^C, set -e) must not leave its stack
# behind; --keep is the only way a stack outlives run.sh.
CURRENT_PROJECT=""
teardown() {
  [ -n "$CURRENT_PROJECT" ] && [ "$KEEP" -eq 0 ] || return 0
  docker compose -p "$CURRENT_PROJECT" down -v >/dev/null 2>&1 || true
  # `down` without --profile skips one-off `run` containers of profiled services,
  # and a timed-out `timeout docker compose run` leaves exactly those behind.
  docker ps -aq --filter "label=com.docker.compose.project=$CURRENT_PROJECT" \
    | xargs -r docker rm -f >/dev/null 2>&1 || true
  CURRENT_PROJECT=""
}
trap teardown EXIT
trap 'exit 130' INT TERM

write_env() {  # write_env <app> <config> <file>
  local app="$1" config="$2" out="$3"
  : >"$out"
  if [ "$STOCK" -eq 0 ]; then
    [ ! -f "$APPTEST_ROOT/$app/php.env" ] || cat "$APPTEST_ROOT/$app/php.env" >>"$out"
    if [ "$config" = hardened ]; then
      echo "PHP_SNUFFLEUPAGUS=$app" >>"$out"
      [ ! -f "$APPTEST_ROOT/$app/php-hardened.env" ] || cat "$APPTEST_ROOT/$app/php-hardened.env" >>"$out"
    fi
  else
    [ ! -f "$APPTEST_ROOT/$app/php-stock.env" ] || cat "$APPTEST_ROOT/$app/php-stock.env" >>"$out"
  fi
}

wait_http() {  # wait_http <host:port> <path> -> 0 once anything but a gateway error answers
  local addr="$1" path="$2" code _
  for _ in $(seq 1 120); do
    code="$(curl -s -o /dev/null -m 30 -w '%{http_code}' -H "Host: $APPTEST_HOST" "http://$addr$path" || true)"
    case "$code" in 000|502|503|504) sleep 1 ;; *) return 0 ;; esac
  done
  return 1
}

run_app() {
  local app="$1" set fixture have want dir manifest
  set="$(apptest_resolve_set "$app" "$PHP")" || { result "$app" "-" "-" FAIL "no set for php $PHP"; return; }
  fixture="$(apptest_fixture_tag "$app" "$set")"
  want="$(apptest_recipe_hash "$app" "$set")"
  have="$(apptest_label "$fixture" com.lotuswebagency.apptest-hash)"
  if [ "$have" != "$want" ]; then
    if [ "$NO_BUILD" -eq 1 ]; then
      result "$app" "$set" "-" FAIL "fixture $fixture is ${have:+stale}${have:-missing} and --no-build was given"
      return
    fi
    "$APPTEST_ROOT/build-fixture.sh" "$app" "$set" || { result "$app" "$set" "-" FAIL "fixture build failed"; return; }
  fi

  dir="$RUN_DIR/$app"
  mkdir -p "$dir"
  manifest="$dir/manifest.json"
  docker run --rm --entrypoint cat "$fixture" /srv/app/.apptest/manifest.json >"$manifest"

  export APPTEST_APP="$app" APPTEST_SET="$set" APPTEST_FIXTURE="$fixture"
  export APPTEST_PROJECT="apptest-${app}-${slug}-$$"
  CURRENT_PROJECT="$APPTEST_PROJECT"
  export APPTEST_PHP_ENV="$dir/php.env" APPTEST_CONFIG=default
  write_env "$app" default "$APPTEST_PHP_ENV"
  echo "--- $app $set ($fixture) project $APPTEST_PROJECT"

  local t0 rc
  t0=$(date +%s)
  if ! compose up -d --wait db redis memcached >"$dir/up.log" 2>&1 \
     || ! compose --profile seed run --rm app >>"$dir/up.log" 2>&1; then
    cat "$dir/up.log"
    result "$app" "$set" "-" FAIL "stack did not come up (see $dir/up.log)"
    [ "$KEEP" -eq 1 ] || compose --profile seed --profile web --profile cli down -v >/dev/null 2>&1 || true
    return
  fi

  if [ "$FLAVOR" = fpm ]; then
    local config addr
    for config in "${CONFIGS[@]}"; do
      APPTEST_CONFIG="$config"
      APPTEST_PHP_ENV="$dir/php-$config.env"
      write_env "$app" "$config" "$APPTEST_PHP_ENV"
      if ! compose --profile web up -d --force-recreate php web >"$dir/up-$config.log" 2>&1; then
        cat "$dir/up-$config.log"
        result "$app" "$set" "$config" FAIL "php/web did not start"
        continue
      fi
      addr="$(compose --profile web port web 80)"
      if ! wait_http "$addr" /; then
        compose --profile web logs --no-color php >"$dir/php-$config.log" 2>&1 || true
        tail -30 "$dir/php-$config.log"
        result "$app" "$set" "$config" FAIL "nothing answered on $addr (see $dir/php-$config.log)"
        continue
      fi
      rc=0
      timeout 1800 python3 "$APPTEST_ROOT/$app/suite/web.py" \
        --base "http://$addr" --host "$APPTEST_HOST" --manifest "$manifest" \
        --set "$set" --php "$PHP" --config "$config" --stock "$STOCK" \
        >"$dir/http-$config.log" 2>&1 || rc=$?
      compose --profile web logs --no-color php >"$dir/php-$config.log" 2>&1 || true
      compose --profile web logs --no-color web >"$dir/web-$config.log" 2>&1 || true
      grep -E '^(FAIL|SKIP)' "$dir/http-$config.log" | head -40 || true
      tail -1 "$dir/http-$config.log"
      if [ "$rc" -ne 0 ]; then
        result "$app" "$set" "$config" FAIL "http suite exit $rc (see $dir/http-$config.log)"
      elif ! scan_log "$dir/php-$config.log"; then
        result "$app" "$set" "$config" FAIL "php log has crash/fatal markers (see $dir/php-$config.log)"
      else
        result "$app" "$set" "$config" ok "$(tail -1 "$dir/http-$config.log")"
      fi
    done
  else
    local step steps=(cli)
    [ "$FLAVOR" != cli-builder ] || steps=(builder cli)
    for step in "${steps[@]}"; do
      [ -f "$APPTEST_ROOT/$app/suite/$step.sh" ] || { result "$app" "$set" "$step" FAIL "no suite/$step.sh"; continue; }
      rc=0
      timeout 1800 docker compose -f "$APPTEST_ROOT/compose.yml" --profile cli run --rm -T cli \
        bash "/apptest/$app/suite/$step.sh" >"$dir/$step.log" 2>&1 || rc=$?
      grep -E '^(FAIL|SKIP)' "$dir/$step.log" | head -40 || true
      tail -1 "$dir/$step.log"
      if [ "$rc" -ne 0 ]; then
        result "$app" "$set" "$step" FAIL "suite/$step.sh exit $rc (see $dir/$step.log)"
      elif ! scan_log "$dir/$step.log"; then
        result "$app" "$set" "$step" FAIL "crash/fatal markers in output (see $dir/$step.log)"
      else
        result "$app" "$set" "$step" ok "$(tail -1 "$dir/$step.log")"
      fi
    done
  fi
  echo "    ${app}: $(( $(date +%s) - t0 ))s"

  if [ "$KEEP" -eq 1 ]; then
    echo "kept: project $APPTEST_PROJECT"
    [ "$FLAVOR" != fpm ] || echo "  curl -H 'Host: $APPTEST_HOST' http://$(compose --profile web port web 80)/"
    echo "  tear down: docker compose -p $APPTEST_PROJECT down -v"
  else
    teardown
  fi
}

for app in "${APPS[@]}"; do
  [ -d "$APPTEST_ROOT/$app/suite" ] || apptest_die "no suites at tests/apps/$app/suite"
  run_app "$app"
done

[ "$TOTAL_FAIL" -eq 0 ] || { echo "FAIL: $TOTAL_FAIL step(s) failed on $IMAGE"; exit 1; }
echo "ok: every app suite passed on $IMAGE ($FLAVOR)"
