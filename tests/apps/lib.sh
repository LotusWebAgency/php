# shellcheck shell=bash
# Variables here are read by the scripts that source this file.
# shellcheck disable=SC2034
# Shared helpers for the application test harness. Sourced by
# build-fixture.sh, run.sh and run-matrix.sh; never executed directly.

APPTEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPTEST_REPO="$(cd "$APPTEST_ROOT/../.." && pwd)"
_apptest_apps="$(python3 "$APPTEST_ROOT/appsets.py" apps)" || { echo "FAIL: tests/apps/sets is invalid (python3 tests/apps/appsets.py check)" >&2; exit 1; }
mapfile -t APPTEST_APPS <<<"$_apptest_apps"
unset _apptest_apps

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

# Everything about which app release runs where is tests/apps/sets, read
# through appsets.py; nothing here re-derives its rules.
apptest_appsets() { python3 "$APPTEST_ROOT/appsets.py" "$@"; }

# apptest_sets_rows [app] -> "app set php-min php-max" lines, one per fixture set.
apptest_sets_rows() { apptest_appsets rows ${1:+--app "$1"}; }

# apptest_set_field <app> <set> <min|max|db>
apptest_set_field() { apptest_appsets field "$@"; }

# apptest_cells [appsets.py cells options] -> "app set php flavor variant configs"
# lines: the cells of one image (--php --flavor --variant [--stock]), or of a
# whole selection. A PHP version may run several sets of one app, and may run
# none: no cell is not a failure.
apptest_cells() { apptest_appsets cells "$@"; }

# Syntax, matrix.json versions, fixture recipes, apps.lock rows, duplicates.
apptest_sets_check() { apptest_appsets check >/dev/null || apptest_die "tests/apps/sets is invalid"; }

apptest_matrix_versions() {
  python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
for v in sorted(m["versions"], key=lambda s: tuple(int(x) for x in s.split("."))):
    print(v)
' "$APPTEST_REPO/matrix.json"
}

# A fixture is the MariaDB of one architecture plus its datadir, so a registry
# can hold only one image per architecture: when APPTEST_FIXTURE_REPO names a
# registry, the tag is <app>-<set>-<arch> and the fixture is pulled before it
# is built (and pushed with build-fixture.sh --push). A bare local name, the
# default, keeps <app>-<set>: a local daemon only ever holds its own arch.
# "Names a registry" is Docker's own rule for a reference: the first path
# component holds a dot or a colon, or is localhost.
apptest_repo_is_registry() {
  local first="${APPTEST_FIXTURE_REPO%%/*}"
  [ "$first" != "$APPTEST_FIXTURE_REPO" ] || return 1
  case "$first" in *.*|*:*|localhost) return 0 ;; esac
  return 1
}

# The daemon's architecture (amd64, arm64), not the shell's: they differ on a remote daemon.
apptest_arch() { docker version --format '{{.Server.Arch}}'; }

apptest_fixture_tag() {
  if apptest_repo_is_registry; then
    echo "${APPTEST_FIXTURE_REPO}:$1-$2-$(apptest_arch)"
  else
    echo "${APPTEST_FIXTURE_REPO}:$1-$2"
  fi
}

# apptest_builder_image <app> <set> -> the stock image the set is built on.
# The fpm tag, not cli-builder: the stock repository publishes fpm for every
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
    # Only the PHP the fixture is built on (the row's lowest) decides its
    # contents; the row's other PHP versions are where it is tested, and
    # adding one must not stale the fixture.
    printf 'set %s %s %s\n' "$app" "$set" "$(apptest_set_field "$app" "$set" min)"
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
# images always carry the inputs-hash label (docker-bake.hcl).
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
# stock Alpine images use 82, the Debian ones and ours 33.
apptest_image_ids() {
  docker run --rm --entrypoint sh "$1" -c 'echo "$(id -u www-data):$(id -g www-data)"'
}

# apptest_fixture_current <tag> <recipe-hash> -> 0 when the local image carries
# that apptest-hash label AND is this daemon's architecture (a fixture of the
# other architecture with the right label is not usable here).
apptest_fixture_current() {
  local have arch
  have="$(apptest_label "$1" com.lotuswebagency.apptest-hash)"
  [ -n "$have" ] && [ "$have" = "$2" ] || return 1
  arch="$(docker image inspect --format '{{.Architecture}}' "$1" 2>/dev/null || true)"
  [ "$arch" = "$(apptest_arch)" ]
}

# apptest_fixture_try_pull <app> <set> -> 0 when the local fixture tag is
# current afterwards, having pulled it from the registry if it was not. A
# pulled image counts only when its apptest-hash label is this tree's recipe
# hash and it is this daemon's architecture; anything else is reported, removed
# again (so it cannot be mistaken for a current fixture later), and the caller
# builds. Not a registry repository: returns 1 at once.
apptest_fixture_try_pull() {
  local app="$1" set="$2" tag want have arch out
  apptest_repo_is_registry || return 1
  tag="$(apptest_fixture_tag "$app" "$set")"
  want="$(apptest_recipe_hash "$app" "$set")"
  ! apptest_fixture_current "$tag" "$want" || return 0
  if ! out="$(docker pull -q "$tag" 2>&1)"; then
    echo "note: $tag was not pulled ($(printf '%s' "$out" | tail -1 | cut -c1-120))" >&2
    return 1
  fi
  have="$(apptest_label "$tag" com.lotuswebagency.apptest-hash)"
  arch="$(docker image inspect --format '{{.Architecture}}' "$tag")"
  if [ "$arch" != "$(apptest_arch)" ]; then
    echo "note: $tag is $arch, this daemon is $(apptest_arch) -- not used" >&2
    docker rmi "$tag" >/dev/null 2>&1 || true
    return 1
  fi
  if [ "$have" != "$want" ]; then
    echo "note: $tag in the registry is stale (apptest-hash ${have:-none}, this tree's recipe $want) -- not used" >&2
    docker rmi "$tag" >/dev/null 2>&1 || true
    return 1
  fi
  echo "ok: pulled $tag (apptest-hash $want)"
}

# apptest_fixture_push <app> <set>
apptest_fixture_push() {
  local tag
  apptest_repo_is_registry || apptest_die "refusing to push: APPTEST_FIXTURE_REPO ($APPTEST_FIXTURE_REPO) is a local name, not a registry repository"
  tag="$(apptest_fixture_tag "$1" "$2")"
  docker push -q "$tag" >/dev/null || apptest_die "docker push $tag failed"
  echo "ok: pushed $tag"
}
