#!/usr/bin/env bash
# Run the PGO training workload against a freshly built, instrumented PHP.
#
#   train.sh <php-binary> <corpus-root> <corpus-src-root> <profraw-dir>
#
# Called from php/build.sh between pass 1 (-fprofile-generate) and pass 2
# (-fprofile-use). The binary is the one in the build tree, not an installed
# one, because the profile has to describe the code that is about to be
# recompiled.
#
# What is trained: /corpus/MANIFEST, written by corpus/verify.sh at corpus build
# time, lists per app the docroot and exactly the paths that answered 200 with the
# expected body; tests/test-corpus-tiers.sh replays it on every matrix.json
# version the tier serves. It is the whole request list, so a corpus that grows an
# app trains it without an edit here. The byte floor and expected substring per
# path come from the app's corpus-src/<app>/endpoints file, the same source
# verify.sh used.
#
# The apps are served by the instrumented sapi/fpm/php-fpm, not by `php -S`: what
# the images run is the FastCGI parser, the request loop and the process manager,
# and those are what the profile has to describe. One pool per app (a static pool
# of PGO_FPM_WORKERS workers on a unix socket) is fed through php-fcgi, the
# FastCGI client the images ship for their healthcheck.
#
# The profiling runtimes write a process's counters at exit() (an atexit handler
# for clang, a destructor for gcc), so every worker has to leave through exit().
# SIGQUIT alone does not get there: the master forwards it to the workers and arms
# a process_control_timeout timer, and when that timer fires it sends SIGTERM, then
# SIGKILL (fpm_pctl_action_next in sapi/fpm/fpm/fpm_process_ctl.c). The default
# timeout is 0, so SIGTERM follows at once, and a worker's SIGTERM is SIG_DFL
# (fpm_signals_init_child), which kills it before its counters are written. Each
# pool therefore sets process_control_timeout, and its log is at debug level,
# because fpm logs a child's exit during shutdown at debug only
# (fpm_children_bury); fpm_stop requires every worker to have exited with code 0.
#
# How far that flush got is checked per pool on the profile itself: the clang
# profile's fcgi_accept_request (a worker-only function) must have run once per
# request, and the run count gcc keeps in fpm_main.gcda must have grown by one per
# worker plus the master.
#
# Nothing here may fail quietly: every request must answer 200, clear the byte
# floor and carry the expected substring, or the build fails. A profile trained on
# framework error pages is worse than none, because the binary still ships and
# the hot paths it lays out are the exception paths.
#
# Framework console commands (artisan, bin/console) are deliberately not run:
# they are exercised only on the tier's floor version during the corpus build, so
# requiring them on every version in the tier would assert an untested property.
# php/pgo/cli-workload.php covers the CLI SAPI instead; it is version-portable
# and its absence is fatal.
#
# Environment: PHP_VERSION (picks the shipped opcache.ini), COMPILER (gcc|clang),
# PGO_FCGI_CLIENT, PGO_FPM_WORKERS, PGO_TRAIN_ITERATIONS, PGO_TRAIN_SUMMARY.
set -euo pipefail

# An expected substring may list alternatives separated by '|' (see
# corpus/prestashop/endpoints) -- the body has to carry at least one.
body_has() {  # body_has <file> <expect>
  local alts=() args=() a
  IFS='|' read -ra alts <<<"$2"
  for a in "${alts[@]}"; do args+=(-e "$a"); done
  grep -qF "${args[@]}" -- "$1"
}

PHP_BIN="${1:?usage: train.sh <php-binary> <corpus-root> <corpus-src-root> <profraw-dir>}"
CORPUS="${2:?usage: train.sh <php-binary> <corpus-root> <corpus-src-root> <profraw-dir>}"
CORPUS_SRC="${3:?usage: train.sh <php-binary> <corpus-root> <corpus-src-root> <profraw-dir>}"
PROFDIR="${4:?usage: train.sh <php-binary> <corpus-root> <corpus-src-root> <profraw-dir>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Requests per path after its first, fully asserted one. The profile needs the
# shape of the workload, but a single request would weight opcache's first-compile
# path as heavily as the steady state deployments run in.
ITERATIONS="${PGO_TRAIN_ITERATIONS:-30}"
# conf/opcache.ini as the repo has it. What the image ships is that file after
# php/pgo/shipped-opcache-ini.sh (the per-version adjustment), and that is what is
# trained under; see below.
OPCACHE_SRC="${PGO_OPCACHE_INI:-/build/conf/opcache.ini}"
# Workers in each app's pool. Static, so every worker exists before the first
# request and every one of them is stopped, and flushes its profile, at the end.
FPM_WORKERS="${PGO_FPM_WORKERS:-4}"
# The FastCGI client; the Dockerfile copies rootfs/usr/local/bin/php-fcgi here.
FCGI_CLIENT="${PGO_FCGI_CLIENT:-/build/bin/php-fcgi}"
# How long a SIGQUIT'd pool's workers get to leave through exit() (the pool's
# process_control_timeout) before the master escalates to SIGTERM. The watchdog
# that declares the master itself stuck waits FPM_STOP_SECONDS + 30.
FPM_STOP_SECONDS="${PGO_FPM_STOP_SECONDS:-120}"
# Optional key=value record for php/build.sh to fold into the image's build record.
SUMMARY="${PGO_TRAIN_SUMMARY:-}"

FPM_PID=""

# Kills a process and its direct children (an fpm master and its workers).
kill_tree() {  # kill_tree <pid>
  local child
  for child in $(child_pids "$1"); do kill -KILL "$child" 2>/dev/null || true; done
  kill -KILL "$1" 2>/dev/null || true
}

# child_pids <pid>: direct children from /proc, because pgrep is not guaranteed.
# /proc/PID/status rather than /proc/PID/stat: a process title with spaces
# ("php-fpm: pool www") shifts stat's fields.
child_pids() {
  local dir
  for dir in /proc/[0-9]*; do
    if [ "$(awk '/^PPid:/ {print $2}' "$dir/status" 2>/dev/null)" = "$1" ]; then
      printf '%s\n' "${dir#/proc/}"
    fi
  done
  return 0
}

fail() {
  echo "FATAL[train]: $*" >&2
  # No pool may outlive a failed training: it would hold the socket and, on a
  # local rerun, a port.
  if [ -n "${FPM_PID:-}" ]; then kill_tree "$FPM_PID"; fi
  exit 1
}

# Negative control path, identical to corpus/verify.sh's default so a corpus that
# answers 200 to everything fails in both places. An app's endpoints file can
# override it with a negative-control line (see corpus/prestashop/endpoints) when
# the shared path cannot fail for that app.
CONTROL_PATH="/corpus-negative-control-4f21a9"

[ -x "$PHP_BIN" ] || fail "$PHP_BIN is not an executable"
[ -f "${CORPUS}/MANIFEST" ] || fail "no ${CORPUS}/MANIFEST -- the corpus image was not mounted"
[ -d "$CORPUS_SRC" ] || fail "no $CORPUS_SRC -- the corpus source tree was not mounted"
[ -f "$FCGI_CLIENT" ] || fail "no $FCGI_CLIENT -- php-fpm cannot be trained without a FastCGI client (the Dockerfile copies rootfs/usr/local/bin/php-fcgi there)"
PHP_VERSION="${PHP_VERSION:?train.sh needs PHP_VERSION to render the opcache.ini the image ships}"

# The build tree the binaries came from: sapi/cli/php -> ../../ . php-src builds
# opcache as a shared module (modules/opcache.so) on every branch except 8.5,
# which compiles it in, so the file's existence decides rather than a version test.
BUILD_ROOT="$(cd "$(dirname "$PHP_BIN")/../.." && pwd)"
[ -f "${BUILD_ROOT}/main/php_version.h" ] \
  || fail "$BUILD_ROOT does not look like a php-src build tree (no main/php_version.h)"
FPM_BIN="${BUILD_ROOT}/sapi/fpm/php-fpm"
[ -x "$FPM_BIN" ] || fail "$FPM_BIN is not an executable -- there is no php-fpm to train"

# Every binary that serves a workload must carry instrumentation, or every
# request below runs for nothing and the merge downstream fails with a misleading
# message. clang's -fprofile-generate always emits the __llvm_prf_cnts section.
# gcc's equivalent is the __gcov_init symbol (libgcov's constructor); nm rather
# than readelf -S because gcc's counters live in ordinary .data/.bss.
COMPILER="${COMPILER:-clang}"
check_instrumented() {  # check_instrumented <binary>
  local bin="$1" syms sections
  if [ "$COMPILER" = gcc ]; then
    syms="$(nm "$bin" 2>/dev/null)" || fail "nm could not read $bin"
    grep -q '__gcov_init' <<<"$syms" \
      || fail "$bin has no __gcov_init symbol -- it was not built with -fprofile-generate, so training it collects nothing"
    # Positive control: an empty symbol table would pass the check above by absence.
    grep -qE '[[:space:]]main$' <<<"$syms" \
      || fail "nm found no main() symbol in $bin -- the instrumentation check above measured nothing"
  else
    sections="$(readelf -S "$bin")"
    grep -q '__llvm_prf_cnts' <<<"$sections" \
      || fail "$bin has no __llvm_prf_cnts section -- it was not built with -fprofile-generate, so training it collects nothing"
    # Positive control: an empty section listing would pass the check above by absence.
    grep -q '\.text' <<<"$sections" \
      || fail "readelf printed no .text section for $bin -- the instrumentation check above measured nothing"
  fi
  echo "ok: $bin is instrumented ($COMPILER)"
}
check_instrumented "$PHP_BIN"
check_instrumented "$FPM_BIN"

SCRATCH="$(mktemp -d)"

php_args=()
if [ -f "${BUILD_ROOT}/modules/opcache.so" ]; then
  php_args+=(-d "zend_extension=${BUILD_ROOT}/modules/opcache.so")
fi

# Train under the ini the image ships, rendered by the script the Dockerfile uses
# for the image's own 15-opcache.ini: the JIT, interned-string buffer (clamped to
# 16 on 7.0-7.2) and accelerated file count deployments run. enable_cli is forced
# on for the CLI workload, which would otherwise leave opcache inert under the
# shipped value (0); php-fpm ignores it.
OPCACHE_INI="${SCRATCH}/opcache.ini"
sh "${HERE}/shipped-opcache-ini.sh" "$PHP_VERSION" "$OPCACHE_SRC" "$OPCACHE_INI" \
  || fail "could not render the opcache.ini this image ships from $OPCACHE_SRC"
while IFS= read -r line; do
  line="${line%%;*}"
  line="$(printf '%s' "$line" | tr -d '[:space:]')"
  case "$line" in
    ''|'['*) continue ;;
  esac
  key="${line%%=*}"; value="${line#*=}"
  [ "$key" != "opcache.enable_cli" ] || value=1
  php_args+=(-d "${key}=${value}")
done < "$OPCACHE_INI"

# Prove it took; otherwise the run could profile a PHP with no opcode cache.
loaded="$("$PHP_BIN" "${php_args[@]}" -r 'echo extension_loaded("Zend OPcache") ? ini_get("opcache.enable_cli") : "no";' 2>/dev/null || true)"
[ "$loaded" = "1" ] || fail "opcache is not active for the training binary (got '$loaded') -- the profile would describe an engine this image never runs"
echo "ok: opcache active for training (${#php_args[@]} ini overrides from the shipped ini, $OPCACHE_SRC for php $PHP_VERSION)"
# php-fpm lists Zend extensions under -m as well; the request-level proof that the
# pool really runs with it enabled is the probe each pool answers below.
"$FPM_BIN" "${php_args[@]}" -m 2>/dev/null | grep -q 'Zend OPcache' \
  || fail "php-fpm does not load Zend OPcache with the training ini -- the fpm profile would describe an engine this image never runs"

mkdir -p "$PROFDIR"
# profraw_count() is a proxy for "new profile activity happened". clang writes one
# new pid-named .profraw per process, so the file count strictly increases. gcc
# rewrites one fixed-name .gcda per object in place, but every process flushes
# counters for every linked translation unit at exit, so the newest .gcda mtime
# increases instead. Both give callers a comparable integer; find -printf prints
# nothing before the first process exits, hence the ${n:-0}.
profraw_count() { local n; n="$(
  if [ "$COMPILER" = gcc ]; then
    # sed reads to the end where head would exit early and SIGPIPE sort, which
    # pipefail turns into a failure.
    find "$PROFDIR" -name '*.gcda' -printf '%T@\n' 2>/dev/null | sort -rn | sed -n '1{s/\..*//;p;}'
  else
    find "$PROFDIR" -maxdepth 1 -name '*.profraw' | wc -l
  fi
)"; printf '%s' "${n:-0}"; }

# fpm_profile_count <app> <marker-file>: profile files php-fpm itself wrote for
# <app>'s pool since the marker was touched.
#   clang: this app's fpm-<app>-*.profraw files (LLVM_PROFILE_FILE names them).
#   gcc:   .gcda files of sapi/fpm's objects newer than the marker. gcc mangles an
#          object's path into the file name with '#' for '/', and nothing outside
#          sapi/fpm has "fpm" in its path; php (the CLI binary) never links
#          sapi/fpm, so these files can only come from a php-fpm process.
fpm_profile_count() {
  if [ "$COMPILER" = gcc ]; then
    find "$PROFDIR" -name '*fpm*.gcda' -newer "$2" | wc -l
  else
    find "$PROFDIR" -maxdepth 1 -name "fpm-${1}-*.profraw" | wc -l
  fi
}

# -fprofile-generate=DIR makes DIR the default drop for any instrumented binary
# run without LLVM_PROFILE_FILE, and php-src's own `make` runs the php it just
# built. That data describes php running build scripts, not serving requests, so it
# is cleared and only what is trained and asserted below gets merged.
stale="$(profraw_count)"
if [ "$stale" -gt 0 ]; then
  if [ "$COMPILER" = gcc ]; then
    n_stale="$(find "$PROFDIR" -name '*.gcda' | wc -l)"
    find "$PROFDIR" -name '*.gcda' -delete
    echo "ok: discarded $n_stale profile file(s) written by the build itself before training started"
  else
    find "$PROFDIR" -maxdepth 1 -name '*.profraw' -delete
    echo "ok: discarded $stale profile file(s) written by the build itself before training started"
  fi
fi

requests=0
apps=""
app_names=""
fpm_labels=""

# --- CLI SAPI ---------------------------------------------------------------
# FPM and CLI do not share a request lifecycle, and the shipped binary runs
# composer, artisan and cron as often as it serves a pool.
CLI_WORKLOAD="${HERE}/cli-workload.php"
[ -f "$CLI_WORKLOAD" ] || fail "no $CLI_WORKLOAD -- the CLI half of the profile has nothing to run"

before="$(profraw_count)"
# %p and %m: both the php binary and modules/opcache.so carry their own copy of
# the profiling runtime and write at exit. With %p alone they resolve to the same
# filename and the second writer overwrites the first; %m is the per-binary
# signature that keeps them apart.
export LLVM_PROFILE_FILE="${PROFDIR}/cli-%p-%m.profraw"
echo "--- cli workload x5"
for i in 1 2 3 4 5; do
  out="$("$PHP_BIN" "${php_args[@]}" "$CLI_WORKLOAD" 2>&1)" \
    || { printf '%s\n' "$out" >&2; fail "cli-workload.php exited non-zero on iteration $i"; }
  grep -q 'CLI-WORKLOAD-OK' <<<"$out" \
    || { printf '%s\n' "$out" >&2; fail "cli-workload.php did not print its completion marker on iteration $i"; }
done
[ "$(profraw_count)" -gt "$before" ] \
  || fail "the cli workload wrote no new profile data"
if [ "$COMPILER" = gcc ]; then
  echo "ok: cli workload updated the gcov counters (newest .gcda mtime advanced)"
else
  echo "ok: cli workload contributed $(( $(profraw_count) - before )) profile file(s)"
fi

# --- php-fpm, one pool per app ----------------------------------------------

# fcgi_request <script-filename> <script-name> <request-uri> <query> <out-file>
# One FastCGI request through php-fcgi to $FPM_SOCK; the raw response (headers,
# blank line, body) goes to <out-file>. php-fcgi is a PHP script, run here by the
# instrumented php with -n. That makes every request spawn a process which would
# write profile data too, and a client's startup and shutdown are not the workload:
# the client's data is sent to a scratch location (a fixed name, so it stays one
# file; GCOV_PREFIX moves gcc's .gcda there) and never reaches $PROFDIR.
fcgi_request() {
  local rc=0
  SCRIPT_FILENAME="$1" SCRIPT_NAME="$2" DOCUMENT_URI="$2" REQUEST_URI="$3" QUERY_STRING="$4" \
  DOCUMENT_ROOT="$FPM_DOCROOT" REQUEST_METHOD=GET REDIRECT_STATUS=200 \
  SERVER_NAME=127.0.0.1 SERVER_ADDR=127.0.0.1 SERVER_PORT="${HOSTPORT##*:}" HTTP_HOST="$HOSTPORT" \
  REMOTE_ADDR=127.0.0.1 REMOTE_PORT=40000 HTTP_USER_AGENT=pgo-train HTTP_ACCEPT='*/*' \
  GCOV_PREFIX="${SCRATCH}/client-gcov" LLVM_PROFILE_FILE="${SCRATCH}/client.profraw" \
    "$PHP_BIN" -n "$FCGI_CLIENT" -t 300 -i "$FPM_SOCK" >"$5" 2>"${SCRATCH}/client.err" || rc=$?
  # Every answered request went through a worker's fcgi_accept_request; the
  # per-pool profile check holds the profile to this count.
  [ "$rc" -ne 0 ] || POOL_REQUESTS=$((POOL_REQUESTS + 1))
  return "$rc"
}

# resolve_script <url-path> -> RESOLVED_SCRIPT, the URL path of the PHP file a web
# server in front of the pool would hand to it: the file itself, a directory's
# index.php, or the docroot's front controller (what `php -S` does too). Anything
# that is not PHP would be served statically and cannot train php-fpm.
resolve_script() {
  local p="$1"
  if [ -f "${FPM_DOCROOT}${p}" ]; then
    RESOLVED_SCRIPT="$p"
  elif [ -d "${FPM_DOCROOT}${p}" ] && [ -f "${FPM_DOCROOT}${p%/}/index.php" ]; then
    RESOLVED_SCRIPT="${p%/}/index.php"
  elif [ -f "${FPM_DOCROOT}/index.php" ]; then
    RESOLVED_SCRIPT="/index.php"
  else
    fail "$app: $p matches no file under ${FPM_DOCROOT} and the docroot has no index.php"
  fi
  case "$RESOLVED_SCRIPT" in
    *.php) ;;
    *) fail "$app: $p resolves to $RESOLVED_SCRIPT, which is not PHP -- a web server would serve it without php-fpm" ;;
  esac
}

show_pool_logs() {
  tail -20 "$FPM_LOG" >&2 2>/dev/null || true
  tail -20 "${FPM_LOG}.out" >&2 2>/dev/null || true
}

# fcgi_get <path> <follow: yes|no>
# Sets FCGI_CODE and leaves the body in ${SCRATCH}/body. With follow=yes redirects
# are followed as curl -L did against the built-in server (PrestaShop 302s once to
# reorder its canonical query string) but only within the corpus host; five hops
# at most.
fcgi_get() {
  local path="$1" follow="$2" hops=0 file query loc
  local raw="${SCRATCH}/raw" hdr="${SCRATCH}/hdr"
  while :; do
    file="${path%%\?*}"; query=""
    case "$path" in *\?*) query="${path#*\?}" ;; esac
    resolve_script "$file"
    fcgi_request "${FPM_DOCROOT}${RESOLVED_SCRIPT}" "$RESOLVED_SCRIPT" "$path" "$query" "$raw" \
      || { cat "${SCRATCH}/client.err" >&2; show_pool_logs; fail "$app $path: php-fcgi could not get a response from the pool"; }
    # Headers end at the first blank line (php-fcgi -i prints them, then the body).
    awk -v h="$hdr" -v b="$SCRATCH/body" 'BEGIN { inh = 1; printf "" > h; printf "" > b }
      inh { if ($0 ~ /^\r?$/) inh = 0; else print > h; next }
      { print > b }' "$raw"
    FCGI_CODE="$(sed -n 's/^[Ss][Tt][Aa][Tt][Uu][Ss]:[[:space:]]*\([0-9][0-9][0-9]\).*/\1/p' "$hdr" | head -1)"
    FCGI_CODE="${FCGI_CODE:-200}"
    case "$FCGI_CODE" in
      301|302|303|307|308)
        [ "$follow" = yes ] || return 0
        loc="$(sed -n 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*//p' "$hdr" | head -1 | tr -d '\r')"
        [ -n "$loc" ] || fail "$app $path answered $FCGI_CODE without a Location header"
        loc="${loc#http://"${HOSTPORT}"}"
        case "$loc" in
          /*) path="$loc" ;;
          *)  fail "$app $path redirects to '$loc', which is not on the corpus host ${HOSTPORT}" ;;
        esac
        hops=$((hops + 1))
        [ "$hops" -le 5 ] || fail "$app $path redirected more than 5 times"
        ;;
      *) return 0 ;;
    esac
  done
}

# fpm_start <app>: write the pool config, start the master in the background, wait
# for the pool to answer its ping and prove opcache is on in a worker.
fpm_start() {
  local app="$1" conf up _
  FPM_SOCK="${SCRATCH}/fpm-${app}.sock"
  FPM_LOG="/tmp/train-fpm-${app}.log"
  conf="${SCRATCH}/fpm-${app}.conf"
  : > "$FPM_LOG"
  # No user/group: the master runs as root in the build and -R permits it, which
  # leaves the workers root too, so they can write the profile directory. clear_env
  # off lets workers see CORPUS_WP_HOST. decorate_workers_output is 7.3+ and would
  # be an unknown directive on 7.0-7.2, so it is left out. process_control_timeout
  # and log_level = debug: see the header (both exist on every version trained).
  cat >"$conf" <<EOF
[global]
pid = ${SCRATCH}/fpm-${app}.pid
error_log = ${FPM_LOG}
log_level = debug
daemonize = no
process_control_timeout = ${FPM_STOP_SECONDS}s

[www]
listen = ${FPM_SOCK}
pm = static
pm.max_children = ${FPM_WORKERS}
pm.max_requests = 0
request_terminate_timeout = 0
ping.path = /fpm-ping
ping.response = pong
catch_workers_output = yes
clear_env = no
EOF
  # Same bounds as corpus/verify.sh: a runaway log kills the pool instead of
  # filling the disk.
  ( ulimit -f 102400
    export LLVM_PROFILE_FILE="${PROFDIR}/fpm-${app}-%p-%m.profraw"
    cd "${CORPUS}/${app}" && exec "$FPM_BIN" -R -F -y "$conf" "${php_args[@]}" -d max_execution_time=300
  ) >"${FPM_LOG}.out" 2>&1 &
  FPM_PID=$!
  POOL_REQUESTS=0

  up=no
  for _ in $(seq 1 120); do
    if [ -S "$FPM_SOCK" ] \
       && fcgi_request /fpm-ping /fpm-ping /fpm-ping "" "${SCRATCH}/ping" 2>/dev/null \
       && grep -q pong "${SCRATCH}/ping"; then
      up=yes; break
    fi
    kill -0 "$FPM_PID" 2>/dev/null || break
    sleep 0.25
  done
  [ "$up" = yes ] || { show_pool_logs; fail "$app: php-fpm never answered its ping"; }

  FPM_CHILDREN="$(child_pids "$FPM_PID" | wc -l)"
  [ "$FPM_CHILDREN" -eq "$FPM_WORKERS" ] \
    || { show_pool_logs; fail "$app: the pool has $FPM_CHILDREN worker(s), expected $FPM_WORKERS"; }

  mkdir -p "${SCRATCH}/probe"
  cat >"${SCRATCH}/probe/opcache-probe.php" <<'EOF'
<?php
$status = function_exists('opcache_get_status') ? opcache_get_status(false) : false;
echo 'opcache=', ($status && !empty($status['opcache_enabled'])) ? '1' : '0', "\n";
EOF
  fcgi_request "${SCRATCH}/probe/opcache-probe.php" /opcache-probe.php /opcache-probe.php "" "${SCRATCH}/probe.out" \
    || { cat "${SCRATCH}/client.err" >&2; show_pool_logs; fail "$app: the opcache probe got no response from the pool"; }
  grep -q 'opcache=1' "${SCRATCH}/probe.out" \
    || { cat "${SCRATCH}/probe.out" >&2; fail "$app: opcache is not enabled in the pool's workers -- the profile would describe an engine this image never runs"; }
  echo "ok: $app pool up (php-fpm master $FPM_PID, $FPM_CHILDREN workers, opcache enabled)"
}

# fpm_stop: graceful shutdown. SIGQUIT makes the master stop accepting and
# forward it to the workers, which finish their request and leave through exit(),
# where the profiling runtime writes; the pool's process_control_timeout keeps the
# master from escalating to SIGTERM meanwhile (see the header). A master that does
# not leave is killed by a watchdog and reported, never waited on forever.
fpm_stop() {
  local pid="$FPM_PID" watchdog rc workers child clean
  workers="$(child_pids "$pid")"
  kill -QUIT "$pid" 2>/dev/null \
    || { show_pool_logs; fail "$app: the php-fpm master is already gone before the graceful stop -- it died while serving"; }
  rm -f "${SCRATCH}/fpm-stop-timeout"
  ( sleep "$((FPM_STOP_SECONDS + 30))"; touch "${SCRATCH}/fpm-stop-timeout"; kill -KILL "$pid" 2>/dev/null || true ) >/dev/null 2>&1 </dev/null &
  watchdog=$!
  if wait "$pid"; then rc=0; else rc=$?; fi
  for child in $(child_pids "$watchdog"); do kill "$child" 2>/dev/null || true; done
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  if [ -e "${SCRATCH}/fpm-stop-timeout" ]; then
    # A master killed from outside leaves its workers behind.
    for child in $workers; do kill -KILL "$child" 2>/dev/null || true; done
    show_pool_logs
    FPM_PID=""
    fail "$app: the php-fpm master did not stop within $((FPM_STOP_SECONDS + 30))s of SIGQUIT -- its workers' counters were never flushed"
  fi
  FPM_PID=""
  if [ "$rc" -ne 0 ]; then
    show_pool_logs
    fail "$app: the php-fpm master exited $rc rather than shutting down cleanly -- its profile counters were never flushed"
  fi
  if grep -qE 'exited on signal|exited with code [1-9]|SIGKILL' "$FPM_LOG"; then
    grep -E 'exited on signal|exited with code [1-9]|SIGKILL' "$FPM_LOG" >&2
    fail "$app: a php-fpm worker did not exit normally -- it never flushed its profile counters"
  fi
  # Positive control for the check above: at debug level every worker's exit is
  # logged, so an empty log, or a log level that hid the exits, cannot pass by
  # absence.
  clean="$(grep -c 'exited with code 0' "$FPM_LOG" || true)"
  [ "$clean" -eq "$FPM_WORKERS" ] \
    || { show_pool_logs; fail "$app: the pool log shows $clean worker(s) exiting with code 0, expected $FPM_WORKERS -- the workers' counters were not all flushed"; }
}

# fpm_pool_flushed <app> <gcc-runs-before>: the profile itself shows every worker's
# counters, not just the master's.
#   clang: the pool's workers merge into the one fpm-<app>-*.profraw (%p is
#          resolved once, in the master, and inherited across fork(); %m makes
#          each writer merge under a lock instead of truncating). fcgi_accept_request
#          runs only in workers, once per accepted request, so its busiest block
#          must have run at least once per answered request.
#   gcc:   libgcov counts in each .gcda's object summary how many processes merged
#          into it. fpm_main.c is linked only into php-fpm, so this pool must have
#          added exactly one run per worker plus the master.
fpm_pool_flushed() {
  local app="$1" runs_before="$2" runs part count
  if [ "$COMPILER" = gcc ]; then
    runs="$(fpm_main_gcda_runs)"
    [ "$((runs - runs_before))" -eq "$((FPM_WORKERS + 1))" ] \
      || fail "$app: fpm_main.gcda gained $((runs - runs_before)) run(s), expected $((FPM_WORKERS + 1)) (master + $FPM_WORKERS workers) -- not every php-fpm process flushed its counters"
    echo "ok: $app: $((runs - runs_before)) php-fpm processes merged into the gcov counters (master + $FPM_WORKERS workers)"
  else
    part="${SCRATCH}/fpm-${app}.profdata"
    llvm-profdata merge -output="$part" "$PROFDIR"/fpm-"${app}"-*.profraw \
      || fail "$app: llvm-profdata could not merge the pool's profile"
    count="$(max_block_count fcgi_accept_request "$part")"
    rm -f "$part"
    [ "$count" -ge "$POOL_REQUESTS" ] \
      || fail "$app: fcgi_accept_request ran at most $count times in the pool's profile for $POOL_REQUESTS answered requests -- the workers' counters were not all flushed"
    echo "ok: $app: fcgi_accept_request ran up to $count times for $POOL_REQUESTS answered requests"
  fi
}

# fpm_main_gcda_runs: the run count in sapi/fpm/fpm/fpm_main.c's .gcda, 0 before
# any php-fpm has exited.
fpm_main_gcda_runs() {
  local f n
  f="$(find "$PROFDIR" -name '*#sapi#fpm#fpm#fpm_main.gcda')"
  [ -n "$f" ] || { echo 0; return 0; }
  [ "$(printf '%s\n' "$f" | wc -l)" -eq 1 ] || fail "more than one fpm_main.gcda under $PROFDIR: $f"
  n="$(gcov-dump "$f" | sed -n 's/.*OBJECT_SUMMARY runs=\([0-9][0-9]*\).*/\1/p')"
  [ -n "$n" ] || fail "gcov-dump printed no OBJECT_SUMMARY run count for $f"
  echo "$n"
}

# max_block_count <function> <profdata>: the largest block counter of the functions
# whose name contains <function>. IR-level profiles carry no "Function count"
# line (llvm-profdata prints it for front-end instrumentation only), so the block
# counters are what says whether, and how often, the function ran.
max_block_count() {
  llvm-profdata show --counts --function="$1" "$2" \
    | awk '/Block counts:/ { gsub(/[][,]/, " "); for (i = 3; i <= NF; i++) if ($i + 0 > max) max = $i + 0 } END { print max + 0 }'
}

# --- HTTP through php-fpm, one app at a time --------------------------------
port=18301
while IFS=$'\t' read -r app docroot version paths; do
  case "$app" in ''|\#*) continue ;; esac
  [ -n "$paths" ] || fail "$app has no paths in ${CORPUS}/MANIFEST"
  [ -d "$docroot" ] || fail "$app: docroot $docroot from MANIFEST does not exist"

  spec="${CORPUS_SRC}/${app}/endpoints"
  [ -f "$spec" ] || fail "$app is in MANIFEST but has no ${spec}"

  # Floors and expected substrings, keyed by path, from the app's endpoints file.
  # Parallel arrays rather than an associative array, to match corpus/verify.sh.
  # db_spec reads the "database" line as verify.sh does: "mysql:<host>:<port>:<dbname>"
  # for PrestaShop, the one app whose database is not a sqlite file. Other apps
  # name a bundled sqlite file, which needs no server and falls into the no-op
  # branch below.
  spec_paths=(); spec_floors=(); spec_expects=(); db_spec=""
  control_path="$CONTROL_PATH"
  # b is the required/optional flag; MANIFEST already contains only paths that
  # served, so there is nothing left for it to decide here.
  # shellcheck disable=SC2034
  while read -r key a b c rest; do
    case "$key" in
      path)     spec_paths+=("$a")
                spec_floors+=("${c:?$spec: path $a has no byte floor}")
                spec_expects+=("${rest:?$spec: path $a has no expected substring}") ;;
      database) db_spec="$a" ;;
      negative-control) control_path="${a:?$spec: negative-control has no path}" ;;
      *)        continue ;;
    esac
  done < "$spec"
  [ "${#spec_paths[@]}" -gt 0 ] || fail "$spec declares no paths"

  # mysql: apps need a running server before anything is requested. db-up.sh and
  # db-down.sh are the scripts Dockerfile.corpus and tests/test-corpus*.sh use;
  # installing mariadb-13.1 is php/build.sh's job. The EXIT trap is set as soon
  # as the database is up and cleared after the normal db-down.sh call, so any
  # fail() during this app's block still stops mariadbd instead of leaking it into
  # the next app's port or the merge step.
  db_up=no
  case "$db_spec" in
    mysql:*)
      "${CORPUS_SRC}/${app}/db-up.sh" "${CORPUS}/${app}"
      db_up=yes
      # shellcheck disable=SC2064  # app/CORPUS_SRC must expand now, not at trap time
      trap "\"${CORPUS_SRC}/${app}/db-down.sh\" 2>/dev/null || true" EXIT
      # Same runtime-host hook as corpus/verify.sh: points the app at the host:port
      # requests carry as their Host header (see corpus/prestashop/set-host.sh).
      [ -x "${CORPUS_SRC}/${app}/set-host.sh" ] \
        && "${CORPUS_SRC}/${app}/set-host.sh" "${CORPUS}/${app}" "127.0.0.1:${port}"
      ;;
    *) : ;; # empty, or a bundled sqlite file path -- nothing to start
  esac

  HOSTPORT="127.0.0.1:${port}"
  FPM_DOCROOT="${docroot%/}"
  # WordPress pins WP_HOME to this host:port (corpus/wordpress/wp-config.php);
  # anything else and every request is a canonical redirect, not a page.
  export CORPUS_WP_HOST="$HOSTPORT"

  before="$(profraw_count)"
  mark="${SCRATCH}/mark-${app}"
  touch "$mark"
  # touch has one-second resolution on some filesystems: wait it out so a file
  # written by this pool is strictly newer than the marker.
  sleep 1.1
  fpm_runs_before=0
  [ "$COMPILER" != gcc ] || fpm_runs_before="$(fpm_main_gcda_runs)"
  fpm_start "$app"

  hit() {  # hit <path> <assert-body: yes|no> <floor> <expect>
    local path="$1" assert_body="$2" floor="${3:-}" expect="${4:-}" bytes
    fcgi_get "$path" yes
    if [ "$FCGI_CODE" != 200 ]; then
      show_pool_logs
      fail "$app $path answered $FCGI_CODE, not 200 -- training on this would profile the error path"
    fi
    if [ "$assert_body" = yes ]; then
      bytes="$(wc -c < "${SCRATCH}/body")"
      [ "$bytes" -ge "$floor" ] || fail "$app $path answered 200 with $bytes bytes, floor is $floor"
      body_has "${SCRATCH}/body" "$expect" \
        || fail "$app $path answered 200 without '$expect' in the body -- a 200 error page trains the wrong code"
      echo "  $app $path -> 200 ($bytes bytes, contains '$expect')"
    fi
    requests=$((requests + 1))
  }

  echo "--- $app $version ($docroot) via php-fpm"
  old_ifs="$IFS"; IFS=','
  # shellcheck disable=SC2206  # MANIFEST's path list is comma-separated on purpose
  path_list=($paths)
  IFS="$old_ifs"
  for path in "${path_list[@]}"; do
    idx=-1; i=0
    for candidate in "${spec_paths[@]}"; do
      [ "$candidate" = "$path" ] && { idx=$i; break; }
      i=$((i + 1))
    done
    [ "$idx" -ge 0 ] || fail "$app: MANIFEST lists $path but $spec does not declare it"
    hit "$path" yes "${spec_floors[$idx]}" "${spec_expects[$idx]}"
    for _ in $(seq 1 "$ITERATIONS"); do hit "$path" no; done
  done

  # Negative control for every 200 above: a front controller that answers 200 to
  # everything would satisfy them all. WordPress answers 301 here rather than 404;
  # any non-200 passes, and redirects are not followed.
  fcgi_get "$control_path" no
  [ "$FCGI_CODE" != 200 ] || fail "$app answered 200 for ${control_path}, which does not exist -- its other 200s mean nothing"
  echo "  $app ${control_path} -> $FCGI_CODE (negative control)"

  fpm_stop
  fpm_pool_flushed "$app" "$fpm_runs_before"

  now="$(profraw_count)"
  [ "$now" -gt "$before" ] \
    || fail "$app produced no new profile data despite answering every request -- the counters were not written"
  fpm_files="$(fpm_profile_count "$app" "$mark")"
  [ "$fpm_files" -gt 0 ] \
    || fail "$app: php-fpm wrote no profile data of its own (no ${COMPILER} profile files from sapi/fpm) -- the pool's workers did not flush their counters"
  if [ "$COMPILER" = gcc ]; then
    echo "ok: $app updated the gcov counters ($fpm_files sapi/fpm .gcda file(s) rewritten by the pool)"
  else
    # Workers merge into the master's file (see fpm_pool_flushed): the count says
    # "something was written", not "one file per worker".
    echo "ok: $app contributed $fpm_files php-fpm profile file(s) ($(( now - before )) new in total)"
  fi

  if [ "$db_up" = yes ]; then
    "${CORPUS_SRC}/${app}/db-down.sh"
    trap - EXIT
  fi

  apps="${apps:+${apps} }${app}=${version}"
  app_names="${app_names:+${app_names} }${app}"
  fpm_labels="${fpm_labels:+${fpm_labels} }fpm-${app}"
  port=$((port + 1))
done < "${CORPUS}/MANIFEST"

[ -n "$apps" ] || fail "${CORPUS}/MANIFEST listed no apps"

total="$(profraw_count)"
[ "$total" -gt 0 ] || fail "training produced no profile data"
if [ "$COMPILER" = gcc ]; then
  file_total="$(find "$PROFDIR" -name '*.gcda' | wc -l)"
  fpm_total="$(find "$PROFDIR" -name '*fpm*.gcda' | wc -l)"
  [ "$fpm_total" -gt 0 ] || fail "no sapi/fpm .gcda file in $PROFDIR after training -- php-fpm contributed nothing to the profile"
  echo "collected $file_total .gcda file(s) ($fpm_total from sapi/fpm; accumulated across every workload) from $requests fastcgi requests over: $apps"
  total="$file_total"
else
  fpm_total="$(find "$PROFDIR" -maxdepth 1 -name 'fpm-*.profraw' | wc -l)"
  [ "$fpm_total" -gt 0 ] || fail "no fpm-*.profraw in $PROFDIR after training -- php-fpm contributed nothing to the profile"
  echo "collected $total profile files ($fpm_total from php-fpm) from $requests fastcgi requests over: $apps"
  find "$PROFDIR" -maxdepth 1 -name '*.profraw' -printf '%f\n' | sed 's/-[0-9][0-9]*_[0-9a-f]*\.profraw$//' | sort | uniq -c
fi

rm -rf "$SCRATCH"

if [ -n "$SUMMARY" ]; then
  {
    printf 'requests=%s\n' "$requests"
    printf 'profraw_files=%s\n' "$total"
    printf 'iterations_per_path=%s\n' "$ITERATIONS"
    printf 'apps=%s\n' "$apps"
    printf 'fpm_workers=%s\n' "$FPM_WORKERS"
    printf 'fpm_profile_files=%s\n' "$fpm_total"
    # Filename prefix of each workload's .profraw files; php/build.sh merges one
    # intermediate profile per label and balances them against each other.
    printf 'labels=cli %s\n' "$fpm_labels"
  } > "$SUMMARY"
fi
