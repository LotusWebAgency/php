#!/usr/bin/env bash
set -euo pipefail
IMAGE="${1:?usage: test-entrypoint.sh <image> <flavor>}"
FLAVOR="${2:?usage: test-entrypoint.sh <image> <flavor>}"
case "$FLAVOR" in
  fpm|cli|cli-builder) ;;
  *) echo "FAIL: flavor '$FLAVOR' is not one of fpm, cli, cli-builder" >&2; exit 1 ;;
esac
fail() { echo "FAIL: $*" >&2; exit 1; }

# Task 19b fix2b: no image builds in this task -- every `docker run` below
# has to test the *working-tree* docker-php-entrypoint (and, for fpm,
# conf/www.conf) against whatever's already built locally, not the stale
# copy baked into that image. ENTRYPOINT_OVERRIDE/WWW_CONF_OVERRIDE are
# opt-in local paths, bind-mounted read-only over the image's own copy on
# every `docker run` this script makes (a container keeps a bind mount for
# its whole life, so `docker exec <c> docker-php-entrypoint ...` -- T19-D --
# picks it up automatically too, no separate handling needed there). Left
# unset (the default), this function is a pure passthrough: smoke.sh's own
# invocation of this script must keep testing exactly what's baked, which
# is the whole point of CF-47's inputs-hash gate. A call that already mounts
# something of its own at the www.conf path (T19-C/T19-M's custom pool
# configs) is left alone -- that mount IS the thing under test there, and
# docker refuses two binds to the same destination.
docker() {
  if [ "$1" = run ]; then
    shift
    local -a extra=()
    if [ -n "${ENTRYPOINT_OVERRIDE:-}" ]; then
      extra+=(-v "${ENTRYPOINT_OVERRIDE}:/usr/local/bin/docker-php-entrypoint:ro")
    fi
    if [ -n "${WWW_CONF_OVERRIDE:-}" ]; then
      case " $* " in
        *"/usr/local/etc/php-fpm.d/www.conf"*) ;;
        *) extra+=(-v "${WWW_CONF_OVERRIDE}:/usr/local/etc/php-fpm.d/www.conf:ro") ;;
      esac
    fi
    command docker run "${extra[@]}" "$@"
    return
  fi
  command docker "$@"
}

# Task 19b fix2b: PHP 7.4's php-fpm -tt duplicates every single NOTICE line
# in its config dump, back to back and byte-identical (confirmed live --
# even the "[global]"/"[www]" pool headers print twice; PHP 8.1+ does not do
# this). A bare `grep -oE '...[0-9]+' | grep -oE '[0-9]+'` for one directive
# then returns the same value twice, and a plain `[[ "$x" -ge N ]]` on that
# two-line string fails with a bash arithmetic-syntax error instead of
# testing anything -- discovered running this suite against 7.4-fpm for the
# first time (this task's images list), not a regression from this round's
# own changes. Collapses stdin (one value per line) to the single distinct
# value the dump actually claims for a directive, still failing loudly if
# -tt ever disagrees with itself rather than silently averaging or picking
# one arbitrarily.
single_value() {
  local vals
  vals=$(sort -u)
  case "$(printf '%s\n' "$vals" | grep -c .)" in
    1) printf '%s' "$vals" ;;
    *) fail "php-fpm -tt gave inconsistent or missing values for a directive: $(tr '\n' ' ' <<<"$vals")" ;;
  esac
}

# Retries a `cgi-fcgi` request a few times: `docker exec true` succeeding only
# proves the container namespace is enterable, not that php-fpm's listener is
# actually accepting connections yet, and a `var=$(cmd)` assignment at the
# top level (unlike inside a function) DOES trip `set -e` on a non-zero exit
# -- a connection-refused race here would otherwise kill the whole suite with
# no FAIL: message, just cgi-fcgi's own raw exit code.
fcgi_request() {
  local cname="$1"; shift
  local out rc
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    set +e
    out=$(docker exec "$@" "$cname" cgi-fcgi -bind -connect 127.0.0.1:9000 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 0 ] && break
    sleep 0.3
  done
  [ "$rc" -eq 0 ] || fail "fcgi_request: cgi-fcgi against $cname never succeeded (last exit $rc): $out"
  echo "$out"
}

# M-c (task 19b fix round 4): PHP 8.0+ removes a disabled function from the
# function table outright ("Call to undefined function proc_open()"); PHP
# 7.x instead leaves it reachable but stubbed, warns "... has been disabled
# for security reasons" and returns false/NULL, so the script keeps running.
# The three proc_open assertions below used to accept the 7.x shape (the
# probe's own derived PROC_OPEN_BLOCKED marker) on every PHP version and
# without requiring that warning's own text -- so on an 8.x image, any
# unrelated proc_open() failure would have passed as "the 7.x shape" even
# though that shape can never legitimately occur there, and even on a real
# 7.x image the marker alone never proved disable_functions was the actual
# cause (T19-P already required the fatal's own log text for the 8.x shape;
# this is that same standard applied to the 7.x one).
PHP_MAJOR=$(docker run --rm "$IMAGE" php -r 'echo PHP_MAJOR_VERSION;')

# T19-I: this whole file used to run only against the fpm image (smoke.sh's
# own gate), with cli/cli-builder coverage faked by deriving a second image
# tag and skipping (printing SKIP, exit 0) when it was not present locally --
# which passed even when no such image had ever been built, and never once
# actually exercised the real cli/cli-builder images even when it was. Fixed
# at both ends: smoke.sh now calls this script once per flavor with the
# image actually under test (no more derived tag, no more SKIP-and-pass), and
# every assertion below that can only mean something for an fpm pool config
# (php-fpm itself does not exist on cli/cli-builder) is gated on $FLAVOR
# rather than assumed. The disable_functions cases further down (T19-B) and
# the extension/chmod-shim/ini-scan-dir guards run for every flavor -- they
# were never fpm-specific to begin with, only untested elsewhere.

# 1. ini overrides land
got=$(docker run --rm -e PHP_MEMORY_LIMIT=777M "$IMAGE" php -r 'echo ini_get("memory_limit");')
[[ "$got" == "777M" ]] || fail "PHP_MEMORY_LIMIT ignored, got '$got'"
echo "ok: PHP_MEMORY_LIMIT"

# 2. extension opt-in -- both names, not just the first
# L-3: bz2/yaml, not mongodb -- ext.json declares mongodb php>=8.1 (pecl.lock's
# own configure refuses anything below that), so it does not exist at all on
# this repo's 7.x/8.0 images ("no such extension: mongodb"); bz2 and yaml are
# both declared php>=7.0 with no upper bound, so they are the version-correct
# choice on every image this script runs against, not just this one.
mods=$(docker run --rm -e PHP_EXT_ENABLE=bz2,yaml "$IMAGE" php -m)
echo "$mods" | grep -qix bz2 || fail "PHP_EXT_ENABLE did not load bz2"
echo "$mods" | grep -qix yaml || fail "PHP_EXT_ENABLE did not load yaml"
echo "ok: PHP_EXT_ENABLE"

if [ "$FLAVOR" = fpm ]; then
# 3-5. Ruling T11-G: no pool config file is written at all -- www.conf
# references every tunable directive as ${PHP_FPM_*} and php-fpm resolves
# them from its own environment. `php-fpm -tt` is the verification tool
# now: it loads and prints the fully-resolved config and exits, no daemon
# needed, works identically writable or read-only.

# 3. autotune scales down on a small container
tt=$(docker run --rm -m 512m "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "512m: php-fpm rejected the config: $tt"
children=$(echo "$tt" | grep -oE 'pm\.max_children = [0-9]+' | grep -oE '[0-9]+' | single_value)
[[ "$children" -ge 4 && "$children" -le 8 ]] || fail "512m container got max_children=$children"
echo "ok: autotune small ($children children)"

# 4. and up on a large one
tt=$(docker run --rm -m 4g "$IMAGE" php-fpm -tt 2>&1)
children_l=$(echo "$tt" | grep -oE 'pm\.max_children = [0-9]+' | grep -oE '[0-9]+' | single_value)
[[ "$children_l" -gt "$children" ]] || fail "4g container got $children_l, not more than 512m's $children"
echo "ok: autotune large ($children_l children)"

# 5. explicit override wins over autotune
tt=$(docker run --rm -m 4g -e PHP_FPM_MAX_CHILDREN=3 "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q 'pm\.max_children = 3$' || fail "PHP_FPM_MAX_CHILDREN ignored: $tt"
echo "ok: explicit override wins"
fi

# 6. read-only rootfs still starts
# Capture, then match. A host-side `docker run ... | grep -q` SIGPIPEs the
# producer on first match and pipefail reports the pipeline as failed; these
# two only ever fail closed (a false red rather than a false pass), but the
# standing idiom in this repo is capture-then-match, and a gate that goes red
# under parallel load trains people to re-run it until it is green.
ro_out=$(docker run --rm --read-only --tmpfs /tmp "$IMAGE" php -r 'echo "ro-ok";')
grep -q ro-ok <<<"$ro_out" \
  || fail "does not start with a read-only rootfs"
echo "ok: read-only rootfs"

# 7. unknown extension fails loudly rather than silently
if docker run --rm -e PHP_EXT_ENABLE=notareal_ext "$IMAGE" php -v >/dev/null 2>&1; then
  fail "unknown extension name did not fail"
fi
echo "ok: unknown extension rejected"

# --- php-ext-enable input guard -------------------------------------------
# PHP_EXT_ENABLE is untrusted-input territory: the entrypoint feeds it
# straight from the container environment into php-ext-enable, which glues
# a "20-" prefix onto whatever name it's given. Today that prefix happens to
# turn a leading ../ into a bogus directory component -- emergent, not
# designed -- so these assert on the guard's own message, not just a
# non-zero exit, to prove the explicit charset check is what's firing.

# 8. ../ is rejected by the guard
set +e
out=$(docker run --rm -e PHP_EXT_ENABLE=../etc "$IMAGE" php -v 2>&1 >/dev/null)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "../ traversal in PHP_EXT_ENABLE was not rejected"
echo "$out" | grep -q "invalid extension name" || fail "../ rejected for the wrong reason: $out"
echo "ok: ../ rejected by guard"

# 9. a leading / is rejected by the guard
set +e
out=$(docker run --rm -e PHP_EXT_ENABLE=/etc/passwd "$IMAGE" php -v 2>&1 >/dev/null)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "leading / in PHP_EXT_ENABLE was not rejected"
echo "$out" | grep -q "invalid extension name" || fail "leading / rejected for the wrong reason: $out"
echo "ok: leading / rejected by guard"

# 10. an empty element (stray/doubled comma) is tolerated, not fatal --
# reached by calling php-ext-enable directly, since PHP_EXT_ENABLE's
# `tr ',' ' '` followed by unquoted word-splitting never actually produces
# an empty positional argument on the entrypoint's own path.
empty_arg_mods=$(docker run --rm "$IMAGE" sh -c 'php-ext-enable "" bz2 >/dev/null && php -m')
grep -qix bz2 <<<"$empty_arg_mods" \
  || fail "an empty argument to php-ext-enable broke a valid extension"
echo "ok: empty element tolerated"

# 11. a shell metacharacter in the name is rejected by the guard
set +e
out=$(docker run --rm -e 'PHP_EXT_ENABLE=bz2;id' "$IMAGE" php -v 2>&1 >/dev/null)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a shell metacharacter in PHP_EXT_ENABLE was not rejected"
echo "$out" | grep -q "invalid extension name" || fail "metacharacter rejected for the wrong reason: $out"
echo "ok: shell metacharacter rejected by guard"

# --- inert-today branches ---------------------------------------------------
# The chmod shim (task 13) doesn't exist in this image yet and must fail
# loudly, not start up silently missing the behaviour that was asked for.
# snuffleupagus (task 12) now does exist -- see assertion 12 below, which
# used to assert the opposite (that PHP_SNUFFLEUPAGUS failed) back when
# neither the module nor tests/test-snuffleupagus.sh's own coverage existed.

# 12. PHP_SNUFFLEUPAGUS=<real ruleset> now succeeds and actually loads the
# module (full ruleset-by-ruleset coverage lives in
# tests/test-snuffleupagus.sh; this just has to prove the entrypoint branch
# itself still does its job on a real image). An unknown ruleset name must
# still fail loudly -- same requirement as before task 12, different reason
# (no such .rules file now, vs. no snuffleupagus support at all before).
# 7.0 and 7.1 ship without the module (ext.json: php >=7.2); there the same
# request has to refuse, naming the extension, rather than start without it.
# Whether it should be present at all is smoke.sh's registry-derived check.
if docker run --rm --entrypoint sh "$IMAGE" -c 'test -f "$(php -r "echo ini_get(\"extension_dir\");")/snuffleupagus.so"'; then
  mods=$(docker run --rm -e PHP_SNUFFLEUPAGUS=laravel "$IMAGE" php -m)
  echo "$mods" | grep -qi snuffleupagus || fail "PHP_SNUFFLEUPAGUS=laravel did not load the snuffleupagus module"
  echo "ok: PHP_SNUFFLEUPAGUS enables the module"
else
  set +e
  out=$(docker run --rm -e PHP_SNUFFLEUPAGUS=laravel "$IMAGE" php -m 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "PHP_SNUFFLEUPAGUS=laravel started on an image without snuffleupagus: $out"
  echo "$out" | grep -q "no such extension: snuffleupagus" \
    || fail "PHP_SNUFFLEUPAGUS=laravel on an image without the module failed for the wrong reason: $out"
  echo "ok: PHP_SNUFFLEUPAGUS refuses on an image that ships without the module"
fi

set +e
out=$(docker run --rm -e PHP_SNUFFLEUPAGUS=foo "$IMAGE" php -v 2>&1 >/dev/null)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "PHP_SNUFFLEUPAGUS=foo (no such ruleset) was not rejected"
echo "$out" | grep -qi "no such snuffleupagus ruleset" || fail "unknown ruleset rejected for the wrong reason: $out"
echo "ok: an unknown ruleset name still fails loudly"

# 12b. PHP_SNUFFLEUPAGUS is a bare ruleset name, never a path: '../x' used to
# resolve outside /usr/local/etc/php/snuffleupagus/. Refused before anything is
# written, on every image, module or not. The empty value is refused by the
# generic set-but-empty loop (see below), repeated here so the whole contract
# sits in one place.
for v in '../etc/passwd' 'a/b' 'UPPER' '-x' '_x' 'a b' 'a.b'; do
  set +e
  out=$(docker run --rm -e "PHP_SNUFFLEUPAGUS=${v}" "$IMAGE" php -v 2>&1 >/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "PHP_SNUFFLEUPAGUS='${v}' was not rejected"
  echo "$out" | grep -qF "refusing PHP_SNUFFLEUPAGUS=${v}: a ruleset name is lowercase letters" \
    || fail "PHP_SNUFFLEUPAGUS='${v}' rejected for the wrong reason: $out"
done
set +e
out=$(docker run --rm -e PHP_SNUFFLEUPAGUS= "$IMAGE" php -v 2>&1 >/dev/null)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "PHP_SNUFFLEUPAGUS= (set but empty) was accepted"
echo "$out" | grep -q "refusing PHP_SNUFFLEUPAGUS: set but empty" \
  || fail "PHP_SNUFFLEUPAGUS= rejected for the wrong reason: $out"
echo "ok: a PHP_SNUFFLEUPAGUS that is not a bare lowercase name is refused"

# 12c. A custom ruleset: a file mounted read-only into the ruleset directory,
# selected by name. Needs the module, so images without it skip.
if docker run --rm --entrypoint sh "$IMAGE" -c 'test -f "$(php -r "echo ini_get(\"extension_dir\");")/snuffleupagus.so"'; then
  sp_custom_dir=$(mktemp -d)
  chmod 755 "$sp_custom_dir"
  printf '%s\n' 'sp.harden_random.enable();' > "${sp_custom_dir}/my-site_2.rules"
  chmod 644 "${sp_custom_dir}/my-site_2.rules"
  out=$(echo '<?php echo "loaded:", ini_get("sp.configuration_file");' \
    | docker run --rm -i -v "${sp_custom_dir}/my-site_2.rules:/usr/local/etc/php/snuffleupagus/my-site_2.rules:ro" \
        -e PHP_SNUFFLEUPAGUS=my-site_2 "$IMAGE" php 2>&1) \
    || { rm -rf "$sp_custom_dir"; fail "a mounted custom ruleset did not load: $out"; }
  rm -rf "$sp_custom_dir"
  echo "$out" | grep -q "loaded:/usr/local/etc/php/snuffleupagus/my-site_2.rules" \
    || fail "the custom ruleset is not the one snuffleupagus was pointed at: $out"
  echo "ok: a custom ruleset mounted into the ruleset directory loads by name"
fi

# 13. PHP_CHMOD_SHIM now succeeds and actually toggles LD_PRELOAD (task 13).
# Behavioural proof that the shim changes chmod() behaviour -- on vs off --
# lives in tests/test-fpm-health.sh; this only proves the entrypoint branch
# itself sets LD_PRELOAD, accepts the documented boolean spellings (CF-33),
# and refuses anything that is neither on nor off rather than silently
# treating it as off.
set +e
out=$(docker run --rm -e PHP_CHMOD_SHIM=1 "$IMAGE" env 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "PHP_CHMOD_SHIM=1 did not start: $out"
echo "$out" | grep -q '^LD_PRELOAD=.*php-chmod-sanitize\.so' || fail "PHP_CHMOD_SHIM=1 did not set LD_PRELOAD: $out"
echo "ok: PHP_CHMOD_SHIM=1 sets LD_PRELOAD"

for v in true TRUE yes on; do
  set +e
  out=$(docker run --rm -e "PHP_CHMOD_SHIM=${v}" "$IMAGE" env 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "PHP_CHMOD_SHIM=${v} did not start: $out"
  echo "$out" | grep -q '^LD_PRELOAD=.*php-chmod-sanitize\.so' || fail "PHP_CHMOD_SHIM=${v} did not set LD_PRELOAD: $out"
done
echo "ok: PHP_CHMOD_SHIM accepts true/TRUE/yes/on"

for v in 0 false FALSE no off; do
  out=$(docker run --rm -e "PHP_CHMOD_SHIM=${v}" "$IMAGE" env 2>&1)
  echo "$out" | grep -q '^LD_PRELOAD=' && fail "PHP_CHMOD_SHIM=${v} unexpectedly set LD_PRELOAD: $out"
done
echo "ok: PHP_CHMOD_SHIM accepts 0/false/no/off and leaves the shim inert"

for v in 2 maybe TRUEX; do
  set +e
  out=$(docker run --rm -e "PHP_CHMOD_SHIM=${v}" "$IMAGE" php -v 2>&1 >/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "PHP_CHMOD_SHIM=${v} (neither on nor off) was not rejected"
  echo "$out" | grep -qi "invalid PHP_CHMOD_SHIM=${v}" || fail "PHP_CHMOD_SHIM=${v} rejected for the wrong reason: $out"
done
echo "ok: PHP_CHMOD_SHIM rejects ambiguous values instead of silently treating them as off"

# --- round-1 review fixes ---------------------------------------------------

if [ "$FLAVOR" = fpm ]; then
# 14. C1: the spec's own documented format for tuning values (an M-suffixed
# size, e.g. PHP_FPM_WORKER_MEMORY=64M) must not silently fall back to the
# baked static pm.max_children.
tt=$(docker run --rm -m 512m -e PHP_FPM_WORKER_MEMORY=64M "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "PHP_FPM_WORKER_MEMORY=64M was rejected: $tt"
echo "$tt" | grep -q 'pm\.max_children = 4$' || fail "PHP_FPM_WORKER_MEMORY=64M did not autotune: $tt"
echo "ok: M-suffixed PHP_FPM_WORKER_MEMORY accepted"

# also: a value that parses to zero must abort loudly, not silently
if docker run --rm -m 512m -e PHP_FPM_WORKER_MEMORY=0 "$IMAGE" true >/dev/null 2>&1; then
  fail "PHP_FPM_WORKER_MEMORY=0 (division by zero) was not rejected"
fi
echo "ok: PHP_FPM_WORKER_MEMORY=0 rejected loudly"
fi

if [ "$FLAVOR" = fpm ]; then
# 15. I1: with no cgroup memory limit, autotuning must not derive from host
# RAM (hundreds of workers on a shared host) -- it must warn and assume a
# small fixed default instead.
set +e
out=$(docker run --rm -e PHP_FPM_WORKER_MEMORY=64 "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "no-limit case did not exit 0: $out"
echo "$out" | grep -qi "no container memory limit detected" || fail "no-limit case did not warn: $out"
children_nolimit=$(echo "$out" | grep -oE 'pm\.max_children = [0-9]+' | grep -oE '[0-9]+' | single_value)
[[ "$children_nolimit" -le 16 ]] || fail "no-limit case derived $children_nolimit children from host RAM instead of a conservative default"
echo "ok: no cgroup limit warns and assumes a conservative default ($children_nolimit children)"
fi

if [ "$FLAVOR" = fpm ]; then
# 16. I2/B1: read-only rootfs must autotune regardless of invocation shape
# -- direct argv[0]=php-fpm, and wrapped in a shell (the exact case that
# silently lost autotuning in round 2: the old mechanism only spliced -y
# onto the command line when php-fpm was literally $1).
tt=$(docker run --rm --read-only --tmpfs /tmp -m 512m "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "read-only rootfs: php-fpm rejected the config: $tt"
echo "$tt" | grep -q 'pm\.max_children = 16$' && fail "read-only rootfs fell back to the static default: $tt"
# The container's real ENTRYPOINT (tini -- docker-php-entrypoint) still
# runs here -- only the COMMAND is a wrapper, so docker-php-entrypoint's own
# "$@" is ["sh", "-c", "exec php-fpm -tt"], $1="sh", not "php-fpm".
tt_wrapped=$(docker run --rm --read-only --tmpfs /tmp -m 256m "$IMAGE" \
  sh -c 'exec php-fpm -tt' 2>&1)
echo "$tt_wrapped" | grep -q 'pm\.max_children = 4$' \
  || fail "read-only rootfs did not autotune when php-fpm was wrapped in a shell: $tt_wrapped"
echo "ok: read-only rootfs autotunes, direct and wrapped"
fi

# 17. I3: a newline in a core PHP_* value must not inject a second ini
# directive (e.g. auto_prepend_file, which would run arbitrary PHP on every
# request).
set +e
out=$(docker run --rm -e "PHP_MEMORY_LIMIT=$(printf '128M\nauto_prepend_file=/tmp/x.php')" "$IMAGE" php -r 'echo ini_get("memory_limit");' 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "newline-embedded PHP_MEMORY_LIMIT was not rejected: $out"
echo "$out" | grep -qi "refusing PHP_MEMORY_LIMIT" || fail "newline injection rejected for the wrong reason: $out"
echo "ok: newline injection rejected"

if [ "$FLAVOR" = fpm ]; then
# 18. I4: PHP_FPM_ACCESS_LOG, the one §10 variable an earlier round found
# unread. /dev/null, not an arbitrary path: `-tt` actually opens the access
# log as part of validating the config, so a path that doesn't exist makes
# this fail for an unrelated reason (ENOENT) rather than testing the
# substitution.
tt=$(docker run --rm -m 512m -e PHP_FPM_ACCESS_LOG=/dev/null "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "PHP_FPM_ACCESS_LOG=/dev/null was rejected: $tt"
echo "$tt" | grep -q 'access\.log = /dev/null$' || fail "PHP_FPM_ACCESS_LOG ignored: $tt"
echo "ok: PHP_FPM_ACCESS_LOG"

# 19. M1: PHP_FPM_MAX_CHILDREN=1 must produce a config php-fpm actually
# accepts (min_spare/max_spare/start_servers all clamped to 1).
tt=$(docker run --rm -m 512m -e PHP_FPM_MAX_CHILDREN=1 "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "PHP_FPM_MAX_CHILDREN=1 produced a config php-fpm rejects: $tt"
echo "ok: PHP_FPM_MAX_CHILDREN=1 starts cleanly"

# 20. M2: an explicit small PHP_FPM_START_SERVERS must be honored exactly,
# not silently raised to the derived-default floor of 2.
tt=$(docker run --rm -m 4g -e PHP_FPM_START_SERVERS=1 "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q 'pm\.start_servers = 1$' || fail "explicit PHP_FPM_START_SERVERS=1 was overridden: $tt"
echo "ok: explicit start_servers honored below the derived-default floor"
fi

# 21. M3: PHP_EXT_ENABLE must not be glob-expanded against the working
# directory before validation.
set +e
out=$(docker run --rm -w /usr/local/etc/php/conf.d -e 'PHP_EXT_ENABLE=*' "$IMAGE" php -v 2>&1 >/dev/null)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "PHP_EXT_ENABLE=* was not rejected: $out"
echo "$out" | grep -q "invalid extension name: '\*'" || fail "PHP_EXT_ENABLE=* expanded to real filenames instead of being rejected literally: $out"
echo "ok: PHP_EXT_ENABLE=* is not glob-expanded"

# 22. M4: PHP_EXT_ENABLE reducing to nothing after splitting on commas is a
# typo, not a silent no-op.
if docker run --rm -e 'PHP_EXT_ENABLE=,,,' "$IMAGE" php -v >/dev/null 2>&1; then
  fail "PHP_EXT_ENABLE=,,, silently did nothing instead of failing loudly"
fi
echo "ok: PHP_EXT_ENABLE=,,, rejected loudly"

# --- round-3 review fixes (ruling T11-G) ------------------------------------

# 23. New-3 residual: CONF_DIR's own read-only fallback used to be a fixed,
# guessable /tmp/php-conf.d -- the same world-writable-path trust ruling
# T11-F removed from FPM pool config, one directory over. Plant an ini file
# at that exact old path *before* the entrypoint ever runs; it must have
# zero effect, while a legitimate override in the same run still applies
# (proving the fallback moved to an unguessable path rather than just
# stopped working).
out=$(docker run --rm --read-only --tmpfs /tmp -m 512m -e PHP_MEMORY_LIMIT=321M --entrypoint sh "$IMAGE" -c '
  mkdir -p /tmp/php-conf.d
  echo "auto_prepend_file=/tmp/pwn.php" > /tmp/php-conf.d/99-zzz-evil.ini
  docker-php-entrypoint php -r "echo \"AP=[\".ini_get(\"auto_prepend_file\").\"] ML=\".ini_get(\"memory_limit\");"
')
echo "$out" | grep -q "AP=\[\]" || fail "ini file planted at the old fixed fallback path was adopted: $out"
echo "$out" | grep -q "ML=321M" || fail "legitimate PHP_MEMORY_LIMIT override broke alongside the planted-file test: $out"
echo "ok: a file planted at the old world-writable conf.d fallback path is ignored"

# 24. New-3 residual: the private conf.d fallback directory must actually be
# non-world-accessible (mode 0700), not just unused by the attack above for
# other reasons.
perm=$(docker run --rm --read-only --tmpfs /tmp -m 512m --entrypoint sh "$IMAGE" -c '
  docker-php-entrypoint true >/dev/null 2>&1
  stat -c "%a %U" /tmp/php-conf.* 2>/dev/null | head -1
')
echo "$perm" | grep -qE '^700 www-data$' || fail "private conf.d fallback directory is not mode 700 owned by www-data: $perm"
echo "ok: private conf.d fallback directory is mode 700, not world-writable"

if [ "$FLAVOR" = fpm ]; then
# 25. Writable case is untouched by any of the read-only machinery: no /tmp
# fallback directory, straight through the baked php-fpm.conf.
tt=$(docker run --rm -m 512m "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "/usr/local/etc/php-fpm.conf test is successful" \
  || fail "writable case unexpectedly used something other than the baked config: $tt"
echo "ok: writable case still uses the baked php-fpm.conf directly"
fi

# 26. New-1: an empty element in an operator-supplied PHP_INI_SCAN_DIR
# (leading, trailing, or doubled ":") must not cause every conf.d ini to be
# parsed twice, in any of the shapes that can produce one. Compared against
# the unset-PHP_INI_SCAN_DIR file count rather than a hardcoded number, so
# a future task adding a baked conf.d file doesn't false-fail this.
baseline=$(docker run --rm "$IMAGE" php -r 'echo count(explode(",", php_ini_scanned_files()));')
# A trailing slash, a doubled slash, a "/." or a "/./" are all the same
# directory written another perfectly ordinary way, and every one of them
# produced the identical double-scan before it was normalised.
for val in '/nonexistent:' ':/nonexistent' '/a::/b' '/usr/local/etc/php/conf.d:' ':' \
           '/usr/local/etc/php/conf.d/' '/usr/local/etc/php/conf.d//' \
           ':/usr/local/etc/php/conf.d/' '/nonexistent/:' \
           '//usr/local/etc/php/conf.d' '/usr/local/etc/php/conf.d/.' \
           '/usr/local/etc/php/conf.d/./'; do
  n=$(docker run --rm -e "PHP_INI_SCAN_DIR=${val}" "$IMAGE" php -r 'echo count(explode(",", php_ini_scanned_files()));')
  case "$val" in
    '/nonexistent:'|':/nonexistent'|'/a::/b'|'/nonexistent/:')
      # these also scan a nonexistent extra dir (0 files) alongside conf.d
      [[ "$n" -eq "$baseline" ]] || fail "PHP_INI_SCAN_DIR='${val}' scanned $n files, expected $baseline"
      ;;
    *)
      [[ "$n" -eq "$baseline" ]] || fail "PHP_INI_SCAN_DIR='${val}' double-scanned conf.d: $n files, expected $baseline"
      ;;
  esac
done
echo "ok: PHP_INI_SCAN_DIR with an empty element or a trailing slash never double-scans conf.d ($baseline files)"

# 27. O1: read-only rootfs plus an operator-supplied PHP_INI_SCAN_DIR with
# no empty element must not silently drop the baked conf.d -- that would
# disable every extension the operator asked for *and* every baked
# hardening setting (disable_functions, opcache), not just our overrides.
out=$(docker run --rm --read-only --tmpfs /tmp -m 512m -e PHP_INI_SCAN_DIR=/nonexistent -e PHP_EXT_ENABLE=bz2 "$IMAGE" sh -c '
  php -m | grep -qix bz2 && echo EXT_OK || echo EXT_MISSING
  php -r "echo \"DISABLE=[\".ini_get(\"disable_functions\").\"]\";"
')
echo "$out" | grep -q EXT_OK || fail "read-only + operator PHP_INI_SCAN_DIR dropped the requested extension: $out"
if [ "$FLAVOR" = cli-builder ]; then
  # cli-builder bakes no disable_functions at all (conf/php-builder.ini
  # deliberately omits it -- build tooling needs proc_open et al), so there
  # is no baked hardening to check for here; confirm it stays that way.
  echo "$out" | grep -q "DISABLE=\[\]" || fail "cli-builder: read-only + operator PHP_INI_SCAN_DIR unexpectedly introduced a disable_functions value: $out"
else
  echo "$out" | grep -q "DISABLE=\[passthru" || fail "read-only + operator PHP_INI_SCAN_DIR dropped baked hardening (disable_functions): $out"
fi
echo "ok: $FLAVOR -- read-only rootfs with an operator PHP_INI_SCAN_DIR keeps the baked conf.d"

# 28. O2: --read-only without --tmpfs /tmp (neither conf.d nor /tmp
# writable) must degrade with a branded diagnostic and still start, not
# die on a raw, unexplained mkdir/mktemp error.
set +e
out=$(docker run --rm --read-only -m 512m "$IMAGE" php -v 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "--read-only without --tmpfs /tmp failed to start: $out"
echo "$out" | grep -qi "docker-php-entrypoint:.*is writable" || fail "--read-only without --tmpfs /tmp gave no branded diagnostic: $out"
# L-3 class fix: this asserted the literal string "PHP 8", which fails on
# any non-8.x image (7.4-fpm prints "PHP 7.4.33 ...") for a reason that has
# nothing to do with what this assertion is actually proving -- that `php -v`
# ran at all after the diagnostic. Match any PHP version, not one baked-in.
echo "$out" | grep -qE "PHP [0-9]+\." || fail "--read-only without --tmpfs /tmp printed a diagnostic but did not actually start: $out"
echo "ok: --read-only without --tmpfs /tmp degrades with a branded diagnostic"

if [ "$FLAVOR" = fpm ]; then
# 29. Bypassing the entrypoint entirely must still produce a valid,
# parseable FPM config -- the whole reason the Dockerfile bakes ENV
# defaults matching the pre-task-11 static www.conf.
tt=$(docker run --rm --entrypoint php-fpm "$IMAGE" -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "bypassing the entrypoint produced an invalid FPM config: $tt"
echo "$tt" | grep -q 'pm\.max_children = 16$' || fail "bypassing the entrypoint did not show the baked legacy default: $tt"
echo "ok: bypassing the entrypoint entirely still yields a valid config"
fi

# --- round-4 review fixes ---------------------------------------------------

if [ "$FLAVOR" = fpm ]; then
# 30. N1 (ruling T11-I): a pool size the operator sets explicitly has to be
# honoured even when it happens to equal the image's own baked default --
# which is the *one* number a Helm chart or compose template that renders
# every tunable from the documented defaults will pass. Until round 4 the
# entrypoint inferred "not overridden" from "equal to the baked default",
# so this exact input was replaced by the autotuned 44/11/11/22 on a 4GB
# container: 2.8GB of workers where the operator asked for 1GB. Tests 5 and
# 20 cannot see this -- they use 3 and 1, values that differ from the
# defaults, so they pass either way.
tt=$(docker run --rm -m 4g \
  -e PHP_FPM_MAX_CHILDREN=16 -e PHP_FPM_START_SERVERS=4 \
  -e PHP_FPM_MIN_SPARE=4 -e PHP_FPM_MAX_SPARE=8 "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "explicit baked-default pool sizes were rejected: $tt"
for want in 'pm\.max_children = 16' 'pm\.start_servers = 4' \
            'pm\.min_spare_servers = 4' 'pm\.max_spare_servers = 8'; do
  echo "$tt" | grep -qE "${want}\$" \
    || fail "an explicit pool size equal to the baked default was replaced by the autotuned one (wanted ${want}): $tt"
done
# ... while an untouched pool on the same container still autotunes, so the
# above is "explicit wins", not "autotuning quietly stopped working".
tt=$(docker run --rm -m 4g "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q 'pm\.max_children = 16$' && fail "autotuning stopped: a 4g container with no overrides got the baked default: $tt"
echo "ok: explicit pool sizes equal to the baked defaults are honored, unset ones still autotune"

# 34. The other half of T11-I: a pinned pool value that is actually honoured
# can now contradict a neighbour this script derived -- `-e
# PHP_FPM_MAX_SPARE=8` on 4GB, where max_children derives to 44 and
# min_spare to 11, is a pool php-fpm refuses outright ("pm.max_spare_servers
# must not be less than pm.min_spare_servers"). The derived neighbour has to
# move: not the pinned value, and not the container's ability to start.
tt=$(docker run --rm -m 4g -e PHP_FPM_MAX_SPARE=8 "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "a pinned pm.max_spare_servers alongside autotuned neighbours produced a config php-fpm rejects: $tt"
echo "$tt" | grep -q 'pm\.max_spare_servers = 8$' || fail "the pinned pm.max_spare_servers was moved instead of its derived neighbours: $tt"
tt=$(docker run --rm -m 4g -e PHP_FPM_MIN_SPARE=30 "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "a pinned pm.min_spare_servers alongside autotuned neighbours produced a config php-fpm rejects: $tt"
echo "$tt" | grep -q 'pm\.min_spare_servers = 30$' || fail "the pinned pm.min_spare_servers was moved instead of its derived neighbours: $tt"
# ...while two pinned values that contradict *each other* stay exactly as
# typed: neither is ours to overrule, and php-fpm's own error names the
# offending pair.
set +e
out=$(docker run --rm -m 4g -e PHP_FPM_MIN_SPARE=10 -e PHP_FPM_MAX_SPARE=8 "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "two contradictory pinned pool values were silently reconciled: $out"
echo "$out" | grep -q "must not be less than pm.min_spare_servers" || fail "contradictory pinned values failed for the wrong reason: $out"
echo "ok: derived pool values yield to pinned ones; contradictory pinned values stay as typed"
fi

if [ "$FLAVOR" = fpm ]; then
# 31. N2 (ruling T11-J): set-but-empty is what an unset shell variable
# renders to in a compose file or Helm template, and it used to be adopted
# silently as a meaning nobody chose -- PHP_FPM_MAX_REQUESTS= became
# pm.max_requests = 0 (worker recycling off, the leak mitigation the
# directive exists for) and PHP_FPM_STATUS_PATH= unpublished the status
# endpoint, both reporting "test is successful". Asserts on the branded
# message, not just a non-zero exit, so it cannot pass for another reason.
for v in PHP_FPM_MAX_REQUESTS PHP_FPM_STATUS_PATH PHP_FPM_MAX_CHILDREN \
         PHP_MEMORY_LIMIT PHP_OPCACHE_JIT PHP_EXT_ENABLE; do
  set +e
  out=$(docker run --rm -m 512m -e "${v}=" "$IMAGE" php-fpm -tt 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "${v}= (set but empty) was accepted: $out"
  echo "$out" | grep -q "refusing ${v}: set but empty" || fail "${v}= rejected for the wrong reason: $out"
done
fi
# The one deliberate exception: an empty PHP_INI_SCAN_DIR is PHP's own
# documented "scan nothing at all" and the only way to opt out of the baked
# conf.d, so it must keep working rather than being rejected as a typo --
# except on fpm (T19-E, discovered running this very assertion against the
# fixed entrypoint): the fpm image bakes a non-empty PHP_DISABLE_FUNCTIONS
# ENV default (needed for www.conf's substitution), which PHP_INI_SCAN_DIR=
# also drops from being enforced for a bare `php` invocation -- the
# entrypoint cannot tell "the operator explicitly asked to disable these
# functions" from "this is only present because the image bakes it for
# www.conf, unrelated to this command", so it treats a present, non-empty
# PHP_DISABLE_FUNCTIONS as a real request either way (the fail-closed
# direction) and refuses rather than silently starting with hardening it
# cannot apply. cli/cli-builder bake no such default, so PHP_DISABLE_FUNCTIONS
# is genuinely unset there and this combination still just starts.
if [ "$FLAVOR" = fpm ]; then
  set +e
  out=$(docker run --rm -e PHP_INI_SCAN_DIR= -e PHP_MEMORY_LIMIT=777M "$IMAGE" php -r 'echo ini_get("memory_limit");' 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fpm: PHP_INI_SCAN_DIR= started despite dropping the image's own baked PHP_DISABLE_FUNCTIONS default: $out"
  echo "$out" | grep -q "PHP_INI_SCAN_DIR is also set to the empty string" \
    || fail "fpm: PHP_INI_SCAN_DIR= + baked PHP_DISABLE_FUNCTIONS refusal did not name PHP_INI_SCAN_DIR: $out"
  echo "ok: fpm -- set-but-empty values rejected loudly; PHP_INI_SCAN_DIR= now also refuses (T19-E: it would drop the image's own baked PHP_DISABLE_FUNCTIONS)"
else
  out=$(docker run --rm -e PHP_INI_SCAN_DIR= -e PHP_MEMORY_LIMIT=777M "$IMAGE" php -r 'echo ini_get("memory_limit");')
  [ "$out" != "777M" ] || fail "$FLAVOR: PHP_INI_SCAN_DIR= no longer disables ini scanning: $out"
  [ -n "$out" ] || fail "$FLAVOR: PHP_INI_SCAN_DIR= (documented opt-out) failed to start"
  echo "ok: $FLAVOR -- set-but-empty values rejected loudly, PHP_INI_SCAN_DIR= still honored (no baked PHP_DISABLE_FUNCTIONS default here)"
fi

# 32/33. N3: under a read-only rootfs the entrypoint creates a private,
# mktemp-named ini directory that has to outlive it (every php process in
# the container reads it), so it cannot be cleaned up on the way out --
# this script ends in exec. On the documented --tmpfs /tmp that costs
# nothing; on a volume- or bind-backed /tmp it used to leave one directory
# behind per start, without bound.
t11vol="t11-conf-$$"
t11vol2="t11-live-vol-$$"
t11live="t11-live-$$"
t11_cleanup() { docker rm -f "$t11live" >/dev/null 2>&1 || true; docker volume rm "$t11vol" "$t11vol2" >/dev/null 2>&1 || true; }
trap t11_cleanup EXIT
docker volume create "$t11vol" >/dev/null

# 32. three starts, at most one directory left behind
for _ in 1 2 3; do
  docker run --rm --read-only -v "$t11vol":/tmp -m 512m "$IMAGE" php -r 'echo "";' >/dev/null 2>&1 \
    || fail "a read-only start with a volume-backed /tmp failed outright"
done
n=$(docker run --rm -v "$t11vol":/tmp --entrypoint sh "$IMAGE" -c 'ls -d /tmp/php-conf.* 2>/dev/null | wc -l')
[ "$n" -le 1 ] || fail "$n private conf directories left behind after 3 starts on a persistent /tmp, expected at most 1"
echo "ok: private conf directories do not accumulate on a persistent /tmp ($n left)"

# 33. ...and the reaping that makes 32 pass must never take a directory a
# *running* container still depends on. A peer sharing /tmp is in another
# PID namespace, so its processes are invisible; the advisory lock each
# private directory carries is the only liveness signal that crosses that
# boundary. Both halves are asserted: not reaped while live, reaped once
# dead -- the second half is what proves the first is not passing simply
# because nothing ever reaps anything.
# Its own volume, not test 32's: a leftover directory there is
# indistinguishable by name from the live container's, and picking the wrong
# one makes this assertion fail for a reason that has nothing to do with
# what it tests. The directory is then identified by the one property only
# the live container's has -- a lock somebody holds -- rather than by
# position in a listing.
docker volume create "$t11vol2" >/dev/null
docker run -d --name "$t11live" --read-only -v "$t11vol2":/tmp -m 512m "$IMAGE" \
  php -r 'sleep(120);' >/dev/null
live_dir=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  live_dir=$(docker run --rm -v "$t11vol2":/tmp --entrypoint sh "$IMAGE" -c '
    for d in /tmp/php-conf.*; do
      [ -d "$d" ] && [ -f "$d/.lock" ] || continue
      flock -n "$d/.lock" true 2>/dev/null || { echo "$d"; break; }
    done')
  [ -n "$live_dir" ] && break
  sleep 1
done
[ -n "$live_dir" ] || fail "the long-running container never created a locked private conf directory"
docker run --rm --read-only -v "$t11vol2":/tmp -m 512m "$IMAGE" php -r 'echo "";' >/dev/null 2>&1
still=$(docker run --rm -v "$t11vol2":/tmp --entrypoint sh "$IMAGE" -c "[ -d '$live_dir' ] && echo PRESENT || echo GONE")
[ "$still" = PRESENT ] || fail "a running container's private conf directory ($live_dir) was reaped by another container's start"
docker rm -f "$t11live" >/dev/null
docker run --rm --read-only -v "$t11vol2":/tmp -m 512m "$IMAGE" php -r 'echo "";' >/dev/null 2>&1
gone=$(docker run --rm -v "$t11vol2":/tmp --entrypoint sh "$IMAGE" -c "[ -d '$live_dir' ] && echo PRESENT || echo GONE")
[ "$gone" = GONE ] || fail "the private conf directory of a container that has exited ($live_dir) was never reaped"
t11_cleanup
trap - EXIT
echo "ok: a live container's private conf directory survives, a dead one's is reaped"

if [ "$FLAVOR" = fpm ]; then
# 35. New-1: www.conf reads the PHP_FPM_*_EFFECTIVE names, so those are the
# only pool variables `docker image inspect` reports -- and therefore the
# ones an operator learning this image's configuration surface finds and
# sets. They are computed outputs: setting one was silently overwritten by
# the autotuned value (999 -> 44 on a 4g container), which is this task's
# opening failure relocated onto the most discoverable name. It has to fail,
# and the message has to name the variable that does work, or a silent trap
# has merely become a dead end.
for pair in 'PHP_FPM_MAX_CHILDREN_EFFECTIVE:PHP_FPM_MAX_CHILDREN' \
            'PHP_FPM_START_SERVERS_EFFECTIVE:PHP_FPM_START_SERVERS' \
            'PHP_FPM_MIN_SPARE_EFFECTIVE:PHP_FPM_MIN_SPARE' \
            'PHP_FPM_MAX_SPARE_EFFECTIVE:PHP_FPM_MAX_SPARE'; do
  internal="${pair%%:*}"; knob="${pair##*:}"
  set +e
  out=$(docker run --rm -m 4g -e "${internal}=999" "$IMAGE" php-fpm -tt 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "${internal}=999 was accepted, then silently overwritten by the autotuned value: $out"
  echo "$out" | grep -q "refusing ${internal}=999" || fail "${internal}=999 was rejected for the wrong reason: $out"
  echo "$out" | grep -q "Set ${knob}=999 instead" \
    || fail "${internal}=999 was rejected without naming ${knob}, the variable that actually works: $out"
done
# The bypass path legitimately reads the baked _EFFECTIVE defaults -- that is
# what they exist for -- so the refusal must live where the entrypoint runs
# and nowhere else.
tt=$(docker run --rm --entrypoint php-fpm -e PHP_FPM_MAX_CHILDREN_EFFECTIVE=999 "$IMAGE" -tt 2>&1)
echo "$tt" | grep -q 'pm\.max_children = 999$' \
  || fail "the entrypoint-bypass path no longer reads PHP_FPM_MAX_CHILDREN_EFFECTIVE: $tt"
echo "ok: the internal _EFFECTIVE names are refused with a signpost; the bypass path still reads them"
fi

# 36. CF-36: PHP_SNUFFLEUPAGUS's write path now checks CONF_WRITABLE up
# front too, the same way PHP_EXT_ENABLE has since task 11 -- previously it
# hit php-ext-enable's or its own `>>` write with no writable conf dir and
# aborted on a raw permission/redirection error instead of the branded
# diagnostic every other write path here gives.
set +e
out=$(docker run --rm --read-only -m 512m -e PHP_SNUFFLEUPAGUS=laravel "$IMAGE" php -v 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "PHP_SNUFFLEUPAGUS with no writable conf dir was not rejected: $out"
echo "$out" | grep -q "PHP_SNUFFLEUPAGUS=laravel requested but no writable ini directory is available" \
  || fail "PHP_SNUFFLEUPAGUS with no writable conf dir failed for the wrong reason: $out"
echo "ok: PHP_SNUFFLEUPAGUS fails with a branded message when no writable conf dir is available"

# --- CF-34 / T19-A / T19-B: fail closed when a hardening control cannot be
# applied, and only when it actually is not going to be in force -----------
#
# The brief's own illustrative value, PHP_DISABLE_FUNCTIONS=exec, turned out
# during task 19b's own verification to be a poor sentinel: exec is already
# in the baked disable_functions default (conf/php-cli.ini, conf/php-fpm.ini
# both ship it), so exec() fails with "Call to undefined function" whether or
# not the operator's override ever reaches an ini file at all -- a test built
# on it would pass identically against a correct entrypoint and a completely
# reverted one. Every assertion below uses proc_open instead, which is
# deliberately NOT in the baked default (composer/Symfony Process need it --
# see CLAUDE.md), so whether proc_open() actually runs is real signal, not
# baked-in coincidence.
#
# T19-B fix-round ruling: "in force" is no longer decided by comparing the
# requested value to a baked constant (that constant was one of three
# independent, unlinked copies of the same string, and it exempted any value
# merely equal to *fpm's* baked default even on cli-builder, which bakes no
# default at all and applies nothing) -- the entrypoint now asks PHP (or
# php-fpm) directly what will actually be in force, so the refusal message
# below names the missing function(s), not a fixed phrase.
#
# T19-I: these assertions used to run only against $IMAGE, which every
# caller in this repo passed as the fpm image, exercising only the raw `php`
# binary it happens to bundle -- with a second "companion" cli image derived
# from the tag and silently SKIPped (exit 0) whenever it was not present, so
# cli/cli-builder were never actually verified even when the companion image
# existed. Fixed at the smoke.sh end: this whole script now runs once per
# real flavor, so $IMAGE genuinely is the cli/cli-builder image when $FLAVOR
# says so, and cases (a)-(d) below need no companion and no skip. Only the
# fpm-pool half (below, "fpm's differing half") stays flavor-gated: it is
# fpm-specific by construction (no www.conf, no pool, on cli/cli-builder).

proc_open_probe='
$d = [0 => ["pipe", "r"], 1 => ["pipe", "w"], 2 => ["pipe", "w"]];
$p = proc_open("echo SENTINEL_RAN", $d, $pipes);
echo is_resource($p) ? stream_get_contents($pipes[1]) : "PROC_OPEN_BLOCKED";'

# 37. (a) a hardening control that cannot be applied refuses to start,
# names the missing function, and the command it would have run never
# actually ran.
set +e
out=$(docker run --rm --read-only -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php -r "$proc_open_probe" 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "$FLAVOR: --read-only + PHP_DISABLE_FUNCTIONS=proc_open started instead of refusing: $out"
if echo "$out" | grep -q "SENTINEL_RAN"; then
  fail "$FLAVOR: proc_open() ran despite the entrypoint refusing to start (CF-34/T19-B regression): $out"
fi
echo "$out" | grep -q "refusing to start: PHP_DISABLE_FUNCTIONS=proc_open" \
  || fail "$FLAVOR: refusal did not name PHP_DISABLE_FUNCTIONS=proc_open: $out"
echo "$out" | grep -q "missing: proc_open" \
  || fail "$FLAVOR: refusal did not name proc_open as the function not in force: $out"
echo "ok: $FLAVOR -- bare --read-only + PHP_DISABLE_FUNCTIONS=proc_open refuses to start (names the setting, sentinel never ran)"

# positive control for 37: same command and sentinel, same bare --read-only,
# nothing set -- proves the refusal above is about the dropped control, not
# about --read-only, proc_open(), or the image itself being broken. Unlike
# exec(), proc_open() is not baked-disabled, so it actually runs here.
out=$(docker run --rm --read-only "$IMAGE" php -r "$proc_open_probe" 2>&1)
echo "$out" | grep -q "SENTINEL_RAN" \
  || fail "$FLAVOR: positive control -- proc_open() did not run with no PHP_DISABLE_FUNCTIONS set under bare --read-only: $out"
echo "ok: $FLAVOR -- positive control -- proc_open() runs under bare --read-only with nothing set"

# 38. (b) a tuning knob dropped the same way keeps the container running,
# and says so by name and value instead of the old one-line generic warning.
set +e
out=$(docker run --rm --read-only -e PHP_MEMORY_LIMIT=256M "$IMAGE" \
  php -r 'echo ini_get("memory_limit");' 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "$FLAVOR: PHP_MEMORY_LIMIT dropped under bare --read-only failed to start: $out"
echo "$out" | grep -q "PHP_MEMORY_LIMIT=256M requested but no ini directory is writable" \
  || fail "$FLAVOR: PHP_MEMORY_LIMIT drop warning did not name the variable and value: $out"
echo "ok: $FLAVOR -- PHP_MEMORY_LIMIT dropped under bare --read-only warns by name and value, still starts"

# 39. (c) an unset variable was never "requested" -- the empty-environment
# bare --read-only case still has to start clean, with none of the new named
# warnings/refusals firing on nothing. On fpm this is also what proves the
# image's own baked PHP_DISABLE_FUNCTIONS ENV default (needed for www.conf)
# is told apart from a real operator override, since that default is always
# present in fpm's environment even though nothing was requested here;
# cli/cli-builder carry no such default, so this is a plain clean-start check
# there.
out=$(docker run --rm --read-only "$IMAGE" php -r 'echo "CLEAN_START";' 2>&1)
echo "$out" | grep -q "CLEAN_START" \
  || fail "$FLAVOR: bare --read-only with nothing set failed to start clean: $out"
if echo "$out" | grep -qE "PHP_DISABLE_FUNCTIONS=|PHP_MEMORY_LIMIT=|not in force|missing:"; then
  fail "$FLAVOR: bare --read-only with nothing set produced a named warning/refusal about a variable nobody set: $out"
fi
echo "ok: $FLAVOR -- bare --read-only with nothing set starts clean"

# 40. (d) with a writable /tmp, the control actually applies -- proc_open()
# is called and its failure observed, not just ini_get() read back. The
# probe is expected to fail (a disabled-function fatal, rc=255): guarded
# with set +e/-e like every other fallible command substitution in this
# file, since a plain top-level `out=$(...)` left unguarded would let
# set -e kill the script on that very fatal, before the assertions below
# ever ran.
set +e
out=$(docker run --rm --read-only --tmpfs /tmp -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php -r "$proc_open_probe" 2>&1)
set -e
if echo "$out" | grep -q "SENTINEL_RAN"; then
  fail "$FLAVOR: proc_open() actually ran under --tmpfs /tmp despite PHP_DISABLE_FUNCTIONS=proc_open: $out"
fi
# A disabled proc_open() is NOT the same fatal shape on every PHP version:
# PHP 8.0+ actually removes it from the function table, so calling it is
# "Call to undefined function proc_open()" (fatal, execution stops there).
# PHP 7.x (confirmed live against 7.4) instead leaves a stub that warns
# ("has been disabled for security reasons") and returns NULL, so the
# script keeps running -- the probe's own is_resource() check catches that
# and echoes PROC_OPEN_BLOCKED. M-c: gated by this image's own PHP_MAJOR,
# not accepted on every version regardless -- the 7.x shape can never
# legitimately occur on 8.x, and requires the warning's own text, not just
# the probe's derived marker (which any unrelated proc_open() failure would
# also print).
if [ "$PHP_MAJOR" -ge 8 ]; then
  echo "$out" | grep -qF "Call to undefined function proc_open()" \
    || fail "$FLAVOR: proc_open() did not fail with PHP $PHP_MAJOR's disabled-function fatal under --tmpfs /tmp: $out"
else
  echo "$out" | grep -q "has been disabled for security reasons" \
    || fail "$FLAVOR: proc_open() did not show PHP $PHP_MAJOR's own 'has been disabled for security reasons' warning under --tmpfs /tmp: $out"
  echo "$out" | grep -qF "PROC_OPEN_BLOCKED" \
    || fail "$FLAVOR: PHP $PHP_MAJOR disabled proc_open() but the probe's own is_resource() check did not report PROC_OPEN_BLOCKED: $out"
fi
echo "ok: $FLAVOR -- PHP_DISABLE_FUNCTIONS applies for real under --tmpfs /tmp (proc_open() actually fails, not just ini_get())"

# T19-E: an operator-emptied PHP_INI_SCAN_DIR means nothing baked is scanned
# at all -- there is no separate main php.ini on this image (`php --ini`
# reports "Loaded Configuration File: (none)"), only conf.d -- so a
# PHP_DISABLE_FUNCTIONS the operator also set cannot be in force either,
# even with a fully writable conf.d. Refused, naming both variables.
set +e
out=$(docker run --rm -e PHP_INI_SCAN_DIR= -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php -r "$proc_open_probe" 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "$FLAVOR: PHP_INI_SCAN_DIR= + PHP_DISABLE_FUNCTIONS=proc_open started instead of refusing: $out"
if echo "$out" | grep -q "SENTINEL_RAN"; then
  fail "$FLAVOR: proc_open() ran despite PHP_INI_SCAN_DIR= dropping every ini, baked hardening included: $out"
fi
echo "$out" | grep -q "missing: proc_open" \
  || fail "$FLAVOR: PHP_INI_SCAN_DIR= + PHP_DISABLE_FUNCTIONS refusal did not name proc_open: $out"
echo "$out" | grep -qi "PHP_INI_SCAN_DIR is also set to the empty string" \
  || fail "$FLAVOR: PHP_INI_SCAN_DIR= + PHP_DISABLE_FUNCTIONS refusal did not name PHP_INI_SCAN_DIR too: $out"
echo "ok: $FLAVOR -- T19-E: empty PHP_INI_SCAN_DIR + PHP_DISABLE_FUNCTIONS refuses, naming both variables"

if [ "$FLAVOR" = fpm ]; then
# fpm's differing half: PHP_DISABLE_FUNCTIONS reaches php-fpm through
# www.conf's php_admin_value regardless of conf.d writability (verified
# against conf/www.conf:54 and reproduced live in task-19b-fix-report.md),
# so fpm has nothing to fail closed on for this variable when the stock
# www.conf is what loads. T19-I: proven through a real FastCGI round trip
# against a live worker (test-fpm-health.sh's own idiom), not `php-fpm -tt`
# -- `-tt` only proves what config WOULD load, never that a running worker
# actually resolves and enforces it.
fpm_e2e_name="t19a-fpm-e2e-$$"
trap 'docker rm -f "$fpm_e2e_name" >/dev/null 2>&1 || true' EXIT
# /probe is a second, separate tmpfs mount for the probe script only -- /tmp
# itself stays part of the read-only rootfs (no --tmpfs /tmp), so
# CONF_WRITABLE is still 0, exactly the bare --read-only scenario CF-34 is
# about.
docker run -d --name "$fpm_e2e_name" --read-only --tmpfs /probe -m 512m -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" >/dev/null
fpm_e2e_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if docker exec "$fpm_e2e_name" true >/dev/null 2>&1; then
    fpm_e2e_ready=1
    break
  fi
  sleep 0.3
done
[ "$fpm_e2e_ready" -eq 1 ] || { docker logs "$fpm_e2e_name" >&2 2>&1 || true; fail "fpm: container for the live PHP_DISABLE_FUNCTIONS FastCGI check never became execable"; }
docker exec "$fpm_e2e_name" sh -c 'printf '"'"'<?php
$d = [0 => ["pipe", "r"], 1 => ["pipe", "w"], 2 => ["pipe", "w"]];
$p = proc_open("echo SENTINEL_RAN", $d, $pipes);
echo is_resource($p) ? stream_get_contents($pipes[1]) : "PROC_OPEN_BLOCKED";
'"'"' > /probe/t19a-probe.php'
fpm_e2e_out=$(fcgi_request "$fpm_e2e_name" -e SCRIPT_FILENAME=/probe/t19a-probe.php -e SCRIPT_NAME=/t19a-probe.php -e REQUEST_METHOD=GET)
# T19-P: any HTTP 500 looks the same from here -- a disabled-function fatal,
# an unrelated crash, or a completely different bug three layers away would
# all produce one. Logs captured *before* the container is removed, and the
# assertion below requires the actual fatal's own text, not just the status
# code it happens to produce.
fpm_e2e_logs=$(docker logs "$fpm_e2e_name" 2>&1)
docker rm -f "$fpm_e2e_name" >/dev/null 2>&1
trap - EXIT
if echo "$fpm_e2e_out" | grep -q "SENTINEL_RAN"; then
  fail "fpm: proc_open() actually ran in a live FastCGI worker despite PHP_DISABLE_FUNCTIONS=proc_open under bare --read-only: $fpm_e2e_out"
fi
# A disabled-function fatal in a live worker is a bare HTTP 500 with an
# empty body (display_errors is off, so the fatal never reaches the
# response) -- but 500+empty is also what a crash, a missing script, or an
# unrelated bug looks like from the HTTP side alone. T19-P: require the
# fatal's own text in the container's logs, not just the status code.
#
# I-4: this used to require the 8.x shape unconditionally, so this whole
# suite failed at the first assertion below on every PHP 7.x fpm image --
# PHP 7.x (confirmed live against 7.4) does not fatal a disabled proc_open()
# at all; it warns and returns false, the script keeps running, and the
# probe's own is_resource() check echoes PROC_OPEN_BLOCKED with a normal 200
# response (matching the CLI probe's own 7.x branch further up).
#
# M-c: gated by this image's own PHP_MAJOR, not merely by which marker
# happens to be present -- the 7.x shape can never legitimately occur on an
# 8.x image, and PROC_OPEN_BLOCKED alone never proved disable_functions was
# the actual cause even on a real 7.x one (a 200 response with a NULL/false
# proc_open() result could come from other bugs too). The 7.x warning goes
# to php-fpm's error log, not the FastCGI response body, so the evidence
# for that branch is checked in $fpm_e2e_logs, matching how the 8.x branch
# already requires the fatal's own log text below.
if [ "$PHP_MAJOR" -lt 8 ]; then
  echo "$fpm_e2e_out" | grep -q "PROC_OPEN_BLOCKED" \
    || fail "fpm: PHP $PHP_MAJOR's live FastCGI worker did not report PROC_OPEN_BLOCKED for a disabled proc_open(): $fpm_e2e_out"
  echo "$fpm_e2e_logs" | grep -q "has been disabled for security reasons" \
    || fail "fpm: got PROC_OPEN_BLOCKED from the live FastCGI worker, but its own logs show no PHP $PHP_MAJOR 'has been disabled for security reasons' warning -- the marker alone does not prove disable_functions caused it. Logs were: $fpm_e2e_logs"
  echo "ok: fpm -- PHP_DISABLE_FUNCTIONS reaches a live FastCGI worker via www.conf's admin_value regardless of conf.d writability (PHP 7.x shape: proc_open() warns and returns false, no fatal)"
else
  echo "$fpm_e2e_out" | grep -q "Status: 500" \
    || fail "fpm: proc_open() did not fail with a 500 in a live FastCGI worker: $fpm_e2e_out"
  echo "$fpm_e2e_logs" | grep -q "Call to undefined function proc_open()" \
    || fail "fpm: got a 500 from the live FastCGI worker, but its own logs show no 'Call to undefined function proc_open()' fatal -- 500 alone does not prove disable_functions caused it. Logs were: $fpm_e2e_logs"
  echo "ok: fpm -- PHP_DISABLE_FUNCTIONS reaches a live FastCGI worker via www.conf's admin_value regardless of conf.d writability, proven through a real request"
fi

# T19-P positive control: the exact same probe, same live worker setup,
# with PHP_DISABLE_FUNCTIONS left unset -- proves the 500+log check above
# is measuring the control, not a live worker that fatals on proc_open()
# (or on this probe script) unconditionally regardless of any setting.
fpm_e2e_ctrl_name="t19a-fpm-e2e-ctrl-$$"
trap 'docker rm -f "$fpm_e2e_ctrl_name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$fpm_e2e_ctrl_name" --read-only --tmpfs /probe -m 512m "$IMAGE" >/dev/null
fpm_e2e_ctrl_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if docker exec "$fpm_e2e_ctrl_name" true >/dev/null 2>&1; then
    fpm_e2e_ctrl_ready=1
    break
  fi
  sleep 0.3
done
[ "$fpm_e2e_ctrl_ready" -eq 1 ] || { docker logs "$fpm_e2e_ctrl_name" >&2 2>&1 || true; fail "fpm: positive-control container for the live PHP_DISABLE_FUNCTIONS FastCGI check never became execable"; }
docker exec "$fpm_e2e_ctrl_name" sh -c 'printf '"'"'<?php
$d = [0 => ["pipe", "r"], 1 => ["pipe", "w"], 2 => ["pipe", "w"]];
$p = proc_open("echo SENTINEL_RAN", $d, $pipes);
echo is_resource($p) ? stream_get_contents($pipes[1]) : "PROC_OPEN_BLOCKED";
'"'"' > /probe/t19a-probe.php'
fpm_e2e_ctrl_out=$(fcgi_request "$fpm_e2e_ctrl_name" -e SCRIPT_FILENAME=/probe/t19a-probe.php -e SCRIPT_NAME=/t19a-probe.php -e REQUEST_METHOD=GET)
docker rm -f "$fpm_e2e_ctrl_name" >/dev/null 2>&1
trap - EXIT
echo "$fpm_e2e_ctrl_out" | grep -q "SENTINEL_RAN" \
  || fail "fpm: T19-P positive control -- proc_open() did not run in a live FastCGI worker with no PHP_DISABLE_FUNCTIONS set: $fpm_e2e_ctrl_out"
echo "ok: fpm -- T19-P positive control -- the same live-worker probe runs proc_open() successfully with nothing disabled"

tt=$(docker run --rm --read-only "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" \
  || fail "fpm: bare --read-only with nothing set failed to start (php-fpm -tt): $tt"
echo "ok: fpm -- bare --read-only with nothing set starts clean (php-fpm -tt)"

# T19-C: argv "$1=php-fpm" alone is not trusted any more -- the entrypoint
# resolves what php-fpm will actually load (php-fpm -tt) and checks each
# pool, not just the stock www.conf's own php_admin_value. Verified against
# a mounted pool config that sets neither php_admin_value[disable_functions]
# nor php_value[disable_functions] at all, through a real FastCGI request
# (not by reading config back) -- must refuse under bare --read-only, since
# nothing in that pool or in conf.d (unwritable) will apply the request.
t19c_conf="/tmp/t19c-www-$$.conf"
cat >"$t19c_conf" <<'CONF'
[www]
user = www-data
group = www-data
listen = 0.0.0.0:9000
pm = static
pm.max_children = 2
CONF
# T19-Q: php-fpm -F runs in the foreground forever once it actually starts,
# so if the refusal below ever regresses, this `docker run` (no -d) blocks
# forever too -- hanging the whole suite on a bare command substitution
# instead of failing it. `timeout` turns that hang into a named failure;
# the container is force-removed unconditionally afterwards regardless of
# which way this goes, since a regression is exactly the case where it is
# still running when the timeout fires.
t19c_fpmf_name="t19c-fpmF-$$"
set +e
out=$(timeout 10 docker run --rm --name "$t19c_fpmf_name" --read-only -m 512m \
  -v "$t19c_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -F 2>&1)
rc=$?
set -e
docker rm -f "$t19c_fpmf_name" >/dev/null 2>&1 || true
rm -f "$t19c_conf"
if [ "$rc" -eq 124 ]; then
  fail "T19-C: php-fpm -F for a pool lacking disable_functions did not refuse within 10s (timed out instead) -- the refusal regressed: $out"
fi
[ "$rc" -ne 0 ] || fail "T19-C: a mounted fpm pool config lacking disable_functions entirely started instead of refusing under bare --read-only: $out"
echo "$out" | grep -q "missing: proc_open" \
  || fail "T19-C: refusal for a pool lacking disable_functions did not name proc_open: $out"
echo "ok: fpm -- T19-C: a mounted pool config that sets neither php_admin_value nor php_value[disable_functions] refuses under bare --read-only"

# ...and the stock www.conf (php_admin_value referencing the operator's own
# value) must still start, proven through the same real FastCGI round trip
# as the "fpm's differing half" check above -- confirms T19-C's fix does not
# regress the ordinary case.
t19c_name="t19c-stock-$$"
trap 'docker rm -f "$t19c_name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$t19c_name" --read-only --tmpfs /probe -m 512m -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" >/dev/null
t19c_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if docker exec "$t19c_name" true >/dev/null 2>&1; then
    t19c_ready=1
    break
  fi
  sleep 0.3
done
[ "$t19c_ready" -eq 1 ] || { docker logs "$t19c_name" >&2 2>&1 || true; fail "T19-C: stock-www.conf container never became execable"; }
docker exec "$t19c_name" sh -c "printf '<?php echo \"REACHED\";' > /probe/t19c-probe.php"
t19c_out=$(fcgi_request "$t19c_name" -e SCRIPT_FILENAME=/probe/t19c-probe.php -e SCRIPT_NAME=/t19c-probe.php -e REQUEST_METHOD=GET)
docker rm -f "$t19c_name" >/dev/null 2>&1
trap - EXIT
echo "$t19c_out" | grep -q "REACHED" \
  || fail "T19-C: the stock www.conf (php_admin_value covers disable_functions) failed to start/serve under bare --read-only: $t19c_out"
echo "ok: fpm -- T19-C: the stock www.conf still starts and serves under bare --read-only"

# T19-M: any `NOTICE: [<anything>]` line other than `[global]` is a pool
# header -- FPM pool names are an arbitrary string; `[app@site]`, `[a b]`
# and `[app:1]` are all legal. A header this script fails to recognise does
# not vanish: its whole config (disable_functions coverage included) gets
# merged into whichever recognised pool precedes it in the same `-tt` dump,
# so an unrecognised, unprotected pool was silently reported as covered by
# its protected neighbour. Four pools, one per port: [www] carries the
# operator's own php_admin_value (the control -- must NOT be named in the
# refusal), the other three carry none at all and use exactly the three
# shapes named above -- each must be named individually, not skipped or
# silently folded into [www]'s coverage.
t19m_conf="/tmp/t19m-www-$$.conf"
cat >"$t19m_conf" <<'CONF'
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9000
pm = static
pm.max_children = 1
php_admin_value[disable_functions] = ${PHP_DISABLE_FUNCTIONS}

[app@site]
user = www-data
group = www-data
listen = 127.0.0.1:9001
pm = static
pm.max_children = 1

[a b]
user = www-data
group = www-data
listen = 127.0.0.1:9002
pm = static
pm.max_children = 1

[app:1]
user = www-data
group = www-data
listen = 127.0.0.1:9003
pm = static
pm.max_children = 1
CONF
set +e
out=$(docker run --rm --read-only -m 512m \
  -v "$t19m_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -f "$t19m_conf"
[ "$rc" -ne 0 ] || fail "T19-M: a pool config with unrecognisable-by-the-old-regex pool names started instead of refusing: $out"
for pool in 'app@site' 'a b' 'app:1'; do
  echo "$out" | grep -qF "pool [${pool}] missing: proc_open" \
    || fail "T19-M: refusal did not individually name pool [${pool}] as missing proc_open (skipped or merged into a neighbour's coverage): $out"
done
echo "$out" | grep -qF "pool [www] missing" \
  && fail "T19-M: the protected [www] pool was incorrectly named in the refusal too: $out"
echo "ok: fpm -- T19-M: pool headers named [app@site], [a b] and [app:1] are each recognised and individually checked, not skipped or merged"
fi

# T19-L: zend_disable_functions splits its argument on literal space/comma
# ONLY and matches case-sensitively against its (lowercase) function table
# -- a check that instead split on all whitespace and lowercased both sides
# would accept 'EXEC, System' or a tab-separated list as equivalent to
# 'exec,system', when PHP leaves both functions callable. Every case below
# runs on every flavor: the up-front validation this fixes has nothing to
# do with fpm/cli/cli-builder.

# (a) mixed uppercase, comma+space -- refused up front, naming the bad
# token, before anything is written or exec'd.
set +e
out=$(docker run --rm --read-only --tmpfs /tmp -e 'PHP_DISABLE_FUNCTIONS=EXEC, System' "$IMAGE" php -r "$proc_open_probe" 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "$FLAVOR: T19-L: PHP_DISABLE_FUNCTIONS='EXEC, System' started instead of being refused: $out"
echo "$out" | grep -qi "refusing PHP_DISABLE_FUNCTIONS" \
  || fail "$FLAVOR: T19-L: 'EXEC, System' was rejected for the wrong reason: $out"
echo "$out" | grep -qF "'EXEC'" \
  || fail "$FLAVOR: T19-L: refusal did not name the offending token 'EXEC': $out"
echo "ok: $FLAVOR -- T19-L: PHP_DISABLE_FUNCTIONS='EXEC, System' is refused up front, naming the bad token"

# (b) a tab is not a valid separator to PHP's own splitter -- it stays part
# of the token, and the resulting token is refused the same way.
tab_value="exec$(printf '\t')system"
set +e
out=$(docker run --rm --read-only --tmpfs /tmp -e "PHP_DISABLE_FUNCTIONS=${tab_value}" "$IMAGE" php -r "$proc_open_probe" 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "$FLAVOR: T19-L: a tab-separated PHP_DISABLE_FUNCTIONS started instead of being refused: $out"
echo "$out" | grep -qi "refusing PHP_DISABLE_FUNCTIONS" \
  || fail "$FLAVOR: T19-L: tab-separated value was rejected for the wrong reason: $out"
echo "ok: $FLAVOR -- T19-L: a tab between function names (not a valid PHP separator) is refused, not silently accepted"

# (c) positive control: a legitimately-formatted value (comma AND a space
# after it -- both are valid separators, collapsed together) still works
# and actually disables every requested name.
set +e
out=$(docker run --rm --read-only --tmpfs /tmp -e 'PHP_DISABLE_FUNCTIONS=exec, proc_open' "$IMAGE" php -r "$proc_open_probe" 2>&1)
set -e
if echo "$out" | grep -q "SENTINEL_RAN"; then
  fail "$FLAVOR: T19-L: proc_open() ran despite 'exec, proc_open' (comma+space) requesting it disabled: $out"
fi
# I-4: accept either disabled-function shape (see the fpm live-worker check
# above) -- this used to require the 8.x-only fatal text, so this positive
# control itself failed the whole suite on every PHP 7.x image. M-c: gated
# by PHP_MAJOR and the real warning text, same as the other two proc_open
# assertions in this file.
if [ "$PHP_MAJOR" -ge 8 ]; then
  echo "$out" | grep -qF "Call to undefined function proc_open()" \
    || fail "$FLAVOR: T19-L: positive control -- 'exec, proc_open' (valid comma+space separator) did not fail with PHP $PHP_MAJOR's disabled-function fatal: $out"
else
  echo "$out" | grep -q "has been disabled for security reasons" \
    || fail "$FLAVOR: T19-L: positive control -- 'exec, proc_open' did not show PHP $PHP_MAJOR's own 'has been disabled for security reasons' warning: $out"
  echo "$out" | grep -qF "PROC_OPEN_BLOCKED" \
    || fail "$FLAVOR: T19-L: positive control -- PHP $PHP_MAJOR disabled proc_open() but the probe's own is_resource() check did not report PROC_OPEN_BLOCKED: $out"
fi
echo "ok: $FLAVOR -- T19-L: positive control -- a comma-plus-space-separated value still splits and applies correctly"

# T19-D: docker exec under --read-only --tmpfs /tmp. Run once (this flavor
# arbitrarily, since the behaviour does not depend on it) rather than once
# per flavor -- it is a docker-exec/entrypoint property, not a flavor one.
if [ "$FLAVOR" = cli ]; then
t19d_name="t19d-exec-$$"
trap 'docker rm -f "$t19d_name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$t19d_name" --read-only --tmpfs /tmp -m 512m "$IMAGE" php -r 'sleep(120);' >/dev/null
# Documented answer (CF-54): `docker exec <c> docker-php-entrypoint php ...`
# re-runs this whole script against the freshly exec'd environment (a new
# private conf.d, PHP_INI_SCAN_DIR recomputed) and DOES see an operator
# override supplied only at exec time.
t19d_out=$(docker exec -e PHP_MEMORY_LIMIT=654M "$t19d_name" docker-php-entrypoint php -r 'echo ini_get("memory_limit");' 2>&1)
echo "$t19d_out" | grep -q "654M" \
  || fail "T19-D: docker exec <c> docker-php-entrypoint php did not see an override set only at exec time: $t19d_out"
echo "ok: T19-D: docker exec <c> docker-php-entrypoint php ... applies overrides set only at exec time"

# ...and the bare form -- `docker exec <c> php ...`, skipping the entrypoint
# entirely -- does NOT, so this cannot silently change: it sees whatever the
# container started with (the image default, since nothing was set at
# `docker run` time), not the exec-time override.
t19d_bare_out=$(docker exec -e PHP_MEMORY_LIMIT=654M "$t19d_name" php -r 'echo ini_get("memory_limit");' 2>&1)
if echo "$t19d_bare_out" | grep -q "654M"; then
  fail "T19-D: bare 'docker exec <c> php' unexpectedly picked up an exec-time-only override (should only see docker-php-entrypoint's own re-run do that): $t19d_bare_out"
fi
# M-6: a failed `docker exec` (container gone, php missing, ...) would also
# print no "654M" and pass the check above for the wrong reason (T14-G) --
# require the exec to have actually run php successfully and read back the
# baked cli default (conf/php-cli.ini's memory_limit = 512M, untouched since
# nothing set PHP_MEMORY_LIMIT at `docker run` time), not just the absence
# of the override.
echo "$t19d_bare_out" | grep -qx "512M" \
  || fail "T19-D: positive control -- bare 'docker exec <c> php' did not run successfully at all (expected the baked cli default 512M): $t19d_bare_out"
echo "ok: T19-D: bare docker exec <c> php ... does not see an override set only at exec time (unchanged, documented baseline)"
docker rm -f "$t19d_name" >/dev/null 2>&1
trap - EXIT
fi

# ------------------------------------------------------------------------
# Task 19b fix round 3: the owner ruling (PHP_DISABLE_FUNCTIONS adds to the
# baked list, never replaces it), C-1 (unresolvable names / per-pool
# extensions), I-1 (a crashed probe fails closed), I-2 (typos and language
# constructs are refused, real functions are not), I-3 (a pool value this
# script cannot safely re-tokenise refuses), M-1/M-2 (NOTICE-line matching
# anchored to the line's own fixed prefix, not "appears somewhere in it").

# Owner ruling: on a writable conf.d, a name baked into the default but NOT
# requested (dl, here) must still end up disabled alongside the requested
# one -- the previous behaviour replaced the baked list outright, so dl()
# came back the moment any other name was requested (this task's own C-1
# CLI repro: `dl("ssh2.so")` loaded a shared extension specifically because
# dl had silently stopped being disabled). cli-builder bakes no default at
# all (conf/php-builder.ini says so explicitly), so this is meaningless
# there.
if [ "$FLAVOR" != cli-builder ]; then
  out=$(docker run --rm -e PHP_DISABLE_FUNCTIONS=get_current_user "$IMAGE" \
    php -r 'echo function_exists("dl") ? "DL_LIVE" : "DL_GONE", " ", function_exists("get_current_user") ? "GCU_LIVE" : "GCU_GONE";' 2>&1)
  echo "$out" | grep -q "DL_GONE" \
    || fail "$FLAVOR: owner ruling -- PHP_DISABLE_FUNCTIONS=get_current_user (writable conf.d) let dl() come back, although it is in the baked default: $out"
  echo "$out" | grep -q "GCU_GONE" \
    || fail "$FLAVOR: owner ruling -- PHP_DISABLE_FUNCTIONS=get_current_user did not actually disable it: $out"
  echo "ok: $FLAVOR -- owner ruling: PHP_DISABLE_FUNCTIONS unions with the baked disable_functions list on a writable conf.d (dl stays disabled, the requested name is added)"
fi

# C-1/I-2: eval (a language construct, never a real function) and shel_exec
# (a typo) are refused as unable to resolve to a real function at all;
# assert_options (a genuine, resolvable function) in the very same list must
# not be swept up in that refusal.
set +e
out=$(docker run --rm --read-only --tmpfs /tmp -e 'PHP_DISABLE_FUNCTIONS=eval,assert_options,shel_exec' "$IMAGE" php -r 'echo "EVAL_RAN";' 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "$FLAVOR: I-2: PHP_DISABLE_FUNCTIONS=eval,assert_options,shel_exec started instead of being refused: $out"
if echo "$out" | grep -q "EVAL_RAN"; then
  fail "$FLAVOR: I-2: refused for the wrong reason -- the command still ran: $out"
fi
echo "$out" | grep -qi "cannot resolve to a real function" \
  || fail "$FLAVOR: I-2: refusal was not the 'cannot resolve' message: $out"
# The offender list is the phrase right before "cannot resolve"; checked as
# that exact, comma-joined phrase (not a bare substring search for each
# name) because the message also echoes the operator's whole original
# PHP_DISABLE_FUNCTIONS=... value first, which itself contains the literal
# text "assert_options" -- a plain `grep -qF assert_options` would match
# that echoed value and always "pass", proving nothing about which names
# were actually flagged unresolvable.
echo "$out" | grep -qF "eval, shel_exec cannot resolve to a real function" \
  || fail "$FLAVOR: I-2: refusal did not name exactly 'eval, shel_exec' (not assert_options) as unresolvable: $out"
echo "ok: $FLAVOR -- C-1/I-2: eval (language construct) and shel_exec (typo) are refused as unresolvable; assert_options (real) is not"

# negative control for I-2: two genuinely real, resolvable functions must
# never be refused at the resolve stage (whether they end up actually
# disabled is a different question, not this one).
out=$(docker run --rm --tmpfs /tmp -e 'PHP_DISABLE_FUNCTIONS=assert_options,proc_open' "$IMAGE" php -r 'echo "REACHED";' 2>&1)
if echo "$out" | grep -qi "cannot resolve to a real function"; then
  fail "$FLAVOR: I-2 negative control -- assert_options/proc_open (both real functions) were wrongly refused as unresolvable: $out"
fi
echo "ok: $FLAVOR -- I-2 negative control -- two real functions are not refused at the resolve stage"

# F-1 (task 19b fix round 4): the baked half of disable_functions_effective's
# union has to come from the image's own baked ini, never from whatever a
# previous start's own 99-env.ini currently resolves to on a persistent
# conf.d -- otherwise requesting a name that happens to disable ini_get()
# itself (ini_get is not on any baked list) starves the very probe used to
# read "baked" on the *next* start, and the union it computes and writes is
# the requested name alone: the real baked list (exec, system, dl, ...)
# silently disappears. Skipped on cli-builder: it bakes no disable_functions
# default at all (conf/php-builder.ini), so there is no baked list here for
# this bug to drop in the first place.
if [ "$FLAVOR" != cli-builder ]; then
f1_confd="/tmp/t19f4-f1-confd-$$"
mkdir -p "$f1_confd"
chmod 777 "$f1_confd"
docker run --rm -v "$f1_confd":/out "$IMAGE" sh -c 'cp /usr/local/etc/php/conf.d/*.ini /out/ 2>/dev/null' >/dev/null
rm -f "$f1_confd/99-env.ini" "$f1_confd/90-opcache-env.ini"
f1_probe='foreach (["ini_get","exec","system","dl"] as $f) { echo $f, "=", function_exists($f) ? "LIVE" : "gone", " "; }'
out1=$(docker run --rm -v "$f1_confd":/usr/local/etc/php/conf.d \
  -e PHP_DISABLE_FUNCTIONS=ini_get "$IMAGE" php -r "$f1_probe")
echo "$out1" | grep -qw "ini_get=gone" || fail "F-1: $FLAVOR: first start did not disable ini_get: $out1"
echo "$out1" | grep -qw "exec=gone" || fail "F-1: $FLAVOR: first start did not carry the baked list (exec) alongside ini_get: $out1"
out2=$(docker run --rm -v "$f1_confd":/usr/local/etc/php/conf.d \
  -e PHP_DISABLE_FUNCTIONS=ini_get "$IMAGE" php -r "$f1_probe")
rm -rf "$f1_confd"
echo "$out2" | grep -qw "exec=gone" \
  || fail "F-1: $FLAVOR: second start on the same persistent conf.d dropped the baked list (exec came back LIVE) after ini_get had already disabled itself on the first start: $out2"
echo "$out2" | grep -qw "system=gone" \
  || fail "F-1: $FLAVOR: second start dropped the baked list (system came back LIVE): $out2"
echo "$out2" | grep -qw "dl=gone" \
  || fail "F-1: $FLAVOR: second start dropped the baked list (dl came back LIVE): $out2"
echo "ok: $FLAVOR -- F-1: PHP_DISABLE_FUNCTIONS=ini_get survives a restart on a persistent conf.d without silently dropping the baked disable_functions list"
fi

if [ "$FLAVOR" = fpm ]; then
# I-3: a pool's own disable_functions value containing a character this
# script cannot safely re-tokenise the way php-fpm itself does (here, the
# ';' that a `php -d` probe -- but not php-fpm -- treats as a comment)
# refuses rather than silently under-verifying it.
i3_conf="/tmp/t19b3-i3-www-$$.conf"
cat >"$i3_conf" <<'CONF'
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9210
pm = static
pm.max_children = 1
php_admin_value[disable_functions] = "proc_open;legacy"
CONF
set +e
out=$(docker run --rm --read-only -m 512m \
  -v "$i3_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -f "$i3_conf"
[ "$rc" -ne 0 ] || fail "I-3: a pool disable_functions value containing ';' started instead of refusing: $out"
echo "$out" | grep -qi "cannot safely re-parse" \
  || fail "I-3: refusal for the ';'-containing pool value was not the charset-refusal message: $out"
echo "ok: fpm -- I-3: a pool disable_functions value this script cannot safely re-tokenise (';') refuses rather than silently under- or over-disabling"

# negative control: the same shape, an ordinary comma-separated value,
# still verifies fine.
i3n_conf="/tmp/t19b3-i3n-www-$$.conf"
cat >"$i3n_conf" <<'CONF'
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9211
pm = static
pm.max_children = 1
php_admin_value[disable_functions] = proc_open
CONF
out=$(docker run --rm --read-only -m 512m \
  -v "$i3n_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rm -f "$i3n_conf"
echo "$out" | grep -q "test is successful" \
  || fail "I-3 negative control: an ordinary comma-separated pool value was wrongly refused: $out"
echo "ok: fpm -- I-3 negative control -- an ordinary pool disable_functions value still verifies fine"

# C-1: a pool that loads its own extension (php_admin_value[extension]) can
# supply a function this script's probe -- which never loads that
# extension -- cannot see; refused outright rather than certified.
ext_conf="/tmp/t19b3-ext-www-$$.conf"
cat >"$ext_conf" <<'CONF'
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9212
pm = static
pm.max_children = 1
php_admin_value[extension] = ssh2
CONF
set +e
out=$(docker run --rm --read-only -m 512m \
  -v "$ext_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -f "$ext_conf"
[ "$rc" -ne 0 ] || fail "C-1: a pool loading its own extension started instead of refusing: $out"
echo "$out" | grep -qi "loads its own extension" \
  || fail "C-1: refusal for a pool loading its own extension was not the expected message: $out"
echo "ok: fpm -- C-1: a pool that loads its own extension (php_admin_value[extension]) refuses rather than certifying a probe that cannot see it (negative control: the stock www.conf, which loads none, already passes above and elsewhere in this file)"

# M-1: a directive VALUE that spoofs the text of a disable_functions NOTICE
# line must not be mistaken for a real directive -- the pool has no real
# disable_functions of its own, so it must fall through to the baseline and
# be refused for missing proc_open, not silently "covered" by the spoof.
m1_conf="/tmp/t19b3-m1-www-$$.conf"
cat >"$m1_conf" <<'CONF'
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9213
pm = static
pm.max_children = 1
php_admin_value[error_log] = "/proc/self/fd/2 NOTICE: php_admin_value[disable_functions] = proc_open"
CONF
set +e
out=$(docker run --rm --read-only -m 512m \
  -v "$m1_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -f "$m1_conf"
[ "$rc" -ne 0 ] || fail "M-1: a pool whose error_log value spoofs a disable_functions NOTICE line started instead of refusing: $out"
echo "$out" | grep -qF "pool [www] missing: proc_open" \
  || fail "M-1: the spoofed pool was not correctly refused as missing proc_open (the spoofed value may have been trusted instead): $out"
echo "ok: fpm -- M-1: a directive value that spoofs a disable_functions NOTICE line is not mistaken for a real directive"

# M-2: a pool whose own name contains the literal text "NOTICE: [global]"
# must still be recognised as its own distinct, unprotected pool, not
# dropped as if it were the real [global] header and merged into [www].
m2_conf="/tmp/t19b3-m2-www-$$.conf"
cat >"$m2_conf" <<'CONF'
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9214
pm = static
pm.max_children = 1
php_admin_value[disable_functions] = ${PHP_DISABLE_FUNCTIONS}

[a NOTICE: [global]
user = www-data
group = www-data
listen = 127.0.0.1:9215
pm = static
pm.max_children = 1
CONF
set +e
out=$(docker run --rm --read-only -m 512m \
  -v "$m2_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -f "$m2_conf"
[ "$rc" -ne 0 ] || fail "M-2: a pool named '[a NOTICE: [global]' started instead of refusing: $out"
echo "$out" | grep -qF "pool [a NOTICE: [global] missing: proc_open" \
  || fail "M-2: the oddly-named pool was not individually recognised and refused (merged into [global] or [www]?): $out"
echo "$out" | grep -qF "pool [www] missing" \
  && fail "M-2: the protected [www] pool was incorrectly named in the refusal too: $out"
echo "ok: fpm -- M-2: a pool whose own name contains 'NOTICE: [global]' is still recognised as its own distinct, unprotected pool"

# C-1 allowlist: fpm_get_status is registered only by the fpm-fcgi SAPI, so
# no CLI-binary probe run by this script can ever see it directly -- it
# must be verified by whether the pool's own resolved value actually names
# it, not silently treated as "not found, so already gone".
out=$(docker run --rm --read-only -m 512m -e PHP_DISABLE_FUNCTIONS=fpm_get_status,proc_open "$IMAGE" php-fpm -tt 2>&1)
echo "$out" | grep -q "test is successful" \
  || fail "C-1 allowlist: PHP_DISABLE_FUNCTIONS=fpm_get_status,proc_open (stock www.conf, whose value covers both) was wrongly refused: $out"
echo "ok: fpm -- C-1 allowlist -- fpm_get_status alongside an ordinary function verifies fine when the pool's value actually covers it"

# negative control: the same allowlisted name, but a pool whose own value
# does not mention it -- must be refused, not silently passed.
al_conf="/tmp/t19b3-allow-www-$$.conf"
cat >"$al_conf" <<'CONF'
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9216
pm = static
pm.max_children = 1
php_admin_value[disable_functions] = proc_open
CONF
set +e
out=$(docker run --rm --read-only -m 512m \
  -v "$al_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=fpm_get_status,proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -f "$al_conf"
[ "$rc" -ne 0 ] || fail "C-1 allowlist negative control: fpm_get_status requested but not covered by the pool's own value started instead of refusing: $out"
echo "$out" | grep -qF "missing: fpm_get_status" \
  || fail "C-1 allowlist negative control: refusal did not name fpm_get_status as missing: $out"
echo "ok: fpm -- C-1 allowlist negative control -- fpm_get_status is verified by containment, not silently passed just because no CLI-binary probe can see it"

# F-2 (task 19b fix round 4): the main-ini half of a per-pool probe's
# resolved value must come from a source an operator's own mounted conf.d
# cannot silently turn into something this script cannot safely re-parse.
# A value quoted with an embedded ';' is legal ini syntax inside quotes --
# php-fpm keeps it as one literal token, "proc_open;x", and disables
# nothing -- but this script's own `-d disable_functions=` probe treats an
# unquoted ';' as a comment start, so it used to see only "proc_open",
# call that "in force", and let the pool's own coverage ("exec") on top be
# certified even though the live worker's real main-ini value never
# actually disabled proc_open at all.
f2_confd="/tmp/t19f4-f2-confd-$$"
mkdir -p "$f2_confd"
cat >"$f2_confd/50-x.ini" <<'CONF'
disable_functions = "proc_open;x"
CONF
f2_conf="/tmp/t19f4-f2-www-$$.conf"
cat >"$f2_conf" <<'CONF'
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9213
pm = static
pm.max_children = 1
php_admin_value[disable_functions] = exec
CONF
set +e
out=$(docker run --rm --read-only -m 512m \
  -v "$f2_confd/50-x.ini":/usr/local/etc/php/conf.d/50-x.ini:ro \
  -v "$f2_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -rf "$f2_confd" "$f2_conf"
[ "$rc" -ne 0 ] || fail "F-2: a mounted main-ini disable_functions=\"proc_open;x\" alongside a pool covering only 'exec' started instead of refusing: $out"
echo "$out" | grep -q "missing: proc_open" \
  || fail "F-2: refusal for the semi-main.ini fixture did not name proc_open as missing: $out"
echo "ok: fpm -- F-2: a mounted main-ini disable_functions value containing ';' no longer lets a pool's own coverage alone pass verification"

# F-2's other vector: conf.d IS writable (this script's own 99-env.ini
# carries the correct union), but an operator-mounted ini sorting after it
# (zz- > 99-) clobbers the main-ini disable_functions value outright. The
# verification probe shares that exact same resolved environment, so it
# must see the same clobbered value the real worker will and refuse, not
# trust the union this script itself just wrote.
f2w_confd="/tmp/t19f4-f2w-confd-$$"
mkdir -p "$f2w_confd"
chmod 777 "$f2w_confd"
docker run --rm -v "$f2w_confd":/out "$IMAGE" sh -c 'cp /usr/local/etc/php/conf.d/*.ini /out/ 2>/dev/null' >/dev/null
rm -f "$f2w_confd/99-env.ini" "$f2w_confd/90-opcache-env.ini"
cat >"$f2w_confd/zz-custom.ini" <<'CONF'
disable_functions = get_current_user
CONF
f2w_conf="/tmp/t19f4-f2w-www-$$.conf"
cat >"$f2w_conf" <<'CONF'
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9214
pm = static
pm.max_children = 1
php_admin_value[disable_functions] = exec
CONF
set +e
out=$(docker run --rm -m 512m \
  -v "$f2w_confd":/usr/local/etc/php/conf.d \
  -v "$f2w_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -rf "$f2w_confd" "$f2w_conf"
[ "$rc" -ne 0 ] || fail "F-2: a writable-conf.d operator ini sorting after 99-env.ini (zz-custom.ini clobbering disable_functions) started instead of refusing: $out"
echo "$out" | grep -q "missing: proc_open" \
  || fail "F-2: refusal for the writable-conf.d zz-custom.ini fixture did not name proc_open as missing: $out"
echo "ok: fpm -- F-2: an operator ini sorting after 99-env.ini on a writable conf.d is still caught by the same resolved-environment probe"
fi
echo "ENTRYPOINT TESTS PASSED"
