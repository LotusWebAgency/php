#!/usr/bin/env bash
# Stop the mariadbd db-up.sh started, if any. Safe to call when it is not
# running (e.g. a caller that never needed the database).
set -euo pipefail
HOST=127.0.0.1
PORT=13306
RUNPIDFILE=/tmp/ps-corpus-mysql.runner.pid

if mysqladmin --host="$HOST" --port="$PORT" --protocol=tcp ping >/dev/null 2>&1; then
  mysqladmin --host="$HOST" --port="$PORT" --protocol=tcp shutdown
fi
if [ -f "$RUNPIDFILE" ]; then
  pid="$(cat "$RUNPIDFILE")"
  wait "$pid" 2>/dev/null || true
fi
rm -f /tmp/ps-corpus-mysql.pid "$RUNPIDFILE"
echo "ok: mariadbd stopped"
