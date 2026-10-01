#!/usr/bin/env bash
# Builds the PrestaShop fixture inside the stock builder container (root, with
# the db/redis/memcached aliases up). host-prep.sh has already put the release
# tree at /srv/src/prestashop.
#
# The set only decides which pinned tree and which installer flags apply; the
# populate step below goes through ObjectModel and so is the same for all of
# them. 9.2 (php 8.1+), 8.2 (php 7.2-8.0), 1.7 (php 7.1) and 1.6 (php 7.0).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SET="${APPTEST_SET:?}"
DOMAIN="${APPTEST_HOST:?}"
APP=/srv/app
ADMIN_DIR=admin-apptest
ADMIN_EMAIL=admin@apptest.test
ADMIN_PASSWORD='ApptestAdmin-2026'

case "$SET" in
  1.6|1.7|8.2|9.2) ;;
  *) echo "FATAL: prestashop set $SET has no recipe yet" >&2; exit 1 ;;
esac

PHP=(php -d memory_limit=-1 -d max_execution_time=0 -d disable_functions=)

step() { echo; echo "=== $(date +%T) $*"; }

step "tree"
[ ! -e "$APP" ] || { echo "FATAL: $APP already exists" >&2; exit 1; }
mv /srv/src/prestashop "$APP"
mkdir -p "$APP/.apptest"
# Composer, for the builder suite's lock replay; the release ships composer.lock only.
# (1.6 has no composer at all: no lock, no vendor/, the classes are its own autoloader's.)
[ "$SET" = 1.6 ] || bash /apptest/fetch.sh prestashop-composer "$SET" "$APP/composer.json"

step "en-US pack"
# Install.php::installLanguages() downloads the en-US pack unconditionally;
# with the pinned bytes in place translationPackIsInCache() is satisfied and
# the installer needs no network. en.gzip is only ever existence-checked.
# 1.6 predates the download: English comes with the release (install/langs/en).
if [ "$SET" = 1.6 ]; then
  echo "1.6 installs English from the tree, nothing to fetch"
else
  mkdir -p "$APP/translations"
  bash /apptest/fetch.sh prestashop-lang "$SET" "$APP/translations/sf-en-US.zip"
  : > "$APP/translations/en.gzip"
fi

# 1.7's installer also downloads ten marketplace modules (ps_mbo, ps_checkout, ps_facebook, psgdpr...)
# from addons.prestashop.com by default: unpinned bytes and services that phone home. The
# release's own tree is the fixture, so that step is left out. 1.6's default step list has the same
# addons_modules download in it, and demo products are a step there (fixtures), not a flag: the installer ignores
# the --ssl/--rewrite/--fixtures below, and configure.php switches rewriting on afterwards.
STEPS=
case "$SET" in 1.6|1.7) STEPS=--step=database,modules,theme,fixtures ;; esac

step "install"
rm -rf "$APP/var/cache/"*
cd "$APP"
"${PHP[@]}" install/index_cli.php \
  --domain="$DOMAIN" --db_server="$APPTEST_DB_HOST" --db_name=prestashop \
  --db_user=root --db_password="$APPTEST_DB_PASSWORD" --db_create=1 --prefix=ps_ \
  --name="Apptest Shop" --firstname=Ada --lastname=Admin \
  --email="$ADMIN_EMAIL" --password="$ADMIN_PASSWORD" \
  --language=en --country=us --all_languages=0 --timezone=UTC \
  --newsletter=0 --send_email=0 --ssl=0 --rewrite=1 --fixtures=1 $STEPS

step "admin dir"
# (BusyBox find on the 7.0 Alpine image has no -quit)
found="$(find "$APP" -maxdepth 1 -type d -name 'admin[0-9a-z]*' ! -name admin-api ! -name "$ADMIN_DIR" -print | sed -n 1p)"
# 8.2's CLI installer leaves the shipped folder as it is; 9.x renames it.
[ -n "$found" ] || { [ ! -d "$APP/admin" ] || found="$APP/admin"; }
[ -n "$found" ] || { echo "FATAL: no admin directory to rename" >&2; ls "$APP"; exit 1; }
mv "$found" "$APP/$ADMIN_DIR"
echo "admin: $(basename "$found") -> $ADMIN_DIR"
rm -rf "$APP/install-dev" "$APP/var/cache/"*

step "configure"
"${PHP[@]}" "$HERE/configure.php"
# Modules that call out to PrestaShop's services (marketplace, billing,
# telemetry, social graph) on admin page loads or hooks. Disabled rather than
# uninstalled: uninstalling ps_facebook itself calls graph.facebook.com.
for module in ps_mbo ps_distributionapiclient ps_eventbus ps_accounts ps_facebook \
              psxmarketingwithgoogle ps_checkout psshipping; do
  # the module set differs per release (8.2 ships only ps_distributionapiclient of these, 1.7 none)
  [ -d "modules/$module" ] || continue
  "${PHP[@]}" bin/console prestashop:module disable "$module" --env=prod --no-debug --no-interaction
done

step "populate"
"${PHP[@]}" "$HERE/populate.php"

step "manifest"
rm -rf "$APP/install" "$APP/var/cache/"*
# The webservice goldens are taken from real responses, so the shop has to
# answer somewhere: php -S on loopback for the length of this step only.
php -S 127.0.0.1:8081 -t "$APP" >/tmp/phpS.log 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:8081/ && break; sleep 1; done
home="$(curl -s -H "Host: $DOMAIN" -w '\n%{http_code}' http://127.0.0.1:8081/)"
[ "${home##*$'\n'}" = 200 ] && grep -q 'Apptest Shop' <<<"$home" \
  || { echo "FATAL: the finished shop does not render its home page" >&2; head -c 1500 <<<"$home" >&2; tail -20 /tmp/phpS.log >&2; exit 1; }
echo "home page renders"
export APPTEST_ADMIN_DIR="$ADMIN_DIR" APPTEST_ADMIN_EMAIL="$ADMIN_EMAIL" APPTEST_ADMIN_PASSWORD="$ADMIN_PASSWORD"
"${PHP[@]}" "$HERE/manifest.php"
kill "$SERVER"; wait "$SERVER" 2>/dev/null || true
trap - EXIT

step "finish"
# Compiled Smarty templates, the Symfony container and Twig caches are left
# out on purpose: the image under test has to build them itself. (1.6 keeps
# them under cache/, with the class index its autoloader writes.)
rm -rf "$APP/var/cache/"* "$APP/var/logs/"* "$APP/img/tmp/"*.jpg
if [ "$SET" = 1.6 ]; then
  rm -rf "$APP/cache/smarty/compile/"* "$APP/cache/smarty/cache/"* "$APP/cache/class_index.php" "$APP/cache/cachefs/"* "$APP/log/"*.log
fi
find "$APP" -name '*.log' -path '*/var/*' -delete
