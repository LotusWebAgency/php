#!/usr/bin/env bash
# Start (or reuse) mariadbd against <app-root>/db-data, listening on
# 127.0.0.1:13306. Idempotent -- does nothing if that port already answers a
# ping, so calling this before every check that needs the database is cheap
# and safe.
#
#   db-up.sh <app-root>
#
# TCP loopback, not a unix socket: PrestaShop 8.x/9.x has *two* independent
# database connections that both have to agree on how to reach it -- the
# classic Db/DbPDO layer (install/index_cli.php, the ObjectModel front
# office), driven entirely by --db_server/--db_name/... CLI args, and the
# Symfony admin container's Doctrine DBAL connection, generated into
# app/config/parameters.php from the DB_SERVER/DB_PORT/DB_NAME/... *environment
# variables* by the same install run. Doctrine's side has no equivalent of
# DbPDO's "host:/socket/path" parsing (measured: it does, reproducibly, fail
# with "An exception occurred while establishing a connection to figure out
# your platform version" the moment AppKernel boots during install, which is
# every run) -- host:port is the one address form both sides parse the same
# way, so this never offers a socket.
#
# --skip-grant-tables: this datadir only ever exists inside a throwaway build
# layer or a --rm test/replay container, is bound to loopback only, and is
# gone the moment that layer or container is. Auth would only give the two
# connections above (and verify.sh, and whatever runs after) a password to
# agree on, for a database nothing outside the container can reach anyway.
#
# mariadbd itself is not shipped by the corpus -- only the app tree and the
# already-populated datadir are (php/pgo/corpus.lock's PrestaShop header and
# task-29a-report.md explain why: nothing PrestaShop/MariaDB may reach the
# runtime images, so the corpus is data, not a service). Whoever mounts the
# corpus has to install mariadb-server itself first: Dockerfile.corpus does,
# to run the CLI installer that produces db-data in the first place;
# tests/test-corpus-tiers.sh and tests/test-corpus.sh do, to replay this same
# proof against every runtime image the tier serves; php/build.sh's PGO
# training stage (task 29b) has to do the same.
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

# --socket is still needed even though nothing here connects over it:
# mariadbd always binds one alongside TCP, and its compiled-in default
# (/run/mysqld/mysqld.sock) is not writable by a non-root uid -- "Bind on
# unix socket: No such file or directory", measured.
#
# --user=$(id -un) (task 29e, found by an actual run of tests/test-corpus.sh,
# which apt-get's mariadb-server and calls this script as --user 0 for that):
# mariadbd refuses to start as uid 0 at all without an explicit --user,
# aborting immediately with "Please consult the Knowledge Base to find out how
# to run mysqld as root!" -- a real MariaDB safety check, not a permissions
# bug, and every caller of this script that runs as www-data (Dockerfile.corpus
# itself, php/build.sh's training stage) already passes the implicit default,
# so this only changes behaviour for the root case, and never fails id -un.
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
