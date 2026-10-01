#!/usr/bin/env bash
# cli-builder suite: what a build stage does with a PrestaShop tree. Replays
# composer install from the release's own lock, proves the image carries every
# extension the platform asks for, lints every PHP file in the tree, and boots
# the console. cli.sh runs afterwards (run.sh chains them).
set -uo pipefail
# shellcheck source=tests/apps/cli-lib.sh
. /apptest/cli-lib.sh
cd /srv/app || exit 1

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export COMPOSER_HOME="$work/home" COMPOSER_CACHE_DIR="${COMPOSER_CACHE_DIR:-/composer-cache}" COMPOSER_NO_INTERACTION=1 COMPOSER_ALLOW_SUPERUSER=1
[ -w "$COMPOSER_CACHE_DIR" ] || export COMPOSER_CACHE_DIR="$work/cache"
mkdir -p "$COMPOSER_HOME"

# Only the stock cli-builder images carry composer; on the other stock images (and there only) the suite fetches
# the pinned one, like the fixture build does.
if ! command -v composer >/dev/null 2>&1 && [ "${APPTEST_STOCK:-0}" = 1 ]; then
  export APPTEST_CACHE="$work/dl"
  mkdir -p "$COMPOSER_HOME/bin" "$APPTEST_CACHE"
  bash /apptest/install-composer.sh "$COMPOSER_HOME/bin/composer" >/dev/null 2>&1 && export PATH="$COMPOSER_HOME/bin:$PATH"
fi
if ! command -v composer >/dev/null 2>&1; then
  fail "composer is not on PATH in this cli-builder image"
  finish prestashop-builder
  exit 1
fi
ok "composer is on PATH ($(composer --version --no-ansi 2>&1 | head -1))"

# Composer's git/unzip fallbacks need proc_open. Older stock images disable it, so there composer alone gets it back.
if ! php -r 'exit(function_exists("proc_open") ? 0 : 1);'; then
  COMPOSER_BIN="$(command -v composer)"
  composer() { php -d disable_functions= "$COMPOSER_BIN" "$@"; }
  skip "composer scripts with the image's own disable_functions -- proc_open is disabled in this image; composer runs with it re-enabled"
fi

# check-platform-reqs, minus two known upstream gaps: 9.x's lock has ezyang/htmlpurifier
# declaring php up to 8.2, and PrestaShop runs it on 8.3+ regardless; 8.2's lock has
# intervention/httpauth at ^7.2 while the release supports 8.0 and 8.1. Anything
# else failing (an extension, another package's php range) still fails.
platform_reqs() {
  # `--format` came with composer 2.3; the 2.2 LTS (what the 7.0 and 7.1 images run) only prints the table
  if ! composer check-platform-reqs --help --no-ansi 2>/dev/null | grep -q -- '--format'; then
    { composer check-platform-reqs "$@" --no-ansi 2>/dev/null || true; } | awk '
      $3 ~ /^(success|failed|missing)$/ { n++; if ($3 != "success") bad = bad " " $1 " (" $3 ")" }
      END { if (!n) { print "unparsable composer output"; exit 1 }
            if (bad) { print "unmet:" bad; exit 1 }
            print "platform: " n " requirements" }'
    return
  fi
  { composer check-platform-reqs "$@" --format=json --no-ansi 2>/dev/null || true; } | php -r '
    $rows = json_decode(stream_get_contents(STDIN), true);
    if (!is_array($rows)) { echo "unparsable composer output", PHP_EOL; exit(1); }
    $bad = []; $waived = 0;
    foreach ($rows as $r) {
      if ($r["status"] === "success") { continue; }
      if ($r["name"] === "php" && in_array($r["failed_requirement"]["source"] ?? "", ["ezyang/htmlpurifier", "intervention/httpauth"], true)) { $waived++; continue; }
      $bad[] = $r["name"] . " (" . $r["status"] . ")";
    }
    if ($bad) { echo "unmet: ", implode(", ", $bad), PHP_EOL; exit(1); }
    echo "platform: ", count($rows), " requirements", $waived ? ", a known upstream php range waived" : "", PHP_EOL;'
}

# The release ships composer.lock and vendor/ but no composer.json; the
# fixture fetched the tag's own (apps.lock: prestashop-composer).
# 1.6 has neither: no lock, no vendor/, nothing for composer to replay.
if [ ! -f /srv/app/composer.lock ]; then
  skip "composer validate, check-platform-reqs, install from the lock, installed set equals vendor/ -- this release ships no composer.json, composer.lock or vendor/ (1.6)"
else
mkdir -p "$work/tree"
cp /srv/app/composer.json /srv/app/composer.lock "$work/tree/"
pushd "$work/tree" >/dev/null || exit 1
check "composer validate" composer validate --no-check-publish --no-ansi
check_out "composer check-platform-reqs --lock (every extension the lock asks for)" "platform: " platform_reqs --lock
check "composer install --no-dev from the lock" composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-ansi --no-progress
check_out "composer check-platform-reqs on what was installed" "platform: " platform_reqs
check_out "installed set equals the vendor/ the release ships" "same: " php -r '
  // composer 1 (the vendor/ 1.7 ships) writes a bare list, composer 2 wraps it in {"packages": [...]}
  $set = function ($f) { $d = json_decode(file_get_contents($f), true); $o = []; foreach (isset($d["packages"]) ? $d["packages"] : $d as $p) { $o[] = $p["name"] . "@" . $p["version"]; } sort($o); return $o; };
  $a = $set("vendor/composer/installed.json"); $b = $set("/srv/app/vendor/composer/installed.json");
  $diff = array_merge(array_diff($a, $b), array_diff($b, $a));
  if ($diff) { echo "differ: ", implode(",", array_slice($diff, 0, 5)), PHP_EOL; exit(1); }
  echo "same: ", count($a), " packages", PHP_EOL;'
popd >/dev/null || exit 1

check_out "composer check-platform-reqs against the shipped vendor/" "platform: " platform_reqs
fi

# php -l over the whole tree, in parallel. Compiled caches and logs are not source.
nproc_n="$(nproc 2>/dev/null || echo 4)"
lint_out="$work/all.out"
# one output file per batch: php -l writes its lines in pieces, and parallel batches sharing a file interleave them
# one php per file: before 8.1 `php -l a b c` only lints a
# (no xargs -P: BusyBox's, on the stock Alpine images, has none; split into one list per core and background a loop each)
find /srv/app -name '*.php' -not -path '/srv/app/var/*' -not -path '/srv/app/img/*' >"$work/files.list"
per_batch=$(( ($(wc -l <"$work/files.list") + nproc_n - 1) / nproc_n ))
split -l "$per_batch" -a 3 "$work/files.list" "$work/batch."
for batch in "$work"/batch.???; do
  ( while IFS= read -r f; do php -l "$f"; done <"$batch" >"$batch.out" 2>&1 ) &
done
wait
cat "$work"/batch.*.out >"$lint_out"
files="$(find /srv/app -name '*.php' -not -path '/srv/app/var/*' -not -path '/srv/app/img/*' | wc -l)"
# Files that are known not to parse on some PHP, and nothing loads them there. Measured over every PHP each tree
# runs on, not per stock image: the 8.2 tree on stock 7.2, 7.3, 7.4 and 8.0 (18 files fail on 7.2, 17 on 7.3, all listed
# below), the 9.2 tree on 8.1, 1.7 on 7.1, and 1.6 on 7.0, where every one of its files parses (nothing listed for it).
#  - upstream files nothing loads (a placeholder example, a PHP 4 era lessify script, a codesniffer fixture); the
#    last two still parse on 7.x, not on 8
#  - 1.7's vendor/symfony/symfony ships its whole Tests/ tree, whose fixtures use PHP 7.4/8 syntax (typed properties,
#    union types) or are broken on purpose (Config's ParseError.php); polyfill-apcu has a bootstrap80.php too
#  - 8.x's vendor/ also ships PHP 8-only syntax (attributes, readonly, union types, the polyfills' bootstrap80.php,
#    api-platform's upgrade tool and its Odm providers, doctrine's AttributeReader) that composer only loads on 8+,
#    so it does not parse on a 7.x image
waived='/srv/app/vendor/marcusschwarz/lesserphp/lessify.inc.php
/srv/app/vendor/greenlion/php-sql-parser/libs/codesniffer/PhOSCo/Sniffs/Commenting/FileCommentSniff.php
/srv/app/modules/ps_facebook/vendor/facebook/php-business-sdk/examples/AdsPixelCRMEventsPostCustom.php
/srv/app/vendor/api-platform/core/src/Core/Upgrade/UpgradeApiFilterVisitor.php
/srv/app/vendor/api-platform/core/src/Core/Upgrade/UpgradeApiPropertyVisitor.php
/srv/app/vendor/api-platform/core/src/Core/Upgrade/UpgradeApiResourceVisitor.php
/srv/app/vendor/api-platform/core/src/Elasticsearch/Metadata/Resource/Factory/ElasticsearchProviderResourceMetadataCollectionFactory.php
/srv/app/vendor/api-platform/core/src/Util/ClientTrait80.php
/srv/app/vendor/api-platform/core/src/Core/Upgrade/UpgradeApiSubresourceVisitor.php
/srv/app/vendor/api-platform/core/src/Core/Upgrade/ColorConsoleDiffFormatter.php
/srv/app/vendor/api-platform/core/src/Doctrine/Odm/State/ItemProvider.php
/srv/app/vendor/api-platform/core/src/Doctrine/Odm/State/CollectionProvider.php
/srv/app/vendor/doctrine/orm/lib/Doctrine/ORM/Mapping/Driver/AttributeReader.php
/srv/app/vendor/doctrine/cache/lib/Doctrine/Common/Cache/Psr6/TypedCacheItem.php
/srv/app/vendor/doctrine/doctrine-bundle/Attribute/AsEntityListener.php
/srv/app/vendor/doctrine/doctrine-bundle/Attribute/AsMiddleware.php
/srv/app/vendor/doctrine/orm/lib/Doctrine/ORM/Mapping/ReflectionReadonlyProperty.php
/srv/app/vendor/symfony/polyfill-iconv/bootstrap80.php
/srv/app/vendor/symfony/polyfill-intl-idn/bootstrap80.php
/srv/app/vendor/symfony/polyfill-intl-normalizer/bootstrap80.php
/srv/app/vendor/symfony/polyfill-mbstring/bootstrap80.php
/srv/app/vendor/symfony/polyfill-apcu/bootstrap80.php
/srv/app/vendor/symfony/symfony/src/Symfony/Component/VarDumper/Tests/Fixtures/Php74.php
/srv/app/vendor/symfony/symfony/src/Symfony/Component/Validator/Tests/Fixtures/Entity_74_Proxy.php
/srv/app/vendor/symfony/symfony/src/Symfony/Component/Validator/Tests/Fixtures/Entity_74.php
/srv/app/vendor/symfony/symfony/src/Symfony/Component/Validator/Tests/Fixtures/ConstraintWithTypedProperty.php
/srv/app/vendor/symfony/symfony/src/Symfony/Component/Serializer/Tests/Fixtures/Php74Dummy.php
/srv/app/vendor/symfony/symfony/src/Symfony/Component/PropertyInfo/Tests/Fixtures/Php80Dummy.php
/srv/app/vendor/symfony/symfony/src/Symfony/Component/PropertyAccess/Tests/Fixtures/UninitializedProperty.php
/srv/app/vendor/symfony/symfony/src/Symfony/Component/Form/Tests/Fixtures/TypehintedPropertiesCar.php
/srv/app/vendor/symfony/symfony/src/Symfony/Component/DependencyInjection/Tests/Fixtures/xml/xml_with_wrong_ext.php
/srv/app/vendor/symfony/symfony/src/Symfony/Component/DependencyInjection/Tests/Fixtures/php/services1-1.php
/srv/app/vendor/symfony/symfony/src/Symfony/Component/DependencyInjection/Tests/Fixtures/includes/uniontype_classes.php
/srv/app/vendor/symfony/symfony/src/Symfony/Component/Config/Tests/Fixtures/ParseError.php'
waived_lines="$(sed 's/^/Errors parsing /' <<<"$waived")"
# the parse error itself comes too when the image logs errors to stderr: "PHP Parse error: ... in <file> on line N"
waived_errors="$(sed 's/^\(.*\)$/ in \1 on line /' <<<"$waived")"
bad="$(grep -vE '^No syntax errors detected in ' "$lint_out" | grep -vxF -f <(printf '%s\n' "$waived_lines") \
  | grep -vF -f <(printf '%s\n' "$waived_errors") | head -10)"
clean="$(grep -c '^No syntax errors detected in ' "$lint_out")"
hit="$(grep -cxF -f <(printf '%s\n' "$waived_lines") "$lint_out")"
# every file answered: parsed, or failed and is on the list (a php that crashed answers neither)
if [ -z "$bad" ] && [ "$((clean + hit))" -eq "$files" ]; then
  ok "php -l: $files files in the tree, no parse errors beyond the $hit known ones that do not parse on php $(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
else
  fail "php -l -- $clean/$files clean, $hit waived"
  printf '%s\n' "$bad" | sed 's/^/    | /'
fi

VERSION="$(php -r 'echo json_decode(file_get_contents("/srv/app/.apptest/manifest.json"), true)["app_version"];')"
case "$VERSION" in   # 8.x's console banner is Symfony's own, 9.x names PrestaShop
  9.*) BANNER="PrestaShop $VERSION" ;;
  *) BANNER="Symfony" ;;
esac
case "$VERSION" in
  1.6.*) skip "console boots, container compiles from cold -- 1.6 has no bin/console (cli.sh compiles Smarty from cold instead)" ;;
  *)
    check_out "console boots" "$BANNER" php -d memory_limit=-1 bin/console --version --env=prod --no-debug
    check "console: container compiles from cold" bash -c 'rm -rf /srv/app/var/cache/* && php -d memory_limit=-1 bin/console cache:warmup --env=prod --no-debug --no-interaction'
    ;;
esac

finish prestashop-builder
