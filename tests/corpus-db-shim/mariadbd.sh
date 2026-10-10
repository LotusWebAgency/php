#!/bin/sh
# db-up.sh insists on finding a mariadbd/mysqld before it pings, and the runtime
# -fpm images ship neither. Mounted at /usr/local/bin/mariadbd by
# tests/test-corpus-tiers.sh. It is only reached when the ping against the
# sidecar failed, i.e. the sidecar database is not up: there is deliberately no
# server in the replay container to fall back on.
echo "FATAL: the sidecar database does not answer on 127.0.0.1:13306, and the replay container has no mariadbd of its own" >&2
exit 1
