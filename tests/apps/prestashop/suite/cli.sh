#!/usr/bin/env bash
# PrestaShop CLI suite: the Symfony console without a network, the fixture's
# recorded values recomputed on this PHP, and the write paths (products,
# images, orders, PDFs) that a cron job or an import script would run.
set -uo pipefail
# shellcheck source=tests/apps/cli-lib.sh
. /apptest/cli-lib.sh
cd /srv/app || exit 1
SUITE=/apptest/prestashop/suite
CONSOLE=(php -d memory_limit=-1 bin/console --env=prod --no-debug --no-interaction --no-ansi)
# The release the fixture was built from; one suite serves every set.
VERSION="$(php -r 'echo json_decode(file_get_contents("/srv/app/.apptest/manifest.json"), true)["app_version"];')"

# run_php_suite <script> [env...] -- a PHP script that prints ok:/FAIL:/SKIP:
# lines is folded into this suite's own count.
run_php_suite() {
  local script="$1" out rc line
  shift
  out="$(env "$@" php -d memory_limit=-1 "$SUITE/$script" 2>&1)"; rc=$?
  while IFS= read -r line; do
    case "$line" in
      "ok: "*) ok "${line#ok: }" ;;
      "FAIL: "*) fail "${line#FAIL: }" ;;
      "SKIP: "*) skip "${line#SKIP: }" ;;
      "") ;;
      *) echo "    | $line" ;;
    esac
  done <<<"$out"
  [ "$rc" -eq 0 ] || fail "$script exited $rc"
}

check "php boots" php -r 'echo PHP_VERSION, PHP_EOL;'
# 1.6 has no Symfony: no bin/console, no container, no Twig. The module and cache checks come back as API calls in
# cli-tasks.php (module enable/disable, smarty compiled from cold); the rest has nothing to run.
case "$VERSION" in 1.6.*) LEGACY=1 ;; *) LEGACY=0 ;; esac
if [ "$LEGACY" -eq 1 ]; then
  skip "console: version, list, debug:router, debug:container, cache:clear, cache:warmup, lint:twig, api:openapi:export, module enable/disable/configure -- 1.6 has no bin/console (no Symfony)"
else
  case "$VERSION" in   # 8.x's console banner is Symfony's own, 9.x names PrestaShop
    9.*) BANNER="PrestaShop $VERSION" ;;
    *) BANNER="Symfony" ;;
  esac
  check_out "console: version" "$BANNER" "${CONSOLE[@]}" --version
  check_out "console: list has the module command" "prestashop:module" "${CONSOLE[@]}" list
  # 1.7 and 8.0 list products on the old catalog page; 8.0 has the grid only as admin_products_v2_index behind a feature flag, 8.1 renamed it
  case "$VERSION" in 1.7.*|8.0.*) PRODUCT_ROUTE=admin_product_catalog ;; *) PRODUCT_ROUTE=admin_products_index ;; esac
  check_out "console: debug:router knows the product grid" "$PRODUCT_ROUTE" "${CONSOLE[@]}" debug:router
  check_out "console: debug:container finds the legacy configuration adapter" "PrestaShop\\Adapter\\Configuration" "${CONSOLE[@]}" debug:container prestashop.adapter.legacy.configuration
  check "console: cache:clear --no-warmup" "${CONSOLE[@]}" cache:clear --no-warmup
  check "console: cache:warmup" "${CONSOLE[@]}" cache:warmup
  V=src/PrestaShopBundle/Resources/views/Admin   # the WebProfiler templates need the dev-only profiler_dump
  twig_dirs=()
  twig_want="Sell Configure Improve Component Common Login"   # Component and Login are 9.x directories
  case "$VERSION" in 1.7.*) twig_want="$twig_want Category Product Module Multistore" ;; esac   # 1.7 has no Sell/, these are its Symfony pages
  for d in $twig_want; do
    [ -d "$V/$d" ] && twig_dirs+=("$V/$d")
  done
  check "console: lint:twig on the back office templates (${twig_dirs[*]##*/})" "${CONSOLE[@]}" lint:twig "${twig_dirs[@]}"
  # The Admin API (and its OpenAPI export) is 9.x; 8.2 has no api: commands
  if "${CONSOLE[@]}" list 2>/dev/null | grep -q 'api:openapi:export'; then
    check "console: api:openapi:export" "${CONSOLE[@]}" api:openapi:export
  else
    skip "console: api:openapi:export -- this release has no Admin API (9.x only)"
  fi
  check_out "console: disable a module" "succeeded" "${CONSOLE[@]}" prestashop:module disable ps_sharebuttons
  check_out "console: enable it again" "succeeded" "${CONSOLE[@]}" prestashop:module enable ps_sharebuttons
  check_out "console: module configure refuses a missing file cleanly" "" bash -c "cd /srv/app && ${CONSOLE[*]} prestashop:module configure ps_sharebuttons /nonexistent.yml; true"

fi

# the webservice goldens need the shop answering, so a throwaway php -S
php -S 127.0.0.1:8081 -t /srv/app >/tmp/apptest-php-s.log 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:8081/ && break; sleep 1; done
run_php_suite check-golden.php APPTEST_WS_BASE=http://127.0.0.1:8081
kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null
trap - EXIT

run_php_suite cli-tasks.php
if [ "$LEGACY" -eq 1 ]; then
  skip "console: cache:clear still works after the writes -- 1.6 has no bin/console (cli-tasks.php clears Smarty's caches after its writes)"
else
  check_out "console: cache:clear still works after the writes" "successfully cleared" "${CONSOLE[@]}" cache:clear --no-warmup
fi

finish prestashop-cli
