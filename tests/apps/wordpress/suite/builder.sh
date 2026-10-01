#!/usr/bin/env bash
# What a build stage does for a WordPress project, inside the cli-builder
# flavor (network available, default user): composer install from a committed
# lock, platform checks, a syntax pass over the whole WordPress + WooCommerce
# tree, and WP-CLI's build-time commands. run.sh runs cli.sh right after.
set -uo pipefail
. /apptest/cli-lib.sh

APP=/srv/app
HERE=/apptest/wordpress/suite
MANIFEST=$APP/.apptest/manifest.json
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export COMPOSER_HOME="$WORK/composer-home" COMPOSER_NO_INTERACTION=1 COMPOSER_ALLOW_SUPERUSER=1
# The shared cache volume saves a download per run; fall back to a private one where the uid cannot write to it.
if [ -w /composer-cache ]; then export COMPOSER_CACHE_DIR=/composer-cache; else export COMPOSER_CACHE_DIR="$WORK/composer-cache"; fi
cd "$WORK" || exit 1

mf() {
  php -r '$v = json_decode(file_get_contents($argv[1]), true); foreach (explode(".", $argv[2]) as $k) { $v = $v[$k]; } echo is_scalar($v) ? $v : json_encode($v);' "$MANIFEST" "$1"
}
check_eq() {
  local name="$1" want="$2" got; shift 2
  got="$("$@" 2>"$APPTEST_OUT")"
  if [ "$got" = "$want" ]; then ok "$name"; else fail "$name -- expected '$want', got '${got:0:200}' from: $*"; sed 's/^/    | /' "$APPTEST_OUT" | tail -10; fi
}

echo "# php $(php -r 'echo PHP_VERSION;'), uid $(id -u), $(nproc) cpus"

# -- composer ------------------------------------------------------------------
if [ ! -x /usr/local/bin/composer ]; then
  fail "composer is missing from /usr/local/bin -- the cli-builder flavor has to ship it"
  finish wordpress-builder
  exit 1
fi
ok "composer is shipped at /usr/local/bin/composer"
check_out "composer runs on this PHP" "Composer version" composer --version --no-ansi

# One lock per set, each resolved on the stock image of the set's php-min: the
# libraries' newest majors need PHP 7.2.5 (guzzle 7, symfony 5) or 7.2 (monolog 2).
mkdir project && cp "$HERE/builder/$APPTEST_SET/composer.json" "$HERE/builder/$APPTEST_SET/composer.lock" project/ && cd project || exit 1
check "composer validate" composer validate --no-check-publish --no-ansi
check "composer install from the committed lock" composer install --no-progress --no-scripts --prefer-dist --optimize-autoloader --no-ansi
check_out "composer check-platform-reqs" "php" composer check-platform-reqs --no-ansi
check_out "composer check-platform-reqs --lock" "php" composer check-platform-reqs --lock --no-ansi
check_out "composer show lists the bundle" "wp-cli/wp-cli-bundle" composer show --no-ansi
check_out "composer show --tree walks the dependency graph" "monolog/monolog" composer show --tree --no-ansi
check "composer dump-autoload --classmap-authoritative" composer dump-autoload --classmap-authoritative --no-ansi
check_out "composer licenses" "MIT" composer licenses --no-ansi
check_min_files() { [ "$(find vendor -name '*.php' | wc -l)" -gt 1000 ]; }
check "vendor tree was materialised" check_min_files

# The libraries load through the generated autoloader and do real work.
check_out "monolog: JSON formatter keeps UTF-8" "тест 🚀" php -r '
require "vendor/autoload.php";
$h = new Monolog\Handler\StreamHandler("php://output");
$h->setFormatter(new Monolog\Formatter\JsonFormatter());
(new Monolog\Logger("apptest", [$h]))->info("тест 🚀 \"quoted\"", ["n" => 1.5]);'
check_out "guzzle: mock handler, PSR-7 request and response" "200:ok:application/json" php -r '
require "vendor/autoload.php";
$mock = new GuzzleHttp\Handler\MockHandler([new GuzzleHttp\Psr7\Response(200, ["Content-Type" => "application/json"], "ok")]);
$c = new GuzzleHttp\Client(["handler" => GuzzleHttp\HandlerStack::create($mock)]);
$r = $c->request("GET", "https://example.test/x?q=" . rawurlencode("тест"));
echo $r->getStatusCode(), ":", $r->getBody(), ":", $r->getHeaderLine("Content-Type");'
check_out "symfony/yaml: parse and dump round trip" "ok" php -r '
require "vendor/autoload.php";
$data = Symfony\Component\Yaml\Yaml::parse("a: [1, 2, {b: тест}]\nc: \"🚀\"\n");
echo Symfony\Component\Yaml\Yaml::parse(Symfony\Component\Yaml\Yaml::dump($data, 4)) === $data ? "ok" : "differs";'

# -- WP-CLI from the composer install, against the fixture tree ---------------------------------------
WPC="php -d memory_limit=-1 $PWD/vendor/wp-cli/wp-cli/php/boot-fs.php --path=$APP"
[ "$(id -u)" -ne 0 ] || WPC="$WPC --allow-root"
check_eq "wp-cli from composer: core version" "$(mf app_version)" $WPC core version
check_out "wp-cli from composer: woocommerce is active" "woocommerce" $WPC plugin list --status=active --field=name
check_eq "wp-cli from composer: published posts" "$(mf counts.posts_published)" $WPC post list --post_type=post --post_status=publish --format=count
check_out "wp-cli from composer: it is the bundle's release" "2.12.0" $WPC --version
check_eq "wp-cli from composer: runs this PHP" "$(php -r 'echo PHP_VERSION;')" $WPC eval 'echo PHP_VERSION;'

# -- syntax pass over the whole application tree, in parallel ----------------------------------------------
JOBS="$(nproc)"; [ "$JOBS" -le 8 ] || JOBS=8
# WooCommerce's GraphQL feature (src/Api, src/Internal/Api) uses enums and
# readonly properties and says so: "Requires PHP 8.1 or later". Below that it is
# never loaded, so a parse error there is not a finding. The same goes for the
# bundled graphql-php class that wraps native enums.
skip_woo_api=()
php -r 'exit(PHP_VERSION_ID < 80100 ? 0 : 1);' && skip_woo_api=(-path "$APP/wp-content/plugins/woocommerce/src/Api" -prune -o -path "$APP/wp-content/plugins/woocommerce/src/Internal/Api" -prune -o -path "$APP/wp-content/plugins/woocommerce/lib/packages/GraphQL/Type/Definition/PhpEnumType.php" -prune -o)
# WooCommerce 7.x's Interactivity API classes use typed properties (7.4+) and only load there.
php -r 'exit(PHP_VERSION_ID < 70400 ? 0 : 1);' && skip_woo_api+=(-path "$APP/wp-content/plugins/woocommerce/packages/woocommerce-blocks/src/Interactivity" -prune -o)
find "$APP" -path "$APP/wp-content/uploads" -prune -o -path "$APP/.apptest" -prune -o "${skip_woo_api[@]}" -name '*.php' -print0 >"$WORK/files.lst"
total="$(tr -cd '\0' <"$WORK/files.lst" | wc -c)"
if [ "$total" -gt 3000 ]; then ok "found $total PHP files in WordPress + WooCommerce"; else fail "only $total PHP files under $APP (expected several thousand)"; fi
started=$(date +%s)
xargs -0 -P "$JOBS" -n 60 sh -c 'for f do out=$(php -l "$f" 2>&1) || echo "$out"; done' sh <"$WORK/files.lst" >"$WORK/lint.out" 2>&1
if [ ! -s "$WORK/lint.out" ]; then ok "php -l: no parse error in $total files ($(( $(date +%s) - started ))s on $JOBS jobs)"; else fail "php -l found parse errors"; head -20 "$WORK/lint.out" | sed 's/^/    | /'; fi

# -- WP-CLI build-time commands ------------------------------------------------------------------------------
check_eq "i18n make-pot: a theme" "1" bash -c "$WPC i18n make-pot $APP/wp-content/themes/$(mf theme.slug) $WORK/theme.pot --slug=$(mf theme.slug) --skip-audit >/dev/null && grep -c '^msgid \"$(mf theme.name)\"' $WORK/theme.pot"
check_eq "i18n make-pot: WooCommerce's templates (PHP parser over real code)" "1" bash -c "$WPC i18n make-pot $APP/wp-content/plugins/woocommerce/templates $WORK/woo.pot --slug=woocommerce --domain=woocommerce --skip-audit >/dev/null && [ \$(grep -c '^msgid ' $WORK/woo.pot) -gt 100 ] && echo 1"
mkdir "$WORK/plugins"
check "scaffold plugin" $WPC scaffold plugin apptest-scaffold --dir="$WORK/plugins" --skip-tests --plugin_name="Apptest Scaffold"
check "scaffolded plugin has its header" grep -Eq 'Plugin Name:[[:space:]]+Apptest Scaffold' "$WORK/plugins/apptest-scaffold/apptest-scaffold.php"
check "scaffolded plugin lints" php -l "$WORK/plugins/apptest-scaffold/apptest-scaffold.php"
check "app tree is writable by the build user" bash -c "touch $APP/wp-content/apptest-writable && rm $APP/wp-content/apptest-writable"

finish wordpress-builder
