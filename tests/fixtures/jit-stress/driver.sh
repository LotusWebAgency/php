#!/usr/bin/env bash
# Runs inside the container under test: CLIENTS request loops against the pool on
# 127.0.0.1:9000, one loop calling opcache_reset() every RESET seconds (0 = none), and
# one loop giving CHURN scripts a new mtime every 0.2 s (0 = none), for SECONDS seconds.
# Prints one line, "requests=N bad=N resets=N", and a line per bad response on stderr.
#
#   driver.sh DIR SECONDS CLIENTS RESET CHURN FILES
set -u
dir="$1" secs="$2" clients="$3" reset="$4" churn="$5" files="$6"
res="$dir/res"
rm -rf "$res"
mkdir -p "$res"
end=$((SECONDS + secs))
export REQUEST_METHOD=GET

fcgi() {  # fcgi <script> [php-fcgi args]
  local script="$1"
  shift
  SCRIPT_FILENAME="$dir/$script" SCRIPT_NAME="/$script" php-fcgi -f -t 30 "$@" 127.0.0.1:9000
}

client() {
  local id="$1" n=0 bad=0 out rc
  while [ "$SECONDS" -lt "$end" ]; do
    n=$((n + 1))
    out="$(fcgi run.php -p "X_SEED=$((id * 1000003 + n))" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ] || [ "$out" != OK ]; then
      bad=$((bad + 1))
      [ "$bad" -gt 5 ] || echo "client $id request $n: rc=$rc ${out:0:200}" >&2
    fi
  done
  echo "$n $bad" >"$res/client-$id"
}

resetter() {
  local n=0
  while [ "$SECONDS" -lt "$end" ]; do
    fcgi reset.php >/dev/null 2>&1 && n=$((n + 1))
    sleep "$reset"
  done
  echo "$n" >"$res/resets"
}

churner() {
  while [ "$SECONDS" -lt "$end" ]; do
    php -n "$dir/churn.php" "$dir" "$files" "$churn"
    sleep 0.2
  done
}

for id in $(seq 1 "$clients"); do client "$id" & done
[ "$reset" = 0 ] || resetter &
[ "$churn" = 0 ] || churner &
wait

requests=0 bad=0 resets=0
for f in "$res"/client-*; do
  read -r n b <"$f"
  requests=$((requests + n))
  bad=$((bad + b))
done
[ ! -f "$res/resets" ] || read -r resets <"$res/resets"
echo "requests=$requests bad=$bad resets=$resets"
