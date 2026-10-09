#!/usr/bin/env bash
# Point an already-installed PrestaShop at the host:port it is actually about
# to be served on, and drop whatever it cached about the old one.
#
#   set-host.sh <app-root> <host:port>
#
# Called by corpus/verify.sh and php/pgo/train.sh right after db-up.sh, before the
# app is served; Dockerfile.corpus's install step still installs against a fixed
# PS_DOMAIN. That domain is baked into ps_shop_url and mirrored into
# ps_configuration's PS_SHOP_DOMAIN/PS_SHOP_DOMAIN_SSL rows, and PrestaShop 302s
# any request whose Host does not match it: `curl http://127.0.0.1:18202/` gets
# `302 Location: http://127.0.0.1:18401/index.php?`, because 18401 (the CLI
# install's fixed port) is neither verify.sh's 18201+N nor train.sh's 18301+N.
# WordPress solves the same problem with CORPUS_WP_HOST, read at request time from
# wp-config.php; PrestaShop's domain is pure database state read by Shop/Context
# on every request, so the fix has to update that state.
#
# Schema: every PrestaShop built here (9.2.0 on the 8.5 tier, 8.2.8 on the 7.2,
# 8.1, 8.2 and 8.4 tiers; corpus.lock has the pins) is on the 1.7+/Symfony-admin
# line, which has carried ps_shop_url and the PS_SHOP_DOMAIN* configuration
# mirror with the same columns throughout. The 1.6 line (7.0 tier) is not covered;
# a missing ps_shop_url fails loudly below rather than doing nothing.
#
# The table prefix is hardcoded to ps_, as in every other PrestaShop query in this
# corpus (corpus/prestashop/endpoints, Dockerfile.corpus's install step), which
# always installs with --prefix=ps_/DB_PREFIX=ps_.
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

# The Symfony container/router cache, which would otherwise keep serving what it
# compiled against the old host (Dockerfile.corpus clears it after its own
# post-install ps_configuration UPDATE too).
rm -rf "${APP:?}/var/cache/"*

echo "ok: prestashop shop url repointed to ${HOSTPORT}"
