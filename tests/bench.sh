#!/usr/bin/env bash
# Compare our build against the official image on the held-out workload
# (tests/bench/workload.php), with an effective PHP configuration proven
# identical on both sides -- not assumed identical because the flags look
# the same.
#
#   tests/bench.sh <our-image> <official-image|auto> <php-version> [--record]
#   tests/bench.sh <our-image> <official-image|auto> <php-version> --prepare
#
# <official-image> may be the literal string "auto": bench.sh then reads
# matrix.json's pinned release for <php-version>, derives the official flavor
# from <our-image>'s tag suffix (cli-builder has no official equivalent -- it is
# benchmarked against the official -cli image, which is printed loudly) and
# pulls php:<release>-<flavor>. If that tag does not exist on Docker Hub, it
# falls back to the floating php:<major.minor>-<flavor> tag and prints both
# versions in the table header instead of silently comparing against a
# different patch release. The fallback is taken only when the registry says the
# tag does not exist; a registry that stays unreadable through ci/retry.sh's
# attempts fails the run instead of benchmarking a different release.
#
# --prepare is the network half and nothing else: it resolves and pulls the
# official image (both under ci/retry.sh), then exits. A run that follows finds
# the pinned image on the daemon and fetches nothing; without --prepare the
# official image is pulled here only when it is not on the daemon yet.
#
# Identical effective configuration. `-d opcache.enable_cli=1` on the official
# image loads nothing below PHP 8.5 (opcache is a shared zend_extension there,
# not enabled by default), and relying on each image's own baked ini would make
# the "delta" mostly a config difference. So neither image's baked conf.d is
# trusted: every ini value this workload's speed can depend on is passed
# explicitly, identically, to both images (`--entrypoint php`, so neither side's
# own entrypoint script runs). The one thing that legitimately differs is
# whether opcache needs `zend_extension=opcache.so` to load at all -- true for
# every version below 8.5 on an image that hasn't already enabled it in a conf.d
# file -- so each side is probed (does `php -v` already say "with Zend
# OPcache"?) and the flag is added only where it's missing, per side.
#
# CANONICAL_INI below is the single list of ini values passed identically to
# BOTH images, so no knob falls through to each image's own baked ini (which
# differs: opcache.memory_consumption, interned_strings_buffer,
# max_accelerated_files, max_wasted_percentage and realpath_cache_ttl all have
# other defaults on the official image). The values are our own baked
# conf/opcache.ini and conf/php-fpm.ini numbers, because that is the
# configuration the README's claim is about.
#
# workload.php prints a settings fingerprint before any timing runs:
# PHP_VERSION, whether opcache is actually accelerating, jit.on/kind/opt_level,
# the full ini_get_all() dump for opcache and pcre (every jit_*,
# memory/interned/accelerated_files/wasted/validate_timestamps/
# revalidate_freq/optimization_level/file_cache directive included), the core
# directives ini_get_all() can't group by extension (memory_limit,
# zend.assertions, zend.enable_gc, realpath_cache_size/ttl, output_buffering),
# and the sorted union of loaded extensions/zend extensions. bench.sh fetches
# that fingerprint from both images for a mode before trusting any measurement
# from it, and FAILS the whole run if any opcache/pcre/core field differs, or if
# xdebug/pcov/a known profiler is loaded on either side. Comparing the full
# ini_get_all() groups rather than a hand-picked field list catches a knob
# nobody thought to name. The extension *list* itself is printed as a diff, not
# compared -- ours ships more extensions by design.
#
# Three modes, one table each: opcache off; opcache on, JIT off; JIT tracing.
# JIT masks PGO (a hot loop under tracing JIT runs very little interpreter or
# runtime C code), so a single "opcache on, JIT on" number would attribute a JIT
# effect to the build. The README has to say which mode it quotes.
#
# Measurement discipline. Runs are interleaved (ours, theirs, ours, theirs, ...),
# not block-then-block, because best-of-N-then-best-of-N mixes thermal/turbo
# drift and host load into the comparison as much as the build. Both images are
# pinned to the same --cpuset-cpus. The first interleaved pair is a discarded
# warm-up (page cache, copy-on-write faults). RUNS (default 7, override via env)
# timed pairs are then taken; median and the interquartile range are reported
# per image per mode. Timing is measured inside PHP with hrtime(), so container
# startup time is excluded on both sides. The delta is printed from the medians,
# unless the two images' IQRs overlap -- then the sign of the delta isn't
# established and bench.sh prints "inconclusive" instead of a percentage.
#
# No automatic recording. Pass --record to append one TSV row per mode to
# tests/bench/results.tsv (date, host CPU model, git commit, both image digests,
# mode, medians, spread, delta). Without --record nothing is written, so the repo
# does not accumulate un-annotated numbers on every run.
#
# CPUSET defaults to the highest-numbered online CPU, not CPU 0 -- CPU 0 is
# where most kernels route IRQs/timer interrupts by default, which adds
# noise to a benchmark that neither side should have to absorb. Still fully
# overridable via the CPUSET env var.
#
# Escape hatches that exist purely to demonstrate the fingerprint gate does what
# it claims (negative controls, not normal runs): EXTRA_INI_OURS /
# EXTRA_INI_THEIRS, space-separated extra `-d` arguments appended after the
# mode's own flags for that side only; DROP_INI_OURS / DROP_INI_THEIRS,
# space-separated CANONICAL_INI directive names to omit for that side only, for
# showing the gate fails once an explicit override is removed and an image falls
# back to its own baked (or default) value. A real bench run has no reason to
# set any of the four.
set -euo pipefail

OURS="${1:?usage: bench.sh <our-image> <official-image|auto> <php-version> [--record|--prepare]}"
THEIRS_ARG="${2:?usage: bench.sh <our-image> <official-image|auto> <php-version> [--record|--prepare]}"
VERSION="${3:?usage: bench.sh <our-image> <official-image|auto> <php-version> [--record|--prepare]}"
RECORD=0
PREPARE=0
for arg in "${@:4}"; do
  case "$arg" in
    --record) RECORD=1 ;;
    --prepare) PREPARE=1 ;;
    *) echo "FAIL: unrecognized argument '$arg'" >&2; exit 1 ;;
  esac
done
[ "$RECORD$PREPARE" != 11 ] || { echo "FAIL: --record and --prepare are exclusive" >&2; exit 1; }

RUNS="${RUNS:-7}"
ITER="${ITER:-200}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BENCH_DIR="$HERE/bench"

fail() { echo "FAIL: $*" >&2; exit 1; }

default_cpuset() {  # default_cpuset -> highest-numbered online CPU id
  local online part hi last=0
  if [ -r /sys/devices/system/cpu/online ]; then
    online="$(cat /sys/devices/system/cpu/online)"
    IFS=',' read -ra parts <<<"$online"
    for part in "${parts[@]}"; do
      hi="${part##*-}"
      if [[ "$hi" =~ ^[0-9]+$ ]] && [ "$hi" -gt "$last" ]; then
        last="$hi"
      fi
    done
  fi
  echo "$last"
}
CPUSET="${CPUSET:-$(default_cpuset)}"

for tool in docker python3; do
  command -v "$tool" >/dev/null || fail "$tool not found on this host"
done

# ------------------------------------------------------- official image ref
official_flavor_of() {  # official_flavor_of <our-image-ref> -> fpm|cli
  # a -v3 variant compares against the same official flavor as its baseline
  case "${1%-v3}" in
    *-cli-builder|*-ext-builder) echo cli ;;   # no official cli-builder or ext-builder image exists
    *-fpm) echo fpm ;;
    *-cli) echo cli ;;
    *) fail "cannot derive a flavor from '$1' -- expected it to end in -fpm, -cli, -cli-builder or -ext-builder, optionally followed by -v3" ;;
  esac
}

matrix_release() {  # matrix_release <version> -> matrix.json's pinned release
  python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
v = sys.argv[2]
if v not in m["versions"]:
    sys.exit("php %s is not a version in matrix.json" % v)
print(m["versions"][v]["release"])
' "$ROOT/matrix.json" "$1"
}

RETRY="$ROOT/ci/retry.sh"

registry_has() {  # registry_has <ref> -> 0 when the registry has it, 1 when it says it does not
  local err rc=0
  err="$(mktemp)"
  "$RETRY" docker manifest inspect "$1" >/dev/null 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -Eiq 'no such manifest|manifest unknown|not found' "$err"; then
      rm -f "$err"
      return 1
    fi
    cat "$err" >&2
    rm -f "$err"
    fail "cannot tell whether $1 exists: the registry could not be read"
  fi
  rm -f "$err"
}

THEIRS="$THEIRS_ARG"
OFFICIAL_VERSION_NOTE=""
if [ "$THEIRS_ARG" = "auto" ]; then
  off_flavor="$(official_flavor_of "$OURS")"
  if [[ "$OURS" == *-cli-builder ]]; then
    echo "NOTE: $OURS is cli-builder; no official cli-builder image exists, comparing against official -cli instead" >&2
  fi
  release="$(matrix_release "$VERSION")"
  pinned_tag="php:${release}-${off_flavor}"
  # A pinned image already on the daemon (--prepare put it there) settles it
  # without asking the registry.
  if { [ "$PREPARE" -eq 0 ] && docker image inspect "$pinned_tag" >/dev/null 2>&1; } || registry_has "$pinned_tag"; then
    THEIRS="$pinned_tag"
  else
    major_minor="${VERSION}"
    fallback_tag="php:${major_minor}-${off_flavor}"
    echo "NOTE: $pinned_tag does not exist on Docker Hub -- falling back to $fallback_tag (floating patch)" >&2
    THEIRS="$fallback_tag"
    OFFICIAL_VERSION_NOTE=" (requested pinned release $release, using floating $major_minor instead)"
  fi
fi

if [ "$PREPARE" -eq 1 ] || ! docker image inspect "$THEIRS" >/dev/null 2>&1; then
  echo "pulling $THEIRS..." >&2
  "$RETRY" docker pull "$THEIRS" >/dev/null
fi
if [ "$PREPARE" -eq 1 ]; then
  echo "ok: $THEIRS is on the daemon" >&2
  exit 0
fi

# Cross-check even an explicitly-supplied official image against matrix.json's
# pinned release: a caller who hand-resolved the tag can still get it wrong, and
# a patch mismatch quietly mixes upstream changes into the delta.
expected_release="$(matrix_release "$VERSION" 2>/dev/null || true)"
actual_version="$(docker run --rm --entrypoint php "$THEIRS" -r 'echo PHP_VERSION;')"
if [ -n "$expected_release" ] && [ "$actual_version" != "$expected_release" ]; then
  echo "WARNING: matrix.json pins php $VERSION to $expected_release, but $THEIRS reports $actual_version -- the delta below mixes in upstream changes between those releases" >&2
  OFFICIAL_VERSION_NOTE=" (matrix.json pins $expected_release, $THEIRS is $actual_version)"
fi

# digest_of -- a locally built/loaded image that was never pushed still gets
# a RepoDigests entry under the containerd store (byte-identical to
# `docker image inspect --format '{{.Id}}'`), which is formatted exactly like a
# real registry digest but is not one -- `docker manifest inspect` on it fails
# (unauthorized/denied, no such repo). Recording that string unlabeled in
# results.tsv would read as a pull reference a reader could verify against
# Docker Hub when they can't. Only a digest a registry actually answers for
# is recorded bare; everything else is prefixed "local:".
digest_of() {  # digest_of <image> -> "repo@sha256:..." or "local:<image id>"
  local image="$1" repo_digest
  if docker manifest inspect "$image" >/dev/null 2>&1; then
    repo_digest="$(docker image inspect "$image" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}')"
    if [ -n "$repo_digest" ]; then
      echo "$repo_digest"
      return
    fi
  fi
  echo "local:$(docker image inspect "$image" --format '{{.Id}}')"
}

our_digest="$(digest_of "$OURS")"
their_digest="$(digest_of "$THEIRS")"

echo "=== bench.sh: $OURS  vs  $THEIRS$OFFICIAL_VERSION_NOTE ==="
echo "ours digest:    $our_digest"
echo "theirs digest:  $their_digest"
echo "RUNS=$RUNS ITER=$ITER CPUSET=$CPUSET"

# ------------------------------------------------------ opcache zend_extension
# On any version below 8.5, opcache is a loadable zend_extension, off by
# default on the official image (and on ours, for a version whose conf.d
# doesn't already enable it). On 8.5, opcache is compiled into the engine on
# both sides and needs nothing extra.
needs_zend_ext() {  # needs_zend_ext <image> -> yes|no
  local out
  out="$(docker run --rm --entrypoint php "$1" -v 2>&1 || true)"
  if echo "$out" | grep -q "Zend OPcache"; then echo no; else echo yes; fi
}

declare -a OURS_BASE_EXTRA=()
declare -a THEIRS_BASE_EXTRA=()
if [ "$(needs_zend_ext "$OURS")" = yes ]; then
  OURS_BASE_EXTRA+=(-d zend_extension=opcache.so)
  echo "NOTE: $OURS needs an explicit zend_extension=opcache.so to load opcache at all" >&2
fi
if [ "$(needs_zend_ext "$THEIRS")" = yes ]; then
  THEIRS_BASE_EXTRA+=(-d zend_extension=opcache.so)
  echo "NOTE: $THEIRS needs an explicit zend_extension=opcache.so to load opcache at all" >&2
fi
# CANONICAL_INI -- see the header comment. The one list of explicit,
# speed-relevant ini values passed identically to both images in every mode,
# on top of the mode's own opcache.enable/opcache.jit flags below. These are
# our own baked conf/opcache.ini and conf/php-fpm.ini values.
CANONICAL_INI=(
  "opcache.memory_consumption=192"
  "opcache.interned_strings_buffer=32"
  "opcache.max_accelerated_files=20000"
  "opcache.max_wasted_percentage=10"
  "opcache.validate_timestamps=1"
  "opcache.revalidate_freq=2"
  "opcache.save_comments=1"
  "opcache.enable_file_override=0"
  "opcache.huge_code_pages=0"
  "opcache.jit_buffer_size=64M"
  "realpath_cache_size=4096K"
  "realpath_cache_ttl=600"
  "zend.assertions=-1"
  "memory_limit=256M"
)

# canonical_flags_into <dropped-names> <array-name> -- appends CANONICAL_INI
# as "-d key=value" pairs onto the named array, skipping any directive named
# in the space-separated <dropped-names> list. The drop list exists only for
# DROP_INI_OURS/DROP_INI_THEIRS (the negative controls); a real run passes "".
canonical_flags_into() {
  local -n out_ref="$2"
  local dropped=" $1 " kv key
  for kv in "${CANONICAL_INI[@]}"; do
    key="${kv%%=*}"
    [[ "$dropped" == *" $key "* ]] && continue
    out_ref+=(-d "$kv")
  done
}
canonical_flags_into "${DROP_INI_OURS:-}" OURS_BASE_EXTRA
canonical_flags_into "${DROP_INI_THEIRS:-}" THEIRS_BASE_EXTRA

# shellcheck disable=SC2206 # intentional word-splitting of an operator-provided flag list
[ -n "${EXTRA_INI_OURS:-}" ] && OURS_BASE_EXTRA+=($EXTRA_INI_OURS)
# shellcheck disable=SC2206
[ -n "${EXTRA_INI_THEIRS:-}" ] && THEIRS_BASE_EXTRA+=($EXTRA_INI_THEIRS)

MODE_NAMES=(opcache-off opcache-on-jit-off jit-tracing)
MODE_OPCACHE_FLAGS=(
  "-d opcache.enable=0 -d opcache.enable_cli=0 -d opcache.jit=off"
  "-d opcache.enable=1 -d opcache.enable_cli=1 -d opcache.jit=off"
  "-d opcache.enable=1 -d opcache.enable_cli=1 -d opcache.jit=tracing"
)

fingerprint_of() {  # fingerprint_of <image> <flags...> -> fingerprint JSON on stdout
  local image="$1"; shift
  docker run --rm --cpuset-cpus="$CPUSET" -v "$BENCH_DIR:/bench:ro" --entrypoint php "$image" \
    "$@" /bench/workload.php fingerprint
}

time_of() {  # time_of <image> <flags...> -> elapsed seconds
  local image="$1"; shift
  docker run --rm --cpuset-cpus="$CPUSET" -v "$BENCH_DIR:/bench:ro" --entrypoint php "$image" \
    "$@" /bench/workload.php "$ITER"
}

# compare_fingerprints <ours.json> <theirs.json> -> exits 1 with a diff on a
# speed-relevant mismatch or a profiler extension; always prints the
# extension-set diff. Compares the full opcache_ini/pcre_ini/core_ini groups
# key-for-key rather than a hand-picked field list -- a directive nobody
# thought to name explicitly is still caught.
compare_fingerprints() {
  python3 - "$1" "$2" <<'PYEOF'
import json, sys

ours = json.loads(sys.argv[1])
theirs = json.loads(sys.argv[2])

# Directives allowed to differ between images even under an identical
# explicit command line -- e.g. a value that legitimately varies by build
# and has no bearing on speed. Empty: every opcache/pcre/core directive this
# bench either sets explicitly (CANONICAL_INI in this script) or leaves at
# PHP's compiled-in default is expected to match exactly for the same PHP
# version. A real mismatch here means CANONICAL_INI is missing a knob, not
# that the field belongs in this set.
WHITELIST = {"opcache_ini": set(), "pcre_ini": set(), "core_ini": set()}

top_level_fields = ["opcache_enabled", "jit_on", "jit_kind", "jit_opt_level"]
mismatches = [(f, ours.get(f), theirs.get(f)) for f in top_level_fields if ours.get(f) != theirs.get(f)]

for group in ("opcache_ini", "pcre_ini", "core_ini"):
    o = ours.get(group) or {}
    t = theirs.get(group) or {}
    for key in sorted(set(o) | set(t)):
        if key in WHITELIST[group]:
            continue
        if o.get(key) != t.get(key):
            mismatches.append(("%s.%s" % (group, key), o.get(key), t.get(key)))

profilers = ("xdebug", "pcov", "blackfire", "tideways", "uprofiler", "xhprof")
def loaded_profilers(fp):
    return sorted(e for e in fp.get("extensions", []) if e.lower() in profilers)

ours_profilers = loaded_profilers(ours)
theirs_profilers = loaded_profilers(theirs)

ours_ext = set(ours.get("extensions", []))
theirs_ext = set(theirs.get("extensions", []))
only_ours = sorted(ours_ext - theirs_ext)
only_theirs = sorted(theirs_ext - ours_ext)
if only_ours:
    print("  extensions only in ours:   " + ", ".join(only_ours))
if only_theirs:
    print("  extensions only in theirs: " + ", ".join(only_theirs))

if mismatches or ours_profilers or theirs_profilers:
    print("FAIL: settings fingerprint mismatch -- the delta would not be measuring the build")
    for f, ov, tv in mismatches:
        print("  %s: ours=%r theirs=%r" % (f, ov, tv))
    if ours_profilers:
        print("  profiler(s) loaded on OURS: " + ", ".join(ours_profilers))
    if theirs_profilers:
        print("  profiler(s) loaded on THEIRS: " + ", ".join(theirs_profilers))
    sys.exit(1)
PYEOF
}

# stats <space-separated times> -> "median q1 q3 min max" on stdout
stats() {
  python3 - "$1" <<'PYEOF'
import sys
times = sorted(float(x) for x in sys.argv[1].split())
n = len(times)

def pct(p):
    if n == 1:
        return times[0]
    k = (n - 1) * p
    f, c = int(k), min(int(k) + 1, n - 1)
    if f == c:
        return times[f]
    return times[f] + (times[c] - times[f]) * (k - f)

print("%.6f %.6f %.6f %.6f %.6f" % (pct(0.5), pct(0.25), pct(0.75), times[0], times[-1]))
PYEOF
}

RESULTS_FILE="$ROOT/tests/bench/results.tsv"
if [ "$RECORD" = 1 ]; then
  mkdir -p "$ROOT/tests/bench"
  if [ ! -s "$RESULTS_FILE" ]; then
    printf 'date\thost_cpu\tgit_commit\tours_image\tours_digest\ttheirs_image\ttheirs_digest\tphp_version\tmode\tours_median_s\tours_iqr\ttheirs_median_s\ttheirs_iqr\tdelta_pct\n' > "$RESULTS_FILE"
  fi
  host_cpu="$(awk -F: '/model name/ {gsub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo)"
  git_commit="$(git -C "$ROOT" rev-parse --short HEAD)"
fi

for mi in "${!MODE_NAMES[@]}"; do
  mode="${MODE_NAMES[$mi]}"
  # shellcheck disable=SC2206 # fixed, script-defined flag strings only
  mode_flags=(${MODE_OPCACHE_FLAGS[$mi]})

  echo
  echo "--- mode: $mode ---"

  ours_fp="$(fingerprint_of "$OURS" "${mode_flags[@]}" "${OURS_BASE_EXTRA[@]}")"
  theirs_fp="$(fingerprint_of "$THEIRS" "${mode_flags[@]}" "${THEIRS_BASE_EXTRA[@]}")"

  if ! compare_fingerprints "$ours_fp" "$theirs_fp"; then
    echo "FAIL: mode $mode aborted -- settings were not identical, no timing was taken" >&2
    exit 1
  fi
  echo "ok: settings fingerprint matches for mode $mode"

  # discarded warm-up, interleaved same as the real runs
  time_of "$OURS" "${mode_flags[@]}" "${OURS_BASE_EXTRA[@]}" >/dev/null
  time_of "$THEIRS" "${mode_flags[@]}" "${THEIRS_BASE_EXTRA[@]}" >/dev/null

  ours_times=()
  theirs_times=()
  for ((i = 0; i < RUNS; i++)); do
    ours_times+=("$(time_of "$OURS" "${mode_flags[@]}" "${OURS_BASE_EXTRA[@]}")")
    theirs_times+=("$(time_of "$THEIRS" "${mode_flags[@]}" "${THEIRS_BASE_EXTRA[@]}")")
  done

  read -r o_med o_q1 o_q3 o_min o_max <<<"$(stats "${ours_times[*]}")"
  read -r t_med t_q1 t_q3 t_min t_max <<<"$(stats "${theirs_times[*]}")"

  printf '%-45s %10s %16s %16s\n' "image" "median(s)" "IQR(s)" "min-max(s)"
  printf '%-45s %10.4f %8.4f-%.4f %8.4f-%.4f\n' "$OURS" "$o_med" "$o_q1" "$o_q3" "$o_min" "$o_max"
  printf '%-45s %10.4f %8.4f-%.4f %8.4f-%.4f\n' "$THEIRS" "$t_med" "$t_q1" "$t_q3" "$t_min" "$t_max"

  # IQR overlap -> the sign of the delta is not established
  overlap=$(python3 -c "print(1 if $o_q1 <= $t_q3 and $t_q1 <= $o_q3 else 0)")
  if [ "$overlap" = 1 ]; then
    verdict="inconclusive (IQRs overlap: ours ${o_q1}-${o_q3}, theirs ${t_q1}-${t_q3})"
    delta="inconclusive"
  else
    delta=$(python3 -c "print('%.1f' % ((($t_med - $o_med) / $t_med) * 100))")
    if python3 -c "exit(0 if $o_med < $t_med else 1)"; then
      verdict="ours ${delta}% faster (median)"
    else
      abs_delta=$(python3 -c "print('%.1f' % abs($delta))")
      verdict="ours ${abs_delta}% SLOWER (median)"
    fi
  fi
  echo "$mode: $verdict"

  if [ "$RECORD" = 1 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.6f\t%.6f-%.6f\t%.6f\t%.6f-%.6f\t%s\n' \
      "$(date -u +%Y-%m-%d)" "$host_cpu" "$git_commit" \
      "$OURS" "$our_digest" "$THEIRS" "$their_digest" "$VERSION" "$mode" \
      "$o_med" "$o_q1" "$o_q3" "$t_med" "$t_q1" "$t_q3" "$delta" >> "$RESULTS_FILE"
  fi
done
