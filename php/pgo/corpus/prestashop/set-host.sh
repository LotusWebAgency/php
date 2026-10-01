#!/usr/bin/env bash
# Point an already-installed PrestaShop at the host:port it is actually about
# to be served on, and drop whatever it cached about the old one.
#
#   set-host.sh <app-root> <host:port>
#
# Called by corpus/verify.sh and php/pgo/train.sh right after db-up.sh, before
# the app is served -- not by Dockerfile.corpus's install step, which still
# installs against a fixed PS_DOMAIN (task 29d's bug 2). That domain gets
# baked into ps_shop_url and mirrored into ps_configuration's PS_SHOP_DOMAIN/
# PS_SHOP_DOMAIN_SSL rows, and PrestaShop 302s any request whose Host does not
# match it (Dispatcher::checkCustomerCompatibilityMobile-adjacent domain
# checks in the front controller) -- the exact failure task 29d reproduced:
# `curl http://127.0.0.1:18202/` -> `302 Location:
# http://127.0.0.1:18401/index.php?`, because 18401 (the CLI install's fixed
# port) is not 18201+N (verify.sh's) or 18301+N (train.sh's). WordPress's
# CORPUS_WP_HOST env var solves the same problem by being read at request
# time from wp-config.php; PrestaShop has no such hook (the domain is pure
# database state, read by Shop/Context on every request, not by a bootstrap
# file this corpus controls), so the fix has to update that state instead.
#
# Schema check (task 29e ruling): every PrestaShop this corpus builds --
# 9.2.0 (8.1/8.2 tiers) and 8.2.8 (7.2 tier), corpus.lock has the pins -- is
# on the 1.7+/Symfony-admin line, which has carried ps_shop_url (added with
# multistore in 1.5) and the PS_SHOP_DOMAIN*/configuration mirror ever since;
# neither changed shape between those two releases (both installs produce the
# same ps_shop_url/ps_configuration columns, confirmed against a real install
# per tier -- see task-29e-report.md). The 1.6 line (7.0 tier, out of scope
# per task-29c-brief item 6) is NOT covered by this script or by that check --
# whoever bootstraps that tier has to verify it separately; failing loudly
# below on a missing ps_shop_url is exactly what should happen there rather
# than silently doing nothing.
#
# Table prefix is hardcoded to ps_, same as every other prestashop query in
# this corpus (corpus/prestashop/endpoints' own SELECT, Dockerfile.corpus's
# install step) -- this corpus always installs with --prefix=ps_/DB_PREFIX=ps_,
# never anything else, so a configurable prefix would be generality nothing
# here exercises.
set -euo pipefail
APP="${1:?usage: set-host.sh <app-root> <host:port>}"
HOSTPORT="${2:?usage: set-host.sh <app-root> <host:port>}"
DB_HOST=127.0.0.1
DB_PORT=13306
DB_NAME=prestashop

mdb() { mariadb --host="$DB_HOST" --port="$DB_PORT" --protocol=tcp "$@"; }

has_table="$(mdb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='ps_shop_url'")"
[ "$has_table" = "1" ] || {
  echo "FATAL[set-host]: no ps_shop_url table in $DB_NAME -- this script was written against the 1.7+/Symfony-admin schema, not whatever this install is" >&2
  exit 1
}

mdb "$DB_NAME" -e "UPDATE ps_shop_url SET domain='${HOSTPORT}', domain_ssl='${HOSTPORT}';"
mdb "$DB_NAME" -e "UPDATE ps_configuration SET value='${HOSTPORT}' WHERE name IN ('PS_SHOP_DOMAIN','PS_SHOP_DOMAIN_SSL');"

# Same cache directory Dockerfile.corpus clears after its own ps_configuration
# UPDATE (PS_REWRITING_SETTINGS) post-install -- the Symfony container/router
# cache that would otherwise keep serving whatever it last compiled against.
rm -rf "${APP:?}/var/cache/"*

echo "ok: prestashop shop url repointed to ${HOSTPORT}"
