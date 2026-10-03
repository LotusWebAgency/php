#!/usr/bin/env bash
# Build application fixture images: one per (app, set) row in ./sets.
#
#   ./tests/apps/build-fixture.sh laravel            every laravel set
#   ./tests/apps/build-fixture.sh wordpress 7.0      one set
#   ./tests/apps/build-fixture.sh --all              every app, every set
#   ./tests/apps/build-fixture.sh --force ...        rebuild even when current
#   ./tests/apps/build-fixture.sh --push ...         also push to APPTEST_FIXTURE_REPO
#
# A fixture is a single image, lotuswebagency/php-apptest:<app>-<set>:
# MariaDB with the populated datadir at /var/lib/mysql-fixture, plus the
# installed, configured application tree at /srv/app (vendor/ included). Run
# it as-is and it is the database; mount a fresh named volume at /srv/app and
# Docker copies the tree into it. Every test run starts from that pristine
# pair and throws it away afterwards, so runs never see each other's writes
# and the same fixture serves every image, every host and CI alike. To share
# it, set APPTEST_FIXTURE_REPO to a registry repository (ghcr.io/<org>/<repo>/
# apptest): the tag becomes <app>-<set>-<arch> (MariaDB is per architecture),
# a fixture that is not current locally is pulled first and used if its label
# matches the recipe hash, and --push uploads what is current (built here, or
# pulled, or already local). A stale or absent registry fixture is rebuilt;
# --force skips the pull.
#
# How a fixture is made: a throwaway network with MariaDB, Redis and
# Memcached on it, and the stock image for the set's php-min
# (apptest_builder_image) as the PHP that installs everything. The app's
# fixture/build.sh runs inside that stock container as root, talks to the
# services by their aliases (db, redis, memcached -- the same names the test
# stack uses, so configs written here are the configs used later), and
# populates the data through the application's own APIs. MariaDB is then
# stopped cleanly, the app tree is copied into its container, and that
# container is committed as the fixture.
#
# The image carries com.lotuswebagency.apptest-hash (apptest_recipe_hash);
# run.sh refuses a fixture whose label disagrees with the tree, the same
# CF-47 rule tests/smoke.sh applies to the php images themselves.
set -euo pipefail
# shellcheck source=tests/apps/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FORCE=0
PUSH=0
ALL=0
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --all) ALL=1; shift ;;
    --push) PUSH=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

[ "$PUSH" -eq 0 ] || apptest_repo_is_registry \
  || apptest_die "--push needs APPTEST_FIXTURE_REPO to be a registry repository (e.g. ghcr.io/lotuswebagency/php/apptest); it is '$APPTEST_FIXTURE_REPO', a local name"

JOBS=()   # "app set"
if [ "$ALL" -eq 1 ]; then
  while read -r app set _lo _hi; do JOBS+=("$app $set"); done < <(apptest_sets_rows)
else
  [ "${#ARGS[@]}" -ge 1 ] || apptest_die "usage: build-fixture.sh <app> [set...] | --all [--force]"
  app="${ARGS[0]}"
  [ -d "$APPTEST_ROOT/$app/fixture" ] || apptest_die "no fixture recipe at tests/apps/$app/fixture"
  if [ "${#ARGS[@]}" -eq 1 ]; then
    while read -r _a set _lo _hi; do JOBS+=("$app $set"); done < <(apptest_sets_rows "$app")
  else
    for set in "${ARGS[@]:1}"; do apptest_set_field "$app" "$set" min >/dev/null || exit 1; JOBS+=("$app $set"); done
  fi
fi

LOG_DIR="${APPTEST_LOG_DIR:-$APPTEST_REPO/.claude/tmp/apptest}/fixtures"
mkdir -p "$LOG_DIR"

build_one() {
  local app="$1" set="$2"
  local tag hash builder name net log manifest app_version builder_ref
  tag="$(apptest_fixture_tag "$app" "$set")"
  hash="$(apptest_recipe_hash "$app" "$set")"
  if [ "$FORCE" -eq 0 ] && apptest_fixture_current "$tag" "$hash"; then
    echo "ok: $tag is current (apptest-hash $hash)"
    [ "$PUSH" -eq 0 ] || apptest_fixture_push "$app" "$set"
    return 0
  fi
  if [ "$FORCE" -eq 0 ] && apptest_fixture_try_pull "$app" "$set"; then
    [ "$PUSH" -eq 0 ] || apptest_fixture_push "$app" "$set"
    return 0
  fi

  builder="$(apptest_builder_image "$app" "$set")"
  docker image inspect "$builder" >/dev/null 2>&1 || docker pull -q "$builder" >/dev/null
  builder_ref="$(docker image inspect --format '{{index .RepoDigests 0}}' "$builder" 2>/dev/null || echo "$builder")"

  name="apptest-build-${app}-${set//./_}-$$"
  net="$name"
  log="$LOG_DIR/$app-$set.log"
  echo "=== $tag: building on $builder (log: $log)"

  # shellcheck disable=SC2064
  trap "docker rm -f '$name-php' '$name-db' '$name-redis' '$name-memcached' >/dev/null 2>&1 || true; docker network rm '$net' >/dev/null 2>&1 || true" RETURN

  docker network create "$net" >/dev/null
  docker run -d --name "$name-db" --network "$net" --network-alias db \
    -e MARIADB_ROOT_PASSWORD="$APPTEST_DB_PASSWORD" \
    "$APPTEST_DB_IMAGE" "${APPTEST_DB_ARGS[@]}" >/dev/null
  docker run -d --name "$name-redis" --network "$net" --network-alias redis "$(apptest_service_image redis)" >/dev/null
  docker run -d --name "$name-memcached" --network "$net" --network-alias memcached "$(apptest_service_image memcached)" >/dev/null

  # The entrypoint's own init server runs with --skip-networking, so a TCP
  # answer means the real server is up, not the bootstrap one.
  local i
  for i in $(seq 1 120); do
    docker exec "$name-db" mariadb -h127.0.0.1 -uroot -p"$APPTEST_DB_PASSWORD" -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
  done
  [ "$i" -lt 120 ] || { docker logs "$name-db" | tail -30; echo "FAIL: $tag: mariadb never answered on TCP"; return 1; }

  docker run -d --name "$name-php" --network "$net" --user 0 \
    -e COMPOSER_ALLOW_SUPERUSER=1 -e COMPOSER_NO_INTERACTION=1 -e COMPOSER_CACHE_DIR=/composer-cache \
    -e APPTEST_APP="$app" -e APPTEST_SET="$set" -e APPTEST_HOST="$APPTEST_HOST" \
    -e APPTEST_DB_HOST=db -e APPTEST_DB_PASSWORD="$APPTEST_DB_PASSWORD" \
    -e APPTEST_PHP_MIN="$(apptest_set_field "$app" "$set" min)" \
    -e APPTEST_PHP_MAX="$(apptest_set_field "$app" "$set" max)" \
    -v "$APPTEST_ROOT:/apptest:ro" \
    -v apptest-dl-cache:/cache \
    -v apptest-composer-cache:/composer-cache \
    --entrypoint tail "$builder" -f /dev/null >/dev/null

  # Optional host-side step, for sources that are images rather than files
  # (PrestaShop ships its release trees as Docker images; see apps.lock).
  if [ -x "$APPTEST_ROOT/$app/fixture/host-prep.sh" ]; then
    if ! "$APPTEST_ROOT/$app/fixture/host-prep.sh" "$set" "$name-php" >"$log" 2>&1; then
      tail -40 "$log"; echo "FAIL: $tag: host-prep.sh failed"; return 1
    fi
  else
    : >"$log"
  fi

  if ! docker exec "$name-php" bash "/apptest/$app/fixture/build.sh" >>"$log" 2>&1; then
    tail -60 "$log"; echo "FAIL: $tag: fixture/build.sh failed"; return 1
  fi
  manifest="$(docker exec "$name-php" cat /srv/app/.apptest/manifest.json 2>/dev/null)" \
    || { echo "FAIL: $tag: build.sh left no /srv/app/.apptest/manifest.json"; return 1; }
  app_version="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["app_version"])' "$manifest")" \
    || { echo "FAIL: $tag: manifest.json has no app_version"; return 1; }

  docker stop "$name-php" >/dev/null
  docker stop -t 120 "$name-db" >/dev/null
  docker cp "$name-php:/srv/app" - | docker cp - "$name-db:/srv/"

  local cmd
  cmd="$(python3 -c 'import json,sys; print(json.dumps(["mariadbd"] + sys.argv[1:]))' "${APPTEST_DB_ARGS[@]}")"
  docker commit \
    --change "CMD $cmd" \
    --change "LABEL org.opencontainers.image.title=\"lotuswebagency/php application fixture: $app $app_version\"" \
    --change "LABEL com.lotuswebagency.apptest-hash=$hash" \
    --change "LABEL com.lotuswebagency.apptest-app=$app" \
    --change "LABEL com.lotuswebagency.apptest-set=$set" \
    --change "LABEL com.lotuswebagency.apptest-app-version=$app_version" \
    --change "LABEL com.lotuswebagency.apptest-builder=$builder_ref" \
    "$name-db" "$tag" >/dev/null
  echo "ok: $tag ($app $app_version, $(docker image inspect --format '{{.Size}}' "$tag" | awk '{printf "%.0f MB", $1/1048576}'))"
  [ "$PUSH" -eq 0 ] || apptest_fixture_push "$app" "$set"
}

failed=0
for job in "${JOBS[@]}"; do
  read -r app set <<<"$job"
  build_one "$app" "$set" || failed=$((failed + 1))
done
[ "$failed" -eq 0 ] || apptest_die "$failed fixture(s) failed to build"
