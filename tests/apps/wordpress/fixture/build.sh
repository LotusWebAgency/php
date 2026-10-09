#!/usr/bin/env bash
# WordPress + WooCommerce + the plugin set fixture. Runs as root inside the stock builder
# container of the set's php-min (see build-fixture.sh). Parameterized by
# APPTEST_SET: sources come from apps.lock rows for that set, everything else
# is the same for every set.
set -euo pipefail

APP=/srv/app
FIX=/apptest/wordpress/fixture
SET="$APPTEST_SET"
WP_URL="http://$APPTEST_HOST"
DL=/tmp/dl
mkdir -p "$APP/.apptest" "$DL"

wp_version="$(bash /apptest/fetch.sh --pin wordpress "$SET")"
woo_version="$(bash /apptest/fetch.sh --pin woocommerce "$SET")"
redis_cache_version="$(bash /apptest/fetch.sh --pin redis-cache "$SET")"
wpcli_version="$(bash /apptest/fetch.sh --pin wp-cli "$SET")"
# The rest of the plugin set, each pinned per set in apps.lock. The names are written out
# here, not built up, because apptest_lock_rows hashes only the rows whose name the recipe
# mentions. A set without a pin for one leaves it out (noted, and the manifest lists what
# is installed); a lock that is ambiguous for one stops the build.
PLUGINS=(akismet contact-form-7 wordpress-seo classic-editor wordfence wpforms-lite all-in-one-wp-migration)
declare -A plugin_version
INSTALLED=()
for p in "${PLUGINS[@]}"; do
  rc=0
  v="$(bash /apptest/fetch.sh --pin "$p" "$SET" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) plugin_version[$p]="$v"; INSTALLED+=("$p") ;;
    1) echo "note: apps.lock has no $p pin for set $SET -- left out" ;;
    *) echo "FAIL: apps.lock is ambiguous for $p/$SET"; exit 1 ;;
  esac
done
export APPTEST_WPCLI_VERSION="$wpcli_version" APPTEST_REDIS_CACHE_VERSION="$redis_cache_version"

# version_ge A B -> A >= B (dotted numeric).
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

bash /apptest/fetch.sh wordpress "$SET" "$DL/wordpress.tgz"
tar -xzf "$DL/wordpress.tgz" --strip-components=1 -C "$APP"
bash /apptest/fetch.sh woocommerce "$SET" "$DL/woocommerce.zip"
unzip -q "$DL/woocommerce.zip" -d "$APP/wp-content/plugins"
bash /apptest/fetch.sh redis-cache "$SET" "$DL/redis-cache.zip"
unzip -q "$DL/redis-cache.zip" -d "$APP/wp-content/plugins"
for p in "${INSTALLED[@]}"; do
  bash /apptest/fetch.sh "$p" "$SET" "$DL/$p.zip"
  # The core tarball bundles an Akismet of its own; the pinned release replaces it, not merges into it.
  rm -rf "${APP:?}/wp-content/plugins/$p"
  unzip -q "$DL/$p.zip" -d "$APP/wp-content/plugins"
done
# The phar has to run on the set's whole PHP range, so it lives in the tree
# and the suites use this copy rather than whatever the image ships.
bash /apptest/fetch.sh wp-cli "$SET" "$APP/.apptest/wp-cli.phar"

# The database is created by hand (mysqli, so no dependence on which client
# binary this image has); WordPress creates its own tables.
php -r '
$m = new mysqli("db", "root", getenv("APPTEST_DB_PASSWORD"));
$m->query("CREATE DATABASE wordpress CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci") or die($m->error . "\n");
'

# Fixed salts: this is a test fixture, and stable salts keep the auth cookies
# and nonces one run mints valid for the whole stack.
cat > "$APP/wp-config.php" <<'PHP'
<?php
define('DB_NAME', 'wordpress');
define('DB_USER', 'root');
define('DB_PASSWORD', 'apptest');
define('DB_HOST', 'db');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');

define('AUTH_KEY',         'apptest-auth-key');
define('SECURE_AUTH_KEY',  'apptest-secure-auth-key');
define('LOGGED_IN_KEY',    'apptest-logged-in-key');
define('NONCE_KEY',        'apptest-nonce-key');
define('AUTH_SALT',        'apptest-auth-salt');
define('SECURE_AUTH_SALT', 'apptest-secure-auth-salt');
define('LOGGED_IN_SALT',   'apptest-logged-in-salt');
define('NONCE_SALT',       'apptest-nonce-salt');

$table_prefix = 'wp_';

define('WP_DEBUG', false);
define('WP_ENVIRONMENT_TYPE', 'production');
define('WP_MEMORY_LIMIT', '256M');
// The suites run cron explicitly (wp cron event run), never from a request.
define('DISABLE_WP_CRON', true);
define('DISALLOW_FILE_MODS', true);
define('AUTOMATIC_UPDATER_DISABLED', true);
define('WP_AUTO_UPDATE_CORE', false);
// The stack has no outbound network: fail update checks and remote fetches at once.
define('WP_HTTP_BLOCK_EXTERNAL', true);

// Redis Object Cache: phpredis against the stack's `redis` service, values
// serialized with igbinary. The drop-in is only switched on at the very end of
// the build, so the data is written without it and the suites meet a cold cache.
// (The plugin has no compression option; that is Object Cache Pro.)
define('WP_REDIS_CLIENT', 'phpredis');
define('WP_REDIS_HOST', 'redis');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_DATABASE', 0);
define('WP_REDIS_PREFIX', 'apptest');
define('WP_REDIS_TIMEOUT', 2);
define('WP_REDIS_READ_TIMEOUT', 2);
define('WP_REDIS_IGBINARY', true);

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}
require_once ABSPATH . 'wp-settings.php';
PHP

wp() { php -d memory_limit=-1 "$APP/.apptest/wp-cli.phar" --path="$APP" --allow-root "$@"; }

wp core install --url="$WP_URL" --title="Apptest Journal" --admin_user=admin \
  --admin_password='Apptest!admin' --admin_email=admin@apptest.test --skip-email
[ "$(wp core version)" = "$wp_version" ] || { echo "FAIL: installed $(wp core version), apps.lock pins $wp_version"; exit 1; }
# The newest default theme the release bundles.
case "$SET" in
  4.9) THEME=twentyseventeen ;;
  5.9) THEME=twentytwentytwo ;;
  *) THEME=twentytwentyfive ;;
esac
wp theme is-installed "$THEME"
wp theme activate "$THEME"

mkdir -p "$APP/wp-content/mu-plugins" "$APP/wp-content/uploads"
cp "$FIX/mu-plugins/apptest.php" "$APP/wp-content/mu-plugins/"

wp eval-file "$FIX/seed-core.php"
wp plugin activate woocommerce
wp eval-file "$FIX/seed-woo.php" stage1
wp eval-file "$FIX/seed-woo.php" stage2
[ "$(wp plugin get woocommerce --field=version)" = "$woo_version" ] || { echo "FAIL: woocommerce version differs from apps.lock ($woo_version)"; exit 1; }
# HPOS became the default for new shops in 8.2; before that orders are posts.
if version_ge "$woo_version" 8.2; then
  [ "$(wp option get woocommerce_custom_orders_table_enabled)" = yes ] || { echo "FAIL: HPOS is not enabled"; exit 1; }
fi
# The rest of the plugins, activated after the shop is seeded (so its data is written
# without them in the way) and before the golden values (so those are what the REST API
# says with them active). seed-plugins.php sets them up quietly.
if [ "${#INSTALLED[@]}" -gt 0 ]; then
  wp plugin activate "${INSTALLED[@]}"
  for p in "${INSTALLED[@]}"; do
    [ "$(wp plugin get "$p" --field=version)" = "${plugin_version[$p]}" ] || { echo "FAIL: $p version differs from apps.lock (${plugin_version[$p]})"; exit 1; }
  done
  wp eval-file "$FIX/seed-plugins.php" "${INSTALLED[@]}"
fi
wp rewrite flush
wp eval-file "$FIX/golden.php" write

# The persistent object cache goes on last: the golden values above are the
# database's own truth, and the suites verify them again with the cache in front.
wp plugin activate redis-cache
wp redis enable
wp redis status | tee "$DL/redis-status.txt"
grep -q 'Connected' "$DL/redis-status.txt" || { echo "FAIL: redis-cache is not connected to redis"; exit 1; }
[ "$(wp eval 'echo wp_using_ext_object_cache() ? 1 : 0;')" = 1 ] || { echo "FAIL: the object-cache.php drop-in is not in use"; exit 1; }

# Everything the build mailed (welcome mails, order mails) is noise for the suites.
: > "$APP/wp-content/uploads/apptest-mail.log"
rm -rf "$DL" /tmp/apptest-img
echo "wordpress $wp_version + woocommerce $woo_version + ${INSTALLED[*]} + redis-cache $redis_cache_version fixture done"
