#!/usr/bin/env bash
set -euo pipefail
IMAGE="${1:?usage: test-snuffleupagus.sh <image>}"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Task 19b fix2b: no image builds in this task -- see the identical block in
# tests/test-entrypoint.sh for the full rationale. ENTRYPOINT_OVERRIDE
# bind-mounts a local docker-php-entrypoint read-only over every `docker
# run` this script makes; left unset (the default) this is a pure
# passthrough, so smoke.sh keeps testing exactly what's baked into the
# image under test.
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

# T12-L (round-6 follow-up): the DIVERGENCES section and the shared rule
# body are meant to be byte-identical across all four ruleset files --
# laravel.rules/wordpress.rules/prestashop.rules duplicate default.rules'
# content rather than @include it (@include is not real snuffleupagus
# syntax). That was checked by hand each round; re-review caught that a
# hand check ("grep -c" returning 4) had counted four matches in one file,
# not one match in each of four files, and reported false coverage as a
# result. This runs the real check every time instead, no docker needed.
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
echo "ok: DIVERGENCES section and shared rule body are byte-identical across all four rulesets (T12-L)"

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
# unserialize() is deliberately NOT tested for blocking here -- there is no
# unserialize rule in default.rules any more (round-1 review, finding I-1).
# The original hand-written rule blocked ordinary object round trips
# (Laravel's queue worker: unserialize(serialize($job)) fatals, an "O:"
# payload) while a one-level-nested POP chain ("a:1:{i:0;O:...}") sailed
# straight through and fired __wakeup/__destruct -- backwards on both
# halves. Fixed by removing it rather than re-deriving it: vendored
# upstream's own default.rules ships the real primitive
# (sp.unserialize_hmac.enable() + a secret key) commented out, which this
# image cannot own a key for, so "no unserialize rule" is the correct state
# here, not a gap to test against. The positive check below instead proves
# the false positive is gone -- see "does not break a legitimate
# unserialize round trip".

# default.rules blocks the classic system()/proc_open() command-injection
# shape when the argument contains shell metacharacters -- the shape a
# correct call never has. Real files, not `php -r`: confirmed separately
# that `-r` compiles through a different internal path where an
# include()/require() call inside it is NOT intercepted by
# disable_function the way the identical call in a real file or a
# stdin-piped script is (verified: a compress.zlib:// include that fatals
# correctly under both a real file and stdin runs to completion under -r).
# proc_open is the one of the two genuinely uncovered by this image's own
# baked disable_functions on every flavor (fpm/cli's list is "passthru,
# shell_exec, exec, system, show_source, dl, popen, pcntl_exec" --
# proc_open is not in it anywhere), so this is real, additional coverage
# everywhere, not just on cli-builder.
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
echo "ok: default.rules blocks proc_open() command injection (I-6)"

# default.rules blocks include() of a non-.php/.inc/.phtml path through a
# wrapper this image's own allow_url_include=Off does not govern
# (compress.zlib://, phar://) -- I-4: the old hand-written rule only
# pattern-matched http/https/ftp/data/php schemes, all of which
# allow_url_include=Off already refuses on its own, so it added zero real
# coverage while missing the wrappers that still work.
gz_payload=$(printf '<?php echo "gz-payload-executed";' | gzip -c | base64 -w0)
probe="<?php file_put_contents('/tmp/probe.gz', base64_decode('${gz_payload}')); include 'compress.zlib:///tmp/probe.gz'; echo 'AFTER';"
out=$(docker run --rm -i -e PHP_SNUFFLEUPAGUS=default "$IMAGE" php -d allow_url_include=1 <<<"$probe" 2>&1) && \
  fail "default.rules did not block a compress.zlib:// wrapper include: $out"
echo "$out" | grep -qi "disabled_function" || fail "wrapper-include block failed for the wrong reason: $out"
echo "$out" | grep -q "gz-payload-executed" && fail "the wrapper-include payload actually ran: $out"
echo "ok: default.rules blocks non-.php wrapper includes (I-4)"

# T12-D/T12-F: putenv("DYLD_LIBRARY_PATH") is exempted on its own merits --
# macOS-only, inert on this (Linux) image, so upstream's LD_-substring
# hardening false-positives on it for no protective benefit. Not a
# Composer-specific carve-out (Symfony's own defensive env-clearing does
# the identical call) and not part of any attempt to make Composer run
# under a ruleset -- ruling T12-F reverted the one exemption (require, for
# Composer's own phar bootstrap) that existed only to serve that goal, once
# it turned out not to achieve it: getting past that call reaches, three
# layers down, the actual proc_open() command-injection filter blocking a
# benign `stty -a | grep columns` pipe -- the headline RCE protection doing
# its job, not a narrow false positive worth exempting. PHP_SNUFFLEUPAGUS
# and Composer are different phases (runtime-serving vs. build/deploy-time)
# and are not meant to run together; see task-12-fix-report.md's Composer
# section for the full chain.
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

# Documented boundary, not a bug: `require` from Composer's own phar
# bootstrap must still be blocked -- there is deliberately no exemption for
# it any more (ruling T12-F reverted the one that existed). This asserts
# the reversion held, not just that it was written.
out=$(docker run --rm -e PHP_SNUFFLEUPAGUS=default --entrypoint sh "$IMAGE" -c '
  echo "<?php require \"phar:///tmp/uploaded.phar/x\"; echo \"SHOULD_NOT_RUN\";" > /tmp/attacker.php
  docker-php-entrypoint php /tmp/attacker.php
' 2>&1) && fail "require of a phar target is no longer blocked -- did the reverted T12-D require exemption come back?: $out"
echo "$out" | grep -qi "disabled_function" || fail "the require probe failed for the wrong reason: $out"
echo "ok: default.rules still blocks require of a phar target (T12-D's require exemption stays reverted)"

# T12-G finding 1 / T12-I: ini_set('display_errors'|'memory_limit') no
# longer fatals -- Laravel's HandleExceptions.php calls
# ini_set('display_errors', 'Off') on every non-testing request; this is
# the team lead's own reproduction of the Critical finding, checked against
# the exact call shape. Version-split @condition PHP_VERSION_ID <80000/
# >=80000 branches (T12-I) are exercised implicitly here since the image
# under test picks whichever branch matches its own build -- there is no
# 7.x snuffleupagus build to test against directly in this suite (ext.json
# constrains snuffleupagus to php>=7.2, and this project's own 7.x images
# don't exist yet, task 15's job), so the <80000 branch is verified by
# param-name inspection against a live PHP 7.0 build instead (see the fix
# report) rather than an end-to-end run here.
out=$(run_probe "$IMAGE" default '<?php ini_set("display_errors","0"); echo "INISET_OK";') \
  || fail "ini_set('display_errors','0') is still blocked -- Laravel's own bootstrap call would fatal every request: $out"
echo "$out" | grep -q "INISET_OK" || fail "ini_set('display_errors','0') did not complete correctly: $out"
echo "ok: ini_set() exemptions unblock display_errors (T12-G/T12-I)"

out=$(run_probe "$IMAGE" default '<?php ini_set("memory_limit","-1"); echo "memory_limit_OK";') \
  || fail "ini_set('memory_limit','-1') is still blocked: $out"
echo "$out" | grep -q "memory_limit_OK" || fail "ini_set('memory_limit','-1') did not complete correctly: $out"
echo "ok: ini_set() exemption covers memory_limit too"

# max_execution_time is NOT exempted (T12-I finding: round-2 re-review found
# the round-3 exemption was a no-op -- nothing in the vendored file ever
# blocked this key in the first place, so removing the exemption changes
# nothing functionally, only removes a comment that implied it did
# something). Still expected to succeed, for the correct reason this time:
# there is no rule for it at all, exempted or not.
out=$(run_probe "$IMAGE" default '<?php ini_set("max_execution_time","0"); echo "MAXEXEC_OK";') \
  || fail "ini_set('max_execution_time','0') is unexpectedly blocked -- did a drop rule for this key get added somewhere?: $out"
echo "$out" | grep -q "MAXEXEC_OK" || fail "ini_set('max_execution_time','0') did not complete correctly: $out"
echo "ok: ini_set('max_execution_time', ...) succeeds because no rule ever covered it (not because of an exemption -- T12-I)"

# ...and does not widen past the two exempted keys: open_basedir stays
# blocked (a security-relevant key none of the three named frameworks were
# found to touch at bootstrap).
out=$(run_probe "$IMAGE" default '<?php ini_set("open_basedir","/"); echo "SHOULD_NOT_RUN";') && \
  fail "ini_set('open_basedir', ...) is no longer blocked -- the ini_set exemption widened past display_errors/memory_limit: $out"
echo "$out" | grep -qi "disabled_function" || fail "the negative ini_set probe failed for the wrong reason: $out"
echo "ok: ini_set() exemptions do not widen past the two named keys"

# T12-I item 4: curl_setopt($h, CURLOPT_SSL_VERIFYPEER, true) no longer
# fatals -- WordPress's WP_Http_Curl::request() passes the PHP *bool* true
# for this option (the secure direction, and curl's own default), but
# upstream's allow rules only match the *strings* "1"/"2", so the call
# fell through to the drop meant to stop SSL verification being turned
# *off*. Every outbound HTTP call WordPress's own core makes -- including
# the update checks that run on ordinary wp-admin page loads -- fatals
# under wordpress.rules without this fix.
out=$(run_probe "$IMAGE" wordpress '<?php $ch = curl_init(); curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, true); echo "CURL_TRUE_OK";') \
  || fail "curl_setopt(..., CURLOPT_SSL_VERIFYPEER, true) is still blocked -- every WordPress outbound HTTP call would fatal: $out"
echo "$out" | grep -q "CURL_TRUE_OK" || fail "curl_setopt(..., true) did not complete correctly: $out"
echo "ok: curl_setopt() exemption unblocks the bool-true SSL-verify-on call (T12-I item 4)"

# ...and does not widen past the safe direction: turning verification OFF
# must still fatal -- that's the actual vector the vendored rule exists
# to stop, and it's not what WordPress's own call shape needs exempted.
out=$(run_probe "$IMAGE" wordpress '<?php $ch = curl_init(); curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false); echo "SHOULD_NOT_RUN";') && \
  fail "curl_setopt(..., CURLOPT_SSL_VERIFYPEER, false) is no longer blocked -- the exemption widened past the safe (true) direction: $out"
echo "$out" | grep -qi "disabled_function" || fail "the negative curl_setopt probe failed for the wrong reason: $out"
echo "ok: curl_setopt() exemption does not widen past disabling SSL verification"

# T12-G finding 2: function_exists()/is_callable() are no longer blocked at
# all -- Symfony Console's Terminal class (loaded by every `php artisan`
# command) probes function_exists('proc_open') before shelling out for
# terminal width, and upstream's backdoor-recon block treated that
# introspection itself as suspicious.
out=$(run_probe "$IMAGE" default '<?php var_dump(function_exists("proc_open")); echo "FNEXISTS_OK";') \
  || fail "function_exists('proc_open') is still blocked: $out"
echo "$out" | grep -q "FNEXISTS_OK" || fail "function_exists('proc_open') did not complete correctly: $out"
out=$(run_probe "$IMAGE" default '<?php var_dump(is_callable("proc_open")); echo "ISCALLABLE_OK";') \
  || fail "is_callable('proc_open') is still blocked: $out"
echo "$out" | grep -q "ISCALLABLE_OK" || fail "is_callable('proc_open') did not complete correctly: $out"
echo "ok: function_exists()/is_callable() are no longer blocked (T12-G finding 2)"

# ...but the actual capability stays gated: the command-injection rules
# this introspection-block removal does NOT touch are still live.
out=$(run_probe "$IMAGE" default '<?php $p = proc_open("id; whoami", [1=>["pipe","w"]], $pipes); echo stream_get_contents($pipes[1]);') && \
  fail "removing the function_exists()/is_callable() block also weakened the real proc_open() command-injection filter: $out"
echo "$out" | grep -qi "disabled_function" || fail "the negative proc_open probe failed for the wrong reason: $out"
echo "ok: removing function_exists()/is_callable() blocking left the real proc_open() filter untouched"

# default.rules does NOT break an ordinary unserialize() round trip -- the
# exact false positive I-1 found (Laravel's queue worker does
# unserialize(serialize($job)) on every job).
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

# prestashop.rules: readonly_exec must stay off, or every cache-rebuild write
# (the exact bug the chmod shim exists for) would be next in line to block.
# There is no writable-then-execute PHP path to probe without a real
# install (task 20), so this is asserted structurally: the ruleset file must
# not enable readonly_exec. Anchored to an uncommented directive line --
# the vendored upstream block itself ships "# sp.readonly_exec.enable();"
# as a commented-out example, which an unanchored grep would also match.
rules=$(docker run --rm "$IMAGE" cat /usr/local/etc/php/snuffleupagus/prestashop.rules)
echo "$rules" | grep -qE '^[[:space:]]*sp\.readonly_exec\.enable' \
  && fail "prestashop.rules enables readonly_exec, which blocks PrestaShop's own cache-rebuild writes"
echo "ok: prestashop.rules leaves readonly_exec off"

# prestashop.rules no longer drops eval() at all -- round-2 review (T12-G
# finding 3) found the old delta's premise false: PrestaShop's own bundled
# Smarty and Twig compile templates through eval() as part of normal
# rendering, not an edge case, so the rule broke the framework it was
# named for on the first page load. Removed rather than narrowed (there was
# no narrow shape available -- eval() is unconditionally what Twig/Smarty
# use). Structural check that it's actually gone, not just that the
# filename_r() exemption around it was removed.
rules=$(docker run --rm "$IMAGE" cat /usr/local/etc/php/snuffleupagus/prestashop.rules)
echo "$rules" | grep -qE '^[[:space:]]*sp\.disable_function\.function\("eval"\)' \
  && fail "prestashop.rules still drops eval() -- Twig/Smarty template compilation would still be broken"
echo "ok: prestashop.rules no longer blocks eval() (T12-G finding 3)"

# Positive: eval() itself runs normally under every ruleset now.
out=$(run_probe "$IMAGE" prestashop '<?php eval("echo \"EVAL_OK\";");') \
  || fail "eval() is still blocked under prestashop.rules: $out"
echo "$out" | grep -q "EVAL_OK" || fail "eval() did not run correctly under prestashop.rules: $out"
echo "ok: prestashop.rules allows ordinary eval() (Twig/Smarty template compilation)"

# But the deeper layer stays intact: upstream's own eval_blacklist (in the
# vendored "Classic webshells patterns" section, untouched by any of this
# task's exemptions) still catches an actual RCE gadget called *inside* an
# eval'd string, even though eval() itself is no longer blocked outright.
# Removing the top-level eval() block should not have gutted this.
#
# cli-builder only, same reasoning as the earlier system()-command-injection
# probe: on fpm/cli, system() is already undefined per the baked
# disable_functions, so the call fails with "Call to undefined function
# system() in ... eval()'d code" *before* ever reaching snuffleupagus's
# eval_blacklist -- and round-2 re-review caught that the original version
# of this assertion (`grep -qi "eval"`) passed there anyway, matching the
# word "eval" in that unrelated PHP error's own filename text, not an
# actual snuffleupagus verdict. Anchored to the real `[eval]` log tag and
# gated to the one flavor where the call actually reaches the rule being
# tested.
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

# wordpress.rules: round-1 review finding I-5 -- the original hand-written
# delta was inert (ini_protection with no keys), a no-op on this PHP
# version (create_function, removed in 8.0), or actively hazardous
# (assert().drop(), which has no security value since PHP 8.0 stopped
# evaluating string arguments to assert(), while zend.assertions=1 in this
# image means a real, benign assert(1===1) actually runs and would fatal
# under that rule). Rebuilt per ruling T12-C: no WordPress-specific delta
# met the "block a real attack AND don't break normal operation" bar
# within scope, so wordpress.rules ships as upstream's defaults, verbatim.
# Both halves of that claim are checked directly rather than trusted.
out=$(run_probe "$IMAGE" wordpress '<?php assert(1 === 1); echo "ASSERT_OK";') \
  || fail "wordpress.rules fatals on a benign assert(1===1): $out"
echo "$out" | grep -q "ASSERT_OK" || fail "assert(1===1) did not complete correctly under wordpress.rules: $out"
echo "ok: wordpress.rules does not fatal on a benign assert()"

wp_directives=$(docker run --rm "$IMAGE" grep -vE '^[[:space:]]*(#|$)' /usr/local/etc/php/snuffleupagus/wordpress.rules)
default_directives=$(docker run --rm "$IMAGE" grep -vE '^[[:space:]]*(#|$)' /usr/local/etc/php/snuffleupagus/default.rules)
[ "$wp_directives" = "$default_directives" ] \
  || fail "wordpress.rules has directives beyond default.rules's -- an unreviewed WordPress-specific delta snuck in"
echo "ok: wordpress.rules ships upstream's defaults with no additional directives"

# sp-upload-check (round-1 review I-2, I-3): three fixes, each demonstrated
# through the actual snuffleupagus upload_validation hook, not just the
# script run standalone.
#
# CF-42/T14-G: empty output used to be treated as proof of "blocked
# pre-execution", but empty is equally what a container that never bound its
# port, a curl that could not connect, or a missing up.php looks like -- and
# the old srv()'s last statement was `echo "$out"`, so it returned 0
# (measurement "succeeded") even when curl failed outright, and the
# readiness loop below it fell through to the upload request regardless of
# whether it ever exhausted. All three are fixed here, not just the one
# webshell assertion that first surfaced it:
#   - the readiness loop now fails the whole test (non-zero, with the
#     container's logs) when it exhausts instead of proceeding anyway;
#   - srv() itself fails outright when curl cannot reach the upload
#     endpoint (captured exit code, not a `| grep`/last-echo swallow);
#   - srv() returns the HTTP status alongside the body ("<status> <body>"),
#     so a rejection assertion checks both together -- status alone can't
#     be faked by a handler bug, and body alone can't be faked by curl
#     silently returning nothing.
# T19-F: this file's own logs, one per srv() call, written to a fixed path
# derived from this script's own pid (there is only ever one srv()
# container alive at a time, so overwriting between calls is fine) --
# NOT returned through srv()'s own stdout, which command substitution
# (`resp=$(srv ...)`) already captures as "<status> <body>" and which every
# existing caller parses that way. A file survives the command-substitution
# subshell srv() itself runs in (only shell-variable/env changes do not),
# so this is the plain way for a caller to see the container's logs without
# reshaping srv()'s return value or fetching them a second time (impossible
# once the container is gone).
SRV_LOG_FILE="/tmp/sp-srv-logs.$$"
# T19-S: this file is overwritten by each srv() call and never removed after
# the last one -- leaked into /tmp on every run of this suite. One trap for
# the one file, set right where the name is chosen.
trap 'rm -f "$SRV_LOG_FILE"' EXIT

srv() {
  # $1: PHP_SNUFFLEUPAGUS  $2: file to upload  $3: optional -- pass
  # "allow_curl_failure" when the upload request itself is *expected* to
  # possibly not get an HTTP response at all (L-4: PHP 7.4's dev server
  # closes the connection outright, curl exit 52, when snuffleupagus's
  # drop() action aborts the worker process before it can write a response
  # -- 8.5 manages to write a bare 500 first). Every other caller keeps the
  # strict behaviour: a curl failure is a hard `fail`, not a valid outcome.
  # Prints "<http-status> <body>" on an ordinary HTTP response, or
  # "000 CURLFAIL:<exit-code>" when $3 was passed and curl could not get a
  # response at all; writes this container's docker logs to $SRV_LOG_FILE
  # either way.
  local name port code out rc status body allow_curl_failure="${3:-}"
  name="sp-upload-e2e-$$"
  port=$((18100 + RANDOM % 1000))

  # T19-F: `set -e` does not propagate out of a `$(...)` command
  # substitution into the calling shell by default (confirmed live: a
  # `false` as a function's non-last statement, called as `x=$(f)`, does not
  # abort the script -- `shopt -s inherit_errexit` would be needed for that,
  # and this repo's scripts do not set it) -- so a failing `docker run -d`
  # here (port already bound by something else, a bad image reference, ...)
  # used to be silently swallowed: the readiness loop below would just spin
  # until it exhausted, or -- worse, the exact false-pass the verifier
  # reproduced -- find something ALREADY listening on the same host port
  # (left over from a previous run, or another process/container entirely)
  # and treat whatever THAT answers with as this container's own response.
  # Checked here explicitly instead of relying on any propagation.
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

  # Readiness poll: curl failing to connect is the expected, normal shape
  # while the server is still starting, not a measurement in its own right
  # -- the actual measurement is the upload request below, which does not
  # tolerate the same failure silently. "000" is curl's own %{http_code} for
  # "no HTTP response was received at all" (connection refused/reset), the
  # only value that can never be a real server response.
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
      # L-4: a caller that explicitly opted in accepts "no HTTP response at
      # all" as a possible outcome (PHP 7.4's dev server closes the
      # connection outright when snuffleupagus's drop() action aborts the
      # worker, where 8.5 manages to write a bare 500 first) -- but it still
      # gets the container's logs, and the caller is the one that must
      # check those logs for snuffleupagus's own rejection line before
      # treating this as anything but a plain failure.
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

  # T19-F: HTTP 500 with an empty body is also exactly what this same
  # handler produces if snuffleupagus rejects the upload -- but it is also
  # exactly what an unrelated stub server, or a totally different failure,
  # produces (that ambiguity is the whole reason CF-42 exists). Captured to
  # a file *before* removing the container -- observed live that the
  # container's own process aborts (a heap-corruption crash under the dev
  # server + JIT combination) the instant snuffleupagus's upload_validation
  # hook drops a request, so `--rm` was dropped from `docker run` above and
  # removal happens here, explicitly, after logs are already on disk, not
  # racing whatever cleanup `--rm` would have triggered on its own.
  docker logs "$name" >"$SRV_LOG_FILE" 2>&1 || true
  docker rm -f "$name" >/dev/null 2>&1

  echo "${status} ${body}"
}

shortecho="/tmp/sp-shortecho-$$.php"
printf '<?= system($_GET[0]); ?>' > "$shortecho"

# Positive control (T14-G): a benign upload through the exact same
# server/channel has to round-trip BEFORE the rejection assertion below
# means anything. Without this, an empty body from the webshell request
# below would be indistinguishable from "the channel never worked at all" --
# this is what tells "blocked" apart from "never asked".
benign="/tmp/sp-benign-$$.txt"
printf 'just an ordinary file' > "$benign"
resp=$(srv default "$benign")
rm -f "$benign"
resp_status="${resp%% *}"; resp_body="${resp#* }"
[ "$resp_status" = 200 ] && [ "$resp_body" = UPLOAD_ACCEPTED ] \
  || fail "sp-upload-check positive control failed: a benign upload through the same channel did not round-trip (status=$resp_status body='$resp_body') -- the webshell-rejection assertion below would prove nothing"
echo "ok: sp-upload-check positive control -- a benign upload round-trips (UPLOAD_ACCEPTED) before the rejection assertion"

# L-4: on PHP 7.4 this same rejection closes the connection outright (curl
# exit 52, "Empty reply from server") instead of returning a bare 500 --
# confirmed via the container's own log: snuffleupagus's drop() logs its
# fatal, and the built-in dev server closes the socket right after without
# ever writing a response, where 8.5's dev server still manages to write
# the 500 first. `allow_curl_failure` lets that shape through; the log line
# check below is what actually decides pass/fail, on every version.
resp=$(srv default "$shortecho" allow_curl_failure)
rm -f "$shortecho"
resp_status="${resp%% *}"; resp_body="${resp#* }"
# T19-F: HTTP 500 + empty body is also exactly what a container that never
# ran the handler at all (a stub, a crashed unrelated process, the wrong
# port) produces -- reproduced live against a stub that always answers 500
# with an empty body and nothing else (see task-19b-fix-report.md). Confirm
# the rejection actually came from snuffleupagus's own upload_validation
# hook by matching its log line in this same container's logs FIRST -- this
# is what the pass/fail decision rests on, not the HTTP-level shape, which
# is allowed to differ by version only once this line is confirmed present.
# A closed connection with no such log line is not evidence of anything and
# stays a plain FAIL.
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
    # L-4: transport closed before any response was written (PHP 7.4's dev
    # server under this exact drop). Acceptable ONLY because sp_log_hit
    # already proved snuffleupagus is what caused it, checked above.
    ;;
  *)
    fail "sp-upload-check: snuffleupagus's log confirms the rejection, but the request returned an unexpected status=$resp_status (body='$resp_body') -- neither the documented 500 nor a closed connection"
    ;;
esac
echo "ok: sp-upload-check rejects <?= webshells (I-3), confirmed via snuffleupagus's own rejection log line (transport shape: status=$resp_status)"

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
echo "ok: sp-upload-check accepts plugin/module zip uploads (I-2)"

# T12-G finding 4: a file whose first bytes are zip magic but which is not
# actually a valid zip -- `PK\x03\x04` immediately followed by
# `<?php system($_GET[0]);` -- used to sail straight through the
# magic-byte-only check (round-2 review found this live) and get accepted
# without any content inspection. Direct script check, matching how the
# fail-closed-on-unreadable check above is verified.
polyglot_check=$(docker run --rm --entrypoint sh "$IMAGE" -c '
  printf "PK\003\004<?php system(\$_GET[0]);" > /tmp/sp-polyglot.zip
  /usr/local/bin/sp-upload-check /tmp/sp-polyglot.zip
  echo "rc=$?"
')
echo "$polyglot_check" | grep -q "rc=1" || fail "sp-upload-check accepted a zip-magic-bytes-then-<?php polyglot: $polyglot_check"
echo "ok: sp-upload-check validates archive integrity, not just magic bytes (T12-G finding 4)"

# T12-I item 5: archive validation decompresses the whole payload to check
# it (that's how integrity checking works), which round-2 re-review showed
# is an unbounded-CPU DoS -- a 9.4MB gzip of 2GB of zeros cost 4.2s of CPU
# in one FPM worker. Fixed with a timeout around each validator call.
# ARCHIVE_CHECK_TIMEOUT=1 here (default in the image is 5) just to keep
# this assertion itself fast -- the bomb below decompresses to 5GB, so a
# real timeout would still fire well before a legitimate small plugin/
# module zip's sub-second validation ever would.
dos_check=$(docker run --rm --entrypoint sh -e ARCHIVE_CHECK_TIMEOUT=1 "$IMAGE" -c '
  dd if=/dev/zero bs=1M count=5000 2>/dev/null | gzip -9 > /tmp/sp-bomb.gz
  /usr/local/bin/sp-upload-check /tmp/sp-bomb.gz
  echo "rc=$?"
' 2>&1)
echo "$dos_check" | grep -q "rc=1" || fail "sp-upload-check did not reject an oversized-decompression archive within its timeout: $dos_check"
echo "ok: sp-upload-check bounds archive-validation CPU cost with a timeout (T12-I item 5)"

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
echo "ok: sp-upload-check fails closed, not open, on an unreadable file (I-3)"

# T12-J: move_uploaded_file() destination patterns anchored to the actual
# file extension. Upstream's own vendored patterns were "\.ph" / "\.ht",
# unanchored -- matching those letters anywhere in the destination path,
# not just as the real extension. Round-2 re-review demonstrated this live
# against ordinary filenames a WordPress media upload can produce.
#
# move_uploaded_file() itself always returns false outside a real HTTP
# upload (its own is_uploaded_file() check fails on a CLI-built tempfile),
# so "PHP's own false" and "snuffleupagus blocked it" are told apart by
# whether the output carries snuffleupagus's own disabled_function tag --
# not by the boolean return value, which is false either way for these
# probes. No @ on the call: before PHP 8 it silences fatals too, so on 7.x
# snuffleupagus's drop message vanished and the block looked like a crash.
# A non-uploaded source makes move_uploaded_file() return false quietly, so
# there is nothing else for it to hide.
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
      fail "$rs.rules still blocks move_uploaded_file() to '$fname' (T12-J regression): $out"
    echo "$out" | grep -q "REACHED_PHP" || fail "$rs.rules probe for '$fname' did not run to completion: $out"
  done
done
echo "ok: move_uploaded_file() no longer false-positives on holiday.photo.jpg, my.phone.png, chart.ht.svg, summer.photos.zip (T12-J)"

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
echo "ok: move_uploaded_file() still blocks shell.php/.PHP/.phtml/.phar/.htaccess/.htpasswd (T12-J)"

# T12-J follow-up (round-6 re-review): the `$`-anchored pattern above
# closed the false-positive bug but reopened a narrower one -- a bare `$`
# anchor stopped matching once a dangerous filename had trailing junk
# after its real extension ("shell.php " with a trailing space, "shell.
# php." with a trailing dot), which the old *unanchored* rule caught by
# accident. Fixed by absorbing a run of trailing spaces and/or dots before
# the end anchor. A trailing tab is deliberately not covered here -- a
# live probe found the config DSL does not reliably pass a `\t` escape
# through to the regex engine as an actual tab, and this project does not
# ship a rule whose own comment claims coverage the probe couldn't verify.
for rs in default laravel wordpress prestashop; do
  for fname in "shell.php " "shell.php." "shell.php   " "shell.php..." "shell.php. " ".htaccess " ".htaccess..."; do
    out=$(move_upload_probe "$rs" "$fname") && \
      fail "$rs.rules did not block move_uploaded_file() to '$fname' (trailing junk after a real extension): $out"
    echo "$out" | grep -qi "disabled_function" || \
      fail "$rs.rules block of '$fname' failed for the wrong reason: $out"
  done
done
echo "ok: move_uploaded_file() still blocks shell.php/.htaccess with trailing spaces/dots after the real extension (T12-J follow-up)"

# The double-extension case: a real, later extension after an earlier
# "ph"/"ht" occurrence must be judged on its own real extension, not the
# earlier one -- confirms the trailing-junk widening didn't turn into a
# second unanchored match.
out=$(move_upload_probe default "shell.php.php") && \
  fail "default.rules did not block move_uploaded_file() to 'shell.php.php': $out"
echo "$out" | grep -qi "disabled_function" || fail "block of 'shell.php.php' failed for the wrong reason: $out"
echo "ok: move_uploaded_file() blocks a double .php extension on its own real ending (T12-J follow-up)"

# mail()'s fifth argument goes to sendmail as flags; -X writes a log file
# wherever it is told. The rule names the argument, and that name changed in
# PHP 8.0 -- a version gate one release off left 8.0-8.2 filtering on a name
# they do not have, so every version is probed rather than one.
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
