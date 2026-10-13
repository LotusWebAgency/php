#!/usr/bin/env bash
# Start (or reuse) mariadbd against <app-root>/db-data, listening on
# 127.0.0.1:13306. Idempotent: does nothing if that port already answers a ping.
#
#   db-up.sh <app-root>
#
# TCP loopback, not a unix socket: PrestaShop 8.x/9.x has two independent database
# connections that must agree on how to reach it -- the classic Db/DbPDO layer
# (install/index_cli.php, the ObjectModel front office), driven by
# --db_server/--db_name/... CLI args, and the Symfony admin container's Doctrine
# DBAL connection, generated into app/config/parameters.php from the
# DB_SERVER/DB_PORT/DB_NAME/... environment variables by the same install run.
# Doctrine has no equivalent of DbPDO's "host:/socket/path" parsing and fails
# with "An exception occurred while establishing a connection to figure out your
# platform version" when AppKernel boots during install, so host:port is the one
# address form both sides parse.
#
# --skip-grant-tables: the datadir only exists in a throwaway build layer or a
# --rm test container and is bound to loopback only, so authentication would only
# give the two connections above (and verify.sh) a password to agree on.
#
# The corpus ships only the app tree and the populated datadir, not mariadbd: no
# PrestaShop/MariaDB software may reach the runtime images (see the PrestaShop
# header of php/pgo/corpus.lock). Whoever mounts the corpus installs
# mariadb-server first: Dockerfile.corpus to run the CLI installer that produces
# db-data, tests/test-corpus-tiers.sh and tests/test-corpus.sh to replay the proof
# on every runtime image, and php/build.sh's PGO training stage.
set -euo pipefail
APP="${1:?usage: db-up.sh <app-root>}"
HOST=127.0.0.1
PORT=13306
PIDFILE=/tmp/ps-corpus-mysql.pid
RUNPIDFILE=/tmp/ps-corpus-mysql.runner.pid
LOG=/tmp/ps-corpus-mysql.log
DATADIR="${APP}/db-data"

MARIADBD="$(command -v mariadbd 2>/dev/null || command -v mysqld 2>/dev/null || true)"
for candidate in /usr/sbin/mariadbd /usr/sbin/mysqld; do
  [ -n "$MARIADBD" ] && break
  [ -x "$candidate" ] && MARIADBD="$candidate"
done
[ -n "$MARIADBD" ] && [ -x "$MARIADBD" ] || {
  echo "FATAL[db-up]: no mariadbd/mysqld on PATH or in /usr/sbin -- install mariadb-server first" >&2
  exit 1
}
[ -d "$DATADIR" ] || {
  echo "FATAL[db-up]: no $DATADIR -- this corpus was not built with a prestashop database" >&2
  exit 1
}

if mysqladmin --host="$HOST" --port="$PORT" --protocol=tcp ping >/dev/null 2>&1; then
  echo "ok: mariadbd already up on ${HOST}:${PORT}"
  exit 0
fi

# --socket is needed although nothing connects over it: mariadbd always binds one
# alongside TCP, and its default (/run/mysqld/mysqld.sock) is not writable by a
# non-root uid ("Bind on unix socket: No such file or directory").
#
# --user=$(id -un): mariadbd refuses to start as uid 0 without an explicit --user
# ("Please consult the Knowledge Base to find out how to run mysqld as root!").
# tests/test-corpus.sh calls this script as root; for the www-data callers it is
# the implicit default anyway.
"$MARIADBD" --datadir="$DATADIR" --bind-address="$HOST" --port="$PORT" --pid-file="$PIDFILE" \
  --user="$(id -un)" \
  --socket=/tmp/ps-corpus-mysql.sock --skip-grant-tables --skip-name-resolve >"$LOG" 2>&1 &
echo $! > "$RUNPIDFILE"

for _ in $(seq 1 120); do
  if mysqladmin --host="$HOST" --port="$PORT" --protocol=tcp ping >/dev/null 2>&1; then
    echo "ok: mariadbd up on ${HOST}:${PORT} (datadir $DATADIR)"
    exit 0
  fi
  kill -0 "$(cat "$RUNPIDFILE")" 2>/dev/null || break
  sleep 0.5
done

echo "FATAL[db-up]: mariadbd did not come up on ${HOST}:${PORT}" >&2
tail -40 "$LOG" >&2 2>/dev/null || true
exit 1
