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
# WHAT IS TRAINED, AND WHY IT IS DERIVED
#
# /corpus/MANIFEST is written by corpus/verify.sh at corpus build time and
# lists, per app, the docroot and exactly the paths that answered 200 with the
# expected body. tests/test-corpus-tiers.sh then replays that manifest on every
# matrix.json version the tier serves, so "these paths serve on this PHP" is an
# already-tested property of the corpus rather than a claim this script makes.
# Reading MANIFEST is therefore the whole request list: no hardcoded paths, and
# a corpus that grows an app trains it without an edit here.
#
# The byte floor and the expected substring per path come from the app's own
# corpus-src/<app>/endpoints file -- the same source verify.sh used -- so the
# training run asserts what the corpus asserts rather than a weaker version of
# it.
#
# NOTHING HERE IS ALLOWED TO FAIL QUIETLY
#
# Every request must answer 200, clear the byte floor and carry the expected
# substring, or the build fails. A profile trained on framework error pages is
# worse than no profile, because the binary still ships and still looks
# optimised: the hot paths it inlines and lays out are the exception paths.
# The corpus measured this failing on 5 of 11 versions before task 16 fixed the
# tiering, and every one of those runs would have been silently green under a
# `|| true`.
#
# The framework *console* commands the first draft of this script ran
# (artisan route:list, bin/console cache:warmup) are deliberately not here.
# The corpus's tested contract is the manifest: the console commands are only
# ever run on the tier's floor version, during the corpus build, so requiring
# them on every version in the tier would be asserting a property nothing has
# ever checked -- and under this file's no-fallback rule, a Laravel 6 console
# command that trips on PHP 8.0 would fail the build for a reason that has
# nothing to do with the compiler. php/pgo/cli-workload.php covers the CLI SAPI
# instead: it is ours, it is version-portable, and its absence is fatal.
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

# How many times each path is requested after its first, fully asserted one.
# The profile only needs the shape of the workload, not a benchmark's worth of
# it -- but one request per path leaves opcache's first-compile path weighted
# as heavily as the steady state every deployment actually runs in.
ITERATIONS="${PGO_TRAIN_ITERATIONS:-30}"
# Where the shipped opcache settings come from, so training runs the engine in
# the configuration the image ships rather than a second copy of it that drifts.
OPCACHE_INI="${PGO_OPCACHE_INI:-/build/conf/opcache.ini}"
# Optional key=value record for php/build.sh to fold into the image's build
# record. Written, never read back, so an empty value simply skips it.
SUMMARY="${PGO_TRAIN_SUMMARY:-}"

fail() { echo "FATAL[train]: $*" >&2; exit 1; }

# The negative control path, kept identical to corpus/verify.sh's default so
# that a corpus which somehow starts answering 200 to everything fails in
# both places. An app's endpoints file can override it with its own
# negative-control line (see corpus/prestashop/endpoints and verify.sh's
# comment on this same default, task 29e) when the shared path cannot fail
# for that app.
CONTROL_PATH="/corpus-negative-control-4f21a9"

[ -x "$PHP_BIN" ] || fail "$PHP_BIN is not an executable"
[ -f "${CORPUS}/MANIFEST" ] || fail "no ${CORPUS}/MANIFEST -- the corpus image was not mounted"
[ -d "$CORPUS_SRC" ] || fail "no $CORPUS_SRC -- the corpus source tree was not mounted"

# The binary has to actually carry instrumentation, or every request below runs
# for nothing and the merge downstream fails with a message about the merge
# rather than about this. __llvm_prf_cnts is an allocated section that clang's
# -fprofile-generate always emits and nothing else does. gcc's equivalent
# runtime symbol is __gcov_init (libgcov's constructor, present in every
# object -fprofile-generate touches); nm rather than readelf -S because gcc's
# counters live in ordinary .data/.bss, not a distinctively-named section.
COMPILER="${COMPILER:-clang}"
if [ "$COMPILER" = gcc ]; then
  syms="$(nm "$PHP_BIN" 2>/dev/null)" || fail "nm could not read $PHP_BIN"
  grep -q '__gcov_init' <<<"$syms" \
    || fail "$PHP_BIN has no __gcov_init symbol -- it was not built with -fprofile-generate, so training it collects nothing"
  # Positive control: an empty or unparsed symbol table would make the grep
  # above pass by absence on any binary.
  grep -qE '[[:space:]]main$' <<<"$syms" \
    || fail "nm found no main() symbol in $PHP_BIN -- the instrumentation check above measured nothing"
else
  sections="$(readelf -S "$PHP_BIN")"
  grep -q '__llvm_prf_cnts' <<<"$sections" \
    || fail "$PHP_BIN has no __llvm_prf_cnts section -- it was not built with -fprofile-generate, so training it collects nothing"
  # Positive control for that grep: if the section listing were empty or
  # unreadable the check above would pass by absence on any binary.
  grep -q '\.text' <<<"$sections" \
    || fail "readelf printed no .text section for $PHP_BIN -- the instrumentation check above measured nothing"
fi
echo "ok: $PHP_BIN is instrumented ($COMPILER)"

# The build tree the binary came from: sapi/cli/php -> ../../ . php-src builds
# opcache as a shared module (modules/opcache.so) on every branch except 8.5,
# which compiles it in -- derived from the file existing rather than from a
# version test, and the assertion right after covers both.
BUILD_ROOT="$(cd "$(dirname "$PHP_BIN")/../.." && pwd)"
[ -f "${BUILD_ROOT}/main/php_version.h" ] \
  || fail "$BUILD_ROOT does not look like a php-src build tree (no main/php_version.h)"

php_args=()
if [ -f "${BUILD_ROOT}/modules/opcache.so" ]; then
  php_args+=(-d "zend_extension=${BUILD_ROOT}/modules/opcache.so")
fi

# conf/opcache.ini is what the runtime image installs. Replay it here so the
# profile is taken with the JIT, the interned-string buffer and the accelerated
# file count the deployments actually run -- enable_cli flipped on, because the
# built-in server is a CLI SAPI and the shipped value (0) would leave opcache
# inert for the whole training run.
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

# ... and prove it took. Without this the whole run could be profiling a PHP
# with no opcode cache at all, which is not the engine any of these images run.
loaded="$("$PHP_BIN" "${php_args[@]}" -r 'echo extension_loaded("Zend OPcache") ? ini_get("opcache.enable_cli") : "no";' 2>/dev/null || true)"
[ "$loaded" = "1" ] || fail "opcache is not active for the training binary (got '$loaded') -- the profile would describe an engine this image never runs"
echo "ok: opcache active for training (${#php_args[@]} ini overrides from $OPCACHE_INI)"

mkdir -p "$PROFDIR"
# profraw_count() is a "how much new profile activity happened" proxy, and the
# two compilers need different proxies for it. clang's -fprofile-generate
# writes one new, distinctly-pid-named .profraw file per process, so a plain
# file count strictly increases with every process that ran. gcc's
# -fprofile-generate=DIR instead writes one .gcda per compiled object, fixed
# by name, rewritten (not appended) in place -- but every process built from
# the same instrumented binary flushes counters for every translation unit
# linked into it at exit (the cli SAPI and the built-in HTTP server below are
# both sapi/cli/php, so this covers both), which bumps essentially every
# .gcda's mtime on every single run. The newest mtime across the tree is
# therefore a monotonically-increasing proxy with the same "-gt" shape as
# clang's file count, without changing any of the before/after call sites
# below.
# find -printf prints nothing when there is no match yet (before the first
# process has exited); every caller treats that as "count so far", so it has
# to be a comparable integer, not an empty string.
profraw_count() { local n; n="$(
  if [ "$COMPILER" = gcc ]; then
    find "$PROFDIR" -name '*.gcda' -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1
  else
    find "$PROFDIR" -maxdepth 1 -name '*.profraw' | wc -l
  fi
)"; printf '%s' "${n:-0}"; }

# -fprofile-generate=DIR makes DIR the default drop for any instrumented binary
# run with no LLVM_PROFILE_FILE set, and php-src's own `make` runs the php it
# has just built -- 16 such files on an 8.5 build, measured. They are real
# profile data, but they describe php running build scripts, not php serving
# requests, and merging them would weight the compiler and the phar packer
# alongside the workload this file spent 300 requests establishing. Cleared, so
# what gets merged is exactly what was trained and asserted below.
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
# FPM and CLI do not share a request lifecycle, and the binary this repo ships
# is used for composer, artisan and cron as often as it is used behind a pool.
# The workload is ours and committed, so it cannot silently not-exist the way
# the brief's ${CORPUS}/bench/bench.php did.
CLI_WORKLOAD="${HERE}/cli-workload.php"
[ -f "$CLI_WORKLOAD" ] || fail "no $CLI_WORKLOAD -- the CLI half of the profile has nothing to run"

before="$(profraw_count)"
# %p AND %m. Both the php binary and modules/opcache.so are compiled with
# -fprofile-generate, so each carries its own copy of the profiling runtime and
# each writes at exit. With %p alone they resolve to the same filename inside
# one process and the second writer overwrites the first -- silently losing
# either the engine's profile or opcache's. %m is the per-binary signature the
# runtime uses to keep them apart (and to merge into an existing file rather
# than truncate it).
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

  # Floors and expected substrings, keyed by path, out of the app's own
  # endpoints file. Parallel arrays rather than an associative array so this
  # keeps working under the same shell corpus/verify.sh already runs in.
  # db_spec picks up the "database" line the same way corpus/verify.sh does --
  # "mysql:<host>:<port>:<dbname>" for the one app (prestashop, task 29a) whose
  # database is not a sqlite file. Every other app (laravel, wordpress,
  # symfony) also has a "database" line, but it names a bundled sqlite file
  # (verify.sh's own default case), not a server to start -- PHP's sqlite
  # PDO driver opens that file directly with nothing else running, so those
  # rows fall into the no-op branch below alongside a genuinely empty spec.
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

  # mysql: apps need a running server before anything is requested (task 29b).
  # db-up.sh/db-down.sh are the same scripts Dockerfile.corpus and
  # tests/test-corpus*.sh already use -- mariadb-server itself is php/build.sh's
  # job to install (this stage only), not this script's. The trap is set the
  # moment the database is up and cleared only after the normal db-down.sh
  # call below, so any fail() during this app's block -- including one caused
  # by the database never having come up -- still stops mariadbd via the EXIT
  # trap `fail`'s own `exit 1` runs, rather than leaking it into the next
  # app's port or the merge step. T17-L negative control: with db-up.sh
  # skipped, prestashop's Db layer cannot reach a database, every controller
  # 500s, and the very first `hit()` call below fails loudly on a non-200
  # status -- proven by hand against a real corpus (see task-29b-report.md).
  db_up=no
  case "$db_spec" in
    mysql:*)
      "${CORPUS_SRC}/${app}/db-up.sh" "${CORPUS}/${app}"
      db_up=yes
      # shellcheck disable=SC2064  # app/CORPUS_SRC must expand now, not at trap time
      trap "\"${CORPUS_SRC}/${app}/db-down.sh\" 2>/dev/null || true" EXIT
      # Same runtime-host hook as corpus/verify.sh (task 29e): whatever port
      # this app is about to be served on below, not a fixed one -- see
      # corpus/prestashop/set-host.sh for why this exists at all.
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

  # -L: PrestaShop 302s once to reorder its own canonical query-string form
  # (?controller=x&id_y=n -> ?id_y=n&controller=x) even with rewriting off --
  # harmless for the other three apps, none of which redirect. Same reason
  # corpus/verify.sh follows redirects everywhere, not only for prestashop.
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
    # connect at all, and a bare assignment would then trip errexit and kill
    # the build with no message. The status is asserted on the next line either
    # way, so nothing is being forgiven here.
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

  # The positive control for every 200 above: a front controller that answers
  # 200 to everything would satisfy all of them and prove nothing about what
  # was actually executed. WordPress answers 301 here rather than 404 -- any
  # non-200 passes.
  if ! code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}${control_path}")"; then
    code=000
  fi
  [ "$code" != 200 ] || { kill "$server" 2>/dev/null || true; fail "$app answered 200 for ${control_path}, which does not exist -- its other 200s mean nothing"; }
  echo "  $app ${control_path} -> $code (negative control)"

  # SIGINT, not SIGTERM. Measured on this repo's own 7.0 and 8.5 images: the
  # built-in server installs a SIGINT handler and exits 0 through the normal
  # path, while SIGTERM kills it (exit 143) -- and a killed process runs no
  # atexit handler, which is exactly where the profiling runtime writes its
  # .profraw. Under SIGTERM every HTTP request above would contribute nothing.
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
    # The filename prefix each workload's .profraw files carry. php/build.sh
    # merges one intermediate profile per label and balances them against each
    # other -- see the merge in that file for why an unbalanced merge is wrong.
    printf 'labels=cli %s\n' "$app_names"
  } > "$SUMMARY"
fi
