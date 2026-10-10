#!/bin/sh
# Stands in for mysqladmin inside a runtime -fpm image, which ships
# mariadb-client-core (the mariadb shell) but not mysqladmin. Mounted at
# /usr/local/bin/mysqladmin by tests/test-corpus-tiers.sh so that
# php/pgo/corpus/prestashop/db-up.sh and db-down.sh find the sidecar database
# the way they find their own: over TCP loopback, in a network namespace shared
# with that sidecar.
#
# ping:     exit 0 when the server answers a query, non-zero otherwise.
# shutdown: a no-op. The sidecar belongs to the test harness, which removes it.
set -eu
cmd=""
for arg in "$@"; do
  case "$arg" in
    -*) set -- "$@" "$arg" ;;
    *)  cmd="$arg" ;;
  esac
  shift
done
case "$cmd" in
  ping)     exec mariadb "$@" -e 'SELECT 1' >/dev/null 2>&1 ;;
  shutdown) echo "shim: leaving the sidecar database running" >&2; exit 0 ;;
  *)        echo "shim: mysqladmin '$cmd' is not supported" >&2; exit 2 ;;
esac
