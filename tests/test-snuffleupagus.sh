#!/usr/bin/env bash
set -euo pipefail
IMAGE="${1:?usage: test-snuffleupagus.sh <image>}"
fail() { echo "FAIL: $*" >&2; exit 1; }

# ENTRYPOINT_OVERRIDE bind-mounts a local docker-php-entrypoint read-only over every
# `docker run` this script makes (see tests/test-entrypoint.sh). Unset, this is a
# pure passthrough, so smoke.sh tests exactly what is baked into the image under test.
docker() {
  if [ "$1" = run ]; then
    shift
    local -a extra=()
    if [ -n "${ENTRYPOINT_OVERRIDE:-}" ]; then
      extra+=(-v "${ENTRYPOINT_OVERRIDE}:/usr/local/bin/docker-php-entrypoint:ro")
    fi
    # Same idea for the rulesets: a working-tree conf/snuffleupagus over the
    # baked one, to try a rule change before rebuilding.
    if [ -n "${SP_RULES_OVERRIDE:-}" ]; then
      extra+=(-v "${SP_RULES_OVERRIDE}:/usr/local/etc/php/snuffleupagus:ro")
    fi
    command docker run "${extra[@]}" "$@"
    return
  fi
  command docker "$@"
}

# The DIVERGENCES section and the shared rule body must be byte-identical across all
# four ruleset files: laravel/wordpress/prestashop.rules duplicate default.rules'
# content because @include is not real snuffleupagus syntax. Checked on every run, no
# docker needed, once per file (a `grep -c` of 4 can be four matches in one file).
CONF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../conf/snuffleupagus" && pwd)"
extract_block() {
  # $1: file  $2: begin-line grep pattern  $3: end-line grep pattern
  local b e
  b=$(grep -n "$2" "$1" | head -1 | cut -d: -f1) || fail "no '$2' marker in $1"
  e=$(grep -n "$3" "$1" | head -1 | cut -d: -f1) || fail "no '$3' marker in $1"
  sed -n "${b},${e}p" "$1"
}
divergences_ref=$(extract_block "$CONF_DIR/default.rules" \
  "^# ============ DIVERGENCES FROM UPSTREAM" "^# =========== END DIVERGENCES FROM UPSTREAM")
body_ref=$(extract_block "$CONF_DIR/default.rules" \
  "BEGIN project exemptions" "sp\.upload_validation\.script")
for rs in laravel wordpress prestashop; do
  f="$CONF_DIR/${rs}.rules"
  div=$(extract_block "$f" "^# ============ DIVERGENCES FROM UPSTREAM" "^# =========== END DIVERGENCES FROM UPSTREAM")
  [ "$div" = "$divergences_ref" ] || fail "${rs}.rules' DIVERGENCES section has drifted from default.rules'"
  body=$(extract_block "$f" "BEGIN project exemptions" "sp\.upload_validation\.script")
  [ "$body" = "$body_ref" ] || fail "${rs}.rules' shared rule body has drifted from default.rules'"
done
echo "ok: DIVERGENCES section and shared rule body are byte-identical across all four rulesets"

# Capture, then match -- `docker run ... | grep -q` exits at the first match
# and SIGPIPEs the producer, and pipefail reports that as a failure of the
# whole pipeline regardless of what grep itself concluded.
mods=$(docker run --rm "$IMAGE" php -m)
echo "$mods" | grep -qi snuffleupagus && fail "loaded by default"
echo "ok: disabled by default"

for rs in default laravel wordpress prestashop; do
  docker run --rm "$IMAGE" test -f "/usr/local/etc/php/snuffleupagus/${rs}.rules" \
    || fail "missing ruleset: $rs"
done
echo "ok: all four rulesets present"

# "loads without error" is checked by running an actual .php file, not `php
# -r`: PHP's -r option compiles its argument through the same eval() opcode
# as the language construct, so a ruleset that legitimately hardens eval()
# (prestashop.rules blocks it outright) would abort `php -r` and be reported
# as "does not load cleanly" even though it is working exactly as intended.
# Piping a real script through stdin exercises the same startup path
# (extension init, ruleset parse, RINIT) without going anywhere near eval().
for rs in default laravel wordpress prestashop; do
  out=$(echo '<?php echo "loaded";' | docker run --rm -i -e "PHP_SNUFFLEUPAGUS=${rs}" "$IMAGE" php 2>&1) \
    || fail "ruleset $rs does not load cleanly: $out"
  echo "$out" | grep -q "loaded" || fail "ruleset $rs did not run the script: $out"
  # A ruleset that fails to parse is required to fail loudly (never load
  # partially) -- snuffleupagus reports a broken configuration file as a
  # PHP Warning/Fatal naming "config" during MINIT, so a clean run must not
  # contain one, however it renders in $?.
  echo "$out" | grep -qi "\[config\]" && fail "ruleset $rs logged a config error while loading: $out"
done
echo "ok: every ruleset loads without error"

mods=$(docker run --rm -e PHP_SNUFFLEUPAGUS=laravel "$IMAGE" php -m)
echo "$mods" | grep -qi snuffleupagus || fail "PHP_SNUFFLEUPAGUS did not enable the module"
echo "ok: PHP_SNUFFLEUPAGUS enables"

docker run --rm -e PHP_SNUFFLEUPAGUS=nonexistent "$IMAGE" php -v >/dev/null 2>&1 \
  && fail "unknown ruleset name did not fail"
echo "ok: unknown ruleset rejected"

# The rulesets must actually do the thing they are named for, not just parse.
#
# unserialize() is deliberately not tested for blocking: default.rules has no
# unserialize rule. A hand-written one blocked ordinary object round trips (Laravel's
# queue worker does unserialize(serialize($job))) while a nested POP chain sailed
# through. Upstream ships the real primitive (sp.unserialize_hmac.enable() + a secret
# key) commented out, and this image cannot own a key, so "no unserialize rule" is the
# correct state. The check below proves the false positive is absent instead.

# default.rules blocks the classic system()/proc_open() command-injection shape when
# the argument contains shell metacharacters. Real files, not `php -r`: `-r` compiles
# through a different internal path where an include()/require() inside it is not
# intercepted by disable_function the way it is in a real file or a stdin-piped
# script. proc_open is not in this image's baked disable_functions on any flavor, so
# this is additional coverage everywhere, not just on cli-builder.
run_probe() {
  # $1: image  $2: PHP_SNUFFLEUPAGUS value  $3: php script (stdin)
  echo "$3" | docker run --rm -i -e "PHP_SNUFFLEUPAGUS=${2}" "$1" php 2>&1
}

# system() specifically is only testable this way on cli-builder: fpm/cli's
# baked disable_functions already refuses it unconditionally ("Call to
# undefined function"), so a generic run would prove PHP's ini hardening,
# not snuffleupagus's, on those two flavors.
case "$IMAGE" in
  *cli-builder*)
    out=$(run_probe "$IMAGE" default '<?php system("id; whoami"); echo "AFTER";') && \
      fail "default.rules did not block system() command injection: $out"
    echo "$out" | grep -qi "disabled_function" || fail "system() block failed for the wrong reason: $out"
    echo "ok: default.rules blocks system() command injection"
    ;;
  *)
    echo "ok: system() command-injection probe skipped (this flavor's own disable_functions already covers it)"
    ;;
esac

out=$(run_probe "$IMAGE" default '<?php $p = proc_open("id; whoami", [1=>["pipe","w"]], $pipes); echo stream_get_contents($pipes[1]);') && \
  fail "default.rules did not block proc_open() command injection: $out"
echo "$out" | grep -qi "disabled_function" || fail "proc_open() block failed for the wrong reason: $out"
echo "ok: default.rules blocks proc_open() command injection"

# default.rules blocks include() of a non-.php/.inc/.phtml path through a wrapper that
# allow_url_include=Off does not govern (compress.zlib://, phar://). A rule matching
# only http/https/ftp/data/php schemes would add no coverage, since
# allow_url_include=Off already refuses those.
gz_payload=$(printf '<?php echo "gz-payload-executed";' | gzip -c | base64 -w0)
probe="<?php file_put_contents('/tmp/probe.gz', base64_decode('${gz_payload}')); include 'compress.zlib:///tmp/probe.gz'; echo 'AFTER';"
out=$(docker run --rm -i -e PHP_SNUFFLEUPAGUS=default "$IMAGE" php -d allow_url_include=1 <<<"$probe" 2>&1) && \
  fail "default.rules did not block a compress.zlib:// wrapper include: $out"
echo "$out" | grep -qi "disabled_function" || fail "wrapper-include block failed for the wrong reason: $out"
echo "$out" | grep -q "gz-payload-executed" && fail "the wrapper-include payload actually ran: $out"
echo "ok: default.rules blocks non-.php wrapper includes"

# putenv("DYLD_LIBRARY_PATH") is exempted on its own merits: macOS-only and inert on
# this Linux image, so upstream's LD_-substring hardening false-positives on it for no
# protective benefit. It is not a Composer-specific carve-out (Symfony's defensive
# env-clearing makes the same call). Composer's phar bootstrap is deliberately not
# exempted: getting past putenv reaches the proc_open() command-injection filter
# blocking a benign `stty -a | grep columns` pipe, which is the headline RCE
# protection doing its job. PHP_SNUFFLEUPAGUS (runtime serving) and Composer
# (build/deploy time) are not meant to run together.
out=$(run_probe "$IMAGE" default '<?php putenv("DYLD_LIBRARY_PATH"); echo "DYLD_CLEARED_OK";') \
  || fail "putenv(\"DYLD_LIBRARY_PATH\") was blocked -- the putenv exemption regressed: $out"
echo "$out" | grep -q "DYLD_CLEARED_OK" || fail "putenv(\"DYLD_LIBRARY_PATH\") did not complete correctly: $out"
echo "ok: putenv() exemption allows the inert-on-Linux DYLD_LIBRARY_PATH"

# ...and does not widen past that one exact value: LD_PRELOAD and friends
# still match the substring rule and stay blocked.
out=$(run_probe "$IMAGE" default '<?php putenv("LD_PRELOAD=/tmp/evil.so"); echo "SHOULD_NOT_RUN";') && \
  fail "putenv(\"LD_PRELOAD=...\") was NOT blocked -- the exemption widened past DYLD_LIBRARY_PATH: $out"
echo "$out" | grep -qi "disabled_function" || fail "the negative putenv probe failed for the wrong reason: $out"
echo "ok: putenv() exemption does not widen past DYLD_LIBRARY_PATH"

# Documented boundary: `require` from Composer's own phar bootstrap stays blocked;
# there is deliberately no exemption for it. This asserts that holds.
out=$(docker run --rm -e PHP_SNUFFLEUPAGUS=default --entrypoint sh "$IMAGE" -c '
  echo "<?php require \"phar:///tmp/uploaded.phar/x\"; echo \"SHOULD_NOT_RUN\";" > /tmp/attacker.php
  docker-php-entrypoint php /tmp/attacker.php
' 2>&1) && fail "require of a phar target is not blocked -- did a require exemption come back?: $out"
echo "$out" | grep -qi "disabled_function" || fail "the require probe failed for the wrong reason: $out"
echo "ok: default.rules still blocks require of a phar target (no require exemption)"

# ini_set('display_errors'|'memory_limit') must not fatal: Laravel's
# HandleExceptions.php calls ini_set('display_errors', 'Off') on every non-testing
# request. The rules use version-split @condition PHP_VERSION_ID <80000 / >=80000
# branches; the image under test exercises whichever matches its own PHP version.
out=$(run_probe "$IMAGE" default '<?php ini_set("display_errors","0"); echo "INISET_OK";') \
  || fail "ini_set('display_errors','0') is still blocked -- Laravel's own bootstrap call would fatal every request: $out"
echo "$out" | grep -q "INISET_OK" || fail "ini_set('display_errors','0') did not complete correctly: $out"
echo "ok: ini_set() exemptions unblock display_errors"

out=$(run_probe "$IMAGE" default '<?php ini_set("memory_limit","-1"); echo "memory_limit_OK";') \
  || fail "ini_set('memory_limit','-1') is still blocked: $out"
echo "$out" | grep -q "memory_limit_OK" || fail "ini_set('memory_limit','-1') did not complete correctly: $out"
echo "ok: ini_set() exemption covers memory_limit too"

# max_execution_time is not exempted: nothing in the vendored file ever blocked that
# key, so it succeeds because no rule covers it at all, exempted or not.
out=$(run_probe "$IMAGE" default '<?php ini_set("max_execution_time","0"); echo "MAXEXEC_OK";') \
  || fail "ini_set('max_execution_time','0') is unexpectedly blocked -- did a drop rule for this key get added somewhere?: $out"
echo "$out" | grep -q "MAXEXEC_OK" || fail "ini_set('max_execution_time','0') did not complete correctly: $out"
echo "ok: ini_set('max_execution_time', ...) succeeds because no rule ever covered it (not because of an exemption)"

# ...and does not widen past the two exempted keys: open_basedir stays
# blocked (a security-relevant key none of the three named frameworks were
# found to touch at bootstrap).
out=$(run_probe "$IMAGE" default '<?php ini_set("open_basedir","/"); echo "SHOULD_NOT_RUN";') && \
  fail "ini_set('open_basedir', ...) is not blocked -- the ini_set exemption widened past display_errors/memory_limit: $out"
echo "$out" | grep -qi "disabled_function" || fail "the negative ini_set probe failed for the wrong reason: $out"
echo "ok: ini_set() exemptions do not widen past the two named keys"

# curl_setopt($h, CURLOPT_SSL_VERIFYPEER, true) must not fatal: WordPress's
# WP_Http_Curl::request() passes the PHP bool true for this option (the secure
# direction and curl's default), but upstream's allow rules match only the strings
# "1"/"2", so the call fell through to the drop meant to stop verification being
# turned off. Every outbound HTTP call in WordPress core, including the update checks
# on ordinary wp-admin loads, would fatal under wordpress.rules.
out=$(run_probe "$IMAGE" wordpress '<?php $ch = curl_init(); curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, true); echo "CURL_TRUE_OK";') \
  || fail "curl_setopt(..., CURLOPT_SSL_VERIFYPEER, true) is still blocked -- every WordPress outbound HTTP call would fatal: $out"
echo "$out" | grep -q "CURL_TRUE_OK" || fail "curl_setopt(..., true) did not complete correctly: $out"
echo "ok: curl_setopt() exemption unblocks the bool-true SSL-verify-on call"

# ...and does not widen past the safe direction: turning verification OFF
# must still fatal -- that's the actual vector the vendored rule exists
# to stop, and it's not what WordPress's own call shape needs exempted.
out=$(run_probe "$IMAGE" wordpress '<?php $ch = curl_init(); curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false); echo "SHOULD_NOT_RUN";') && \
  fail "curl_setopt(..., CURLOPT_SSL_VERIFYPEER, false) is not blocked -- the exemption widened past the safe (true) direction: $out"
echo "$out" | grep -qi "disabled_function" || fail "the negative curl_setopt probe failed for the wrong reason: $out"
echo "ok: curl_setopt() exemption does not widen past disabling SSL verification"

# function_exists()/is_callable() must not be blocked: Symfony Console's Terminal class
# (loaded by every `php artisan` command) probes function_exists('proc_open') before
# shelling out for terminal width, and upstream's backdoor-recon block treated that
# introspection as suspicious.
out=$(run_probe "$IMAGE" default '<?php var_dump(function_exists("proc_open")); echo "FNEXISTS_OK";') \
  || fail "function_exists('proc_open') is still blocked: $out"
echo "$out" | grep -q "FNEXISTS_OK" || fail "function_exists('proc_open') did not complete correctly: $out"
out=$(run_probe "$IMAGE" default '<?php var_dump(is_callable("proc_open")); echo "ISCALLABLE_OK";') \
  || fail "is_callable('proc_open') is still blocked: $out"
echo "$out" | grep -q "ISCALLABLE_OK" || fail "is_callable('proc_open') did not complete correctly: $out"
echo "ok: function_exists()/is_callable() are not blocked"

# ...but the actual capability stays gated by the command-injection rules.
out=$(run_probe "$IMAGE" default '<?php $p = proc_open("id; whoami", [1=>["pipe","w"]], $pipes); echo stream_get_contents($pipes[1]);') && \
  fail "removing the function_exists()/is_callable() block also weakened the real proc_open() command-injection filter: $out"
echo "$out" | grep -qi "disabled_function" || fail "the negative proc_open probe failed for the wrong reason: $out"
echo "ok: removing function_exists()/is_callable() blocking left the real proc_open() filter untouched"

# default.rules does not break an ordinary unserialize() round trip (Laravel's queue
# worker does unserialize(serialize($job)) on every job).
out=$(run_probe "$IMAGE" default '<?php class J{public $to="a@b.com";} $d=serialize(new J()); var_dump(unserialize($d)); echo "ROUNDTRIP_OK";') \
  || fail "default.rules broke an ordinary unserialize(serialize()) round trip: $out"
echo "$out" | grep -q "ROUNDTRIP_OK" || fail "unserialize round trip did not complete correctly: $out"
echo "ok: default.rules does not break a legitimate unserialize round trip"

# laravel.rules: must NOT globally enforce strict typing -- that breaks the
# routine loose-typed calls (numeric route/query strings into int-typed
# params) that Laravel and its ecosystem rely on throughout.
out=$(echo '<?php function f(int $x) { return $x * 2; } echo f("5");' | docker run --rm -i -e PHP_SNUFFLEUPAGUS=laravel "$IMAGE" php 2>&1) \
  || fail "laravel.rules broke an ordinary loose-typed function call: $out"
echo "$out" | grep -q "10" || fail "laravel.rules did not evaluate the loose-typed call correctly: $out"
echo "ok: laravel.rules does not break loose-typed calls"

# prestashop.rules: readonly_exec must stay off, or every cache-rebuild write (the bug
# the chmod shim exists for) would be blocked. There is no writable-then-execute PHP
# path to probe without a real install, so this is asserted structurally, anchored to
# an uncommented directive: the vendored upstream block ships
# "# sp.readonly_exec.enable();" as a commented-out example that an unanchored grep
# would also match.
rules=$(docker run --rm "$IMAGE" cat /usr/local/etc/php/snuffleupagus/prestashop.rules)
echo "$rules" | grep -qE '^[[:space:]]*sp\.readonly_exec\.enable' \
  && fail "prestashop.rules enables readonly_exec, which blocks PrestaShop's own cache-rebuild writes"
echo "ok: prestashop.rules leaves readonly_exec off"

# prestashop.rules does not drop eval(): PrestaShop's bundled Smarty and Twig compile
# templates through eval() as part of normal rendering, so a drop rule would break the
# first page load, and no narrower shape exists. Structural check that the rule is
# absent, not just its filename_r() exemption.
rules=$(docker run --rm "$IMAGE" cat /usr/local/etc/php/snuffleupagus/prestashop.rules)
echo "$rules" | grep -qE '^[[:space:]]*sp\.disable_function\.function\("eval"\)' \
  && fail "prestashop.rules still drops eval() -- Twig/Smarty template compilation would still be broken"
echo "ok: prestashop.rules does not block eval()"

# Positive: eval() itself runs normally under every ruleset.
out=$(run_probe "$IMAGE" prestashop '<?php eval("echo \"EVAL_OK\";");') \
  || fail "eval() is still blocked under prestashop.rules: $out"
echo "$out" | grep -q "EVAL_OK" || fail "eval() did not run correctly under prestashop.rules: $out"
echo "ok: prestashop.rules allows ordinary eval() (Twig/Smarty template compilation)"

# The deeper layer stays intact: upstream's eval_blacklist (in the vendored "Classic
# webshells patterns" section) still catches an actual RCE gadget called inside an
# eval'd string, although eval() itself is not blocked.
#
# cli-builder only, like the system() probe above: on fpm/cli system() is undefined
# per the baked disable_functions, so the call fails with "Call to undefined function
# system() in ... eval()'d code" before reaching eval_blacklist, and a loose
# `grep -qi "eval"` would match the word in that unrelated error's filename. Anchored
# to the real `[eval]` log tag.
case "$IMAGE" in
  *cli-builder*)
    out=$(run_probe "$IMAGE" default '<?php eval("system(\"id; whoami\");");') && \
      fail "system() called inside eval() was NOT blocked -- eval_blacklist regressed: $out"
    echo "$out" | grep -q "\[eval\]" || fail "the eval_blacklist probe failed for the wrong reason (no [eval] tag in the output): $out"
    echo "ok: eval_blacklist still catches system()/exec() called inside eval()"
    ;;
  *)
    echo "ok: eval_blacklist probe skipped (this flavor's own disable_functions already covers system() before eval_blacklist would)"
    ;;
esac

# wordpress.rules ships upstream's defaults verbatim: no WordPress-specific delta
# blocks a real attack without breaking normal operation. A delta would be inert
# (ini_protection with no keys), a no-op on this PHP (create_function, removed in
# 8.0) or hazardous (assert().drop() has no security value since PHP 8.0 stopped
# evaluating string arguments, while zend.assertions=1 in this image makes a benign
# assert(1===1) run and fatal under that rule). Both halves of the claim are checked
# directly.
out=$(run_probe "$IMAGE" wordpress '<?php assert(1 === 1); echo "ASSERT_OK";') \
  || fail "wordpress.rules fatals on a benign assert(1===1): $out"
echo "$out" | grep -q "ASSERT_OK" || fail "assert(1===1) did not complete correctly under wordpress.rules: $out"
echo "ok: wordpress.rules does not fatal on a benign assert()"

wp_directives=$(docker run --rm "$IMAGE" grep -vE '^[[:space:]]*(#|$)' /usr/local/etc/php/snuffleupagus/wordpress.rules)
default_directives=$(docker run --rm "$IMAGE" grep -vE '^[[:space:]]*(#|$)' /usr/local/etc/php/snuffleupagus/default.rules)
[ "$wp_directives" = "$default_directives" ] \
  || fail "wordpress.rules has directives beyond default.rules's -- an unreviewed WordPress-specific delta snuck in"
echo "ok: wordpress.rules ships upstream's defaults with no additional directives"

# sp-upload-check through the actual snuffleupagus upload_validation hook, not just
# the script run standalone.
#
# Empty output is not proof of "blocked pre-execution": it is equally what a container
# that never bound its port, a curl that could not connect, or a missing up.php
# produces. So:
#   - the readiness loop fails the whole test (with the container's logs) when it
#     exhausts;
#   - srv() fails outright when curl cannot reach the upload endpoint (captured exit
#     code, not a `| grep`/last-echo swallow);
#   - srv() returns the HTTP status alongside the body ("<status> <body>"), so a
#     rejection assertion checks both: status alone can't be faked by a handler bug,
#     and body alone can't be faked by curl silently returning nothing.
# Each srv() call writes its container's logs to a fixed path derived from this
# script's pid (one srv() container is alive at a time, so overwriting is fine), not
# to srv()'s stdout, which `resp=$(srv ...)` captures as "<status> <body>". A file
# survives the command-substitution subshell, and the logs can't be fetched once the
# container is gone.
SRV_LOG_FILE="/tmp/sp-srv-logs.$$"
# Removed on exit: each srv() call overwrites the file, so the last one would leak.
trap 'rm -f "$SRV_LOG_FILE"' EXIT

srv() {
  # $1: PHP_SNUFFLEUPAGUS  $2: file to upload  $3: optional "allow_curl_failure" when
  # the upload request itself may legitimately get no HTTP response (PHP 7.4's dev
  # server closes the connection, curl exit 52, when snuffleupagus's drop() aborts the
  # worker before it writes a response; 8.5 writes a bare 500 first). Every other
  # caller is strict: a curl failure is a hard `fail`.
  # Prints "<http-status> <body>" on an ordinary response, or "000 CURLFAIL:<exit-code>"
  # when $3 was passed and curl got no response; writes the container's docker logs to
  # $SRV_LOG_FILE either way.
  local name port code out rc status body allow_curl_failure="${3:-}"
  name="sp-upload-e2e-$$"
  port=$((18100 + RANDOM % 1000))

  # `set -e` does not propagate out of a `$(...)` command substitution (without `shopt
  # -s inherit_errexit`, which this repo's scripts do not set), so a failing `docker
  # run -d` here (port already bound, bad image reference) would be swallowed: the
  # readiness loop would spin, or find something already listening on the same host
  # port and treat its answer as this container's. Checked explicitly instead.
  if ! docker run -d --name "$name" -e "PHP_SNUFFLEUPAGUS=${1}" -p "${port}:8099" \
    -w /tmp --entrypoint sh "$IMAGE" -c '
      printf '"'"'<?php
if (!empty($_FILES["f"]["tmp_name"]) && is_uploaded_file($_FILES["f"]["tmp_name"])) {
  echo "UPLOAD_ACCEPTED";
} else {
  echo "UPLOAD_REJECTED";
}
'"'"' > /tmp/up.php
      docker-php-entrypoint php -S 0.0.0.0:8099 up.php
    ' >/dev/null; then
    fail "srv: docker run -d failed to start a container for PHP_SNUFFLEUPAGUS=${1} on host port ${port}"
  fi

  # Readiness poll: curl failing to connect is the normal shape while the server
  # starts; the upload request below is the actual measurement and does not tolerate
  # it. "000" is curl's %{http_code} for "no HTTP response at all", the one value that
  # can never be a real server response.
  code="000"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || true)
    [ -n "$code" ] && [ "$code" != "000" ] && break
    sleep 0.3
  done
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    echo "srv: $name (PHP_SNUFFLEUPAGUS=${1}) never became ready on port ${port}; its logs:" >&2
    docker logs "$name" >&2 2>&1 || true
    docker rm -f "$name" >/dev/null 2>&1 || true
    fail "srv: readiness loop exhausted waiting for PHP_SNUFFLEUPAGUS=${1} on port ${port}"
  fi

  set +e
  out=$(curl -s -w $'\n%{http_code}' -F "f=@${2}" "http://127.0.0.1:${port}/up.php")
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    if [ -n "$allow_curl_failure" ]; then
      # A caller that opted in accepts "no HTTP response at all" (PHP 7.4's dev server
      # closes the connection when snuffleupagus's drop() aborts the worker, where 8.5
      # writes a bare 500 first), but it still gets the logs and must check them for
      # snuffleupagus's own rejection line.
      docker logs "$name" >"$SRV_LOG_FILE" 2>&1 || true
      docker rm -f "$name" >/dev/null 2>&1
      echo "000 CURLFAIL:${rc}"
      return 0
    fi
    docker logs "$name" >&2 2>&1 || true
    docker rm -f "$name" >/dev/null 2>&1 || true
    fail "srv: curl could not reach PHP_SNUFFLEUPAGUS=${1} on port ${port} for the upload request itself (curl exit $rc)"
  fi
  status="${out##*$'\n'}"
  body="${out%$'\n'*}"

  # HTTP 500 with an empty body is what this handler produces if snuffleupagus rejects
  # the upload, but also what an unrelated stub server or a different failure produces.
  # Logs are captured before removing the container: its own process aborts (a
  # heap-corruption crash under the dev server + JIT combination) the instant the
  # upload_validation hook drops a request, so `--rm` is not used and removal happens
  # here, after the logs are on disk.
  docker logs "$name" >"$SRV_LOG_FILE" 2>&1 || true
  docker rm -f "$name" >/dev/null 2>&1

  echo "${status} ${body}"
}

shortecho="/tmp/sp-shortecho-$$.php"
printf '<?= system($_GET[0]); ?>' > "$shortecho"

# Positive control: a benign upload through the same server/channel must round-trip
# before the rejection assertion means anything; otherwise an empty body from the
# webshell request would be indistinguishable from "the channel never worked".
benign="/tmp/sp-benign-$$.txt"
printf 'just an ordinary file' > "$benign"
resp=$(srv default "$benign")
rm -f "$benign"
resp_status="${resp%% *}"; resp_body="${resp#* }"
[ "$resp_status" = 200 ] && [ "$resp_body" = UPLOAD_ACCEPTED ] \
  || fail "sp-upload-check positive control failed: a benign upload through the same channel did not round-trip (status=$resp_status body='$resp_body') -- the webshell-rejection assertion below would prove nothing"
echo "ok: sp-upload-check positive control -- a benign upload round-trips (UPLOAD_ACCEPTED) before the rejection assertion"

# On PHP 7.4 this rejection closes the connection outright (curl exit 52, "Empty reply
# from server") instead of returning a bare 500: snuffleupagus's drop() logs its fatal
# and the dev server closes the socket without writing a response, where 8.5 still
# writes the 500. `allow_curl_failure` lets that shape through; the log line check
# below decides pass/fail on every version.
resp=$(srv default "$shortecho" allow_curl_failure)
rm -f "$shortecho"
resp_status="${resp%% *}"; resp_body="${resp#* }"
# HTTP 500 + empty body is also what a container that never ran the handler (a stub,
# a crashed unrelated process, the wrong port) produces. Confirm the rejection came
# from snuffleupagus's upload_validation hook by matching its log line in this
# container's logs first; that decides pass/fail, and the HTTP shape may differ by
# version only once the line is present. A closed connection without it is not
# evidence of anything and stays a FAIL.
sp_log_hit=0
grep -qE '\[snuffleupagus\]\[[^]]*\]\[upload_validation\]\[drop\]' "$SRV_LOG_FILE" && sp_log_hit=1
if [ "$sp_log_hit" -ne 1 ]; then
  fail "sp-upload-check's <?= webshell request got status=$resp_status body='$resp_body', but this container's own logs show no snuffleupagus upload_validation rejection for it -- neither a 500/empty body nor a closed connection is evidence of a real rejection without this log line. Logs were: $(cat "$SRV_LOG_FILE")"
fi
case "$resp_status" in
  500)
    [ -z "$resp_body" ] \
      || fail "sp-upload-check: snuffleupagus's log confirms the rejection, but the HTTP 500 carried a non-empty body ('$resp_body') -- the response shape itself regressed"
    ;;
  000)
    # Transport closed before any response was written (PHP 7.4's dev server under this
    # drop). Acceptable only because sp_log_hit already proved snuffleupagus caused it.
    ;;
  *)
    fail "sp-upload-check: snuffleupagus's log confirms the rejection, but the request returned an unexpected status=$resp_status (body='$resp_body') -- neither the documented 500 nor a closed connection"
    ;;
esac
echo "ok: sp-upload-check rejects <?= webshells, confirmed via snuffleupagus's own rejection log line (transport shape: status=$resp_status)"

stored_zip_dir="/tmp/sp-plugin-$$"
mkdir -p "$stored_zip_dir/hello-dolly"
printf '<?php\n/* Plugin Name: Hello Dolly */\n' > "$stored_zip_dir/hello-dolly/hello.php"
printf '<?php // Silence is golden\n' > "$stored_zip_dir/hello-dolly/index.php"
( cd "$stored_zip_dir" && zip -qr0 plugin.zip hello-dolly )
resp=$(srv wordpress "$stored_zip_dir/plugin.zip")
rm -rf "$stored_zip_dir"
resp_status="${resp%% *}"; resp_body="${resp#* }"
[ "$resp_status" = 200 ] && [ "$resp_body" = UPLOAD_ACCEPTED ] \
  || fail "sp-upload-check rejected a stored (uncompressed) WordPress-plugin-shaped zip: got status=$resp_status body='$resp_body'"
echo "ok: sp-upload-check accepts plugin/module zip uploads"

# A file whose first bytes are zip magic but which is not a valid zip (`PK\x03\x04`
# followed by `<?php system($_GET[0]);`) must be rejected, not accepted on the magic
# bytes alone. Direct script check, like the fail-closed-on-unreadable check below.
polyglot_check=$(docker run --rm --entrypoint sh "$IMAGE" -c '
  printf "PK\003\004<?php system(\$_GET[0]);" > /tmp/sp-polyglot.zip
  /usr/local/bin/sp-upload-check /tmp/sp-polyglot.zip
  echo "rc=$?"
')
echo "$polyglot_check" | grep -q "rc=1" || fail "sp-upload-check accepted a zip-magic-bytes-then-<?php polyglot: $polyglot_check"
echo "ok: sp-upload-check validates archive integrity, not just magic bytes"

# Archive validation decompresses the whole payload, an unbounded-CPU DoS (a 9.4MB
# gzip of 2GB of zeros costs 4.2s in one FPM worker); each validator call is wrapped
# in a timeout. ARCHIVE_CHECK_TIMEOUT=1 (default 5) keeps this assertion fast: the
# bomb below decompresses to 5GB, so the timeout fires well before a legitimate small
# plugin/module zip's sub-second validation would.
dos_check=$(docker run --rm --entrypoint sh -e ARCHIVE_CHECK_TIMEOUT=1 "$IMAGE" -c '
  dd if=/dev/zero bs=1M count=5000 2>/dev/null | gzip -9 > /tmp/sp-bomb.gz
  /usr/local/bin/sp-upload-check /tmp/sp-bomb.gz
  echo "rc=$?"
' 2>&1)
echo "$dos_check" | grep -q "rc=1" || fail "sp-upload-check did not reject an oversized-decompression archive within its timeout: $dos_check"
echo "ok: sp-upload-check bounds archive-validation CPU cost with a timeout"

# Fail-closed on an unreadable file: checked directly against the script,
# since racing an HTTP upload against a permission change mid-flight isn't
# a reliable way to reach the same code path.
unreadable_check=$(docker run --rm --user root --entrypoint sh "$IMAGE" -c '
  touch /tmp/sp-noperm.php
  chmod 000 /tmp/sp-noperm.php
  su -s /bin/sh www-data -c "/usr/local/bin/sp-upload-check /tmp/sp-noperm.php"
  echo "rc=$?"
')
echo "$unreadable_check" | grep -q "rc=1" || fail "sp-upload-check did not fail closed on an unreadable file: $unreadable_check"
echo "ok: sp-upload-check fails closed, not open, on an unreadable file"

# move_uploaded_file() destination patterns are anchored to the actual file extension.
# Upstream's patterns were "\.ph" / "\.ht", unanchored, matching those letters anywhere
# in the destination path, which false-positives on ordinary filenames a WordPress
# media upload can produce.
#
# move_uploaded_file() always returns false outside a real HTTP upload (the
# is_uploaded_file() check fails on a CLI tempfile), so "PHP's own false" and
# "snuffleupagus blocked it" are told apart by the output carrying snuffleupagus's
# disabled_function tag, not by the return value. No @ on the call: before PHP 8 it
# silences fatals too, so on 7.x the drop message vanished and the block looked like a
# crash. A non-uploaded source makes the call return false quietly, so there is
# nothing else for @ to hide.
move_upload_probe() {
  # $1: ruleset  $2: destination filename
  run_probe "$IMAGE" "$1" "<?php
\$src = tempnam(sys_get_temp_dir(), 'up');
file_put_contents(\$src, 'x');
move_uploaded_file(\$src, sys_get_temp_dir().'/${2}');
echo 'REACHED_PHP';"
}

# False positives upstream's unanchored pattern produced -- must now reach
# ordinary PHP execution (REACHED_PHP, no snuffleupagus block) on every
# ruleset, since all four share the same corrected body.
for rs in default laravel wordpress prestashop; do
  for fname in holiday.photo.jpg my.phone.png chart.ht.svg summer.photos.zip; do
    out=$(move_upload_probe "$rs" "$fname")
    echo "$out" | grep -qi "disabled_function" && \
      fail "$rs.rules still blocks move_uploaded_file() to '$fname' (regression): $out"
    echo "$out" | grep -q "REACHED_PHP" || fail "$rs.rules probe for '$fname' did not run to completion: $out"
  done
done
echo "ok: move_uploaded_file() does not false-positive on holiday.photo.jpg, my.phone.png, chart.ht.svg, summer.photos.zip"

# The actual attack shapes the anchored pattern must still catch, case
# folded and across every suffix family upstream's own pattern intended.
for rs in default laravel wordpress prestashop; do
  for fname in shell.php shell.PHP shell.phtml shell.phar .htaccess x.htpasswd; do
    out=$(move_upload_probe "$rs" "$fname") && \
      fail "$rs.rules did not block move_uploaded_file() to '$fname': $out"
    echo "$out" | grep -qi "disabled_function" || \
      fail "$rs.rules block of '$fname' failed for the wrong reason: $out"
  done
done
echo "ok: move_uploaded_file() still blocks shell.php/.PHP/.phtml/.phar/.htaccess/.htpasswd"

# A bare `$` anchor would stop matching once a dangerous filename has trailing junk
# after its real extension ("shell.php " with a trailing space, "shell.php." with a
# trailing dot), so the pattern absorbs a run of trailing spaces and/or dots before the
# end anchor. A trailing tab is not covered: the config DSL does not reliably pass a
# `\t` escape through to the regex engine as a tab, and no rule should claim coverage
# the probe could not verify.
for rs in default laravel wordpress prestashop; do
  for fname in "shell.php " "shell.php." "shell.php   " "shell.php..." "shell.php. " ".htaccess " ".htaccess..."; do
    out=$(move_upload_probe "$rs" "$fname") && \
      fail "$rs.rules did not block move_uploaded_file() to '$fname' (trailing junk after a real extension): $out"
    echo "$out" | grep -qi "disabled_function" || \
      fail "$rs.rules block of '$fname' failed for the wrong reason: $out"
  done
done
echo "ok: move_uploaded_file() still blocks shell.php/.htaccess with trailing spaces/dots after the real extension"

# The double-extension case: a real, later extension after an earlier
# "ph"/"ht" occurrence must be judged on its own real extension, not the
# earlier one -- confirms the trailing-junk widening didn't turn into a
# second unanchored match.
out=$(move_upload_probe default "shell.php.php") && \
  fail "default.rules did not block move_uploaded_file() to 'shell.php.php': $out"
echo "$out" | grep -qi "disabled_function" || fail "block of 'shell.php.php' failed for the wrong reason: $out"
echo "ok: move_uploaded_file() blocks a double .php extension on its own real ending"

# mail()'s fifth argument goes to sendmail as flags; -X writes a log file wherever it
# is told. The rule names the argument, and that name changed in PHP 8.0, so every
# version is probed rather than one.
for rs in default laravel wordpress prestashop; do
  for fn in mail mb_send_mail; do
    out=$(run_probe "$IMAGE" "$rs" "<?php $fn('a@example.com', 's', 'm', '', '-X/tmp/shell.php'); echo 'REACHED_PHP';") && \
      fail "$rs.rules did not block $fn() with sendmail flags: $out"
    echo "$out" | grep -qi "disabled_function" || fail "$rs.rules $fn() block failed for the wrong reason: $out"
  done
done
echo "ok: mail() and mb_send_mail() refuse sendmail flags on every ruleset"

# v0.14.0 upstream: CURLOPT_SSLENGINE (10089) loads an OpenSSL engine, i.e.
# a shared object of the caller's choosing (php-src issue 22035).
for rs in default laravel wordpress prestashop; do
  out=$(run_probe "$IMAGE" "$rs" '<?php $c = curl_init(); curl_setopt($c, 10089, "/tmp/evil.so"); echo "REACHED_PHP";') && \
    fail "$rs.rules did not block curl_setopt(CURLOPT_SSLENGINE): $out"
  echo "$out" | grep -qi "disabled_function" || fail "$rs.rules CURLOPT_SSLENGINE block failed for the wrong reason: $out"
done
echo "ok: curl_setopt(CURLOPT_SSLENGINE) blocked on every ruleset"

# sp.xxe_protection is deliberately not enabled in any ruleset (conf/snuffleupagus/*.rules
# say why): its hook replaced libxml_disable_entity_loader() with a nop, which on php 7
# also swallowed the application's own call, while protecting nothing in a request.
# Pin both halves of that. The function is the real one again -- the real one returns the
# previous state, so a first call to disable the loader returns false, where the nop
# returned true -- and nothing logs under the [xxe] tag. On php 7, the application's own
# libxml_disable_entity_loader(true) then does what it says: LIBXML_NOENT expands a
# file:// entity until the app has called it, and not after.
xxe_probe='<?php
echo @libxml_disable_entity_loader(true) === false ? "LOADER_REAL\n" : "LOADER_REPLACED\n";
@libxml_disable_entity_loader(false);
libxml_set_external_entity_loader(function () { return null; });
if (PHP_MAJOR_VERSION >= 8) { echo "SKIP_PHP8\n"; echo "DONE\n"; exit; }
file_put_contents("/tmp/xxe-probe", "XXE_PROBE");
$x = "<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY x SYSTEM \"file:///tmp/xxe-probe\">]><r>&x;</r>";
libxml_set_external_entity_loader(null);
$d = new DOMDocument(); @$d->loadXML($x, LIBXML_NOENT);
echo strpos($d->textContent, "XXE_PROBE") !== false ? "BASELINE_EXPANDED\n" : "BASELINE_NOT_EXPANDED\n";
libxml_disable_entity_loader(true);
$d = new DOMDocument(); @$d->loadXML($x, LIBXML_NOENT);
echo strpos($d->textContent, "XXE_PROBE") === false ? "APP_DISABLE_BLOCKS\n" : "APP_DISABLE_IGNORED\n";
echo "DONE\n";'
for rs in default laravel wordpress prestashop; do
  out=$(run_probe "$IMAGE" "$rs" "$xxe_probe") || fail "$rs.rules: the xxe probe did not run: $out"
  echo "$out" | grep -q "DONE" || fail "$rs.rules: the xxe probe did not finish: $out"
  echo "$out" | grep -q "LOADER_REAL" \
    || fail "$rs.rules: libxml_disable_entity_loader() is still replaced (sp.xxe_protection on?): $out"
  echo "$out" | grep -qiE "\[xxe\]|A call to libxml_[a-z_]+ was tried" \
    && fail "$rs.rules: something still logs under the xxe tag: $out"
  if ! echo "$out" | grep -q "SKIP_PHP8"; then
    echo "$out" | grep -q "BASELINE_EXPANDED" \
      || fail "$rs.rules: LIBXML_NOENT did not expand the file:// entity, so the check below proves nothing: $out"
    echo "$out" | grep -q "APP_DISABLE_BLOCKS" \
      || fail "$rs.rules: the application's libxml_disable_entity_loader(true) did not block the file:// entity: $out"
  fi
done
echo "ok: libxml_disable_entity_loader() is the real function with no xxe log line on every ruleset; on php 7 the application's own call blocks file:// entities"

echo "SNUFFLEUPAGUS TESTS PASSED"
