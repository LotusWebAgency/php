#!/usr/bin/env bash
set -euo pipefail
IMAGE="${1:?usage: test-entrypoint.sh <image> <flavor>}"
FLAVOR="${2:?usage: test-entrypoint.sh <image> <flavor>}"
case "$FLAVOR" in
  fpm|cli|cli-builder) ;;
  *) echo "FAIL: flavor '$FLAVOR' is not one of fpm, cli, cli-builder" >&2; exit 1 ;;
esac
fail() { echo "FAIL: $*" >&2; exit 1; }

# ENTRYPOINT_OVERRIDE/WWW_CONF_OVERRIDE are opt-in local paths, bind-mounted
# read-only over the image's own copy on every `docker run`, so the working-tree
# docker-php-entrypoint (and, for fpm, conf/www.conf) can be tested against an
# already-built image. A container keeps a bind mount for its whole life, so
# `docker exec <c> docker-php-entrypoint ...` picks it up too. Unset, this is a pure
# passthrough: smoke.sh must test exactly what is baked. A call that already mounts
# its own file at the www.conf path (the custom pool configs) is left alone: that
# mount is the thing under test, and docker refuses two binds to the same
# destination.
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

# php-fpm -tt on PHP 7.4 prints every NOTICE line twice, byte-identical (even the
# "[global]"/"[www]" headers; 8.1+ does not). A bare `grep -o` for one directive
# would return the value twice and break a numeric `[[ ... -ge N ]]`. This collapses
# stdin (one value per line) to the single distinct value, still failing loudly if
# -tt ever disagrees with itself.
single_value() {
  local vals
  vals=$(sort -u)
  case "$(printf '%s\n' "$vals" | grep -c .)" in
    1) printf '%s' "$vals" ;;
    *) fail "php-fpm -tt gave inconsistent or missing values for a directive: $(tr '\n' ' ' <<<"$vals")" ;;
  esac
}

# Retries a `cgi-fcgi` request: `docker exec true` succeeding only proves the
# namespace is enterable, not that php-fpm is accepting connections yet, and a
# top-level `var=$(cmd)` trips `set -e` on a non-zero exit, so a connection-refused
# race would kill the suite with no FAIL message.
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

# PHP 8.0+ removes a disabled function from the function table outright ("Call to
# undefined function proc_open()"); PHP 7.x leaves a stub that warns "... has been
# disabled for security reasons" and returns false/NULL, so the script keeps running.
# The proc_open assertions below gate on PHP_MAJOR and require that warning's own
# text: the 7.x shape can never occur on 8.x, and the probe's derived
# PROC_OPEN_BLOCKED marker alone would also appear for any unrelated failure.
PHP_MAJOR=$(docker run --rm "$IMAGE" php -r 'echo PHP_MAJOR_VERSION;')

# This file runs once per flavor (smoke.sh passes the image actually under test), so
# assertions that only mean something for an fpm pool config are gated on $FLAVOR.
# The disable_functions cases and the extension/chmod-shim/ini-scan-dir guards run
# for every flavor.

# 1. ini overrides land
got=$(docker run --rm -e PHP_MEMORY_LIMIT=777M "$IMAGE" php -r 'echo ini_get("memory_limit");')
[[ "$got" == "777M" ]] || fail "PHP_MEMORY_LIMIT ignored, got '$got'"
echo "ok: PHP_MEMORY_LIMIT"

# 2. extension opt-in -- both names, not just the first
# bz2/yaml rather than mongodb: ext.json declares them php>=7.0, so they exist on
# every image this script runs against (mongodb needs php>=8.1).
mods=$(docker run --rm -e PHP_EXT_ENABLE=bz2,yaml "$IMAGE" php -m)
echo "$mods" | grep -qix bz2 || fail "PHP_EXT_ENABLE did not load bz2"
echo "$mods" | grep -qix yaml || fail "PHP_EXT_ENABLE did not load yaml"
echo "ok: PHP_EXT_ENABLE"

if [ "$FLAVOR" = fpm ]; then
# 3-5. No pool config file is written: www.conf references every tunable directive
# as ${PHP_FPM_*} and php-fpm resolves them from its environment. `php-fpm -tt`
# loads and prints the resolved config and exits, no daemon needed, writable or
# read-only.

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
# Capture, then match: a host-side `docker run ... | grep -q` SIGPIPEs the producer
# on first match and pipefail reports a false failure.
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
# PHP_EXT_ENABLE goes straight from the container environment into php-ext-enable,
# which prefixes the name with "20-". These tests assert on the guard's own message,
# not just a non-zero exit, to prove the explicit charset check fires.

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

# 10. an empty element (stray/doubled comma) is tolerated, not fatal -- reached by
# calling php-ext-enable directly, since the entrypoint's `tr ',' ' '` plus unquoted
# word-splitting never produces an empty positional argument.
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

# --- snuffleupagus and chmod shim ------------------------------------------

# 12. PHP_SNUFFLEUPAGUS=<real ruleset> loads the module (ruleset-by-ruleset coverage
# lives in tests/test-snuffleupagus.sh). An unknown ruleset name must fail loudly.
# 7.0 and 7.1 ship without the module (ext.json: php >=7.2); there the same request
# has to refuse, naming the extension, rather than start without it. Whether it
# should be present at all is smoke.sh's registry-derived check.
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

# 12b. PHP_SNUFFLEUPAGUS is a bare ruleset name, never a path ('../x' would resolve
# outside /usr/local/etc/php/snuffleupagus/). Refused before anything is written, on
# every image. The empty value is refused by the generic set-but-empty loop,
# repeated here so the whole contract sits in one place.
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

# 13. PHP_CHMOD_SHIM toggles LD_PRELOAD. Behavioral proof that the shim changes
# chmod() lives in tests/test-fpm-health.sh; this proves the entrypoint branch sets
# LD_PRELOAD, accepts the documented boolean spellings, and refuses anything that is
# neither on nor off rather than treating it as off.
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

# --- autotuning and input validation ----------------------------------------

if [ "$FLAVOR" = fpm ]; then
# 14. An M-suffixed size (PHP_FPM_WORKER_MEMORY=64M) must not silently fall back to
# the baked static pm.max_children.
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
# 15. With no cgroup memory limit, autotuning must not derive from host RAM (hundreds
# of workers on a shared host); it must warn and assume a small fixed default.
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
# 16. A read-only rootfs must autotune regardless of invocation shape: direct
# argv[0]=php-fpm, and wrapped in a shell.
tt=$(docker run --rm --read-only --tmpfs /tmp -m 512m "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "read-only rootfs: php-fpm rejected the config: $tt"
echo "$tt" | grep -q 'pm\.max_children = 16$' && fail "read-only rootfs fell back to the static default: $tt"
# The real ENTRYPOINT still runs; only the COMMAND is a wrapper, so the entrypoint's
# "$@" is ["sh", "-c", "exec php-fpm -tt"] and $1 is not php-fpm.
tt_wrapped=$(docker run --rm --read-only --tmpfs /tmp -m 256m "$IMAGE" \
  sh -c 'exec php-fpm -tt' 2>&1)
echo "$tt_wrapped" | grep -q 'pm\.max_children = 4$' \
  || fail "read-only rootfs did not autotune when php-fpm was wrapped in a shell: $tt_wrapped"
echo "ok: read-only rootfs autotunes, direct and wrapped"
fi

# 17. A newline in a core PHP_* value must not inject a second ini directive (e.g.
# auto_prepend_file, which would run arbitrary PHP on every request).
set +e
out=$(docker run --rm -e "PHP_MEMORY_LIMIT=$(printf '128M\nauto_prepend_file=/tmp/x.php')" "$IMAGE" php -r 'echo ini_get("memory_limit");' 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "newline-embedded PHP_MEMORY_LIMIT was not rejected: $out"
echo "$out" | grep -qi "refusing PHP_MEMORY_LIMIT" || fail "newline injection rejected for the wrong reason: $out"
echo "ok: newline injection rejected"

if [ "$FLAVOR" = fpm ]; then
# 18. PHP_FPM_ACCESS_LOG. /dev/null, not an arbitrary path: `-tt` opens the access log
# while validating, so a missing path would fail for an unrelated reason.
tt=$(docker run --rm -m 512m -e PHP_FPM_ACCESS_LOG=/dev/null "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "PHP_FPM_ACCESS_LOG=/dev/null was rejected: $tt"
echo "$tt" | grep -q 'access\.log = /dev/null$' || fail "PHP_FPM_ACCESS_LOG ignored: $tt"
echo "ok: PHP_FPM_ACCESS_LOG"

# 19. PHP_FPM_MAX_CHILDREN=1 must produce a config php-fpm accepts (min_spare,
# max_spare and start_servers all clamped to 1).
tt=$(docker run --rm -m 512m -e PHP_FPM_MAX_CHILDREN=1 "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "PHP_FPM_MAX_CHILDREN=1 produced a config php-fpm rejects: $tt"
echo "ok: PHP_FPM_MAX_CHILDREN=1 starts cleanly"

# 20. An explicit small PHP_FPM_START_SERVERS is honored exactly, not raised to the
# derived-default floor of 2.
tt=$(docker run --rm -m 4g -e PHP_FPM_START_SERVERS=1 "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q 'pm\.start_servers = 1$' || fail "explicit PHP_FPM_START_SERVERS=1 was overridden: $tt"
echo "ok: explicit start_servers honored below the derived-default floor"
fi

# 21. PHP_EXT_ENABLE must not be glob-expanded against the working directory before
# validation.
set +e
out=$(docker run --rm -w /usr/local/etc/php/conf.d -e 'PHP_EXT_ENABLE=*' "$IMAGE" php -v 2>&1 >/dev/null)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "PHP_EXT_ENABLE=* was not rejected: $out"
echo "$out" | grep -q "invalid extension name: '\*'" || fail "PHP_EXT_ENABLE=* expanded to real filenames instead of being rejected literally: $out"
echo "ok: PHP_EXT_ENABLE=* is not glob-expanded"

# 22. PHP_EXT_ENABLE reducing to nothing after splitting on commas is a typo, not a
# silent no-op.
if docker run --rm -e 'PHP_EXT_ENABLE=,,,' "$IMAGE" php -v >/dev/null 2>&1; then
  fail "PHP_EXT_ENABLE=,,, silently did nothing instead of failing loudly"
fi
echo "ok: PHP_EXT_ENABLE=,,, rejected loudly"

# --- read-only fallback directory and PHP_INI_SCAN_DIR -----------------------

# 23. A file planted at a fixed, guessable /tmp/php-conf.d must have no effect, while
# a legitimate override in the same run still applies (the read-only fallback
# directory is unguessable rather than merely broken).
out=$(docker run --rm --read-only --tmpfs /tmp -m 512m -e PHP_MEMORY_LIMIT=321M --entrypoint sh "$IMAGE" -c '
  mkdir -p /tmp/php-conf.d
  echo "auto_prepend_file=/tmp/pwn.php" > /tmp/php-conf.d/99-zzz-evil.ini
  docker-php-entrypoint php -r "echo \"AP=[\".ini_get(\"auto_prepend_file\").\"] ML=\".ini_get(\"memory_limit\");"
')
echo "$out" | grep -q "AP=\[\]" || fail "ini file planted at the old fixed fallback path was adopted: $out"
echo "$out" | grep -q "ML=321M" || fail "legitimate PHP_MEMORY_LIMIT override broke alongside the planted-file test: $out"
echo "ok: a file planted at the old world-writable conf.d fallback path is ignored"

# 24. The private conf.d fallback directory must be mode 0700, not merely unused by
# the attack above.
perm=$(docker run --rm --read-only --tmpfs /tmp -m 512m --entrypoint sh "$IMAGE" -c '
  docker-php-entrypoint true >/dev/null 2>&1
  stat -c "%a %U" /tmp/php-conf.* 2>/dev/null | head -1
')
echo "$perm" | grep -qE '^700 www-data$' || fail "private conf.d fallback directory is not mode 700 owned by www-data: $perm"
echo "ok: private conf.d fallback directory is mode 700, not world-writable"

if [ "$FLAVOR" = fpm ]; then
# 25. The writable case uses the baked php-fpm.conf directly, with no /tmp fallback
# directory.
tt=$(docker run --rm -m 512m "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "/usr/local/etc/php-fpm.conf test is successful" \
  || fail "writable case unexpectedly used something other than the baked config: $tt"
echo "ok: writable case still uses the baked php-fpm.conf directly"
fi

# 26. An empty element in an operator-supplied PHP_INI_SCAN_DIR (leading, trailing or
# doubled ":") must not make every conf.d ini parse twice. Compared against the
# unset-PHP_INI_SCAN_DIR file count, not a hardcoded number.
baseline=$(docker run --rm "$IMAGE" php -r 'echo count(explode(",", php_ini_scanned_files()));')
# A trailing slash, a doubled slash, "/." and "/./" are the same directory spelled
# another ordinary way and must not double-scan either.
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

# 27. A read-only rootfs plus an operator PHP_INI_SCAN_DIR with no empty element must
# not drop the baked conf.d, which would disable every requested extension and every
# baked hardening setting (disable_functions, opcache).
out=$(docker run --rm --read-only --tmpfs /tmp -m 512m -e PHP_INI_SCAN_DIR=/nonexistent -e PHP_EXT_ENABLE=bz2 "$IMAGE" sh -c '
  php -m | grep -qix bz2 && echo EXT_OK || echo EXT_MISSING
  php -r "echo \"DISABLE=[\".ini_get(\"disable_functions\").\"]\";"
')
echo "$out" | grep -q EXT_OK || fail "read-only + operator PHP_INI_SCAN_DIR dropped the requested extension: $out"
if [ "$FLAVOR" = cli-builder ]; then
  # cli-builder bakes no disable_functions (conf/php-builder.ini omits it because
  # build tooling needs proc_open et al), so there is no hardening to check; confirm
  # it stays that way.
  echo "$out" | grep -q "DISABLE=\[\]" || fail "cli-builder: read-only + operator PHP_INI_SCAN_DIR unexpectedly introduced a disable_functions value: $out"
else
  echo "$out" | grep -q "DISABLE=\[passthru" || fail "read-only + operator PHP_INI_SCAN_DIR dropped baked hardening (disable_functions): $out"
fi
echo "ok: $FLAVOR -- read-only rootfs with an operator PHP_INI_SCAN_DIR keeps the baked conf.d"

# 28. --read-only without --tmpfs /tmp (neither conf.d nor /tmp writable) must degrade
# with a branded diagnostic and still start, not die on a raw mkdir/mktemp error.
set +e
out=$(docker run --rm --read-only -m 512m "$IMAGE" php -v 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "--read-only without --tmpfs /tmp failed to start: $out"
echo "$out" | grep -qi "docker-php-entrypoint:.*is writable" || fail "--read-only without --tmpfs /tmp gave no branded diagnostic: $out"
# Match any PHP version: this proves only that `php -v` ran after the diagnostic.
echo "$out" | grep -qE "PHP [0-9]+\." || fail "--read-only without --tmpfs /tmp printed a diagnostic but did not actually start: $out"
echo "ok: --read-only without --tmpfs /tmp degrades with a branded diagnostic"

if [ "$FLAVOR" = fpm ]; then
# 29. Bypassing the entrypoint must still produce a valid FPM config: the Dockerfile
# bakes ENV defaults for exactly this.
tt=$(docker run --rm --entrypoint php-fpm "$IMAGE" -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "bypassing the entrypoint produced an invalid FPM config: $tt"
echo "$tt" | grep -q 'pm\.max_children = 16$' || fail "bypassing the entrypoint did not show the baked legacy default: $tt"
echo "ok: bypassing the entrypoint entirely still yields a valid config"
fi

# --- explicit pool sizes and set-but-empty values -----------------------------

if [ "$FLAVOR" = fpm ]; then
# 30. A pool size the operator sets explicitly must be honored even when it equals the
# image's baked default, which is the one number a Helm chart or compose template
# rendering every tunable from the documented defaults will pass. Tests 5 and 20 use
# values that differ from the defaults, so they cannot see this.
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

# 34. A pinned pool value can contradict a neighbor the script derived: `-e
# PHP_FPM_MAX_SPARE=8` on 4GB (max_children 44, min_spare 11) is a pool php-fpm
# refuses ("pm.max_spare_servers must not be less than pm.min_spare_servers"). The
# derived neighbor has to move, not the pinned value and not the container's ability
# to start.
tt=$(docker run --rm -m 4g -e PHP_FPM_MAX_SPARE=8 "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "a pinned pm.max_spare_servers alongside autotuned neighbors produced a config php-fpm rejects: $tt"
echo "$tt" | grep -q 'pm\.max_spare_servers = 8$' || fail "the pinned pm.max_spare_servers was moved instead of its derived neighbors: $tt"
tt=$(docker run --rm -m 4g -e PHP_FPM_MIN_SPARE=30 "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" || fail "a pinned pm.min_spare_servers alongside autotuned neighbors produced a config php-fpm rejects: $tt"
echo "$tt" | grep -q 'pm\.min_spare_servers = 30$' || fail "the pinned pm.min_spare_servers was moved instead of its derived neighbors: $tt"
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
# 31. Set-but-empty is what an unset shell variable renders to in a compose file or
# Helm template; PHP_FPM_MAX_REQUESTS= would otherwise become pm.max_requests = 0 and
# PHP_FPM_STATUS_PATH= would unpublish the status endpoint. Asserts on the branded
# message, not just a non-zero exit.
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
# The one deliberate exception: an empty PHP_INI_SCAN_DIR is PHP's own "scan nothing
# at all" and the only way to opt out of the baked conf.d, so it keeps working,
# except on fpm. The fpm image bakes a non-empty PHP_DISABLE_FUNCTIONS ENV default
# (for www.conf's substitution) that PHP_INI_SCAN_DIR= stops being enforced for a
# bare `php`; the entrypoint cannot tell that from an explicit request, so it fails
# closed and refuses. cli/cli-builder bake no such default, so the combination just
# starts there.
if [ "$FLAVOR" = fpm ]; then
  set +e
  out=$(docker run --rm -e PHP_INI_SCAN_DIR= -e PHP_MEMORY_LIMIT=777M "$IMAGE" php -r 'echo ini_get("memory_limit");' 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fpm: PHP_INI_SCAN_DIR= started despite dropping the image's own baked PHP_DISABLE_FUNCTIONS default: $out"
  echo "$out" | grep -q "PHP_INI_SCAN_DIR is also set to the empty string" \
    || fail "fpm: PHP_INI_SCAN_DIR= + baked PHP_DISABLE_FUNCTIONS refusal did not name PHP_INI_SCAN_DIR: $out"
  echo "ok: fpm -- set-but-empty values rejected loudly; PHP_INI_SCAN_DIR= also refuses (it would drop the image's own baked PHP_DISABLE_FUNCTIONS)"
else
  out=$(docker run --rm -e PHP_INI_SCAN_DIR= -e PHP_MEMORY_LIMIT=777M "$IMAGE" php -r 'echo ini_get("memory_limit");')
  [ "$out" != "777M" ] || fail "$FLAVOR: PHP_INI_SCAN_DIR= does not disable ini scanning: $out"
  [ -n "$out" ] || fail "$FLAVOR: PHP_INI_SCAN_DIR= (documented opt-out) failed to start"
  echo "ok: $FLAVOR -- set-but-empty values rejected loudly, PHP_INI_SCAN_DIR= still honored (no baked PHP_DISABLE_FUNCTIONS default here)"
fi

# 32/33. Under a read-only rootfs the entrypoint creates a private, mktemp-named ini
# directory that must outlive it (every php process reads it), so it cannot clean up
# on exit. On the documented --tmpfs /tmp that costs nothing; on a volume- or
# bind-backed /tmp the entrypoint reaps leftovers.
conf_vol="conf-vol-$$"
live_vol="live-vol-$$"
live_ctr="live-ctr-$$"
live_cleanup() { docker rm -f "$live_ctr" >/dev/null 2>&1 || true; docker volume rm "$conf_vol" "$live_vol" >/dev/null 2>&1 || true; }
trap live_cleanup EXIT
docker volume create "$conf_vol" >/dev/null

# 32. three starts, at most one directory left behind
for _ in 1 2 3; do
  docker run --rm --read-only -v "$conf_vol":/tmp -m 512m "$IMAGE" php -r 'echo "";' >/dev/null 2>&1 \
    || fail "a read-only start with a volume-backed /tmp failed outright"
done
n=$(docker run --rm -v "$conf_vol":/tmp --entrypoint sh "$IMAGE" -c 'ls -d /tmp/php-conf.* 2>/dev/null | wc -l')
[ "$n" -le 1 ] || fail "$n private conf directories left behind after 3 starts on a persistent /tmp, expected at most 1"
echo "ok: private conf directories do not accumulate on a persistent /tmp ($n left)"

# 33. ...and the reaping must never take a directory a *running* container still
# depends on. A peer sharing /tmp is in another PID namespace, so the advisory lock
# each private directory carries is the only liveness signal that crosses it. Both
# halves are asserted (not reaped while live, reaped once dead) so the first cannot
# pass merely because nothing ever reaps.
# It has its own volume because a leftover directory in test 32's is
# indistinguishable by name from the live container's; the live one is identified by
# the one property only it has, a held lock.
docker volume create "$live_vol" >/dev/null
docker run -d --name "$live_ctr" --read-only -v "$live_vol":/tmp -m 512m "$IMAGE" \
  php -r 'sleep(120);' >/dev/null
live_dir=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  live_dir=$(docker run --rm -v "$live_vol":/tmp --entrypoint sh "$IMAGE" -c '
    for d in /tmp/php-conf.*; do
      [ -d "$d" ] && [ -f "$d/.lock" ] || continue
      flock -n "$d/.lock" true 2>/dev/null || { echo "$d"; break; }
    done')
  [ -n "$live_dir" ] && break
  sleep 1
done
[ -n "$live_dir" ] || fail "the long-running container never created a locked private conf directory"
docker run --rm --read-only -v "$live_vol":/tmp -m 512m "$IMAGE" php -r 'echo "";' >/dev/null 2>&1
still=$(docker run --rm -v "$live_vol":/tmp --entrypoint sh "$IMAGE" -c "[ -d '$live_dir' ] && echo PRESENT || echo GONE")
[ "$still" = PRESENT ] || fail "a running container's private conf directory ($live_dir) was reaped by another container's start"
docker rm -f "$live_ctr" >/dev/null
docker run --rm --read-only -v "$live_vol":/tmp -m 512m "$IMAGE" php -r 'echo "";' >/dev/null 2>&1
gone=$(docker run --rm -v "$live_vol":/tmp --entrypoint sh "$IMAGE" -c "[ -d '$live_dir' ] && echo PRESENT || echo GONE")
[ "$gone" = GONE ] || fail "the private conf directory of a container that has exited ($live_dir) was never reaped"
live_cleanup
trap - EXIT
echo "ok: a live container's private conf directory survives, a dead one's is reaped"

if [ "$FLAVOR" = fpm ]; then
# 35. www.conf reads the PHP_FPM_*_EFFECTIVE names, so those are what `docker image
# inspect` reports and operators find and set. They are computed outputs that the
# autotuned value would silently overwrite (999 -> 44 on 4g), so setting one has to
# fail, and the message has to name the variable that does work.
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
# The bypass path legitimately reads the baked _EFFECTIVE defaults, so the refusal
# must live where the entrypoint runs and nowhere else.
tt=$(docker run --rm --entrypoint php-fpm -e PHP_FPM_MAX_CHILDREN_EFFECTIVE=999 "$IMAGE" -tt 2>&1)
echo "$tt" | grep -q 'pm\.max_children = 999$' \
  || fail "the entrypoint-bypass path does not read PHP_FPM_MAX_CHILDREN_EFFECTIVE: $tt"
echo "ok: the internal _EFFECTIVE names are refused with a signpost; the bypass path still reads them"
fi

# 36. PHP_SNUFFLEUPAGUS checks CONF_WRITABLE up front, like PHP_EXT_ENABLE, so a
# missing writable conf dir gets the branded diagnostic instead of a raw redirection
# error.
set +e
out=$(docker run --rm --read-only -m 512m -e PHP_SNUFFLEUPAGUS=laravel "$IMAGE" php -v 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "PHP_SNUFFLEUPAGUS with no writable conf dir was not rejected: $out"
echo "$out" | grep -q "PHP_SNUFFLEUPAGUS=laravel requested but no writable ini directory is available" \
  || fail "PHP_SNUFFLEUPAGUS with no writable conf dir failed for the wrong reason: $out"
echo "ok: PHP_SNUFFLEUPAGUS fails with a branded message when no writable conf dir is available"

# --- fail closed when a hardening control cannot be applied, and only when it
# actually is not going to be in force ---------------------------------------
#
# Every assertion below uses proc_open as the sentinel: it is deliberately not in
# the baked disable_functions default (composer and Symfony Process need it, see
# CLAUDE.md), so whether proc_open() runs is real signal. exec would not be: it is
# baked-disabled, so a test on it passes with or without the operator's override.
#
# The entrypoint asks PHP (or php-fpm) what will actually be in force rather than
# comparing against a baked constant, so refusals name the missing function(s).
#
# smoke.sh runs this script once per real flavor, so $IMAGE is the cli/cli-builder
# image when $FLAVOR says so. Only the fpm-pool half ("fpm's differing half") is
# flavor-gated: there is no www.conf or pool on cli/cli-builder.

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
  fail "$FLAVOR: proc_open() ran despite the entrypoint refusing to start (regression): $out"
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

# 38. (b) a tuning knob dropped the same way keeps the container running and is named
# with its value.
set +e
out=$(docker run --rm --read-only -e PHP_MEMORY_LIMIT=256M "$IMAGE" \
  php -r 'echo ini_get("memory_limit");' 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "$FLAVOR: PHP_MEMORY_LIMIT dropped under bare --read-only failed to start: $out"
echo "$out" | grep -q "PHP_MEMORY_LIMIT=256M requested but no ini directory is writable" \
  || fail "$FLAVOR: PHP_MEMORY_LIMIT drop warning did not name the variable and value: $out"
echo "ok: $FLAVOR -- PHP_MEMORY_LIMIT dropped under bare --read-only warns by name and value, still starts"

# 39. (c) an unset variable was never "requested": the empty-environment bare
# --read-only case must start clean, with none of the named warnings or refusals
# firing. On fpm this also proves the image's baked PHP_DISABLE_FUNCTIONS ENV default
# (always present there for www.conf) is told apart from a real override.
out=$(docker run --rm --read-only "$IMAGE" php -r 'echo "CLEAN_START";' 2>&1)
echo "$out" | grep -q "CLEAN_START" \
  || fail "$FLAVOR: bare --read-only with nothing set failed to start clean: $out"
if echo "$out" | grep -qE "PHP_DISABLE_FUNCTIONS=|PHP_MEMORY_LIMIT=|not in force|missing:"; then
  fail "$FLAVOR: bare --read-only with nothing set produced a named warning/refusal about a variable nobody set: $out"
fi
echo "ok: $FLAVOR -- bare --read-only with nothing set starts clean"

# 40. (d) with a writable /tmp, the control applies: proc_open() is called and its
# failure observed, not just ini_get() read back. The probe is expected to fail
# (rc=255), so the substitution is guarded with set +e/-e.
set +e
out=$(docker run --rm --read-only --tmpfs /tmp -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php -r "$proc_open_probe" 2>&1)
set -e
if echo "$out" | grep -q "SENTINEL_RAN"; then
  fail "$FLAVOR: proc_open() actually ran under --tmpfs /tmp despite PHP_DISABLE_FUNCTIONS=proc_open: $out"
fi
# A disabled proc_open() is not the same shape on every PHP version: 8.0+ removes it
# from the function table ("Call to undefined function proc_open()", fatal), while
# 7.x leaves a stub that warns ("has been disabled for security reasons") and
# returns NULL, so the probe's own is_resource() check echoes PROC_OPEN_BLOCKED.
# Gated by PHP_MAJOR; the 7.x branch requires the warning's own text, not just the
# marker, which any unrelated proc_open() failure would also print.
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

# An operator-emptied PHP_INI_SCAN_DIR means nothing baked is scanned (the image has
# no main php.ini, only conf.d), so a PHP_DISABLE_FUNCTIONS set alongside it cannot
# be in force even with a writable conf.d. Refused, naming both variables.
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
echo "ok: $FLAVOR -- empty PHP_INI_SCAN_DIR + PHP_DISABLE_FUNCTIONS refuses, naming both variables"

if [ "$FLAVOR" = fpm ]; then
# fpm's differing half: PHP_DISABLE_FUNCTIONS reaches php-fpm through www.conf's
# php_admin_value regardless of conf.d writability, so fpm has nothing to fail closed
# on for this variable when the stock www.conf loads. Proven through a real FastCGI
# round trip against a live worker (test-fpm-health.sh's idiom), not `php-fpm -tt`,
# which shows only what config would load, not what a running worker enforces.
fpm_e2e_name="fpm-e2e-$$"
trap 'docker rm -f "$fpm_e2e_name" >/dev/null 2>&1 || true' EXIT
# /probe is a separate tmpfs for the probe script only; /tmp stays part of the
# read-only rootfs, so CONF_WRITABLE is 0, the bare --read-only scenario.
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
'"'"' > /probe/e2e-probe.php'
fpm_e2e_out=$(fcgi_request "$fpm_e2e_name" -e SCRIPT_FILENAME=/probe/e2e-probe.php -e SCRIPT_NAME=/e2e-probe.php -e REQUEST_METHOD=GET)
# Any HTTP 500 looks the same from here (a disabled-function fatal, an unrelated
# crash, a bug elsewhere), so logs are captured before the container is removed and
# the assertion below requires the fatal's own text, not just the status code.
fpm_e2e_logs=$(docker logs "$fpm_e2e_name" 2>&1)
docker rm -f "$fpm_e2e_name" >/dev/null 2>&1
trap - EXIT
if echo "$fpm_e2e_out" | grep -q "SENTINEL_RAN"; then
  fail "fpm: proc_open() actually ran in a live FastCGI worker despite PHP_DISABLE_FUNCTIONS=proc_open under bare --read-only: $fpm_e2e_out"
fi
# A disabled-function fatal in a live worker is a bare HTTP 500 with an empty body
# (display_errors is off), which is also what a crash or a missing script looks
# like, so the fatal's own text is required in the container's logs.
#
# PHP 7.x does not fatal a disabled proc_open(): it warns and returns false, the
# script keeps running, and the probe's is_resource() check echoes PROC_OPEN_BLOCKED
# with a normal 200 (matching the CLI probe's 7.x branch above). Gated by PHP_MAJOR;
# the 7.x warning goes to php-fpm's error log rather than the response body, so that
# branch checks $fpm_e2e_logs.
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

# Positive control: the same probe and live worker with PHP_DISABLE_FUNCTIONS unset,
# proving the 500+log check measures the control and not a worker that fatals on
# proc_open() (or this probe script) unconditionally.
fpm_e2e_ctrl_name="fpm-e2e-ctrl-$$"
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
'"'"' > /probe/e2e-probe.php'
fpm_e2e_ctrl_out=$(fcgi_request "$fpm_e2e_ctrl_name" -e SCRIPT_FILENAME=/probe/e2e-probe.php -e SCRIPT_NAME=/e2e-probe.php -e REQUEST_METHOD=GET)
docker rm -f "$fpm_e2e_ctrl_name" >/dev/null 2>&1
trap - EXIT
echo "$fpm_e2e_ctrl_out" | grep -q "SENTINEL_RAN" \
  || fail "fpm: positive control -- proc_open() did not run in a live FastCGI worker with no PHP_DISABLE_FUNCTIONS set: $fpm_e2e_ctrl_out"
echo "ok: fpm -- positive control -- the same live-worker probe runs proc_open() successfully with nothing disabled"

tt=$(docker run --rm --read-only "$IMAGE" php-fpm -tt 2>&1)
echo "$tt" | grep -q "test is successful" \
  || fail "fpm: bare --read-only with nothing set failed to start (php-fpm -tt): $tt"
echo "ok: fpm -- bare --read-only with nothing set starts clean (php-fpm -tt)"

# argv "$1=php-fpm" alone is not trusted: the entrypoint resolves what php-fpm will
# load (php-fpm -tt) and checks each pool, not just the stock www.conf's
# php_admin_value. A mounted pool config that sets neither
# php_admin_value[disable_functions] nor php_value[disable_functions] must be refused
# under bare --read-only, since nothing in that pool or in the unwritable conf.d
# applies the request.
stockconf_conf="/tmp/stockconf-www-$$.conf"
cat >"$stockconf_conf" <<'CONF'
[www]
user = www-data
group = www-data
listen = 0.0.0.0:9000
pm = static
pm.max_children = 2
CONF
# php-fpm -F runs in the foreground forever once it starts, so a regressed refusal
# would hang this `docker run` (no -d) and the whole suite. `timeout` turns the hang
# into a named failure; the container is force-removed afterwards either way.
stockconf_fpmf_name="stockconf-fpmF-$$"
set +e
out=$(timeout 10 docker run --rm --name "$stockconf_fpmf_name" --read-only -m 512m \
  -v "$stockconf_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -F 2>&1)
rc=$?
set -e
docker rm -f "$stockconf_fpmf_name" >/dev/null 2>&1 || true
rm -f "$stockconf_conf"
if [ "$rc" -eq 124 ]; then
  fail "php-fpm -F for a pool lacking disable_functions did not refuse within 10s (timed out instead) -- the refusal regressed: $out"
fi
[ "$rc" -ne 0 ] || fail "a mounted fpm pool config lacking disable_functions entirely started instead of refusing under bare --read-only: $out"
echo "$out" | grep -q "missing: proc_open" \
  || fail "refusal for a pool lacking disable_functions did not name proc_open: $out"
echo "ok: fpm -- a mounted pool config that sets neither php_admin_value nor php_value[disable_functions] refuses under bare --read-only"

# ...and the stock www.conf (php_admin_value referencing the operator's own value)
# must still start, proven through the same FastCGI round trip as above.
stockconf_name="stockconf-stock-$$"
trap 'docker rm -f "$stockconf_name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$stockconf_name" --read-only --tmpfs /probe -m 512m -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" >/dev/null
stockconf_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if docker exec "$stockconf_name" true >/dev/null 2>&1; then
    stockconf_ready=1
    break
  fi
  sleep 0.3
done
[ "$stockconf_ready" -eq 1 ] || { docker logs "$stockconf_name" >&2 2>&1 || true; fail "stock-www.conf container never became execable"; }
docker exec "$stockconf_name" sh -c "printf '<?php echo \"REACHED\";' > /probe/stockconf-probe.php"
stockconf_out=$(fcgi_request "$stockconf_name" -e SCRIPT_FILENAME=/probe/stockconf-probe.php -e SCRIPT_NAME=/stockconf-probe.php -e REQUEST_METHOD=GET)
docker rm -f "$stockconf_name" >/dev/null 2>&1
trap - EXIT
echo "$stockconf_out" | grep -q "REACHED" \
  || fail "the stock www.conf (php_admin_value covers disable_functions) failed to start/serve under bare --read-only: $stockconf_out"
echo "ok: fpm -- the stock www.conf still starts and serves under bare --read-only"

# Any `NOTICE: [<anything>]` line other than `[global]` is a pool header: pool names
# are arbitrary (`[app@site]`, `[a b]` and `[app:1]` are all legal). A header the
# script fails to recognize would have its config (disable_functions coverage
# included) merged into the preceding pool, reporting an unprotected pool as covered.
# Four pools, one per port: [www] carries the operator's php_admin_value (the
# control, must NOT be named in the refusal); the other three carry none, use the
# three shapes above, and must each be named individually.
mixconf_conf="/tmp/mixconf-www-$$.conf"
cat >"$mixconf_conf" <<'CONF'
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
  -v "$mixconf_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -f "$mixconf_conf"
[ "$rc" -ne 0 ] || fail "a pool config with unusual pool names started instead of refusing: $out"
for pool in 'app@site' 'a b' 'app:1'; do
  echo "$out" | grep -qF "pool [${pool}] missing: proc_open" \
    || fail "refusal did not individually name pool [${pool}] as missing proc_open (skipped or merged into a neighbor's coverage): $out"
done
echo "$out" | grep -qF "pool [www] missing" \
  && fail "the protected [www] pool was incorrectly named in the refusal too: $out"
echo "ok: fpm -- pool headers named [app@site], [a b] and [app:1] are each recognized and individually checked, not skipped or merged"
fi

# zend_disable_functions splits on literal space/comma only and matches
# case-sensitively against a lowercase function table, so 'EXEC, System' or a
# tab-separated list leaves both functions callable. Every case below runs on every
# flavor.

# (a) mixed uppercase, comma+space -- refused up front, naming the bad
# token, before anything is written or exec'd.
set +e
out=$(docker run --rm --read-only --tmpfs /tmp -e 'PHP_DISABLE_FUNCTIONS=EXEC, System' "$IMAGE" php -r "$proc_open_probe" 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "$FLAVOR: PHP_DISABLE_FUNCTIONS='EXEC, System' started instead of being refused: $out"
echo "$out" | grep -qi "refusing PHP_DISABLE_FUNCTIONS" \
  || fail "$FLAVOR: 'EXEC, System' was rejected for the wrong reason: $out"
echo "$out" | grep -qF "'EXEC'" \
  || fail "$FLAVOR: refusal did not name the offending token 'EXEC': $out"
echo "ok: $FLAVOR -- PHP_DISABLE_FUNCTIONS='EXEC, System' is refused up front, naming the bad token"

# (b) a tab is not a valid separator to PHP's own splitter -- it stays part
# of the token, and the resulting token is refused the same way.
tab_value="exec$(printf '\t')system"
set +e
out=$(docker run --rm --read-only --tmpfs /tmp -e "PHP_DISABLE_FUNCTIONS=${tab_value}" "$IMAGE" php -r "$proc_open_probe" 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "$FLAVOR: a tab-separated PHP_DISABLE_FUNCTIONS started instead of being refused: $out"
echo "$out" | grep -qi "refusing PHP_DISABLE_FUNCTIONS" \
  || fail "$FLAVOR: tab-separated value was rejected for the wrong reason: $out"
echo "ok: $FLAVOR -- a tab between function names (not a valid PHP separator) is refused, not silently accepted"

# (c) positive control: a legitimately-formatted value (comma AND a space
# after it -- both are valid separators, collapsed together) still works
# and actually disables every requested name.
set +e
out=$(docker run --rm --read-only --tmpfs /tmp -e 'PHP_DISABLE_FUNCTIONS=exec, proc_open' "$IMAGE" php -r "$proc_open_probe" 2>&1)
set -e
if echo "$out" | grep -q "SENTINEL_RAN"; then
  fail "$FLAVOR: proc_open() ran despite 'exec, proc_open' (comma+space) requesting it disabled: $out"
fi
# Accept either disabled-function shape (see the fpm live-worker check above), gated
# by PHP_MAJOR and the real warning text like the other proc_open assertions.
if [ "$PHP_MAJOR" -ge 8 ]; then
  echo "$out" | grep -qF "Call to undefined function proc_open()" \
    || fail "$FLAVOR: positive control -- 'exec, proc_open' (valid comma+space separator) did not fail with PHP $PHP_MAJOR's disabled-function fatal: $out"
else
  echo "$out" | grep -q "has been disabled for security reasons" \
    || fail "$FLAVOR: positive control -- 'exec, proc_open' did not show PHP $PHP_MAJOR's own 'has been disabled for security reasons' warning: $out"
  echo "$out" | grep -qF "PROC_OPEN_BLOCKED" \
    || fail "$FLAVOR: positive control -- PHP $PHP_MAJOR disabled proc_open() but the probe's own is_resource() check did not report PROC_OPEN_BLOCKED: $out"
fi
echo "ok: $FLAVOR -- positive control -- a comma-plus-space-separated value still splits and applies correctly"

# docker exec under --read-only --tmpfs /tmp. Run once, on cli: it is a
# docker-exec/entrypoint property, not a flavor one.
if [ "$FLAVOR" = cli ]; then
execenv_name="execenv-exec-$$"
trap 'docker rm -f "$execenv_name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$execenv_name" --read-only --tmpfs /tmp -m 512m "$IMAGE" php -r 'sleep(120);' >/dev/null
# `docker exec <c> docker-php-entrypoint php ...` re-runs this whole script against
# the freshly exec'd environment (a new private conf.d, PHP_INI_SCAN_DIR recomputed)
# and sees an override supplied only at exec time.
execenv_out=$(docker exec -e PHP_MEMORY_LIMIT=654M "$execenv_name" docker-php-entrypoint php -r 'echo ini_get("memory_limit");' 2>&1)
echo "$execenv_out" | grep -q "654M" \
  || fail "docker exec <c> docker-php-entrypoint php did not see an override set only at exec time: $execenv_out"
echo "ok: docker exec <c> docker-php-entrypoint php ... applies overrides set only at exec time"

# ...and the bare form -- `docker exec <c> php ...`, skipping the entrypoint
# entirely -- does NOT, so this cannot silently change: it sees whatever the
# container started with (the image default, since nothing was set at
# `docker run` time), not the exec-time override.
execenv_bare_out=$(docker exec -e PHP_MEMORY_LIMIT=654M "$execenv_name" php -r 'echo ini_get("memory_limit");' 2>&1)
if echo "$execenv_bare_out" | grep -q "654M"; then
  fail "bare 'docker exec <c> php' unexpectedly picked up an exec-time-only override (should only see docker-php-entrypoint's own re-run do that): $execenv_bare_out"
fi
# A failed `docker exec` (container gone, php missing) would also print no "654M", so
# require php to have run and read back the baked cli default (conf/php-cli.ini
# memory_limit = 512M; nothing set PHP_MEMORY_LIMIT at `docker run` time).
echo "$execenv_bare_out" | grep -qx "512M" \
  || fail "positive control -- bare 'docker exec <c> php' did not run successfully at all (expected the baked cli default 512M): $execenv_bare_out"
echo "ok: bare docker exec <c> php ... does not see an override set only at exec time (unchanged, documented baseline)"
docker rm -f "$execenv_name" >/dev/null 2>&1
trap - EXIT
fi

# ------------------------------------------------------------------------
# PHP_DISABLE_FUNCTIONS adds to the baked list, never replaces it; names that cannot
# resolve to a real function are refused; a pool value the script cannot safely
# re-tokenize is refused; and NOTICE-line matching is anchored to the line's fixed
# prefix.

# On a writable conf.d, a name baked into the default but not requested (dl) must
# stay disabled alongside the requested one; otherwise dl("ssh2.so") could load a
# shared extension. cli-builder bakes no default (conf/php-builder.ini), so this is
# meaningless there.
if [ "$FLAVOR" != cli-builder ]; then
  out=$(docker run --rm -e PHP_DISABLE_FUNCTIONS=get_current_user "$IMAGE" \
    php -r 'echo function_exists("dl") ? "DL_LIVE" : "DL_GONE", " ", function_exists("get_current_user") ? "GCU_LIVE" : "GCU_GONE";' 2>&1)
  echo "$out" | grep -q "DL_GONE" \
    || fail "$FLAVOR: PHP_DISABLE_FUNCTIONS=get_current_user (writable conf.d) let dl() come back, although it is in the baked default: $out"
  echo "$out" | grep -q "GCU_GONE" \
    || fail "$FLAVOR: PHP_DISABLE_FUNCTIONS=get_current_user did not actually disable it: $out"
  echo "ok: $FLAVOR -- PHP_DISABLE_FUNCTIONS unions with the baked disable_functions list on a writable conf.d (dl stays disabled, the requested name is added)"
fi

# eval (a language construct) and shel_exec (a typo) are refused as unable to resolve
# to a real function; assert_options (real) in the same list must not be swept up in
# that refusal.
set +e
out=$(docker run --rm --read-only --tmpfs /tmp -e 'PHP_DISABLE_FUNCTIONS=eval,assert_options,shel_exec' "$IMAGE" php -r 'echo "EVAL_RAN";' 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "$FLAVOR: PHP_DISABLE_FUNCTIONS=eval,assert_options,shel_exec started instead of being refused: $out"
if echo "$out" | grep -q "EVAL_RAN"; then
  fail "$FLAVOR: refused for the wrong reason -- the command still ran: $out"
fi
echo "$out" | grep -qi "cannot resolve to a real function" \
  || fail "$FLAVOR: refusal was not the 'cannot resolve' message: $out"
# The offender list is the phrase right before "cannot resolve", checked as that
# exact comma-joined phrase: the message also echoes the operator's whole original
# value, which itself contains "assert_options", so a bare substring search would
# always pass.
echo "$out" | grep -qF "eval, shel_exec cannot resolve to a real function" \
  || fail "$FLAVOR: refusal did not name exactly 'eval, shel_exec' (not assert_options) as unresolvable: $out"
echo "ok: $FLAVOR -- eval (language construct) and shel_exec (typo) are refused as unresolvable; assert_options (real) is not"

# negative control: two genuinely real, resolvable functions must never be refused at
# the resolve stage (whether they end up disabled is a different question).
out=$(docker run --rm --tmpfs /tmp -e 'PHP_DISABLE_FUNCTIONS=assert_options,proc_open' "$IMAGE" php -r 'echo "REACHED";' 2>&1)
if echo "$out" | grep -qi "cannot resolve to a real function"; then
  fail "$FLAVOR: negative control -- assert_options/proc_open (both real functions) were wrongly refused as unresolvable: $out"
fi
echo "ok: $FLAVOR -- negative control -- two real functions are not refused at the resolve stage"

# The baked half of the union must come from the image's own baked ini, never from a
# previous start's 99-env.ini on a persistent conf.d. Otherwise requesting a name
# that disables ini_get() itself (not on any baked list) starves the probe on the
# next start, and the real baked list (exec, system, dl, ...) silently disappears.
# Skipped on cli-builder: no baked disable_functions default.
if [ "$FLAVOR" != cli-builder ]; then
confd1_confd="/tmp/ep-f1-confd-$$"
mkdir -p "$confd1_confd"
chmod 777 "$confd1_confd"
docker run --rm -v "$confd1_confd":/out "$IMAGE" sh -c 'cp /usr/local/etc/php/conf.d/*.ini /out/ 2>/dev/null' >/dev/null
rm -f "$confd1_confd/99-env.ini" "$confd1_confd/90-opcache-env.ini"
confd1_probe='foreach (["ini_get","exec","system","dl"] as $f) { echo $f, "=", function_exists($f) ? "LIVE" : "gone", " "; }'
out1=$(docker run --rm -v "$confd1_confd":/usr/local/etc/php/conf.d \
  -e PHP_DISABLE_FUNCTIONS=ini_get "$IMAGE" php -r "$confd1_probe")
echo "$out1" | grep -qw "ini_get=gone" || fail "$FLAVOR: first start did not disable ini_get: $out1"
echo "$out1" | grep -qw "exec=gone" || fail "$FLAVOR: first start did not carry the baked list (exec) alongside ini_get: $out1"
out2=$(docker run --rm -v "$confd1_confd":/usr/local/etc/php/conf.d \
  -e PHP_DISABLE_FUNCTIONS=ini_get "$IMAGE" php -r "$confd1_probe")
rm -rf "$confd1_confd"
echo "$out2" | grep -qw "exec=gone" \
  || fail "$FLAVOR: second start on the same persistent conf.d dropped the baked list (exec came back LIVE) after ini_get had already disabled itself on the first start: $out2"
echo "$out2" | grep -qw "system=gone" \
  || fail "$FLAVOR: second start dropped the baked list (system came back LIVE): $out2"
echo "$out2" | grep -qw "dl=gone" \
  || fail "$FLAVOR: second start dropped the baked list (dl came back LIVE): $out2"
echo "ok: $FLAVOR -- PHP_DISABLE_FUNCTIONS=ini_get survives a restart on a persistent conf.d without silently dropping the baked disable_functions list"
fi

if [ "$FLAVOR" = fpm ]; then
# A pool's own disable_functions value containing a character the script cannot
# safely re-tokenize the way php-fpm does (here ';', a comment to `php -d` but not to
# php-fpm) is refused rather than under-verified.
pool_conf="/tmp/ep-i3-www-$$.conf"
cat >"$pool_conf" <<'CONF'
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
  -v "$pool_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -f "$pool_conf"
[ "$rc" -ne 0 ] || fail "a pool disable_functions value containing ';' started instead of refusing: $out"
echo "$out" | grep -qi "cannot safely re-parse" \
  || fail "refusal for the ';'-containing pool value was not the charset-refusal message: $out"
echo "ok: fpm -- a pool disable_functions value this script cannot safely re-tokenize (';') refuses rather than silently under- or over-disabling"

# negative control: the same shape, an ordinary comma-separated value,
# still verifies fine.
pooln_conf="/tmp/ep-i3n-www-$$.conf"
cat >"$pooln_conf" <<'CONF'
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9211
pm = static
pm.max_children = 1
php_admin_value[disable_functions] = proc_open
CONF
out=$(docker run --rm --read-only -m 512m \
  -v "$pooln_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rm -f "$pooln_conf"
echo "$out" | grep -q "test is successful" \
  || fail "negative control: an ordinary comma-separated pool value was wrongly refused: $out"
echo "ok: fpm -- negative control -- an ordinary pool disable_functions value still verifies fine"

# A pool that loads its own extension (php_admin_value[extension]) can supply a
# function the script's probe cannot see; refused outright rather than certified.
ext_conf="/tmp/ep-ext-www-$$.conf"
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
[ "$rc" -ne 0 ] || fail "a pool loading its own extension started instead of refusing: $out"
echo "$out" | grep -qi "loads its own extension" \
  || fail "refusal for a pool loading its own extension was not the expected message: $out"
echo "ok: fpm -- a pool that loads its own extension (php_admin_value[extension]) refuses rather than certifying a probe that cannot see it (negative control: the stock www.conf, which loads none, already passes above and elsewhere in this file)"

# A directive VALUE that spoofs a disable_functions NOTICE line must not be mistaken
# for a real directive: the pool has no real disable_functions, falls through to the
# baseline, and is refused for missing proc_open.
mix1_conf="/tmp/ep-m1-www-$$.conf"
cat >"$mix1_conf" <<'CONF'
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
  -v "$mix1_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -f "$mix1_conf"
[ "$rc" -ne 0 ] || fail "a pool whose error_log value spoofs a disable_functions NOTICE line started instead of refusing: $out"
echo "$out" | grep -qF "pool [www] missing: proc_open" \
  || fail "the spoofed pool was not correctly refused as missing proc_open (the spoofed value may have been trusted instead): $out"
echo "ok: fpm -- a directive value that spoofs a disable_functions NOTICE line is not mistaken for a real directive"

# A pool named with the literal text "NOTICE: [global]" must be recognized as its own
# unprotected pool, not dropped as the real [global] header and merged into [www].
mix2_conf="/tmp/ep-m2-www-$$.conf"
cat >"$mix2_conf" <<'CONF'
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
  -v "$mix2_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -f "$mix2_conf"
[ "$rc" -ne 0 ] || fail "a pool named '[a NOTICE: [global]' started instead of refusing: $out"
echo "$out" | grep -qF "pool [a NOTICE: [global] missing: proc_open" \
  || fail "the oddly-named pool was not individually recognized and refused (merged into [global] or [www]?): $out"
echo "$out" | grep -qF "pool [www] missing" \
  && fail "the protected [www] pool was incorrectly named in the refusal too: $out"
echo "ok: fpm -- a pool whose own name contains 'NOTICE: [global]' is still recognized as its own distinct, unprotected pool"

# Allowlist: fpm_get_status is registered only by the fpm-fcgi SAPI, so no CLI-binary
# probe can see it; it is verified by whether the pool's resolved value names it, not
# treated as "not found, so already gone".
# it, not silently treated as "not found, so already gone".
out=$(docker run --rm --read-only -m 512m -e PHP_DISABLE_FUNCTIONS=fpm_get_status,proc_open "$IMAGE" php-fpm -tt 2>&1)
echo "$out" | grep -q "test is successful" \
  || fail "allowlist: PHP_DISABLE_FUNCTIONS=fpm_get_status,proc_open (stock www.conf, whose value covers both) was wrongly refused: $out"
echo "ok: fpm -- allowlist -- fpm_get_status alongside an ordinary function verifies fine when the pool's value actually covers it"

# negative control: the same allowlisted name, but a pool whose own value
# does not mention it -- must be refused, not silently passed.
al_conf="/tmp/ep-allow-www-$$.conf"
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
[ "$rc" -ne 0 ] || fail "allowlist negative control: fpm_get_status requested but not covered by the pool's own value started instead of refusing: $out"
echo "$out" | grep -qF "missing: fpm_get_status" \
  || fail "allowlist negative control: refusal did not name fpm_get_status as missing: $out"
echo "ok: fpm -- allowlist negative control -- fpm_get_status is verified by containment, not silently passed just because no CLI-binary probe can see it"

# The main-ini half of a per-pool probe's value must not be turned into something the
# script cannot safely re-parse by an operator's mounted conf.d. A quoted value with
# an embedded ';' is legal ini: php-fpm keeps the literal token "proc_open;x" and
# disables nothing, but the script's `-d disable_functions=` probe treats an unquoted
# ';' as a comment start, would see only "proc_open", and would certify the pool's own
# coverage ("exec") although the worker's real main-ini value never disabled
# proc_open.
confd2_confd="/tmp/ep-f2-confd-$$"
mkdir -p "$confd2_confd"
cat >"$confd2_confd/50-x.ini" <<'CONF'
disable_functions = "proc_open;x"
CONF
confd2_conf="/tmp/ep-f2-www-$$.conf"
cat >"$confd2_conf" <<'CONF'
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
  -v "$confd2_confd/50-x.ini":/usr/local/etc/php/conf.d/50-x.ini:ro \
  -v "$confd2_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -rf "$confd2_confd" "$confd2_conf"
[ "$rc" -ne 0 ] || fail "a mounted main-ini disable_functions=\"proc_open;x\" alongside a pool covering only 'exec' started instead of refusing: $out"
echo "$out" | grep -q "missing: proc_open" \
  || fail "refusal for the semi-main.ini fixture did not name proc_open as missing: $out"
echo "ok: fpm -- a mounted main-ini disable_functions value containing ';' does not let a pool's own coverage alone pass verification"

# The other vector: conf.d is writable (99-env.ini carries the correct union), but an
# operator-mounted ini sorting after it (zz- > 99-) clobbers disable_functions. The
# verification probe shares that resolved environment, so it must see the clobbered
# value the real worker will and refuse, not trust the union the script just wrote.
confd2w_confd="/tmp/ep-f2w-confd-$$"
mkdir -p "$confd2w_confd"
chmod 777 "$confd2w_confd"
docker run --rm -v "$confd2w_confd":/out "$IMAGE" sh -c 'cp /usr/local/etc/php/conf.d/*.ini /out/ 2>/dev/null' >/dev/null
rm -f "$confd2w_confd/99-env.ini" "$confd2w_confd/90-opcache-env.ini"
cat >"$confd2w_confd/zz-custom.ini" <<'CONF'
disable_functions = get_current_user
CONF
confd2w_conf="/tmp/ep-f2w-www-$$.conf"
cat >"$confd2w_conf" <<'CONF'
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
  -v "$confd2w_confd":/usr/local/etc/php/conf.d \
  -v "$confd2w_conf":/usr/local/etc/php-fpm.d/www.conf:ro \
  -e PHP_DISABLE_FUNCTIONS=proc_open "$IMAGE" php-fpm -tt 2>&1)
rc=$?
set -e
rm -rf "$confd2w_confd" "$confd2w_conf"
[ "$rc" -ne 0 ] || fail "a writable-conf.d operator ini sorting after 99-env.ini (zz-custom.ini clobbering disable_functions) started instead of refusing: $out"
echo "$out" | grep -q "missing: proc_open" \
  || fail "refusal for the writable-conf.d zz-custom.ini fixture did not name proc_open as missing: $out"
echo "ok: fpm -- an operator ini sorting after 99-env.ini on a writable conf.d is still caught by the same resolved-environment probe"
fi
echo "ENTRYPOINT TESTS PASSED"
