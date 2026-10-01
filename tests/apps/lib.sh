# shellcheck shell=bash
# Variables here are read by the scripts that source this file.
# shellcheck disable=SC2034
# Shared helpers for the application test harness. Sourced by
# build-fixture.sh, run.sh and run-matrix.sh; never executed directly.

APPTEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPTEST_REPO="$(cd "$APPTEST_ROOT/../.." && pwd)"
APPTEST_APPS=(laravel wordpress prestashop)

# Where fixtures are tagged and which stock image line they are built on.
# Both are overridable so CI can pull prebuilt fixtures from a registry and a
# fork can baseline against a different known-good image.
APPTEST_FIXTURE_REPO="${APPTEST_FIXTURE_REPO:-lotuswebagency/php-apptest}"
APPTEST_BUILDER_REPO="${APPTEST_BUILDER_REPO:-dementev/php-fpm-with-ext}"

# The fixture image is this MariaDB plus the populated datadir and the app
# tree. Pinned by digest: a fixture has to be rebuilt deliberately, never
# because a tag moved under it.
APPTEST_DB_IMAGE="mariadb:11.8@sha256:79d59758afc91b89b120b0a8904d637f5a3b3e1c4900f29b740d6d46c72fef68"
APPTEST_DB_DATADIR=/var/lib/mysql-fixture
APPTEST_DB_PASSWORD=apptest
# The same server flags at build time and at test time, so the fixture's
# datadir is never opened by a server configured differently from the one
# that wrote it.
APPTEST_DB_ARGS=(
  "--datadir=$APPTEST_DB_DATADIR"
  --character-set-server=utf8mb4
  --collation-server=utf8mb4_unicode_ci
  --innodb-buffer-pool-size=256M
  --innodb-flush-log-at-trx-commit=2
  --skip-name-resolve
  --max-connections=500
  --max-allowed-packet=256M
)

# Side services, pinned the same way. compose.yml reads them from the
# environment run.sh exports, so this is the only place they are named.
export APPTEST_WEB_IMAGE="nginx:1.30-alpine@sha256:0985e772fb9f729e6fa0980da05fca5d9c468e870eed43071545afa9d2e27d94"
export APPTEST_REDIS_IMAGE="redis:8-alpine@sha256:3811787313eba226a2ef38658c6ccb91cd5e110edc89c37767de373120a0e5a0"
export APPTEST_MEMCACHED_IMAGE="memcached:1.6-alpine@sha256:9e4de012dc607573052061c0bcb38abc775e1dd59b24e7ac38d1892842094aaf"
apptest_service_image() {
  case "$1" in
    web) echo "$APPTEST_WEB_IMAGE" ;;
    redis) echo "$APPTEST_REDIS_IMAGE" ;;
    memcached) echo "$APPTEST_MEMCACHED_IMAGE" ;;
  esac
}

# The hostname every app is installed under. The HTTP suites connect to the
# published port on 127.0.0.1 and send this as Host, so WordPress's siteurl
# and PrestaShop's shop domain never need rewriting per run.
APPTEST_HOST=apptest.test

apptest_die() { echo "FAIL: $*" >&2; exit 1; }

# apptest_ver_le A B -> true when version A <= version B (dotted numeric).
apptest_ver_le() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# apptest_sets_rows [app] -> "app set php-min php-max" lines from ./sets.
apptest_sets_rows() {
  local want="${1:-}" app set lo hi
  while read -r app set lo hi; do
    case "$app" in ''|\#*) continue ;; esac
    [ -z "$want" ] || [ "$app" = "$want" ] || continue
    printf '%s %s %s %s\n' "$app" "$set" "$lo" "$hi"
  done < "$APPTEST_ROOT/sets"
}

# apptest_resolve_set <app> <php X.Y> -> the set that php version runs.
apptest_resolve_set() {
  local app="$1" php="$2" hits=() _a set lo hi
  while read -r _a set lo hi; do
    if apptest_ver_le "$lo" "$php" && apptest_ver_le "$php" "$hi"; then hits+=("$set"); fi
  done < <(apptest_sets_rows "$app")
  [ "${#hits[@]}" -eq 1 ] || { echo "FAIL: php $php matches ${#hits[@]} $app sets (${hits[*]:-none}) in tests/apps/sets" >&2; return 1; }
  echo "${hits[0]}"
}

# apptest_set_field <app> <set> <min|max>
apptest_set_field() {
  local _a set lo hi
  while read -r _a set lo hi; do
    [ "$set" = "$2" ] || continue
    case "$3" in min) echo "$lo" ;; max) echo "$hi" ;; esac
    return 0
  done < <(apptest_sets_rows "$1")
  echo "FAIL: no $1 set '$2' in tests/apps/sets" >&2
  return 1
}

# Every matrix.json version must resolve to exactly one set of every app, or
# a version silently goes untested.
apptest_sets_check() {
  local v app bad=0
  while read -r v; do
    for app in "${APPTEST_APPS[@]}"; do
      apptest_resolve_set "$app" "$v" >/dev/null || bad=1
    done
  done < <(apptest_matrix_versions)
  [ "$bad" -eq 0 ] || apptest_die "tests/apps/sets does not map every matrix.json version to exactly one set per app"
}

apptest_matrix_versions() {
  python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
for v in sorted(m["versions"], key=lambda s: tuple(int(x) for x in s.split("."))):
    print(v)
' "$APPTEST_REPO/matrix.json"
}

apptest_fixture_tag() { echo "${APPTEST_FIXTURE_REPO}:$1-$2"; }

# apptest_builder_image <app> <set> -> the stock image the set is built on.
# The fpm tag, not cli-builder: the predecessor publishes fpm for every
# version and cli-builder only for a few, and composer comes from apps.lock
# rather than from the image anyway.
apptest_builder_image() {
  local lo
  lo="$(apptest_set_field "$1" "$2" min)" || return 1
  echo "${APPTEST_BUILDER_REPO}:${lo}-fpm"
}

# apptest_recipe_hash <app> <set> -> content hash of everything that decides
# what the fixture contains. Suites and nginx configs are deliberately left
# out: changing a test must not force a rebuild of the data it tests.
apptest_recipe_hash() {
  local app="$1" set="$2"
  {
    printf 'set %s\n' "$(apptest_sets_rows "$app" | awk -v s="$set" '$2 == s')"
    printf 'db %s\n' "$APPTEST_DB_IMAGE" "${APPTEST_DB_ARGS[@]}"
    printf 'builder %s\n' "$(apptest_builder_image "$app" "$set")"
    apptest_lock_rows "$app" "$set"
    (cd "$APPTEST_ROOT" && find build-fixture.sh fetch.sh install-composer.sh "$app/fixture" -type f -print0 \
      | LC_ALL=C sort -z | xargs -0 sha256sum)
  } | sha256sum | cut -d' ' -f1
}

# apptest_lock_rows <app> <set> -> the apps.lock rows this fixture can fetch:
# the shared "-" rows, plus this set's rows whose name the app's recipe
# mentions. Hashing the whole file would make every fixture of every app
# stale whenever any one app pins something new.
apptest_lock_rows() {
  local app="$1" set="$2" name rset rest
  while read -r name rset rest; do
    case "$name" in ''|\#*) continue ;; esac
    if [ "$rset" = "-" ] || { [ "$rset" = "$set" ] && grep -rqw -- "$name" "$APPTEST_ROOT/$app/fixture"; }; then
      printf 'lock %s %s %s\n' "$name" "$rset" "$rest"
    fi
  done < "$APPTEST_ROOT/apps.lock"
}

apptest_label() { docker image inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true; }

# apptest_is_stock <image> -> true for anything this repo did not build. Our
# images always carry the CF-47 inputs-hash label (docker-bake.hcl).
apptest_is_stock() {
  local h
  h="$(apptest_label "$1" com.lotuswebagency.inputs-hash)"
  [ -z "$h" ] || [ "$h" = "<no value>" ]
}

# apptest_image_php <image> -> "X.Y" as the image's own php reports it.
apptest_image_php() {
  docker run --rm --entrypoint php "$1" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;'
}

# apptest_image_ids <image> -> "uid:gid" of www-data inside the image. The
# predecessor's Alpine images use 82, the Debian ones and ours 33.
apptest_image_ids() {
  docker run --rm --entrypoint sh "$1" -c 'echo "$(id -u www-data):$(id -g www-data)"'
}
