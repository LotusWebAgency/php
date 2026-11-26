#!/usr/bin/env bash
set -euo pipefail
IMAGE="${1:?usage: test-fpm-health.sh <image>}"
fail() { echo "FAIL: $*" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker-lib.sh
. "$HERE/docker-lib.sh"
name="fpm-health-$$"
downname="fpm-health-down-$$"
shimname="fpm-health-shim-$$"
portname="fpm-health-port-$$"
sockname="fpm-health-sock-$$"
v6name="fpm-health-v6-$$"
emname="fpm-health-emrestart-$$"
trap 'docker rm -f "$name" "$downname" "$shimname" "$portname" "$sockname" "$v6name" "$emname" >/dev/null 2>&1 || true' EXIT

wait_healthy() {
  local cname="$1" st=none
  for _ in $(seq 1 30); do
    st=$(docker inspect --format='{{.State.Health.Status}}' "$cname" 2>/dev/null || echo none)
    [ "$st" = healthy ] && return 0
    sleep 1
  done
  docker logs "$cname" >&2 || true
  fail "$cname never became healthy (status=$st)"
}

# probe <container> [VAR=value]...: runs php-fpm-healthcheck with the given
# environment; sets probe_rc and probe_err (stderr).
probe() {
  local cname="$1" args=()
  shift
  for kv in "$@"; do args+=(-e "$kv"); done
  set +e
  probe_err="$(docker exec "${args[@]}" "$cname" php-fpm-healthcheck 2>&1 >/dev/null)"
  probe_rc=$?
  set -e
}

drun -d --name "$name" "$IMAGE" >/dev/null
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
# own command is, so this still exercises the real php-fpm-healthcheck against a
# pool that is genuinely down (connection refused), not a mock.
drun -d --name "$downname" --entrypoint sleep "$IMAGE" 300 >/dev/null
status=none
for i in $(seq 1 60); do
  status=$(docker inspect --format='{{.State.Health.Status}}' "$downname" 2>/dev/null || echo none)
  [ "$status" = unhealthy ] && break
  sleep 1
done
[ "$status" = unhealthy ] || { docker logs "$downname"; fail "healthcheck never reported unhealthy with the pool down (status=$status after ${i}s)"; }
echo "ok: healthcheck reports unhealthy when the pool is down (after ${i}s)"

# The probe itself, run by hand against the live pool and the dead one: exit
# codes and the one-line stderr message the HEALTHCHECK log shows.
probe "$name"
[ "$probe_rc" -eq 0 ] && [ -z "$probe_err" ] || fail "php-fpm-healthcheck against the live pool exited $probe_rc: $probe_err"
echo "ok: php-fpm-healthcheck exits 0 silently against a healthy pool"

probe "$downname"
[ "$probe_rc" -eq 1 ] && grep -q 'did not answer' <<<"$probe_err" || fail "php-fpm-healthcheck against a stopped pool: rc=$probe_rc, stderr '$probe_err'"
echo "ok: php-fpm-healthcheck exits 1 against a stopped pool"

probe "$name" PHP_FPM_PING_RESPONSE=not-the-response
[ "$probe_rc" -eq 1 ] && grep -q 'unexpected ping response' <<<"$probe_err" || fail "a wrong expected response: rc=$probe_rc, stderr '$probe_err'"
[ "$(wc -l <<<"$probe_err")" -eq 1 ] || fail "the failure message is not one line: '$probe_err'"
echo "ok: php-fpm-healthcheck exits 1 with a one-line message on a wrong expected response"

probe "$name" PHP_FPM_PING_PATH=/no-such-ping
[ "$probe_rc" -eq 1 ] || fail "an unknown ping path exited $probe_rc, expected 1"
echo "ok: php-fpm-healthcheck exits 1 when the pool does not answer the ping path"

# 200 bytes is past 127, so the path goes out in the four-byte FastCGI length form.
long_ping_path="/$(head -c 200 /dev/zero | tr '\0' p)"
probe "$name" "PHP_FPM_PING_PATH=$long_ping_path"
[ "$probe_rc" -eq 1 ] && [ "$(wc -l <<<"$probe_err")" -eq 1 ] && [ -n "$probe_err" ] || fail "a 201-byte ping path: rc=$probe_rc, stderr '$probe_err'"
echo "ok: php-fpm-healthcheck sends a ping path over 127 bytes and exits 1 with one stderr line"

for listen in 0.0.0.0:9000 9000 '[::]:9000' localhost:9000; do
  probe "$name" "PHP_FPM_LISTEN=$listen"
  [ "$probe_rc" -eq 0 ] || fail "PHP_FPM_LISTEN=$listen against the live pool exited $probe_rc: $probe_err"
done
echo "ok: php-fpm-healthcheck reaches the pool through 0.0.0.0:PORT, PORT, [::]:PORT and HOST:PORT"

probe "$name" PHP_FPM_LISTEN=127.0.0.1:9999
[ "$probe_rc" -eq 1 ] || fail "a port nothing listens on exited $probe_rc, expected 1"
echo "ok: php-fpm-healthcheck exits 1 on a port nobody listens on"

# A pool bound to [::]: the probe must reach it through [::1], not only the v4 loopback.
if docker exec "$name" grep -q '^00000000000000000000000000000001 ' /proc/net/if_inet6; then
  drun -d --name "$v6name" -e 'PHP_FPM_LISTEN=[::]:9124' "$IMAGE" >/dev/null
  wait_healthy "$v6name"
  probe "$v6name" 'PHP_FPM_LISTEN=[::1]:9124'
  [ "$probe_rc" -eq 0 ] || fail "[::1]:9124 against a pool on [::]:9124 exited $probe_rc: $probe_err"
  echo "ok: php-fpm-healthcheck reaches a [::]:PORT pool through [::1]:PORT"
else
  echo "skip: no IPv6 loopback in the container, [::1]:PORT case not run"
fi

# A pool on a custom port and one on a unix socket: the baked HEALTHCHECK reads the
# same PHP_FPM_LISTEN the pool does, so both must go healthy on their own.
drun -d --name "$portname" -e PHP_FPM_LISTEN=127.0.0.1:9123 "$IMAGE" >/dev/null
wait_healthy "$portname"
probe "$portname"
[ "$probe_rc" -eq 0 ] || fail "custom port pool: php-fpm-healthcheck exited $probe_rc: $probe_err"
probe "$portname" PHP_FPM_LISTEN=127.0.0.1:9000
[ "$probe_rc" -eq 1 ] || fail "custom port pool: the default port answered ($probe_rc)"
echo "ok: php-fpm-healthcheck follows a custom PHP_FPM_LISTEN port"

drun -d --name "$sockname" -e PHP_FPM_LISTEN=/tmp/fpm.sock "$IMAGE" >/dev/null
wait_healthy "$sockname"
probe "$sockname"
[ "$probe_rc" -eq 0 ] || fail "unix socket pool: php-fpm-healthcheck exited $probe_rc: $probe_err"
probe "$sockname" PHP_FPM_LISTEN=unix:/tmp/fpm.sock
[ "$probe_rc" -eq 0 ] || fail "unix socket pool, unix: prefix: exited $probe_rc: $probe_err"
probe "$sockname" PHP_FPM_LISTEN=/tmp/no-such.sock
[ "$probe_rc" -eq 1 ] || fail "a missing unix socket exited $probe_rc, expected 1"
echo "ok: php-fpm-healthcheck speaks to a unix socket listen"

# A stand-in FastCGI server for what the live pool never does: stall, and answer
# in several records with padding. It reads the request up to the empty STDIN
# record, then plays MODE.
docker exec -i "$name" sh -c "cat > /tmp/fake-fcgi.php" <<'PHP'
<?php
list(, $port, $mode) = $argv;
$server = stream_socket_server("tcp://127.0.0.1:$port");
$conn = stream_socket_accept($server, 8);
if ($conn === false) {
    exit;
}
if ($mode === 'stall') {
    sleep(8);
    exit;
}
function readn($conn, $want)
{
    $buf = '';
    while (strlen($buf) < $want) {
        $chunk = fread($conn, $want - strlen($buf));
        if ($chunk === false || $chunk === '') {
            exit;
        }
        $buf .= $chunk;
    }
    return $buf;
}
while (true) {
    $h = unpack('Cver/Ctype/nid/nlen/Cpad/Cres', readn($conn, 8));
    if ($h['len'] + $h['pad'] > 0) {
        readn($conn, $h['len'] + $h['pad']);
    }
    if ($h['type'] === 5 && $h['len'] === 0) {
        break;
    }
}
function rec($type, $data, $pad = 0)
{
    return pack('CCnnCC', 1, $type, 1, strlen($data), $pad, 0) . $data . str_repeat("\0", $pad);
}
$end = rec(3, pack('NCCCCCC', 0, 0, 0, 0, 0, 0, 0));
if ($mode === 'split-match') {
    $out = rec(6, "Content-type: text/plain\r\n\r\npo") . rec(7, 'a warning', 7) . rec(6, 'ng') . rec(6, '') . $end;
} else {
    $first = $mode === 'multi-match' ? "Content-type: text/plain\r\n\r\npong" : "Content-type: text/plain\r\n\r\nnope";
    $out = rec(6, $first, 5);
    for ($i = 0; $i < 4; $i++) {
        $out .= rec(6, str_repeat('x', 65535), 1);
    }
    $out .= rec(7, 'a warning', 7) . rec(6, '') . $end;
}
fwrite($conn, $out);
fclose($conn);
PHP
fake_probe() {
  local mode="$1"
  set +e
  probe_out="$(docker exec "$name" sh -c "timeout 15 php -n /tmp/fake-fcgi.php 9100 $mode & sleep 1; start=\$(date +%s); \
    PHP_FPM_LISTEN=127.0.0.1:9100 php-fpm-healthcheck 2>&1; echo rc=\$? secs=\$((\$(date +%s) - start)); wait" 2>&1)"
  set -e
}

fake_probe stall
grep -q 'rc=1 ' <<<"$probe_out" && grep -q 'did not answer' <<<"$probe_out" || fail "a server that never answers: $probe_out"
secs="$(sed -n 's/.*secs=//p' <<<"$probe_out")"
[ "$secs" -le 3 ] || fail "a stalled server held the probe for $secs s, over the 3 s HEALTHCHECK timeout"
echo "ok: php-fpm-healthcheck gives up on a stalled server within the HEALTHCHECK timeout (${secs}s)"

fake_probe multi-match
grep -q '^rc=0 ' <<<"$probe_out" || fail "a padded multi-record response with the text in the first record: $probe_out"
echo "ok: php-fpm-healthcheck reads padded multi-record responses (over 256 KB) to END_REQUEST"

fake_probe split-match
grep -q '^rc=0 ' <<<"$probe_out" || fail "the expected text split across two STDOUT records: $probe_out"
echo "ok: php-fpm-healthcheck matches text split across STDOUT records"

fake_probe multi-miss
grep -q 'rc=1 ' <<<"$probe_out" && grep -q 'unexpected ping response' <<<"$probe_out" || fail "an oversized response without the text: $probe_out"
echo "ok: php-fpm-healthcheck rejects an oversized response without the expected text"

# The shim has to be proven in an actual FPM worker, not the CLI SAPI: `docker run
# -e PHP_CHMOD_SHIM=1 "$IMAGE" php -r '...'` overrides CMD and execs the php binary
# directly (the "docker exec php -r runs a separate CLI process" trap the error_log
# assertion below also routes around), which would prove the shim in a process
# PrestaShop never runs in. Route through php-fcgi against a live pool instead.
#
# `shimname` is a second container: LD_PRELOAD is exported once by the entrypoint at
# container start, so PHP_CHMOD_SHIM must be set before that container's php-fpm
# master (and every worker it forks) starts; it cannot be toggled against the running
# `$name` container the way SCRIPT_FILENAME can be varied per request. $name is
# already confirmed healthy; only the new container needs its own wait.
drun -d --name "$shimname" -e PHP_CHMOD_SHIM=1 "$IMAGE" >/dev/null
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
    php-fcgi 127.0.0.1:9000 | tr -d '\r' | sed '/^$/d' | tail -1
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
# error_log directive strings) never drives a real request. php-fcgi makes it
# possible to drive one through the live worker and prove the application's own
# error_log() output reaches `docker logs`, the only thing that proves errors escape
# the container (catch_workers_output otherwise swallows it into a private pipe).
marker="behavioral-errlog-$$"
docker exec "$name" sh -c "printf '<?php error_log(\"${marker}\");' > /tmp/errlog-test.php"
docker exec -e SCRIPT_FILENAME=/tmp/errlog-test.php -e SCRIPT_NAME=/errlog-test.php -e REQUEST_METHOD=GET "$name" \
  php-fcgi 127.0.0.1:9000 >/dev/null
found=0
for i in $(seq 1 10); do
  docker logs "$name" 2>&1 | grep -q "$marker" && { found=1; break; }
  sleep 1
done
[ "$found" = 1 ] || { docker logs "$name"; fail "application error_log() output never reached docker logs"; }
echo "ok: application error_log() output reaches docker logs (behavioral)"

# php-fcgi edge cases against the live pool: FastCGI length encoding, parameter
# records, multi-record responses, a body larger than memory_limit, -f and -t.
fcgi_script() {
  docker exec -i "$name" sh -c "cat > /tmp/$1"
}
fcgi_run() {
  local script="$1"
  shift
  docker exec -e "SCRIPT_FILENAME=/tmp/$script" -e "SCRIPT_NAME=/$script" -e REQUEST_METHOD=GET "$name" \
    php-fcgi "$@" 127.0.0.1:9000
}

# A name and a value over 127 bytes need the four-byte length encoding.
fcgi_script fcgi-long.php <<'PHP'
<?php
echo strlen($_SERVER['X_LONG_VALUE']), ',', isset($_SERVER[str_repeat('N', 130)]) ? 'name' : 'noname';
PHP
long_value="$(head -c 300 /dev/zero | tr '\0' a)"
long_name="$(head -c 130 /dev/zero | tr '\0' N)"
out="$(fcgi_run fcgi-long.php -p "X_LONG_VALUE=$long_value" -p "$long_name=1" | tr -d '\r')"
[ "$out" = "300,name" ] || fail "a 300-byte value and a 130-byte name did not survive: got '$out', expected '300,name'"
echo "ok: php-fcgi sends parameters over 127 bytes"

# 800 pairs of about 110 bytes are 88 KB: two FCGI_PARAMS records, and the cut
# between them has to fall between pairs.
fcgi_script fcgi-params.php <<'PHP'
<?php
$count = 0;
$bytes = 0;
foreach ($_SERVER as $key => $value) {
    if (strpos($key, 'BULK_PARAM_') === 0) {
        $count++;
        $bytes += strlen($value);
    }
}
echo $count, ',', $bytes;
PHP
bulk_value="$(head -c 100 /dev/zero | tr '\0' v)"
bulk_args=()
for i in $(seq 1 800); do
  bulk_args+=(-p "$(printf 'BULK_PARAM_%04d' "$i")=$bulk_value")
done
out="$(fcgi_run fcgi-params.php "${bulk_args[@]}" | tr -d '\r')"
[ "$out" = "800,80000" ] || fail "800 parameters over two records did not all arrive: got '$out', expected '800,80000'"
echo "ok: php-fcgi splits 88 KB of parameters across records between pairs"

# 320,000 bytes of response is five FCGI_STDOUT records at least.
fcgi_script fcgi-big.php <<'PHP'
<?php
for ($i = 0; $i < 40000; $i++) {
    printf("%07d\n", $i);
}
PHP
want="$(seq -f '%07g' 0 39999 | md5sum | cut -d' ' -f1)"
got="$(fcgi_run fcgi-big.php | md5sum | cut -d' ' -f1)"
[ "$got" = "$want" ] || fail "a 320,000-byte multi-record response arrived altered: md5 $got, expected $want"
echo "ok: php-fcgi reassembles a multi-record response"

# A 50 MB body is past php -n's 128M memory_limit once it is buffered and copied;
# streamed, it goes through in 64 KB records.
fcgi_script fcgi-post.php <<'PHP'
<?php
$in = fopen('php://input', 'rb');
$hash = hash_init('md5');
$size = 0;
while (!feof($in)) {
    $data = fread($in, 65536);
    $size += strlen($data);
    hash_update($hash, $data);
}
echo $size, ' ', hash_final($hash);
PHP
post_file="$(mktemp)"
head -c 52428800 /dev/urandom > "$post_file"
want="52428800 $(md5sum "$post_file" | cut -d' ' -f1)"
set +e
got="$(docker exec -i -e SCRIPT_FILENAME=/tmp/fcgi-post.php -e SCRIPT_NAME=/fcgi-post.php -e REQUEST_METHOD=POST \
  -e CONTENT_TYPE=application/octet-stream -e CONTENT_LENGTH=52428800 "$name" \
  php-fcgi -t 60 -p PHP_VALUE=post_max_size=64M 127.0.0.1:9000 < "$post_file" | tr -d '\r')"
rc=$?
set -e
rm -f "$post_file"
[ "$rc" -eq 0 ] && [ "$got" = "$want" ] || fail "a 50 MB POST body did not arrive intact (rc=$rc): got '$got', expected '$want'"
echo "ok: php-fcgi streams a 50 MB request body"

# -f: exit 22 on an error status, with the body still printed; 0 otherwise.
fcgi_script fcgi-status.php <<'PHP'
<?php
http_response_code((int) $_SERVER['X_STATUS']);
echo 'status body';
PHP
for code in 404 500 200; do
  expect_rc=22
  [ "$code" = 200 ] && expect_rc=0
  set +e
  out="$(fcgi_run fcgi-status.php -f -p "X_STATUS=$code" 2>/dev/null | tr -d '\r')"
  rcs=("${PIPESTATUS[@]}")
  set -e
  [ "${rcs[0]}" -eq "$expect_rc" ] || fail "php-fcgi -f on a $code response exited ${rcs[0]}, expected $expect_rc"
  [ "$out" = "status body" ] || fail "php-fcgi -f on a $code response printed '$out'"
done
echo "ok: php-fcgi -f exits 22 on 404 and 500, 0 on 200, and still prints the body"

# -t: a script slower than the deadline is exit 1, not a hang.
fcgi_script fcgi-slow.php <<'PHP'
<?php
sleep(5);
echo 'late';
PHP
start=$SECONDS
set +e
err="$(fcgi_run fcgi-slow.php -t 1 2>&1 >/dev/null)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "php-fcgi -t 1 against a 5 s script exited $rc, expected 1"
grep -q 'timed out' <<<"$err" || fail "php-fcgi -t 1 timeout message is '$err'"
[ $((SECONDS - start)) -lt 4 ] || fail "php-fcgi -t 1 took $((SECONDS - start)) s to give up"
echo "ok: php-fcgi -t exits 1 on a timeout"

# Emergency restart: workers dying on SIGSEGV (a crashing JIT or extension) past the
# threshold within the interval make the master reload instead of respawning into the
# same failure. Threshold 3 keeps the test short; the master keeps its PID across a
# reload, the workers do not, and the pool has to serve again afterwards.
drun -d --name "$emname" -m 512m -e PHP_FPM_EMERGENCY_RESTART_THRESHOLD=3 -e PHP_FPM_EMERGENCY_RESTART_INTERVAL=30s "$IMAGE" >/dev/null
wait_healthy "$emname"
docker exec -i "$emname" sh -c 'cat > /tmp/em-ok.php' <<'PHP'
<?php
echo 'serving ', getmypid();
PHP
em_get() {
  docker exec -e SCRIPT_FILENAME=/tmp/em-ok.php -e SCRIPT_NAME=/em-ok.php -e REQUEST_METHOD=GET "$emname" \
    php-fcgi -f -t 10 127.0.0.1:9000 | tr -d '\r'
}
em_get | grep -q '^serving [0-9]' || fail "emergency restart: the pool did not serve before the test"
master_pid="$(docker exec "$emname" pgrep -f 'php-fpm: master process' | head -n1)"
workers_before="$(docker exec "$emname" pgrep -f 'php-fpm: pool www' | sort | tr '\n' ' ')"
[ -n "$master_pid" ] && [ -n "$workers_before" ] || fail "emergency restart: no master/worker processes found"
reloaded=0
for _ in 1 2 3 4 5 6; do
  docker exec "$emname" sh -c 'for p in $(pgrep -f "php-fpm: pool www"); do kill -SEGV "$p"; done' || true
  sleep 1
  if docker logs "$emname" 2>&1 | grep -q 'failed processes threshold (3 in 30 sec) is reached, initiating reload'; then reloaded=1; break; fi
done
[ "$reloaded" = 1 ] || { docker logs "$emname" >&2; fail "emergency restart: SIGSEGV on the workers did not trigger the master's reload"; }
wait_healthy "$emname"
for _ in $(seq 1 20); do em_get | grep -q '^serving [0-9]' && break; sleep 1; done
em_get | grep -q '^serving [0-9]' || { docker logs "$emname" >&2; fail "emergency restart: the pool did not serve after the reload"; }
[ "$(docker exec "$emname" pgrep -f 'php-fpm: master process' | head -n1)" = "$master_pid" ] \
  || fail "emergency restart: the master PID changed (the container would have restarted, not php-fpm reloaded)"
[ "$(docker exec "$emname" pgrep -f 'php-fpm: pool www' | sort | tr '\n' ' ')" != "$workers_before" ] \
  || fail "emergency restart: the workers are the ones that were killed"
echo "ok: SIGSEGV workers past PHP_FPM_EMERGENCY_RESTART_THRESHOLD make the master reload and the pool serves again"

echo "FPM HEALTH TESTS PASSED"
