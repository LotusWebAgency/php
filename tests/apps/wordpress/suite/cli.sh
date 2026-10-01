#!/usr/bin/env bash
# WordPress + WooCommerce from the command line, inside the image under test,
# through the WP-CLI phar the fixture installed in the tree (it has to run on
# every PHP of the set, so the suite never uses whatever the image ships).
# Additive: it runs on a stack the web suite may have used before it.
set -uo pipefail
. /apptest/cli-lib.sh

APP=/srv/app
MANIFEST=$APP/.apptest/manifest.json
RUN="$(date +%s)$$"
cd "$APP" || exit 1

WP_FLAGS=(--path="$APP")
[ "$(id -u)" -ne 0 ] || WP_FLAGS+=(--allow-root)
wp() { php -d memory_limit=-1 "$APP/.apptest/wp-cli.phar" "${WP_FLAGS[@]}" "$@"; }
mf() {
  php -r '$v = json_decode(file_get_contents($argv[1]), true); foreach (explode(".", $argv[2]) as $k) { $v = $v[$k]; } echo is_scalar($v) ? $v : json_encode($v);' "$MANIFEST" "$1"
}

# check_eq <name> <expected> <cmd...> -- the command's whole output, trimmed, must equal it.
check_eq() {
  local name="$1" want="$2" got; shift 2
  got="$("$@" 2>"$APPTEST_OUT")"
  if [ "$got" = "$want" ]; then ok "$name"; else fail "$name -- expected '$want', got '${got:0:200}' from: $*"; sed 's/^/    | /' "$APPTEST_OUT" | tail -10; fi
}
# check_min <name> <minimum> <cmd...> -- the output is an integer >= minimum.
check_min() {
  local name="$1" want="$2" got; shift 2
  got="$("$@" 2>"$APPTEST_OUT")"
  if [ "$got" -ge "$want" ] 2>/dev/null; then ok "$name"; else fail "$name -- expected >= $want, got '${got:0:200}' from: $*"; sed 's/^/    | /' "$APPTEST_OUT" | tail -10; fi
}
# report_lines -- reads "ok: ..."/"FAIL: ..." lines from stdin, as the PHP helper scripts print them.
report_lines() {
  local line seen=0
  while IFS= read -r line; do
    case "$line" in
      ok:*) seen=$((seen + 1)); ok "${line#ok: }" ;;
      FAIL:*) seen=$((seen + 1)); fail "${line#FAIL: }" ;;
      *) echo "    | $line" ;;
    esac
  done
  [ "$seen" -gt 0 ] || fail "helper script printed no results"
}

APP_VERSION="$(mf app_version)"
WOO_VERSION="$(mf woocommerce)"
REDIS_CACHE_VERSION="$(mf redis_cache)"
HPOS="$(mf woo.hpos)"
HAVE_PROC_OPEN=1
php -r 'exit(function_exists("proc_open") ? 0 : 1);' || HAVE_PROC_OPEN=0
MYSQL_BIN="$(command -v mariadb || command -v mysql || true)"

echo "# php $(php -r 'echo PHP_VERSION;'), wp-cli $(mf wp_cli), wordpress $APP_VERSION, woocommerce $WOO_VERSION, redis-cache $REDIS_CACHE_VERSION, uid $(id -u)"

# -- WP-CLI and core -----------------------------------------------------------
check_eq "wp-cli runs on the PHP under test" "$(php -r 'echo PHP_VERSION;')" wp eval 'echo PHP_VERSION;'
check_out "wp-cli phar is the pinned release" "$(mf wp_cli)" wp --version
check_eq "core version" "$APP_VERSION" wp core version
check "core is installed" wp core is-installed
check_out "config: database host" "db" wp config get DB_HOST
check_out "config: cron is off for requests" "1" wp config get DISABLE_WP_CRON
check_eq "site url" "http://apptest.test" wp option get siteurl
check_eq "blog name" "Apptest Journal" wp option get blogname
check_eq "core: this PHP meets WordPress's minimum" "1" wp eval 'echo version_compare(PHP_VERSION, $GLOBALS["required_php_version"], ">=") ? 1 : 0;'

# -- database ------------------------------------------------------------------
if [ "$HAVE_PROC_OPEN" -eq 1 ] && [ -n "$MYSQL_BIN" ]; then
  check_eq "db query: published posts" "$(mf counts.posts_published)" wp db query "SELECT COUNT(*) FROM wp_posts WHERE post_type='post' AND post_status='publish'" --skip-column-names
  check_out "db check: every table is OK" "Success: Database checked" wp db check
  if [ "$HPOS" = yes ]; then
    check_out "db tables lists HPOS orders table" "wp_wc_orders" wp db tables --all-tables-with-prefix
  else
    check_out "db tables lists the order items table" "wp_woocommerce_order_items" wp db tables --all-tables-with-prefix
  fi
else
  skip "db query / db check" "needs proc_open and a mysql client (proc_open=$HAVE_PROC_OPEN, client=${MYSQL_BIN:-none})"
fi
check_out "wpdb reaches the server (mysqlnd)" "utf8mb4" wp eval 'global $wpdb; echo $wpdb->charset;'
check_eq "wpdb: 4-byte UTF-8 round trip" "🚀 тест 测试" wp eval 'global $wpdb; $wpdb->query("CREATE TEMPORARY TABLE apptest_tmp (v VARCHAR(50) CHARACTER SET utf8mb4)"); $wpdb->insert("apptest_tmp", ["v" => "🚀 тест 测试"]); echo $wpdb->get_var("SELECT v FROM apptest_tmp");'

# -- content counts, against the fixture's manifest --------------------------------------
check_eq "posts: published" "$(mf counts.posts_published)" wp post list --post_type=post --post_status=publish --format=count
check_min "posts: drafts" "$(mf counts.posts_draft)" wp post list --post_type=post --post_status=draft --format=count
check_eq "pages: published" "$(mf counts.pages)" wp post list --post_type=page --post_status=publish --format=count
check_eq "comments: approved on the busiest post" "$(mf posts.most_commented.comments)" wp comment list --post_id="$(mf posts.most_commented.id)" --status=approve --format=count
check_min "comments: pending" "$(mf counts.comments_pending)" wp comment list --status=hold --format=count
check_eq "terms: categories" "$(mf counts.categories)" wp term list category --format=count
check_eq "terms: tags" "$(mf counts.tags)" wp term list post_tag --format=count
check_min "media: attachments" "$(mf counts.attachments)" wp post list --post_type=attachment --format=count
check_min "users: accounts" "$(mf counts.users)" wp user list --format=count
check_eq "users: authors" "5" wp user list --role=author --format=count
check_out "users: admin by login" "admin" wp user get admin --field=user_login
check_out "users: roles include shop_manager and customer" "shop_manager" wp role list --field=role
check_eq "post by ID: UTF-8 title survives" "$(mf posts.russian.title)" wp post get "$(mf posts.russian.id)" --field=post_title
check_eq "post meta: serialized array survives" "тест" wp eval '$m = get_post_meta(array_values(get_posts(["meta_key" => "apptest_data", "numberposts" => 1, "fields" => "ids"]))[0], "apptest_data", true); echo $m["nested"]["z"];'
check_eq "post meta: JSON with quotes and backslashes survives" "line
\"quoted\" \\ back" wp eval '$id = get_posts(["meta_key" => "apptest_json", "numberposts" => 1, "fields" => "ids"])[0]; echo json_decode(get_post_meta($id, "apptest_json", true), true)["text"];'
check_eq "search: site query for a Cyrillic word" "$(mf search.cyrillic.rest_total)" wp post list --post_type=post --post_status=publish --s="лиса" --format=count
check_out "menus: the primary menu" "Primary Menu" wp menu list --fields=name --format=csv
check_eq "menus: its items" "$(mf menu.items)" wp menu item list "$(mf menu.id)" --format=count
check_eq "sticky posts" "5" wp eval 'echo count(get_option("sticky_posts"));'

# -- options, transients, cache ----------------------------------------------------------
check_eq "option: plain value" "plain value" wp option get apptest_plain
check_eq "option: serialized nested data (JSON view)" "deep" wp eval '$o = get_option("apptest_serialized"); echo $o["nested"]["x"]["y"]["z"];'
check_eq "option: a stdClass inside a serialized option" "d" wp eval '$o = get_option("apptest_serialized"); echo $o["object"]->b["c"];'
check_eq "option: UTF-8 in a serialized option" "Ünïcödé тест 测试 🚀" wp option pluck apptest_serialized string
check "option: add, update, pluck, delete" bash -c "
  set -e
  wp() { php -d memory_limit=-1 $APP/.apptest/wp-cli.phar ${WP_FLAGS[*]} \"\$@\"; }
  wp option add apptest_cli_$RUN '{\"a\":{\"b\":1}}' --format=json
  [ \"\$(wp option pluck apptest_cli_$RUN a b)\" = 1 ]
  wp option patch update apptest_cli_$RUN a b 2
  [ \"\$(wp option pluck apptest_cli_$RUN a b)\" = 2 ]
  wp option delete apptest_cli_$RUN"
check "transient: set, get, delete" bash -c "
  wp() { php -d memory_limit=-1 $APP/.apptest/wp-cli.phar ${WP_FLAGS[*]} \"\$@\"; }
  wp transient set apptest_cli_$RUN 'value ü' 3600 && [ \"\$(wp transient get apptest_cli_$RUN)\" = 'value ü' ] && wp transient delete apptest_cli_$RUN"
check_out "cache: the object cache works in a process" "hit" wp eval 'wp_cache_set("k", "hit", "apptest"); echo wp_cache_get("k", "apptest"); wp_cache_delete("k", "apptest");'
check_out "cache type" "Redis" wp cache type
check "cache flush" wp cache flush

# -- Redis object cache --------------------------------------------------------------------
# Every wp-cli call is its own process, so what one stores is only visible to
# the next through Redis.
check_out "redis: wp redis status is connected" "Status: Connected" wp redis status
check_out "redis: the client is phpredis" "Client: PhpRedis" wp redis status
check_out "redis: the drop-in is valid" "Drop-in: Valid" wp redis status
check_out "redis: igbinary is switched on" "WP_REDIS_IGBINARY: true" wp redis status
check_eq "redis: plugin version" "$REDIS_CACHE_VERSION" wp plugin get redis-cache --field=version
check_eq "redis: the drop-in is the object cache in use" "1" wp eval 'echo wp_using_ext_object_cache() ? 1 : 0;'
check "cache: set in one process" wp cache set apptest_cli_$RUN "value ü 🚀" apptest_cli
check_eq "cache: read back by the next process" "value ü 🚀" wp cache get apptest_cli_$RUN apptest_cli
check "cache: add succeeds once, then refuses the existing key (across processes)" bash -c "
  wp() { php -d memory_limit=-1 $APP/.apptest/wp-cli.phar ${WP_FLAGS[*]} \"\$@\"; }
  wp cache add apptest_cli_add_$RUN 1 apptest_cli >/dev/null && ! wp cache add apptest_cli_add_$RUN 2 apptest_cli >/dev/null 2>&1"
check_out "cache: an array is stored as igbinary" "igbinary" wp eval '
  global $wp_object_cache;
  wp_cache_set("apptest_cli_arr_'"$RUN"'", ["a" => 1, "b" => ["ü", true, null]], "apptest_cli");
  $raw = $wp_object_cache->redis_instance()->get($wp_object_cache->build_key("apptest_cli_arr_'"$RUN"'", "apptest_cli"));
  echo substr($raw, 0, 4) === "\x00\x00\x00\x02" ? "igbinary" : "other:" . bin2hex(substr($raw, 0, 8));'
check_eq "cache: that array reads back intact in the next process" 'ü' wp eval '$v = wp_cache_get("apptest_cli_arr_'"$RUN"'", "apptest_cli"); echo $v["b"][0];'
pid_plain="$(mf posts.plain.id)"
wp eval 'get_post('"$pid_plain"');'
check_eq "cache: a post cached by one process is a hit for the next" "hit" wp eval '
  global $wp_object_cache; $b = $wp_object_cache->info(); get_post('"$pid_plain"'); $a = $wp_object_cache->info();
  echo ($a->hits > $b->hits && $a->misses === $b->misses) ? "hit" : "miss " . ($a->hits - $b->hits) . "/" . ($a->misses - $b->misses);'
check_min "cache: Redis holds keys" 20 wp eval 'global $wp_object_cache; echo $wp_object_cache->redis_instance()->dbSize();'
check "cache flush empties Redis" bash -c "
  wp() { php -d memory_limit=-1 $APP/.apptest/wp-cli.phar ${WP_FLAGS[*]} \"\$@\"; }
  wp cache flush >/dev/null && ! wp cache get apptest_cli_$RUN apptest_cli >/dev/null 2>&1"
check "transient delete --expired" wp transient delete --expired

# -- rewrite, cron -----------------------------------------------------------------------
check_eq "rewrite structure" "/%postname%/" wp option get permalink_structure
check "rewrite flush" wp rewrite flush
check_min "rewrite rules registered" 100 wp rewrite list --format=count
check "cron: run what is due" wp cron event run --due-now
check_min "cron: events are scheduled" 1 wp cron event list --format=count
check_out "cron: schedules" "hourly" wp cron schedule list
check "cron: schedule and run an own event" bash -c "
  wp() { php -d memory_limit=-1 $APP/.apptest/wp-cli.phar ${WP_FLAGS[*]} \"\$@\"; }
  wp cron event schedule apptest_cli_$RUN now hourly && wp cron event run apptest_cli_$RUN && wp cron event delete apptest_cli_$RUN"

# -- search-replace: serialized-aware, dry run -----------------------------------------------
out="$(wp search-replace apptest.test example.invalid --dry-run --skip-columns=guid 2>&1)"
n="$(printf '%s\n' "$out" | sed -n 's/.*Success: \([0-9]*\) replacements to be made.*/\1/p')"
if [ -n "$n" ] && [ "$n" -gt 1000 ]; then ok "search-replace --dry-run finds $n occurrences"; else fail "search-replace --dry-run -- got '${out: -300}'"; fi
check_out "search-replace --dry-run reaches serialized options" "wp_options" wp search-replace apptest.test example.invalid --dry-run --skip-columns=guid --report

# -- passwords, nonces, crypto helpers ---------------------------------------------------------
wp eval-file /apptest/wordpress/suite/users.php 2>&1 | report_lines
check "user check-password: bcrypt account" wp user check-password admin 'Apptest!admin'
check "user check-password: phpass account" wp user check-password "$(mf legacy_hash_user)" "Apptest!$(mf legacy_hash_user)"
if wp user check-password admin wrong >/dev/null 2>&1; then fail "user check-password accepts a wrong password"; else ok "user check-password refuses a wrong password"; fi

# -- golden values, computed by the stock PHP that built the fixture ----------------------------
wp eval-file /apptest/wordpress/fixture/golden.php verify 2>&1 | report_lines

# -- the image pipeline ---------------------------------------------------------------------------
# Regenerate thumbnails of one attachment of each seeded type (GD and Imagick
# do the decoding and resizing).
ids="$(wp eval '
  $seen = [];
  foreach (get_posts(["post_type" => "attachment", "numberposts" => -1, "orderby" => "ID", "order" => "ASC"]) as $a) {
    if (!isset($seen[$a->post_mime_type]) && strpos($a->post_mime_type, "image/") === 0) { $seen[$a->post_mime_type] = $a->ID; }
  }
  echo implode(" ", $seen);')"
check_out "media regenerate (one image per seeded format: $ids)" "Success: Regenerated" wp media regenerate $ids --yes
for id in $ids; do
  check_out "attachment $id: metadata lists thumbnails after regeneration" "thumbnail" wp post meta get "$id" _wp_attachment_metadata --format=json
  check_eq "attachment $id: thumbnail file exists and is an image" "1" wp eval '$f = get_attached_file('"$id"'); $t = dirname($f) . "/" . wp_get_attachment_metadata('"$id"')["sizes"]["thumbnail"]["file"]; echo (file_exists($t) && wp_getimagesize($t)) ? 1 : 0;'
done
check_out "media image-size" "thumbnail" wp media image-size
php -r '
$im = imagecreatetruecolor(1000, 700);
for ($y = 0; $y < 700; $y++) { imageline($im, 0, $y, 1000, $y, imagecolorallocate($im, $y % 256, 100, 200 - $y % 200)); }
imagejpeg($im, "/tmp/apptest-cli-'"$RUN"'.jpg", 90);'
mid="$(wp media import /tmp/apptest-cli-$RUN.jpg --title="CLI image $RUN" --porcelain 2>/dev/null)"
if [ -n "$mid" ] && [ "$mid" -gt 0 ] 2>/dev/null; then ok "media import creates attachment $mid"; else fail "media import -- got '$mid'"; fi
check_eq "media import: sizes were generated" "1" wp eval 'echo isset(wp_get_attachment_metadata('"${mid:-0}"')["sizes"]["medium"]) ? 1 : 0;'
rm -f "/tmp/apptest-cli-$RUN.jpg"

# -- export to WXR and parse it back ---------------------------------------------------------------------
wxr="/tmp/apptest-wxr-$RUN.xml"
if wp export --stdout --post_type=post --start_date=2024-03-01 --end_date=2024-03-31 >"$wxr" 2>"$APPTEST_OUT"; then
  check_eq "export: WXR parses and holds the month's posts" "$(mf month.count)" php -r '
    $x = new DOMDocument(); $x->load($argv[1]);
    $n = 0; foreach ($x->getElementsByTagName("item") as $i) { $n++; }
    echo $n;' "$wxr"
  check_out "export: WXR keeps UTF-8" "wp:wxr_version" cat "$wxr"
  check_eq "export: every item is a published post" "0" php -r '
    $x = new DOMDocument(); $x->load($argv[1]); $bad = 0;
    foreach ($x->getElementsByTagName("status") as $s) { if ($s->nodeValue !== "publish") { $bad++; } }
    echo $bad;' "$wxr"
else
  fail "export -- $(tail -5 "$APPTEST_OUT")"
fi
rm -f "$wxr"

# -- writes through WP-CLI -----------------------------------------------------------------------------------
pid="$(wp post create --post_title="CLI post $RUN Ünï 🚀" --post_content='<!-- wp:paragraph --><p>cli</p><!-- /wp:paragraph -->' --post_status=draft --porcelain 2>/dev/null)"
if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then ok "post create -> $pid"; else fail "post create -- got '$pid'"; fi
check_eq "post: title with emoji survives" "CLI post $RUN Ünï 🚀" wp post get "${pid:-0}" --field=post_title
check "post meta add and get" bash -c "
  wp() { php -d memory_limit=-1 $APP/.apptest/wp-cli.phar ${WP_FLAGS[*]} \"\$@\"; }
  wp post meta add ${pid:-0} apptest_cli 'ü' && [ \"\$(wp post meta get ${pid:-0} apptest_cli)\" = 'ü' ]"
check_out "cache: the new post is cached in Redis" "cached" wp eval 'echo wp_cache_get('"${pid:-0}"', "posts") !== false ? "cached" : "cold";'
check "post update" wp post update "${pid:-0}" --post_title="CLI post $RUN edited"
check_eq "cache: the next process sees the update, never the old copy" "fresh" wp eval '$c = wp_cache_get('"${pid:-0}"', "posts"); echo ($c === false || $c->post_title === "CLI post '"$RUN"' edited") ? "fresh" : "stale";'
check_eq "cache: get_post returns the new title" "CLI post $RUN edited" wp eval 'echo get_post('"${pid:-0}"')->post_title;'
check "user create" wp user create "cli_$RUN" "cli_$RUN@apptest.test" --role=subscriber --user_pass="Apptest!cli$RUN" --porcelain
check "user check-password: the account just created" wp user check-password "cli_$RUN" "Apptest!cli$RUN"
check "comment create" wp comment create --comment_post_ID="$(mf comment_target.id)" --comment_content="CLI comment $RUN" --comment_author="CLI" --comment_author_email="cli@example.test"

# -- plugins and themes -------------------------------------------------------------------------------------------
check_out "plugin list: woocommerce is active" "woocommerce" wp plugin list --status=active --field=name
check_eq "plugin: woocommerce version" "$WOO_VERSION" wp plugin get woocommerce --field=version
check "theme: the fixture theme is active" wp theme is-active "$(mf theme.slug)"
check "plugin: every plugin can be listed as JSON" wp plugin list --format=json

# -- WooCommerce CLI ----------------------------------------------------------------------------------------------------
if [ "$HPOS" = yes ]; then
  check_out "wc hpos status: enabled" "HPOS enabled?: yes" wp wc hpos status --user=admin
else
  skip "wc hpos status" "WooCommerce $WOO_VERSION keeps orders as posts (HPOS is the default from 8.2)"
fi
check_eq "wc product list: every product" "$(mf counts.products)" wp wc product list --user=admin --fields=id --format=count
sku="$(mf woo.simple_sample.sku)"
check_out "wc product list: filter by SKU" "$(mf woo.simple_sample.id)" wp wc product list --user=admin --sku="$sku" --fields=id --format=ids
check_eq "wc product get: price" "$(mf woo.simple_sample.price)" wp wc product get "$(mf woo.simple_sample.id)" --user=admin --field=price
check_eq "wc product get: variable product type" "variable" wp wc product get "$(mf woo.variable_sample.id)" --user=admin --field=type
check_min "wc product_variation list" 2 wp wc product_variation list "$(mf woo.variable_sample.id)" --user=admin --fields=id --format=count
check_min "wc order list" 20 wp wc shop_order list --user=admin --per_page=100 --fields=id --format=count
check_min "wc customer list" 5 wp wc customer list --user=admin --role=all --per_page=100 --fields=id --format=count
check_out "wc shipping_zone list" "Test zone" wp wc shipping_zone list --user=admin --fields=name --format=csv
check_out "wc payment_gateway: cash on delivery enabled" "1" wp wc payment_gateway get cod --user=admin --field=enabled
check_out "wc coupon list" "$(mf woo.coupon)" wp wc shop_coupon list --user=admin --fields=code --format=csv
oid="$(wp wc shop_order create --user=admin --payment_method=cod --status=on-hold --billing='{"first_name":"CLI","last_name":"'"$RUN"'","email":"cli-'"$RUN"'@example.test","country":"US","state":"CA"}' --line_items='[{"product_id":'"$(mf woo.simple_sample.id)"',"quantity":2}]' --shipping_lines='[{"method_id":"flat_rate","method_title":"Flat rate","total":"5.00"}]' --porcelain 2>/dev/null)"
if [ -n "$oid" ] && [ "$oid" -gt 0 ] 2>/dev/null; then ok "wc order create -> $oid"; else fail "wc order create -- got '$oid'"; fi
check_eq "wc order get: status" "on-hold" wp wc shop_order get "${oid:-0}" --user=admin --field=status
want_total="$(php -r 'printf("%.2f", $argv[1] * 2 + 5);' "$(mf woo.simple_sample.price)")"
check_eq "wc order get: total is 2 x price + shipping" "$want_total" wp wc shop_order get "${oid:-0}" --user=admin --field=total
check "wc order update: complete it" wp wc shop_order update "${oid:-0}" --user=admin --status=completed
check_eq "wc order get: completed" "completed" wp wc shop_order get "${oid:-0}" --user=admin --field=status
check_out "wc order note create" "Success" wp wc order_note create "${oid:-0}" --user=admin --note="CLI note $RUN"
check "wc tool run: clear_transients" wp wc tool run clear_transients --user=admin
check_out "wc tracker snapshot reports this PHP" "\"php_version\":\"$(php -r 'echo PHP_VERSION;')\"" wp wc tracker snapshot --user=admin --format=json
check_eq "wc: the order store holds the seeded orders" "$(mf counts.orders)" wp eval 'echo count(array_intersect(wc_get_orders(["limit" => -1, "return" => "ids"]), '"$(mf woo.orders)"'));'

finish wordpress-cli
