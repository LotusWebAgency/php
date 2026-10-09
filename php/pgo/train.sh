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
# Source of the shipped opcache settings, so training uses the image's own
# configuration rather than a copy that drifts.
OPCACHE_INI="${PGO_OPCACHE_INI:-/build/conf/opcache.ini}"
# Optional key=value record for php/build.sh to fold into the image's build record.
SUMMARY="${PGO_TRAIN_SUMMARY:-}"

fail() { echo "FATAL[train]: $*" >&2; exit 1; }

# Negative control path, identical to corpus/verify.sh's default so a corpus that
# answers 200 to everything fails in both places. An app's endpoints file can
# override it with a negative-control line (see corpus/prestashop/endpoints) when
# the shared path cannot fail for that app.
CONTROL_PATH="/corpus-negative-control-4f21a9"

[ -x "$PHP_BIN" ] || fail "$PHP_BIN is not an executable"
[ -f "${CORPUS}/MANIFEST" ] || fail "no ${CORPUS}/MANIFEST -- the corpus image was not mounted"
[ -d "$CORPUS_SRC" ] || fail "no $CORPUS_SRC -- the corpus source tree was not mounted"

# The binary must carry instrumentation, or every request below runs for nothing
# and the merge downstream fails with a misleading message. clang's
# -fprofile-generate always emits the __llvm_prf_cnts section. gcc's equivalent is
# the __gcov_init symbol (libgcov's constructor); nm rather than readelf -S
# because gcc's counters live in ordinary .data/.bss.
COMPILER="${COMPILER:-clang}"
if [ "$COMPILER" = gcc ]; then
  syms="$(nm "$PHP_BIN" 2>/dev/null)" || fail "nm could not read $PHP_BIN"
  grep -q '__gcov_init' <<<"$syms" \
    || fail "$PHP_BIN has no __gcov_init symbol -- it was not built with -fprofile-generate, so training it collects nothing"
  # Positive control: an empty symbol table would pass the check above by absence.
  grep -qE '[[:space:]]main$' <<<"$syms" \
    || fail "nm found no main() symbol in $PHP_BIN -- the instrumentation check above measured nothing"
else
  sections="$(readelf -S "$PHP_BIN")"
  grep -q '__llvm_prf_cnts' <<<"$sections" \
    || fail "$PHP_BIN has no __llvm_prf_cnts section -- it was not built with -fprofile-generate, so training it collects nothing"
  # Positive control: an empty section listing would pass the check above by absence.
  grep -q '\.text' <<<"$sections" \
    || fail "readelf printed no .text section for $PHP_BIN -- the instrumentation check above measured nothing"
fi
echo "ok: $PHP_BIN is instrumented ($COMPILER)"

# The build tree the binary came from: sapi/cli/php -> ../../ . php-src builds
# opcache as a shared module (modules/opcache.so) on every branch except 8.5,
# which compiles it in, so the file's existence decides rather than a version test.
BUILD_ROOT="$(cd "$(dirname "$PHP_BIN")/../.." && pwd)"
[ -f "${BUILD_ROOT}/main/php_version.h" ] \
  || fail "$BUILD_ROOT does not look like a php-src build tree (no main/php_version.h)"

php_args=()
if [ -f "${BUILD_ROOT}/modules/opcache.so" ]; then
  php_args+=(-d "zend_extension=${BUILD_ROOT}/modules/opcache.so")
fi

# Replay conf/opcache.ini so the profile is taken with the JIT, interned-string
# buffer and accelerated file count deployments run. enable_cli is forced on: the
# built-in server is a CLI SAPI and the shipped value (0) would leave opcache inert.
[ -f "$OPCACHE_INI" ] || fail "no $OPCACHE_INI -- cannot train with the opcache settings the image ships"
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
echo "ok: opcache active for training (${#php_args[@]} ini overrides from $OPCACHE_INI)"

mkdir -p "$PROFDIR"
# profraw_count() is a proxy for "new profile activity happened". clang writes one
# new pid-named .profraw per process, so the file count strictly increases. gcc
# rewrites one fixed-name .gcda per object in place, but every process flushes
# counters for every linked translation unit at exit, so the newest .gcda mtime
# increases instead. Both give callers a comparable integer; find -printf prints
# nothing before the first process exits, hence the ${n:-0}.
profraw_count() { local n; n="$(
  if [ "$COMPILER" = gcc ]; then
    find "$PROFDIR" -name '*.gcda' -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1
  else
    find "$PROFDIR" -maxdepth 1 -name '*.profraw' | wc -l
  fi
)"; printf '%s' "${n:-0}"; }

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

# --- HTTP, one app at a time ------------------------------------------------
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
  # installing mariadb-server is php/build.sh's job. The EXIT trap is set as soon
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
      # Same runtime-host hook as corpus/verify.sh: points the app at the port it
      # is about to be served on (see corpus/prestashop/set-host.sh).
      [ -x "${CORPUS_SRC}/${app}/set-host.sh" ] \
        && "${CORPUS_SRC}/${app}/set-host.sh" "${CORPUS}/${app}" "127.0.0.1:${port}"
      ;;
    *) : ;; # empty, or a bundled sqlite file path -- nothing to start
  esac

  before="$(profraw_count)"
  log="/tmp/train-${app}.log"
  export LLVM_PROFILE_FILE="${PROFDIR}/${app}-%p-%m.profraw"
  # WordPress pins WP_HOME to this host:port (corpus/wordpress/wp-config.php);
  # anything else and every request is a canonical redirect, not a page.
  export CORPUS_WP_HOST="127.0.0.1:${port}"
  # Same bounds as corpus/verify.sh: a runaway request fails instead of
  # spinning, and a runaway log kills the server instead of filling the disk.
  ( ulimit -f 102400; cd "${CORPUS}/${app}" && exec "$PHP_BIN" "${php_args[@]}" -d max_execution_time=300 -S "127.0.0.1:${port}" -t "$docroot" ) >"$log" 2>&1 &
  server=$!

  # -L: PrestaShop 302s once to reorder its canonical query string
  # (?controller=x&id_y=n -> ?id_y=n&controller=x) even with rewriting off; the
  # other apps do not redirect. corpus/verify.sh follows redirects everywhere too.
  first="${paths%%,*}"
  up=no
  for _ in $(seq 1 80); do
    if curl -fsSL -o /dev/null "http://127.0.0.1:${port}${first}" 2>/dev/null; then up=yes; break; fi
    kill -0 "$server" 2>/dev/null || break
    sleep 0.25
  done
  [ "$up" = yes ] || { tail -20 "$log" >&2; kill "$server" 2>/dev/null || true; fail "$app never answered on ${first}"; }

  hit() {  # hit <path> <assert-body: yes|no> <floor> <expect>
    local path="$1" assert_body="$2" floor="${3:-}" expect="${4:-}" code bytes
    # An explicit 000 rather than `|| true`: curl exits non-zero when it cannot
    # connect, and a bare assignment would trip errexit with no message. The status
    # is still asserted below.
    if ! code="$(curl -sL -o /tmp/train-body -w '%{http_code}' "http://127.0.0.1:${port}${path}")"; then
      code=000
    fi
    if [ "$code" != 200 ]; then
      tail -20 "$log" >&2
      kill "$server" 2>/dev/null || true
      fail "$app $path answered $code, not 200 -- training on this would profile the error path"
    fi
    if [ "$assert_body" = yes ]; then
      bytes="$(wc -c < /tmp/train-body)"
      [ "$bytes" -ge "$floor" ] || { kill "$server" 2>/dev/null || true; fail "$app $path answered 200 with $bytes bytes, floor is $floor"; }
      body_has /tmp/train-body "$expect" \
        || { kill "$server" 2>/dev/null || true; fail "$app $path answered 200 without '$expect' in the body -- a 200 error page trains the wrong code"; }
      echo "  $app $path -> 200 ($bytes bytes, contains '$expect')"
    fi
    requests=$((requests + 1))
  }

  echo "--- $app $version ($docroot)"
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
    [ "$idx" -ge 0 ] || { kill "$server" 2>/dev/null || true; fail "$app: MANIFEST lists $path but $spec does not declare it"; }
    hit "$path" yes "${spec_floors[$idx]}" "${spec_expects[$idx]}"
    for _ in $(seq 1 "$ITERATIONS"); do hit "$path" no; done
  done

  # Negative control for every 200 above: a front controller that answers 200 to
  # everything would satisfy them all. WordPress answers 301 here rather than 404;
  # any non-200 passes.
  if ! code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}${control_path}")"; then
    code=000
  fi
  [ "$code" != 200 ] || { kill "$server" 2>/dev/null || true; fail "$app answered 200 for ${control_path}, which does not exist -- its other 200s mean nothing"; }
  echo "  $app ${control_path} -> $code (negative control)"

  # SIGINT, not SIGTERM: the built-in server handles SIGINT and exits 0 through
  # the normal path, while SIGTERM kills it (143) before the atexit handler where
  # the profiling runtime writes its .profraw.
  kill -INT "$server" 2>/dev/null || true
  if wait "$server"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 0 ] || { tail -20 "$log" >&2; fail "$app's server exited $rc rather than shutting down cleanly -- its profile counters were never flushed"; }

  now="$(profraw_count)"
  [ "$now" -gt "$before" ] \
    || fail "$app produced no new profile data despite answering every request -- the counters were not written"
  if [ "$COMPILER" = gcc ]; then
    echo "ok: $app updated the gcov counters (newest .gcda mtime advanced)"
  else
    echo "ok: $app contributed $(( now - before )) profile file(s)"
  fi

  if [ "$db_up" = yes ]; then
    "${CORPUS_SRC}/${app}/db-down.sh"
    trap - EXIT
  fi

  apps="${apps:+${apps} }${app}=${version}"
  app_names="${app_names:+${app_names} }${app}"
  port=$((port + 1))
done < "${CORPUS}/MANIFEST"

[ -n "$apps" ] || fail "${CORPUS}/MANIFEST listed no apps"

total="$(profraw_count)"
[ "$total" -gt 0 ] || fail "training produced no profile data"
if [ "$COMPILER" = gcc ]; then
  file_total="$(find "$PROFDIR" -name '*.gcda' | wc -l)"
  echo "collected $file_total .gcda file(s) (accumulated across every workload) from $requests http requests over: $apps"
  total="$file_total"
else
  echo "collected $total profile files from $requests http requests over: $apps"
  find "$PROFDIR" -maxdepth 1 -name '*.profraw' -printf '%f\n' | sed 's/-[0-9][0-9]*_[0-9a-f]*\.profraw$//' | sort | uniq -c
fi

if [ -n "$SUMMARY" ]; then
  {
    printf 'requests=%s\n' "$requests"
    printf 'profraw_files=%s\n' "$total"
    printf 'iterations_per_path=%s\n' "$ITERATIONS"
    printf 'apps=%s\n' "$apps"
    # Filename prefix of each workload's .profraw files; php/build.sh merges one
    # intermediate profile per label and balances them against each other.
    printf 'labels=cli %s\n' "$app_names"
  } > "$SUMMARY"
fi
