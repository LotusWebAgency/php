#!/usr/bin/env bash
# Compare php configurations (JIT on/off, opcache sizes, any env-driven ini) on
# real applications behind nginx + php-fpm, using the tests/apps stacks.
#
#   tests/bench-apps.sh --quick
#   tests/bench-apps.sh
#   tests/bench-apps.sh --app wordpress --php 8.5 \
#       --mode 'small:PHP_OPCACHE_MEMORY=128M' --mode 'large:PHP_OPCACHE_MEMORY=256M'
#   tests/bench-apps.sh --php 8.5 --image 8.5=lwa-php-local:8.5-fpm
#
# Options:
#   --app A[:SET]    wordpress, laravel, prestashop (repeatable; default all). Without
#                    :SET the newest fixture set that runs on the PHP version is used.
#   --php V          PHP version (repeatable; default 8.5 and 8.4; --quick: 8.5)
#   --mode N:K=V ... a mode is a name and the env vars it sets on the php container
#                    (repeatable, at least two; the first is the baseline). Default
#                    jit-off:PHP_OPCACHE_JIT=disable and jit-tracing:PHP_OPCACHE_JIT=tracing.
#                    Several vars: --mode 'name:PHP_OPCACHE_JIT=tracing PHP_OPCACHE_JIT_BUFFER=128M'
#   --image V=REF    the image for PHP version V (default lotuswebagency/php:V-fpm,
#                    used as found locally, pulled when absent); recorded by digest
#   --pull           pull the default images again before the run
#   --quick          2 reps x 3 s, one PHP version: a smoke run that shows large effects only
#   --reps N         repetitions per mode (default 3; --quick 2)
#   --duration S     seconds per URL per repetition (default 5; --quick 3)
#   --warmup S       seconds per URL after every mode switch, not measured (default 3; --quick 2)
#   --out DIR        results directory (default tests/bench/runs/<run id>, gitignored)
#
# Environment:
#   BENCH_CPUSET_PHP / _WRK / _SVC   cpusets of php, wrk and db/redis/memcached/nginx;
#                    default is derived from nproc (php 8 CPUs, wrk 2, services 2, the rest
#                    left free as the interference gauge)
#   BENCH_WORKERS    static php-fpm children (default: CPUs in the php cpuset)
#   BENCH_PHP_MEM    php container memory limit (default 6g; opcache sizing follows it)
#   BENCH_GATE_MAX / BENCH_GATE_WAIT   whole-host busy % allowed before a block (default 10)
#                    and the most seconds to wait for it (default 10); a busy host is
#                    flagged in the results, never waited out
#   BENCH_GIT_SHA / BENCH_GIT_DIRTY   recorded in the manifest when the tree is not a git
#                    checkout (a copy rsynced to another host)
#   BENCH_FIXTURE_REPO   registry repository the fixtures are pulled from when they are
#                    not local (default ghcr.io/lotuswebagency/php/apptest)
#
# Per app x PHP version one stack comes up once. Per mode switch only the php container is
# recreated (nginx reloaded), the opcache/JIT state is probed to prove the mode applied
# (a block where it did not is failed), every URL is warmed, then measured with wrk. Modes
# alternate (A B, then B A, ...) so drift cancels in the paired per-repetition deltas.
# Results: manifest.json, results.json, results.csv, summary.md and the raw wrk output.
# Run it on an otherwise idle machine (under `heavy` where that exists).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/apps/lib.sh
. "$HERE/apps/lib.sh"
BENCH="$HERE/bench"
APPS_PY=(python3 -I "$BENCH/apps.py")

WRK_IMAGE="${BENCH_WRK_IMAGE:-williamyeh/wrk@sha256:78adc0d9d51a99e6759e702a08d03eaece81c890ffcc9790ef9e5b199d54f091}"
WRK_THREADS=2
WRK_CONNS=16
GATE_MAX="${BENCH_GATE_MAX:-10}"
GATE_WAIT="${BENCH_GATE_WAIT:-10}"
BENCH_FIXTURE_REPO="${BENCH_FIXTURE_REPO:-ghcr.io/lotuswebagency/php/apptest}"

APP_ARGS=() PHPS=() MODE_NAMES=() MODE_ENVS=()
declare -A IMAGES=()
QUICK=0 PULL=0 CUSTOM=0 REPS="" DURATION="" WARMUP="" OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) APP_ARGS+=("${2:?}"); shift 2 ;;
    --php) PHPS+=("${2:?}"); shift 2 ;;
    --mode)
      [[ "${2:?}" == *:* ]] || apptest_die "--mode wants name:VAR=value [VAR=value ...], got '$2'"
      [[ "${2%%:*}" =~ ^[A-Za-z0-9._-]+$ ]] || apptest_die "mode name '${2%%:*}' is not [A-Za-z0-9._-]+"
      MODE_NAMES+=("${2%%:*}"); MODE_ENVS+=("${2#*:}"); shift 2 ;;
    --image)
      [[ "${2:?}" == *=* ]] || apptest_die "--image wants VERSION=REF, got '$2'"
      IMAGES["${2%%=*}"]="${2#*=}"; shift 2 ;;
    --pull) PULL=1; shift ;;
    --quick) QUICK=1; shift ;;
    --reps) REPS="${2:?}"; CUSTOM=1; shift 2 ;;
    --duration) DURATION="${2:?}"; CUSTOM=1; shift 2 ;;
    --warmup) WARMUP="${2:?}"; CUSTOM=1; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,47p' "$0"; exit 0 ;;
    *) apptest_die "unknown argument $1 (tests/bench-apps.sh --help)" ;;
  esac
done

PRESET=default
if [ "$QUICK" -eq 1 ]; then
  PRESET=quick
  : "${REPS:=2}" "${DURATION:=3}" "${WARMUP:=2}"
  [ "${#PHPS[@]}" -gt 0 ] || PHPS=(8.5)
else
  : "${REPS:=3}" "${DURATION:=5}" "${WARMUP:=3}"
  [ "${#PHPS[@]}" -gt 0 ] || PHPS=(8.5 8.4)
fi
[ "$CUSTOM" -eq 0 ] || PRESET="$PRESET+custom"
[ "${#APP_ARGS[@]}" -gt 0 ] || APP_ARGS=(wordpress laravel prestashop)
if [ "${#MODE_NAMES[@]}" -eq 0 ]; then
  MODE_NAMES=(jit-off jit-tracing)
  MODE_ENVS=("PHP_OPCACHE_JIT=disable" "PHP_OPCACHE_JIT=tracing")
fi
[ "${#MODE_NAMES[@]}" -ge 2 ] || apptest_die "need at least two modes to compare"
[ "$(printf '%s\n' "${MODE_NAMES[@]}" | sort -u | wc -l)" -eq "${#MODE_NAMES[@]}" ] || apptest_die "duplicate mode name"
for m in "${MODE_ENVS[@]}"; do
  read -ra kvs <<<"$m"
  for kv in "${kvs[@]}"; do [[ "$kv" =~ ^[A-Z_][A-Z0-9_]*=.*$ ]] || apptest_die "mode setting '$kv' is not VAR=value"; done
done
modes_json="$(for i in "${!MODE_NAMES[@]}"; do printf '%s\0%s\0' "${MODE_NAMES[$i]}" "${MODE_ENVS[$i]}"; done | "${APPS_PY[@]}" modes)" \
  || apptest_die "a mode sets a PHP_OPCACHE_* variable the image does not read"
for n in "$REPS" "$DURATION" "$WARMUP"; do [[ "$n" =~ ^[1-9][0-9]*$ ]] || apptest_die "reps, duration and warmup are positive integers"; done
for app in "${APP_ARGS[@]}"; do
  [[ " ${APPTEST_APPS[*]} " == *" ${app%%:*} "* ]] || apptest_die "app '${app%%:*}' is not in tests/apps/sets (${APPTEST_APPS[*]})"
  case "${app%%:*}" in wordpress|laravel|prestashop) ;; *) apptest_die "no benchmark URLs for ${app%%:*}" ;; esac
done

# CPU layout: php workers, wrk and the services each get their own CPUs; whatever is
# left is the free set whose load shows interference from outside the benchmark.
cpus_expand() { local part; for part in ${1//,/ }; do if [[ "$part" == *-* ]]; then seq "${part%-*}" "${part#*-}"; else echo "$part"; fi; done; }
cpus_range() { if [ "$2" -gt 1 ]; then echo "$1-$(($1 + $2 - 1))"; else echo "$1"; fi; }
NPROC="$(nproc)"
if [ -z "${BENCH_CPUSET_PHP:-}${BENCH_CPUSET_WRK:-}${BENCH_CPUSET_SVC:-}" ]; then
  W=8; [ "$NPROC" -ge 14 ] || W=$((NPROC - 6))
  [ "$W" -ge 2 ] || apptest_die "$NPROC CPUs is too few to derive cpusets; set BENCH_CPUSET_PHP, BENCH_CPUSET_WRK and BENCH_CPUSET_SVC"
  FREE=$((NPROC - W - 4))
  BENCH_CPUSET_PHP="$(cpus_range "$FREE" "$W")"
  BENCH_CPUSET_WRK="$(cpus_range $((FREE + W)) 2)"
  BENCH_CPUSET_SVC="$(cpus_range $((FREE + W + 2)) 2)"
fi
: "${BENCH_CPUSET_PHP:?set all three BENCH_CPUSET_* or none}" "${BENCH_CPUSET_WRK:?}" "${BENCH_CPUSET_SVC:?}"
USED="$(cpus_expand "$BENCH_CPUSET_PHP,$BENCH_CPUSET_WRK,$BENCH_CPUSET_SVC" | sort -n)"
[ "$(wc -l <<<"$USED")" -eq "$(sort -nu <<<"$USED" | wc -l)" ] || apptest_die "the three cpusets overlap"
FREE_CPUS="$(comm -23 <(seq 0 $((NPROC - 1)) | sort) <(sort <<<"$USED") | sort -n | paste -sd, -)"
WORKERS="${BENCH_WORKERS:-$(cpus_expand "$BENCH_CPUSET_PHP" | wc -l)}"
export BENCH_CPUSET_PHP BENCH_CPUSET_WRK BENCH_CPUSET_SVC BENCH_PHP_MEM="${BENCH_PHP_MEM:-6g}"

# Host busy %, from /proc/stat: snap <file> now, busy_of <file> [csv of cpus] since then.
snap() { grep '^cpu[0-9]' /proc/stat >"$1"; }
busy_of() {
  grep '^cpu[0-9]' /proc/stat | paste -d' ' "$1" - | awk -v want="${2:-}" '
    BEGIN { n = split(want, w, ","); for (i = 1; i <= n; i++) sel[w[i]] = 1 }
    { cpu = substr($1, 4) + 0; if (want != "" && !(cpu in sel)) next
      for (i = 2; i <= 9; i++) { t1 += $i; t2 += $(11 + i) }
      di += ($16 + $17) - ($5 + $6) }
    END { dt = t2 - t1; printf "%.1f\n", (dt > 0 ? 100 * (1 - di / dt) : 0) }'
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/php-bench-XXXXXX")"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN="${OUT:-$BENCH/runs/$RUN_ID}"
mkdir -p "$RUN"
RUN="$(cd "$RUN" && pwd)"
WRK_NAME="php-bench-wrk-$$"
PROJECT=""
FAILED=0

compose() { docker compose -f "$APPTEST_ROOT/compose.yml" -f "$BENCH/apps-override.yml" "$@"; }
teardown() {
  docker rm -f "$WRK_NAME" >/dev/null 2>&1 || true
  if [ -n "$PROJECT" ]; then
    docker compose -p "$PROJECT" down -v >/dev/null 2>&1 || true
    docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" | xargs -r docker rm -f >/dev/null 2>&1 || true
    PROJECT=""
  fi
}
cleanup() { teardown; rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

urls_of() {  # urls_of <app> -> "label<TAB>path[<TAB>header]" lines
  case "$1" in
    wordpress) printf '%s\t%s\n' front / listing /category/guides/ api '/wp-json/wp/v2/posts?per_page=10' ;;
    laravel) printf '%s\t%s\n' front / post /posts/p1-backup-network api '/api/posts?per_page=10&page=3' ;;
    prestashop)
      # prestashop/fixture/lib.php's WS_KEY
      printf '%s\t%s\n' front / product /45-sturdy-walnut-kettle-26.html
      printf 'api\t/api/products?display=full&limit=20&output_format=JSON\tAuthorization: Basic %s\n' "$(printf 'APPTESTWSKEYAPPTESTWSKEY12345678:' | base64 -w0)" ;;
  esac
}

image_ref() {  # image_ref <ver> -> prints the ref to run (by digest when the image has one)
  local ref="${IMAGES[$1]:-lotuswebagency/php:$1-fpm}" digest
  if ! docker image inspect "$ref" >/dev/null 2>&1 || { [ "$PULL" -eq 1 ] && [ -z "${IMAGES[$1]:-}" ]; }; then
    apptest_retry registry docker pull -q "$ref" >/dev/null || apptest_die "cannot pull $ref"
  fi
  digest="$(docker image inspect --format '{{index (split (join .RepoDigests ",") ",") 0}}' "$ref" 2>/dev/null || true)"
  [[ "$digest" == *@sha256:* ]] && echo "$digest" || echo "$ref"
}

ensure_fixture() {  # ensure_fixture <app> <set> -> FIXTURE, current for this tree's recipe or fails
  local want repo
  want="$(apptest_recipe_hash "$1" "$2")"
  for repo in "${APPTEST_FIXTURE_REPO}" "$BENCH_FIXTURE_REPO"; do
    APPTEST_FIXTURE_REPO="$repo"
    FIXTURE="$(apptest_fixture_tag "$1" "$2")"
    apptest_fixture_current "$FIXTURE" "$want" && return 0
    apptest_fixture_try_pull "$1" "$2" >&2 || true
    apptest_fixture_current "$FIXTURE" "$want" && return 0
  done
  return 1
}

wait_ready() {  # wait_ready <addr> -> 0 once anything but a gateway error answers
  local code _
  for _ in $(seq 1 400); do
    code="$(curl -s -o /dev/null -m 30 -w '%{http_code}' -H "Host: $APPTEST_HOST" "http://$1/" || true)"
    case "$code" in 000|502|503|504) sleep 0.25 ;; *) return 0 ;; esac
  done
  return 1
}

check_urls() {  # one request per URL before the first block: exactly 200 (wrk counts 3xx as good) and the app's caches warmed once
  local l label path hdr code bad=0
  for l in "${URLS[@]}"; do
    IFS=$'\t' read -r label path hdr <<<"$l"
    code="$(curl -s -o /dev/null -m 180 -w '%{http_code}' -H "Host: $APPTEST_HOST" ${hdr:+-H "$hdr"} "http://$ADDR$path" || true)"
    echo "  url check $label $path: $code"
    [ "$code" = 200 ] || { echo "  FAIL: $path answered $code, not 200"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

wrk() {  # wrk <seconds> <path> <outfile> [header]
  docker exec "$WRK_NAME" wrk -t"$WRK_THREADS" -c"$WRK_CONNS" -d"${1}s" --latency \
    -H "Host: $APPTEST_HOST" ${4:+-H "$4"} "http://web$2" >"$3" 2>&1 || true
  grep -q '^Requests/sec' "$3" || { BLOCK_DETAIL="wrk produced no result for $2: $(tail -1 "$3")"; return 1; }
  ! grep -q 'Non-2xx' "$3" || { BLOCK_DETAIL="non-2xx answers on $2"; return 1; }
}

RSS_SCRIPT='for d in /proc/[0-9]*; do
  c=$(tr "\0" " " < "$d/cmdline" 2>/dev/null) || continue
  case "$c" in *"pool www"*) ;; *) continue ;; esac
  [ "${d#/proc/}" != "$$" ] || continue
  echo "${d#/proc/} $(awk "/^VmRSS/{print \$2}" "$d/status") $(awk "/^Pss:/{print \$2}" "$d/smaps_rollup")"
done'

write_mode_env() {  # write_mode_env <app> <mode env> <out>: the app's php.env, the pool, then the mode; last assignment wins
  {
    [ ! -f "$APPTEST_ROOT/$1/php.env" ] || cat "$APPTEST_ROOT/$1/php.env"
    echo "PHP_FPM_PM=static"
    echo "PHP_FPM_MAX_CHILDREN=$WORKERS"
    read -ra kvs <<<"$2"
    [ "${#kvs[@]}" -eq 0 ] || printf '%s\n' "${kvs[@]}"
  } | awk -F= '{ if ($0 == "") next; if (!($1 in at)) { at[$1] = ++n; key[n] = $1 } line[$1] = $0 } END { for (i = 1; i <= n; i++) print line[key[i]] }' >"$3"
}

BLOCK_DETAIL=""
block_body() {  # block_body <dir> <mode index> -> 0, or 1 with BLOCK_DETAIL
  local d="$1" mi="$2" l label path hdr free
  write_mode_env "$APP" "${MODE_ENVS[$mi]}" "$d/php.env"
  export APPTEST_PHP_ENV="$d/php.env"
  compose --profile web up -d --no-deps --force-recreate php >"$d/up.log" 2>&1 || { BLOCK_DETAIL="php did not start (see $d/up.log)"; return 1; }
  docker exec "$PROJECT-web-1" nginx -s reload >>"$d/up.log" 2>&1 || { BLOCK_DETAIL="nginx reload failed"; return 1; }
  wait_ready "$ADDR" || { BLOCK_DETAIL="nothing answered after the php recreate"; return 1; }
  if [ "$PROBE_INSTALLED" -eq 0 ]; then
    docker exec -i "$PROJECT-php-1" sh -c "cat > $DOCROOT/jitprobe.php" <"$BENCH/jitprobe.php" || { BLOCK_DETAIL="cannot install the probe"; return 1; }
    PROBE_INSTALLED=1
  fi
  probe "$d/probe-pre.json"
  "${APPS_PY[@]}" verify "$d/probe-pre.json" "$d/php.env" "$VER" "${MODE_ENVS[$mi]}" >"$d/verify.txt" 2>&1 \
    || { BLOCK_DETAIL="mode did not apply: $(tr '\n' ';' <"$d/verify.txt")"; return 1; }
  for l in "${URLS[@]}"; do
    IFS=$'\t' read -r label path hdr <<<"$l"
    wrk "$WARMUP" "$path" "$d/warm-$label.txt" "${hdr:-}" || return 1
  done
  for l in "${URLS[@]}"; do
    IFS=$'\t' read -r label path hdr <<<"$l"
    snap "$TMP/b"
    wrk "$DURATION" "$path" "$d/wrk-$label.txt" "${hdr:-}" || return 1
    free="$(busy_of "$TMP/b" "$FREE_CPUS")"
    echo "free_busy=$free" >"$d/busy-$label.txt"
  done
  probe "$d/probe-post.json"
  docker exec "$PROJECT-php-1" sh -c "$RSS_SCRIPT" >"$d/rss.txt" 2>&1 || true
  docker logs "$PROJECT-php-1" >"$d/php.log" 2>&1 || true
  if grep -aqE 'exited on signal|SIGSEGV|SIGBUS|SIGILL|SIGABRT|Segmentation fault|zend_mm_heap corrupted|PHP Fatal error|PHP Parse error' "$d/php.log"; then
    BLOCK_DETAIL="php log has crash or fatal markers (see $d/php.log)"; return 1
  fi
  return 0
}

probe() { curl -s -m 20 -H "Host: $APPTEST_HOST" "http://$ADDR/jitprobe.php" >"$1" || echo '{}' >"$1"; }

run_block() {  # run_block <rep> <mode index> <position>
  local rep="$1" mi="$2" pos="$3" mode d t0=$SECONDS status=ok gate_busy gate_t0=$SECONDS gate_state=ok
  mode="${MODE_NAMES[$mi]}"
  d="$SDIR/rep$rep-$mode"
  mkdir -p "$d"
  while :; do
    snap "$TMP/g"; sleep 1
    gate_busy="$(busy_of "$TMP/g")"
    awk -v b="$gate_busy" -v m="$GATE_MAX" 'BEGIN { exit !(b < m) }' && break
    if [ $((SECONDS - gate_t0)) -ge "$GATE_WAIT" ]; then gate_state=busy; break; fi
  done
  BLOCK_DETAIL=""
  block_body "$d" "$mi" || { status=FAIL; FAILED=1; }
  printf 'mode=%s\nrep=%s\npos=%s\nstatus=%s\ndetail=%s\ngate_busy=%s\ngate_state=%s\nseconds=%s\n' \
    "$mode" "$rep" "$pos" "$status" "$BLOCK_DETAIL" "$gate_busy" "$gate_state" "$((SECONDS - t0))" >"$d/meta.txt"
  local rps note=""
  [ "$gate_state" = ok ] || note=" HOST BUSY"
  rps="$(grep -h '^Requests/sec' "$d"/wrk-*.txt 2>/dev/null | awk '{printf "%s ", $2}' || true)"
  echo "  rep$rep $mode: $status, host ${gate_busy}%$note | ${rps:-}$BLOCK_DETAIL ($((SECONDS - t0)) s)"
}

run_stack() {  # run_stack <app> <set> <ver>
  local app="$1" set="$2" ver="$3" t0=$SECONDS ids rep mi pos run_ref php_real
  APP="$app" VER="$ver"
  run_ref="$(image_ref "$ver")"
  php_real="$(apptest_image_php "$run_ref")"
  [ "$php_real" = "$ver" ] || apptest_die "$run_ref is php $php_real, not $ver"
  ids="$(apptest_image_ids "$run_ref")"
  ensure_fixture "$app" "$set" || apptest_die "no current fixture for $app $set (pull or build it: tests/apps/run.sh $run_ref --app $app)"
  SDIR="$RUN/$app-$set-php$ver"
  mkdir -p "$SDIR"
  export APPTEST_ROOT APPTEST_HOST PHP_IMAGE="$run_ref" APPTEST_PHP="$ver" APPTEST_FLAVOR=fpm APPTEST_STOCK=0
  export APP_UID="${ids%%:*}" APP_GID="${ids##*:}" APPTEST_RETRY
  export APPTEST_SP_SRC="$APPTEST_ROOT" APPTEST_SP_DST=/apptest-sp-rules-unused
  export APPTEST_APP="$app" APPTEST_SET="$set" APPTEST_FIXTURE="$FIXTURE" APPTEST_CONFIG=default
  PROJECT="apptest-bench-${app}-${set//./_}-php${ver//./_}-$$"
  export APPTEST_PROJECT="$PROJECT"
  export APPTEST_PHP_ENV="$SDIR/php-init.env"
  write_mode_env "$app" "" "$APPTEST_PHP_ENV"
  case "$app" in laravel) DOCROOT=/srv/app/public ;; *) DOCROOT=/srv/app ;; esac
  mapfile -t URLS < <(urls_of "$app")
  PROBE_INSTALLED=0
  echo "== $app $set php $ver  $run_ref  fixture $FIXTURE"

  compose up -d --wait db redis memcached >"$SDIR/up.log" 2>&1 \
    && compose --profile seed run --rm app >>"$SDIR/up.log" 2>&1 \
    && compose --profile web up -d --no-deps php web >>"$SDIR/up.log" 2>&1 \
    && docker run -d --init --label claude.adhoc=1 --name "$WRK_NAME" --pull never --network "${PROJECT}_internal" \
         --cpuset-cpus "$BENCH_CPUSET_WRK" --entrypoint tail "$WRK_IMAGE" -f /dev/null >>"$SDIR/up.log" 2>&1 \
    || { echo "  stack did not come up (see $SDIR/up.log)"; FAILED=1; teardown; return; }
  ADDR="$(docker port "$PROJECT-web-1" 80 | head -1)"
  wait_ready "$ADDR" || { echo "  nothing answers on $ADDR"; FAILED=1; teardown; return; }
  check_urls || { FAILED=1; teardown; return; }

  "${APPS_PY[@]}" json "$SDIR/stack.json" app="$app" set="$set" php="$ver" \
    image.ref="$run_ref" image.digest="$([[ "$run_ref" == *@* ]] && echo "${run_ref#*@}" || docker image inspect --format '{{.Id}}' "$run_ref")" \
    image.inputs_hash="$(apptest_label "$run_ref" com.lotuswebagency.inputs-hash)" \
    fixture.ref="$FIXTURE" fixture.digest="$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' "$FIXTURE")" \
    fixture.recipe_hash="$(apptest_label "$FIXTURE" com.lotuswebagency.apptest-hash)" \
    "urls:=$(printf '%s\n' "${URLS[@]}" | cut -f1,2 | python3 -c 'import json,sys; print(json.dumps([l.rstrip("\n").split("\t") for l in sys.stdin]))')"
  echo "  up in $((SECONDS - t0)) s"

  for rep in $(seq 1 "$REPS"); do
    for pos in $(seq 1 "${#MODE_NAMES[@]}"); do
      if [ $((rep % 2)) -eq 1 ]; then mi=$((pos - 1)); else mi=$((${#MODE_NAMES[@]} - pos)); fi
      run_block "$rep" "$mi" "$pos"
    done
  done
  teardown
  echo "  stack done in $((SECONDS - t0)) s"
}

# ---------------------------------------------------------------- manifest
apptest_ensure_image "$WRK_IMAGE"
apptest_ensure_service_images
cpu_model="$(awk -F': *' '/^model name/{print $2; exit}' /proc/cpuinfo)"
governor="$(sort -u /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | paste -sd, - || true)"
snap "$TMP/h"; sleep 2
git_sha="${BENCH_GIT_SHA:-$(git -C "$APPTEST_REPO" rev-parse HEAD 2>/dev/null || echo unknown)}"
git_dirty="${BENCH_GIT_DIRTY:-false}"
[ -n "${BENCH_GIT_DIRTY:-}" ] || [ -z "$(git -C "$APPTEST_REPO" status --porcelain 2>/dev/null)" ] || git_dirty=true
"${APPS_PY[@]}" json "$RUN/manifest.json" run_id="$RUN_ID" preset="$PRESET" "reps:=$REPS" "duration_s:=$DURATION" "warmup_s:=$WARMUP" \
  "workers:=$WORKERS" "modes:=$modes_json" \
  git.sha="$git_sha" "git.dirty:=$git_dirty" \
  host.cpu_model="$cpu_model" host.governor="$governor" "host.nproc:=$NPROC" host.kernel="$(uname -r)" \
  host.docker="$(docker version --format '{{.Server.Version}}')" "host.busy_start_pct:=$(busy_of "$TMP/h")" \
  "host.loadavg=$(cut -d' ' -f1-3 /proc/loadavg)" \
  cpusets.php="$BENCH_CPUSET_PHP" cpusets.wrk="$BENCH_CPUSET_WRK" cpusets.svc="$BENCH_CPUSET_SVC" cpusets.free="$FREE_CPUS" \
  php_mem="$BENCH_PHP_MEM" wrk.image="$WRK_IMAGE" "wrk.threads:=$WRK_THREADS" "wrk.connections:=$WRK_CONNS" \
  "gate.max_busy_pct:=$GATE_MAX" "gate.max_wait_s:=$GATE_WAIT" \
  "apps:=$(printf '%s\n' "${APP_ARGS[@]}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().split()))')" \
  "php_versions:=$(printf '%s\n' "${PHPS[@]}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().split()))')"
echo "=== run $RUN_ID: $PRESET, ${#PHPS[@]} php x ${#APP_ARGS[@]} app x ${#MODE_NAMES[@]} modes x $REPS reps, ${DURATION}s per URL, ${WARMUP}s warmup; php cpus $BENCH_CPUSET_PHP ($WORKERS workers), wrk $BENCH_CPUSET_WRK, services $BENCH_CPUSET_SVC, free $FREE_CPUS"
echo "    results $RUN"

for ver in "${PHPS[@]}"; do
  for app_arg in "${APP_ARGS[@]}"; do
    app="${app_arg%%:*}"
    if [[ "$app_arg" == *:* ]]; then
      set="${app_arg#*:}"
    else
      set="$(apptest_cells --php "$ver" --flavor fpm --variant baseline --app "$app" | tail -1 | cut -f2)"
      [ -n "$set" ] || apptest_die "tests/apps/sets has no $app set for php $ver"
    fi
    run_stack "$app" "$set" "$ver"
  done
done

"${APPS_PY[@]}" json "$RUN/manifest.json" "wall_s:=$SECONDS"
echo "=== wall time $SECONDS s"
"${APPS_PY[@]}" report "$RUN" || FAILED=1
[ "$FAILED" -eq 0 ] || { echo "FAIL: at least one stack or block failed (see above and $RUN)"; exit 1; }
