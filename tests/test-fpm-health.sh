#!/usr/bin/env bash
set -euo pipefail
IMAGE="${1:?usage: test-fpm-health.sh <image>}"
fail() { echo "FAIL: $*" >&2; exit 1; }
name="fpm-health-$$"
downname="fpm-health-down-$$"
shimname="fpm-health-shim-$$"
trap 'docker rm -f "$name" "$downname" "$shimname" >/dev/null 2>&1 || true' EXIT

docker run -d --name "$name" "$IMAGE" >/dev/null
for i in $(seq 1 30); do
  status=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo none)
  [ "$status" = healthy ] && break
  [ "$status" = unhealthy ] && { docker logs "$name"; fail "container went unhealthy"; }
  sleep 1
done
[ "$status" = healthy ] || { docker logs "$name"; fail "never became healthy (status=$status)"; }
echo "ok: healthy after ${i}s"

docker logs "$name" 2>&1 | grep -iE 'fatal|segfault|core dumped' && fail "critical errors in log"
echo "ok: clean startup log"

# The healthcheck has to prove the negative too, not just the positive --
# override the entrypoint so php-fpm never starts. HEALTHCHECK is baked into
# the image and keeps running inside the container regardless of what its
# own command is, so this still exercises the real vendored
# php-fpm-healthcheck against a pool that is genuinely down (cgi-fcgi
# refusing to connect), not a mock.
docker run -d --name "$downname" --entrypoint sleep "$IMAGE" 300 >/dev/null
status=none
for i in $(seq 1 60); do
  status=$(docker inspect --format='{{.State.Health.Status}}' "$downname" 2>/dev/null || echo none)
  [ "$status" = unhealthy ] && break
  sleep 1
done
[ "$status" = unhealthy ] || { docker logs "$downname"; fail "healthcheck never reported unhealthy with the pool down (status=$status after ${i}s)"; }
echo "ok: healthcheck reports unhealthy when the pool is down (after ${i}s)"

# The shim has to be proven in an actual FPM worker, not the CLI SAPI: `docker run
# -e PHP_CHMOD_SHIM=1 "$IMAGE" php -r '...'` overrides CMD and execs the php binary
# directly (the "docker exec php -r runs a separate CLI process" trap the error_log
# assertion below also routes around), which would prove the shim in a process
# PrestaShop never runs in. Route through cgi-fcgi against a live pool instead.
#
# `shimname` is a second container: LD_PRELOAD is exported once by the entrypoint at
# container start, so PHP_CHMOD_SHIM must be set before that container's php-fpm
# master (and every worker it forks) starts; it cannot be toggled against the running
# `$name` container the way SCRIPT_FILENAME can be varied per request. $name is
# already confirmed healthy; only the new container needs its own wait.
docker run -d --name "$shimname" -e PHP_CHMOD_SHIM=1 "$IMAGE" >/dev/null
for i in $(seq 1 30); do
  st=$(docker inspect --format='{{.State.Health.Status}}' "$shimname" 2>/dev/null || echo none)
  [ "$st" = healthy ] && break
  sleep 1
done
[ "$st" = healthy ] || { docker logs "$shimname"; fail "$shimname never became healthy (status=$st)"; }

chmod_probe='<?php $f = tempnam(sys_get_temp_dir(), "t"); chmod($f, 0); echo substr(sprintf("%o", fileperms($f)), -4);'
run_chmod_probe() {
  local cname="$1"
  docker exec -i "$cname" sh -c "cat > /tmp/chmod-probe.php" <<<"$chmod_probe"
  docker exec -e SCRIPT_FILENAME=/tmp/chmod-probe.php -e SCRIPT_NAME=/chmod-probe.php -e REQUEST_METHOD=GET "$cname" \
    cgi-fcgi -bind -connect 127.0.0.1:9000 | tr -d '\r' | sed '/^$/d' | tail -1
}

set +e
out="$(run_chmod_probe "$shimname")"
rc=$?
set -e
[ "$rc" -eq 0 ] && [ "$out" = "0644" ] || fail "chmod shim inactive in a real FPM worker: got '$out' (rc=$rc), expected 0644"
echo "ok: chmod shim active in a live FPM worker under PHP_CHMOD_SHIM=1"

set +e
out="$(run_chmod_probe "$name")"
rc=$?
set -e
[ "$rc" -eq 0 ] && [ "$out" = "0000" ] || fail "chmod shim active in a real FPM worker without opt-in: got '$out' (rc=$rc)"
echo "ok: chmod shim inert in a live FPM worker by default"

# error_log() from a live worker: a config assertion (smoke.sh checks the ini/global
# error_log directive strings) never drives a real request. libfcgi-bin makes it
# possible to drive one through the live worker and prove the application's own
# error_log() output reaches `docker logs`, the only thing that proves errors escape
# the container (catch_workers_output otherwise swallows it into a private pipe).
marker="behavioral-errlog-$$"
docker exec "$name" sh -c "printf '<?php error_log(\"${marker}\");' > /tmp/errlog-test.php"
docker exec -e SCRIPT_FILENAME=/tmp/errlog-test.php -e SCRIPT_NAME=/errlog-test.php -e REQUEST_METHOD=GET "$name" \
  cgi-fcgi -bind -connect 127.0.0.1:9000 >/dev/null
found=0
for i in $(seq 1 10); do
  docker logs "$name" 2>&1 | grep -q "$marker" && { found=1; break; }
  sleep 1
done
[ "$found" = 1 ] || { docker logs "$name"; fail "application error_log() output never reached docker logs"; }
echo "ok: application error_log() output reaches docker logs (behavioral)"

echo "FPM HEALTH TESTS PASSED"
