#!/usr/bin/env bash
# Read-only root filesystem: `docker run --read-only --tmpfs /tmp` is the
# documented deployment shape, and /tmp is the whole writable set. Measured, not
# assumed -- a full workload on a writable container (session, upload,
# PHP_EXT_ENABLE, PHP_SNUFFLEUPAGUS, healthcheck) leaves `docker diff` with only
# /usr/local/etc/php/conf.d (which docker-php-entrypoint redirects into a private
# /tmp directory when it is not writable) and /tmp (sessions, upload temp files).
#
#   ./tests/test-readonly.sh <image> <flavor>      flavor: fpm | cli | cli-builder
#
# Where an assertion depends on /tmp being writable it has a control that proves
# the same check fails without it: PHP_EXT_ENABLE's refusal, the cli session and
# temp file program, the cli-builder project directory, the fpm request, and
# npx's need for an exec /tmp. Two checks have no such control and say so:
# opcache (shared memory, needs no path at all) and net-snmp (its state
# directory is pre-created in the image), so they show only that nothing there
# writes to the read-only rootfs, not that the check could have caught it.
#
# Every container command runs under `timeout` inside the container (a host-side
# timeout would only kill the docker client). The two detached fpm containers
# are the exception: the entrypoint branches on php-fpm being its first argument,
# so wrapping it would skip the very startup checks under test; the EXIT trap
# removes them.
set -euo pipefail
IMAGE="${1:?usage: test-readonly.sh <image> <flavor>}"
FLAVOR="${2:?usage: test-readonly.sh <image> <flavor>}"
case "$FLAVOR" in
  fpm|cli|cli-builder) ;;
  *) echo "FAIL: flavor '$FLAVOR' is not one of fpm, cli, cli-builder" >&2; exit 1 ;;
esac
fail() { echo "FAIL: $*" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/docker-lib.sh
. "$HERE/docker-lib.sh"

RO=(--read-only --tmpfs /tmp -m 512m)
# /tmp mounted exec: cli-builder's npx unpacks packages to /tmp/npm/_npx and runs
# them from there; the Docker default (noexec) makes that fail with EACCES.
RO_EXEC=(--read-only --tmpfs /tmp:exec -m 512m)
# What a failed write under a read-only rootfs looks like in PHP, net-snmp,
# npm and composer output alike.
WRITE_ERR='read-only file system|permission denied|failed to open stream|unable to (create|write|open)|cannot (create|open|write)|EROFS|Created directory'

EXTDIR=$(drun --rm "$IMAGE" timeout 20 php -r 'echo ini_get("extension_dir");')
has_ext() { drun --rm "$IMAGE" timeout 20 test -f "${EXTDIR}/$1.so"; }

# Every flavor, every combination: refusing loudly is the documented failure
# mode when there is nowhere to put the env-driven ini. Control for everything
# below -- without /tmp, PHP_EXT_ENABLE cannot be honored and the container says
# so and exits instead of starting without the extension.
set +e
out=$(drun --rm --read-only -m 512m -e PHP_EXT_ENABLE=bz2 "$IMAGE" timeout 20 php -v 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "$FLAVOR: --read-only without a writable /tmp started although PHP_EXT_ENABLE=bz2 could not be applied: $out"
grep -q "PHP_EXT_ENABLE=bz2 requested but no writable ini directory" <<<"$out" \
  || fail "$FLAVOR: --read-only without /tmp refused PHP_EXT_ENABLE, but not with the branded diagnostic: $out"
echo "ok: $FLAVOR -- control: --read-only without /tmp refuses PHP_EXT_ENABLE loudly (exit $rc), never silently"

# ------------------------------------------------------------------ cli side
# One PHP program for the cli and cli-builder flavors: session round trip,
# temp file, the env-driven ini and the opted-in extension.
cli_php='
session_start();
$_SESSION["k"] = "v"; $id = session_id(); session_write_close();
$_SESSION = []; session_id($id); session_start();
echo "SESSION=", $_SESSION["k"] ?? "lost", "\n"; session_write_close();
$t = tempnam(sys_get_temp_dir(), "ro");
echo "TEMPFILE=", ($t !== false && file_put_contents($t, "x") === 1) ? "ok" : "bad", "\n"; @unlink($t);
echo "MEM=", ini_get("memory_limit"), "\n";
echo "BZ2=", extension_loaded("bz2") ? "y" : "n", "\n";
'
if [ "$FLAVOR" != fpm ]; then
  out=$(drun --rm "${RO[@]}" -e PHP_MEMORY_LIMIT=321M -e PHP_EXT_ENABLE=bz2 "$IMAGE" timeout 20 php -d session.use_cookies=0 -r "$cli_php" 2>&1)
  for want in "SESSION=v" "TEMPFILE=ok" "MEM=321M" "BZ2=y"; do
    grep -qx "$want" <<<"$out" || fail "$FLAVOR: read-only cli: expected '$want': $out"
  done
  ! grep -qiE "$WRITE_ERR" <<<"$out" || fail "$FLAVOR: read-only cli printed a write error: $out"
  echo "ok: $FLAVOR -- read-only cli: PHP_MEMORY_LIMIT and PHP_EXT_ENABLE apply, session round trip and temp file work, no write errors"

  # Control: the same program without /tmp. The session cannot be written and
  # PHP says why; if it passed here the assertions above would prove nothing.
  out=$(drun --rm --read-only -m 512m "$IMAGE" timeout 20 php -d session.use_cookies=0 -r "$cli_php" 2>&1 || true)
  grep -qx "SESSION=lost" <<<"$out" || fail "$FLAVOR: control: the session survived a read-only rootfs without /tmp: $out"
  grep -qi "read-only file system" <<<"$out" || fail "$FLAVOR: control: a failed session write was not reported: $out"
  echo "ok: $FLAVOR -- control: without /tmp the same program loses its session and says 'Read-only file system'"

  # opcache is a shared-memory mapping, not a file: it needs no writable path.
  out=$(drun --rm "${RO[@]}" "$IMAGE" timeout 20 sh -c '
    echo "<?php function ro_probe() { return 1; }" > /tmp/ro-inc.php
    cat > /tmp/ro-main.php <<"EOF"
<?php
require "/tmp/ro-inc.php"; ro_probe();
$s = opcache_get_status(false);
echo "OPCACHE=", $s["opcache_enabled"] ? "on" : "off", " CACHED=", $s["opcache_statistics"]["num_cached_scripts"], "\n";
EOF
    php -d opcache.enable_cli=1 -d opcache.file_update_protection=0 /tmp/ro-main.php' 2>&1) \
    || fail "$FLAVOR: the opcache probe did not run under --read-only: $out"
  grep -qE '^OPCACHE=on CACHED=[1-9]' <<<"$out" || fail "$FLAVOR: opcache is not caching scripts under --read-only: $out"
  echo "ok: $FLAVOR -- opcache caches scripts under --read-only"

  if has_ext snmp; then
    out=$(drun --rm "${RO[@]}" -e PHP_EXT_ENABLE=snmp "$IMAGE" timeout 20 php -r '
      $s = new SNMP(SNMP::VERSION_3, "127.0.0.1", "u");
      $s->setSecurity("authPriv", "SHA", "authpass12345", "AES", "privpass12345");
      $s->timeout = 100000; $s->retries = 0;
      @$s->get("1.3.6.1.2.1.1.1.0");
      echo "SNMP_DONE\n";' 2>&1)
    grep -qx "SNMP_DONE" <<<"$out" || fail "$FLAVOR: net-snmp v3 session did not run under --read-only: $out"
    ! grep -qiE "$WRITE_ERR" <<<"$out" || fail "$FLAVOR: net-snmp complained about its state directory under --read-only: $out"
    echo "ok: $FLAVOR -- net-snmp (/var/lib/snmp is pre-created, no tmpfs needed) is silent under --read-only"
  fi
fi

if [ "$FLAVOR" = cli-builder ]; then
  # The documented builder tasks: composer and npm, caches in /tmp
  # (COMPOSER_HOME/npm_config_cache/COREPACK_HOME), the project on a writable
  # volume. /app stands in for the bind mount. The container has no network, so
  # nothing here may reach a registry: npm's audit, fund notice and update check
  # and composer's network are switched off rather than left to time out.
  out=$(drun --rm "${RO[@]}" -e NPM_CONFIG_UPDATE_NOTIFIER=false -e COMPOSER_DISABLE_NETWORK=1 \
    --tmpfs /app:exec,uid=33,gid=33 "$IMAGE" timeout 60 bash -c '
    set -e
    cd /app
    mkdir lp && printf "{\"name\":\"lp\",\"version\":\"1.0.0\",\"bin\":{\"lp\":\"cli.js\"}}" > lp/package.json
    printf "#!/usr/bin/env node\nconsole.log(\"LP_RAN\")\n" > lp/cli.js && chmod +x lp/cli.js
    npm init -y >/dev/null
    npm install --offline --no-audit --no-fund ./lp >/dev/null
    npx --no-install lp
    composer init -n --name=ro/probe >/dev/null
    composer install --no-interaction
    test -f vendor/autoload.php && echo AUTOLOAD_OK
    corepack --version >/dev/null && echo COREPACK_OK
    ls /tmp' 2>&1)
  for want in LP_RAN AUTOLOAD_OK COREPACK_OK; do
    grep -qx "$want" <<<"$out" || fail "cli-builder: read-only npm/composer task: expected '$want': $out"
  done
  grep -qx npm <<<"$out" && grep -qx composer <<<"$out" \
    || fail "cli-builder: composer/npm caches did not land under /tmp (COMPOSER_HOME, npm_config_cache): $out"
  ! grep -qiE "$WRITE_ERR" <<<"$out" || fail "cli-builder: read-only npm/composer task printed a write error: $out"
  echo "ok: cli-builder -- composer install and npm install/npx run read-only with /tmp for caches and a writable project dir"

  # Control: same task with the project directory left read-only fails loudly.
  set +e
  out=$(drun --rm "${RO[@]}" "$IMAGE" timeout 20 bash -c 'cd /app && npm init -y' 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cli-builder: control: npm init succeeded in a read-only /app: $out"
  grep -qiE "EROFS|read-only file system" <<<"$out" || fail "cli-builder: control: npm init in a read-only /app failed without naming the cause: $out"
  echo "ok: cli-builder -- control: a read-only project directory fails loudly (EROFS), so /app must be a volume"

  # npx unpacks a package into /tmp/npm/_npx and executes its bin from there, so
  # cli-builder is the one flavor whose /tmp has to be mounted exec. Offline: the
  # package is packed from a local directory and installed from its tarball.
  npx_task='set -e
    cd /app
    mkdir lp && printf "{\"name\":\"lp\",\"version\":\"1.0.0\",\"bin\":{\"lp\":\"cli.js\"}}" > lp/package.json
    printf "#!/usr/bin/env node\nconsole.log(\"LP_RAN\")\n" > lp/cli.js && chmod +x lp/cli.js
    (cd lp && npm pack --silent >/dev/null)
    npx --yes --offline --package=/app/lp/lp-1.0.0.tgz lp'
  out=$(drun --rm "${RO_EXEC[@]}" --tmpfs /app:exec,uid=33,gid=33 "$IMAGE" timeout 60 bash -c "$npx_task" 2>&1) \
    || fail "cli-builder: offline npx failed with --tmpfs /tmp:exec: $out"
  grep -qx LP_RAN <<<"$out" || fail "cli-builder: npx ran but the package's bin did not print LP_RAN: $out"
  echo "ok: cli-builder -- npx runs a package's bin from /tmp with --tmpfs /tmp:exec (offline, from a local tarball)"

  # Negative control: the very same task on Docker's default noexec /tmp.
  set +e
  out=$(drun --rm "${RO[@]}" --tmpfs /app:exec,uid=33,gid=33 "$IMAGE" timeout 60 bash -c "$npx_task" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cli-builder: control: npx ran from a noexec /tmp, so the exec requirement is not what the docs say: $out"
  grep -qiE "permission denied|EACCES" <<<"$out" || fail "cli-builder: control: npx failed on a noexec /tmp without naming a permission error: $out"
  ! grep -qx LP_RAN <<<"$out" || fail "cli-builder: control: the package's bin ran although /tmp is noexec: $out"
  echo "ok: cli-builder -- control: on a noexec /tmp the same npx task fails with a permission error, so cli-builder needs --tmpfs /tmp:exec"
fi

# ------------------------------------------------------------------ fpm side
if [ "$FLAVOR" != fpm ]; then
  exit 0
fi

name="ro-fpm-$$"
ctrl="ro-fpm-ctrl-$$"
trap 'docker rm -f "$name" "$ctrl" >/dev/null 2>&1 || true' EXIT

# What a request has to prove from inside a worker: the env-driven memory limit
# reached the pool, a session was written and read back, a multipart upload
# reached its temp file and was readable, opcache is on, the opted-in extension
# is loaded, and (with PHP_CHMOD_SHIM) the LD_PRELOAD shim is live.
probe_php='<?php
header("Content-Type: text/plain");
session_start(); $_SESSION["k"] = "v"; $id = session_id(); session_write_close();
$_SESSION = []; session_id($id); session_start();
echo "SESSION=", $_SESSION["k"] ?? "lost", "\n"; session_write_close();
echo "MEM=", ini_get("memory_limit"), "\n";
foreach ($_FILES as $f) {
  echo "UPLOAD=", $f["error"] === 0 && is_uploaded_file($f["tmp_name"]) ? file_get_contents($f["tmp_name"]) : "ERR" . $f["error"], "\n";
}
$o = function_exists("opcache_get_status") ? opcache_get_status(false) : null;
echo "OPCACHE=", $o && $o["opcache_enabled"] ? "on" : "off", "\n";
echo "BZ2=", extension_loaded("bz2") ? "y" : "n", "\n";
echo "SP=", extension_loaded("snuffleupagus") ? "y" : "n", "\n";
$c = tempnam(sys_get_temp_dir(), "c"); @chmod($c, 0); clearstatcache();
echo "CHMOD=", is_file($c) ? decoct(fileperms($c) & 0777) : "nofile", "\n"; @unlink($c);
'
body=$(printf -- '--B\r\nContent-Disposition: form-data; name="f"; filename="a.txt"\r\nContent-Type: text/plain\r\n\r\nhello-upload\r\n--B--\r\n')

# $1 container, $2 dir the probe script is written to. Prints the response body.
fpm_probe() {
  local c="$1" dir="$2" out rc
  docker exec -i "$c" timeout 20 sh -c "cat > ${dir}/ro-probe.php" <<<"$probe_php"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    set +e
    out=$(printf '%s' "$body" | docker exec -i -e SCRIPT_FILENAME="${dir}/ro-probe.php" -e SCRIPT_NAME=/ro-probe.php \
      -e REQUEST_METHOD=POST -e CONTENT_TYPE='multipart/form-data; boundary=B' -e CONTENT_LENGTH="${#body}" \
      "$c" timeout 20 cgi-fcgi -bind -connect 127.0.0.1:9000 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 0 ] && break
    sleep 0.3
  done
  [ "$rc" -eq 0 ] || fail "fpm: cgi-fcgi against $c never succeeded (last exit $rc): $out"
  printf '%s\n' "$out"
}

wait_healthy() {
  local c="$1"
  for _ in $(seq 1 40); do
    docker exec "$c" timeout 20 php-fpm-healthcheck >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  docker logs "$c" >&2 2>&1 || true
  fail "fpm: php-fpm-healthcheck never succeeded in $c"
}

# The assertions, as a function so the control can run the very same ones.
# Returns non-zero (and says why on stdout) when any fails.
probe_ok() {
  local resp="$1" logs="$2" want_mem="$3" want_sp="$4" bad=0 want
  for want in "SESSION=v" "MEM=${want_mem}" "UPLOAD=hello-upload" "OPCACHE=on" "BZ2=y" "SP=${want_sp}" "CHMOD=644"; do
    grep -qx "$want" <<<"$resp" || { echo "missing '$want'"; bad=1; }
  done
  if grep -qiE "$WRITE_ERR" <<<"$logs"; then
    echo "write error in the container logs"; bad=1
  fi
  return "$bad"
}

sp_env=()
sp_want=n
if has_ext snuffleupagus; then
  sp_env=(-e PHP_SNUFFLEUPAGUS=default)
  sp_want=y
fi

drun -d --name "$name" "${RO[@]}" -e PHP_MEMORY_LIMIT=300M -e PHP_EXT_ENABLE=bz2 -e PHP_CHMOD_SHIM=true "${sp_env[@]}" "$IMAGE" >/dev/null
wait_healthy "$name"
echo "ok: fpm -- starts read-only and php-fpm-healthcheck (cgi-fcgi ping) answers"
resp=$(fpm_probe "$name" /tmp)
wait_healthy "$name"
logs=$(docker logs "$name" 2>&1)
why=$(probe_ok "$resp" "$logs" 300M "$sp_want") || fail "fpm: read-only worker: ${why//$'\n'/; }. Response: $resp. Logs: $logs"
echo "ok: fpm -- read-only worker: PHP_MEMORY_LIMIT/PHP_EXT_ENABLE/PHP_CHMOD_SHIM${sp_env:+/PHP_SNUFFLEUPAGUS} applied, session, multipart upload, opcache work, no write errors in the logs"
docker rm -f "$name" >/dev/null 2>&1

# Control: bare --read-only (the probe script lives on a second tmpfs, /tmp is
# not writable; env-driven ini and PHP_SNUFFLEUPAGUS would refuse to start, so
# none are set). fpm still starts -- nothing in its own startup writes -- and
# the same request must now fail probe_ok, with PHP reporting the real cause in
# the logs rather than a silent 200.
drun -d --name "$ctrl" --read-only --tmpfs /probe -m 512m -e PHP_CHMOD_SHIM=true "$IMAGE" >/dev/null
wait_healthy "$ctrl"
resp=$(fpm_probe "$ctrl" /probe)
logs=$(docker logs "$ctrl" 2>&1)
docker rm -f "$ctrl" >/dev/null 2>&1
trap - EXIT
if why=$(probe_ok "$resp" "$logs" 256M n); then
  fail "fpm: control: the read-only assertions passed on a container with no writable /tmp, so they prove nothing. Response: $resp"
fi
grep -qi "read-only file system" <<<"$logs" \
  || fail "fpm: control: the broken container failed (${why//$'\n'/; }) but its logs never said 'Read-only file system': $logs"
grep -qx "SESSION=lost" <<<"$resp" || fail "fpm: control: expected the session to be lost without /tmp: $resp"
echo "ok: fpm -- control: without a writable /tmp the same request fails the same assertions and the logs say 'Read-only file system'"
