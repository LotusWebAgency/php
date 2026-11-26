#!/usr/bin/env bash
# Runs php-fpm with the image's default JIT under the two situations that have crashed
# workers in generated code: opcache restarts and a full opcache. Pass = no worker died
# abnormally (no SIGSEGV, SIGBUS or non-zero exit in the pool's log, no emergency
# restart) and no request got anything but a correct 2xx answer.
#
#   tests/test-jit-stress.sh <image> [--informational]
#
#   reset  concurrent load on JIT-heavy scripts while another client calls
#          opcache_reset() in a loop, with the opcache size the entrypoint picks
#   full   an opcache too small for the scripts, with their mtimes changing under it
#          (wasted memory, so cache_full and oom restarts)
#   full-reset  the same with opcache_reset() every few seconds on top
#
# --informational is for versions whose JIT is off by default (8.0, 8.1): it turns the
# JIT on, prints the same verdict and always exits 0. A scenario must also exercise what
# it claims to (resets or restarts happened, JIT code was compiled), or it fails: a
# stress run that never reached the risky path proves nothing.
#
# Environment: JIT_STRESS_SECONDS (per scenario, default 75), JIT_STRESS_CLIENTS
# (default 12), JIT_STRESS_KEEP=1 (keep the containers).
set -euo pipefail
IMAGE="${1:?usage: test-jit-stress.sh <image> [--informational]}"
INFORMATIONAL=0
[ "${2:-}" != --informational ] || INFORMATIONAL=1
SECS="${JIT_STRESS_SECONDS:-75}"
CLIENTS="${JIT_STRESS_CLIENTS:-12}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker-lib.sh
. "$HERE/docker-lib.sh"

failures=()
note_fail() { failures+=("$1"); echo "FAIL: $1" >&2; }
names=()
cleanup() { [ "${JIT_STRESS_KEEP:-0}" = 1 ] || { [ "${#names[@]}" -eq 0 ] || docker rm -f "${names[@]}" >/dev/null 2>&1 || true; }; }
trap cleanup EXIT

fcgi() {  # fcgi <container> <script>
  docker exec -e "SCRIPT_FILENAME=/tmp/jit/$2" -e "SCRIPT_NAME=/$2" -e REQUEST_METHOD=GET "$1" \
    php-fcgi -f -t 30 127.0.0.1:9000
}

# scenario <label> <files> <pad> <need> <reset> <churn> [docker run args]
scenario() {
  local label="$1" files="$2" pad="$3" need="$4" reset="$5" churn="$6" cname st healthy="none" out log
  shift 6
  cname="php-jit-stress-$label-$$"
  names+=("$cname")
  echo "--- $label: $files scripts, ${SECS}s, $CLIENTS clients, $([ "$reset" = 0 ] && echo 'no opcache_reset()' || echo "opcache_reset() every ${reset}s"), $([ "$churn" = 0 ] && echo 'no mtime churn' || echo "mtime churn $churn per 0.2s")"
  drun -d --label claude.adhoc=1 --name "$cname" -m 1g -e PHP_FPM_MAX_CHILDREN=8 "$@" "$IMAGE" >/dev/null
  for _ in $(seq 1 30); do
    healthy=$(docker inspect --format='{{.State.Health.Status}}' "$cname" 2>/dev/null || echo none)
    [ "$healthy" = healthy ] && break
    sleep 1
  done
  [ "$healthy" = healthy ] || { docker logs "$cname" >&2 || true; note_fail "$label: the pool never became healthy"; return 0; }

  tar -C "$HERE/fixtures" -c jit-stress | docker exec -i "$cname" tar -x -C /tmp
  docker exec "$cname" sh -c 'rm -rf /tmp/jit && mv /tmp/jit-stress /tmp/jit'
  docker exec "$cname" php -n /tmp/jit/gen.php /tmp/jit "$files" 1500 "$pad" >/dev/null
  # Warm the pool so the first revalidation window does not race the generator.
  fcgi "$cname" run.php >/dev/null 2>&1 || true

  st="$(fcgi "$cname" status.php | tr -d '\r')"
  python3 -c '
import json, sys
s = json.loads(sys.argv[1])
j = s["jit"] or {}
print("jit: enabled=%s on=%s kind=%s buffer=%s" % (j.get("enabled"), j.get("on"), j.get("kind"), j.get("buffer_size")))
print("opcache: memory used=%s free=%s wasted%%=%.1f" % (s["memory"]["used_memory"], s["memory"]["free_memory"], s["memory"]["current_wasted_percentage"]))
' "$st"
  if ! python3 -c 'import json,sys; j=json.loads(sys.argv[1])["jit"] or {}; sys.exit(0 if j.get("enabled") and j.get("on") else 1)' "$st"; then
    if [ "$INFORMATIONAL" = 1 ]; then
      echo "note: $label: this build has no usable JIT, nothing to stress"
      return 0
    fi
    note_fail "$label: the JIT is not on in the image's default configuration: $st"
    return 0
  fi

  out="$(docker exec "$cname" bash /tmp/jit/driver.sh /tmp/jit "$SECS" "$CLIENTS" "$reset" "$churn" "$files" 2>&1 || true)"
  echo "$out" | sed 's/^/    /'
  st="$(fcgi "$cname" status.php | tr -d '\r')"
  log="$(docker logs "$cname" 2>&1)"

  local requests bad resets abnormal before=${#failures[@]}
  requests="$(grep -oE 'requests=[0-9]+' <<<"$out" | tail -n1 | cut -d= -f2 || true)"
  bad="$(grep -oE 'bad=[0-9]+' <<<"$out" | tail -n1 | cut -d= -f2 || true)"
  resets="$(grep -oE 'resets=[0-9]+' <<<"$out" | tail -n1 | cut -d= -f2 || true)"
  abnormal="$(grep -E 'exited on signal|exited with code [1-9]|SIGSEGV|SIGBUS|SIGABRT|failed processes threshold|segfault' <<<"$log" || true)"
  [ -n "$requests" ] && [ -n "$bad" ] || { note_fail "$label: the load driver reported nothing: $out"; return 0; }

  python3 -c '
import json, sys
s = json.loads(sys.argv[1])
st, j, m = s["stats"], s["jit"] or {}, s["memory"]
print("    after: manual_restarts=%s oom_restarts=%s hash_restarts=%s cache_full=%s jit_buffer_free=%s/%s wasted=%.1f%%" % (
    st["manual_restarts"], st["oom_restarts"], st["hash_restarts"], s["full"], j.get("buffer_free"), j.get("buffer_size"), m["current_wasted_percentage"]))
' "$st"

  [ "$bad" = 0 ] || note_fail "$label: $bad of $requests requests failed or answered wrongly"
  [ -z "$abnormal" ] || { echo "$abnormal" | head -n 12 | sed 's/^/    log: /' >&2; note_fail "$label: workers died abnormally ($(grep -c . <<<"$abnormal") log lines)"; }
  [ "$requests" -ge 200 ] || note_fail "$label: only $requests requests in ${SECS}s, too few to prove anything"
  case "$need" in
    resets)
      [ "${resets:-0}" -ge 10 ] || note_fail "$label: only ${resets:-0} opcache_reset() calls succeeded, the restart path was not exercised"
      python3 -c 'import json,sys; s=json.loads(sys.argv[1]); sys.exit(0 if s["stats"]["manual_restarts"] >= 5 else 1)' "$st" \
        || note_fail "$label: opcache recorded fewer than 5 manual restarts, the restart path was not exercised" ;;
    full)
      python3 -c 'import json,sys; s=json.loads(sys.argv[1]); t=s["stats"]; sys.exit(0 if t["oom_restarts"] + t["hash_restarts"] >= 1 or s["full"] else 1)' "$st" \
        || note_fail "$label: the opcache never filled up (no oom restart, not full), the full-cache path was not exercised" ;;
  esac
  python3 -c 'import json,sys; j=json.loads(sys.argv[1])["jit"]; sys.exit(0 if j["buffer_free"] < j["buffer_size"] else 1)' "$st" \
    || note_fail "$label: no JIT code in the buffer at the end, the JIT was not exercised"
  [ "${#failures[@]}" -gt "$before" ] || echo "ok: $label: $requests requests, no failures, no abnormal worker exits"
}

jit_env=()
[ "$INFORMATIONAL" = 0 ] || jit_env=(-e PHP_OPCACHE_JIT=tracing)

scenario reset 60 8 resets 0.3 0 "${jit_env[@]}"
scenario full 400 60 full 0 8 -e PHP_OPCACHE_MEMORY=16 "${jit_env[@]}"
scenario full-reset 400 60 full 4 8 -e PHP_OPCACHE_MEMORY=16 "${jit_env[@]}"

if [ "${#failures[@]}" -gt 0 ]; then
  if [ "$INFORMATIONAL" = 1 ]; then
    echo "INFORMATIONAL: JIT stress found ${#failures[@]} problem(s) with the JIT forced on (it is off by default on this version): ${failures[*]}"
    exit 0
  fi
  echo "JIT STRESS TESTS FAILED (${#failures[@]})" >&2
  exit 1
fi
echo "JIT STRESS TESTS PASSED"
