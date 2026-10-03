#!/usr/bin/env bash
# Everything that can be checked without building an image. This is what CI's
# PR gate will call before the real (expensive) builds -- a drift, a stale
# generated file, a shellcheck regression or a mislabelled local image should
# fail here, in seconds, rather than be discovered forty minutes into a
# from-source PGO build.
#
#   ./tests/preflight.sh
#
# Does not stop at the first failure: every section runs, and the summary at
# the end says which ones broke. Same reasoning as tests/build-all.sh -- a
# run that dies on section 1 tells you nothing about sections 2-7.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
cd "$ROOT" || exit 1

FAILED=()
section() { echo; echo "=== $*"; }
ok()      { echo "ok: $*"; }
fail()    { echo "FAIL: $*" >&2; FAILED+=("$*"); }

# ---------------------------------------------------------- 1. matrix drift
section "1/8 matrix.gen.hcl drift (scripts/gen_matrix.py --check)"
if python3 scripts/gen_matrix.py --check; then
  ok "matrix.gen.hcl matches matrix.json"
else
  fail "matrix.gen.hcl is stale -- run: python3 scripts/gen_matrix.py"
fi

# -------------------------------------------------------------- 2. pgo tiers
section "2/8 PGO corpus tiers (scripts/pgo_tiers.py check)"
if python3 scripts/pgo_tiers.py check; then
  ok "every pgo=true version has a tier, every opt-out has a reason"
else
  fail "scripts/pgo_tiers.py check failed"
fi

# --------------------------------------------------- 3. bake --print + COMPILER
section "3/8 bake --print for every target and the pr subset (both platforms), COMPILER cross-check"
bake_print() {  # bake_print <group> -> the rendered JSON, or empty + FAIL on error
  local out
  if ! out=$(docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl "$1" --print 2>&1); then
    fail "docker buildx bake --print $1 failed: $out"
    return 1
  fi
  # buildx prints a short progress preamble before the JSON on some drivers;
  # take from the first '{' rather than assuming line 1.
  sed -n '/^{/,$p' <<<"$out"
}
default_json="$(bake_print default)" && [ -n "$default_json" ] || fail "bake --print default produced no JSON"
pr_json="$(bake_print pr)" && [ -n "$pr_json" ] || fail "bake --print pr produced no JSON"

if [ -n "${default_json:-}" ]; then
  # Script-checked cross-reference, not eyeballed: every php-* target's own
  # COMPILER arg and com.lotuswebagency.compiler label must both equal
  # matrix.json's compiler field for that version, and every target must
  # carry both platforms -- otherwise an arm64 build silently drops out of
  # the matrix, or a target compiles with the wrong toolchain from the very
  # first line of its build log.
  check_script="$(mktemp --suffix=.py)"
  cat > "$check_script" <<'PYEOF'
import json, re, sys
matrix = json.load(open(sys.argv[1]))
data = json.load(open(sys.argv[2]))
problems = []
checked = 0
for name, t in data.get("target", {}).items():
    m = re.match(r"php-(\d+)_(\d+)(?:-.*)?$", name)
    if not m:
        continue
    php = f"{m.group(1)}.{m.group(2)}"
    spec = matrix["versions"].get(php)
    if spec is None:
        problems.append(f"{name}: matrix.json has no version {php}")
        continue
    want = spec["compiler"]
    args = t.get("args", {})
    labels = t.get("labels", {})
    got_arg = args.get("COMPILER")
    got_label = labels.get("com.lotuswebagency.compiler")
    if got_arg != want:
        problems.append(f"{name}: COMPILER arg is {got_arg!r}, matrix.json says {want!r}")
    if got_label != want:
        problems.append(f"{name}: com.lotuswebagency.compiler label is {got_label!r}, matrix.json says {want!r}")
    platforms = set(t.get("platforms", []))
    if not {"linux/amd64", "linux/arm64"} <= platforms:
        problems.append(f"{name}: platforms are {sorted(platforms)}, expected both linux/amd64 and linux/arm64")
    checked += 1
if checked == 0:
    problems.append("no php-* targets found in bake --print output -- nothing was checked")
for p in problems:
    print("PROBLEM: " + p)
print(f"checked {checked} targets")
PYEOF
  default_json_file="$(mktemp)"
  printf '%s' "$default_json" > "$default_json_file"
  check_out="$(python3 "$check_script" "$ROOT/matrix.json" "$default_json_file")"
  rm -f "$check_script" "$default_json_file"
  echo "$check_out"
  if grep -q '^PROBLEM:' <<<"$check_out"; then
    fail "bake target COMPILER/label/platform cross-check found problems (see above)"
  else
    ok "every php-* bake target's COMPILER arg and com.lotuswebagency.compiler label match matrix.json, both platforms present"
  fi
fi

if [ -n "${pr_json:-}" ]; then
  # The pr group in docker-bake.hcl and the CI matrix (scripts/gen_matrix.py
  # --github pr, whose legs name every target they bake, riders included) are
  # two spellings of one list; a target in one and not the other is a PR that
  # silently stops building something, or a leg bake cannot resolve.
  pr_json_file="$(mktemp)"
  printf '%s' "$pr_json" > "$pr_json_file"
  pr_out="$(python3 scripts/gen_matrix.py --github pr | python3 -c '
import json, sys
legs = json.load(sys.stdin)["include"]
bake = json.load(open(sys.argv[1]))
ci = {n for leg in legs for n in leg["bake"].split()}
grp = set(bake["group"]["pr"]["targets"])
for n in sorted(ci - grp):
    print(f"PROBLEM: {n} is built by a CI pr leg but is not in the bake pr group")
for n in sorted(grp - ci):
    print(f"PROBLEM: {n} is in the bake pr group but no CI pr leg builds it")
print(f"pr legs: {len(legs)}, targets they bake: {len(ci)}, bake pr group: {len(grp)}")
' "$pr_json_file")"
  rm -f "$pr_json_file"
  echo "$pr_out"
  if grep -q '^PROBLEM:' <<<"$pr_out"; then
    fail "the bake pr group and scripts/gen_matrix.py --github pr disagree (see above)"
  else
    ok "the bake pr group matches the targets the CI pr legs build"
  fi
fi

# ------------------------------------------------------------- 4. shellcheck
section "4/8 shellcheck on every shell file"
command -v shellcheck >/dev/null || fail "shellcheck not found on this host"
if command -v shellcheck >/dev/null; then
  # rootfs's runtime scripts have no .sh extension (they ship as bare
  # executables in the image) but are bash, same as everything else here.
  shell_files=()
  while IFS= read -r f; do shell_files+=("$f"); done < <(
    find . -name '*.sh' -not -path './.git/*' -not -path './.claude/*' | sort
    find rootfs/usr/local/bin -maxdepth 1 -type f 2>/dev/null | sort
  )
  [ "${#shell_files[@]}" -gt 0 ] || fail "no shell files found to check"

  # Pre-existing, out-of-scope findings this task did not introduce and is not
  # here to fix (task 37a already logged the build.sh one as a known info,
  # not a real bug). Anything else new, in any file, fails the gate -- this is
  # a narrow, named allowlist, not a blanket severity drop.
  declare -A ALLOWED=(
    ["./deps/build-deps.sh"]="SC2155"
    ["./php/build.sh"]="SC2015"
  )
  for f in "${shell_files[@]}"; do
    out="$(shellcheck -x --severity=warning "$f" 2>&1)" && { ok "shellcheck $f"; continue; }
    codes="$(grep -oE 'SC[0-9]+' <<<"$out" | sort -u)"
    allowed="${ALLOWED[$f]:-}"
    bad=""
    for code in $codes; do
      case " $allowed " in *" $code "*) ;; *) bad="${bad:+$bad }$code" ;; esac
    done
    if [ -n "$bad" ]; then
      fail "shellcheck $f: $bad"
      echo "$out"
    else
      ok "shellcheck $f (pre-existing, accepted: $codes)"
    fi
  done
fi

# ----------------------------------------------------- 5. fetch-verified.sh
section "5/8 deps/fetch-verified.sh (tests/test-fetch-verified.sh)"
if bash "$HERE/test-fetch-verified.sh"; then
  ok "test-fetch-verified.sh"
else
  fail "tests/test-fetch-verified.sh failed"
fi

# --------------------------------------------- 6. python unit/lock-format tests
section "6/8 python unit tests (scripts/: matrix/ext-registry/elf-hardening/flags/locks; ci/: vex)"
# Covers, among others, the lock-file format checks that exist:
# scripts/test_versions_lock.py (deps/versions.lock), scripts/test_release_keys.py
# (php/release-keys.asc), scripts/test_fetch_verified_sync.py (the two
# fetch-verified.sh copies stay byte-identical), plus scripts/test_gen_matrix.py,
# scripts/test_pgo_tiers.py, scripts/test_ext_registry.py and
# scripts/test_flags.py's own unit-level assertions on cflags.sh/ldflags.sh.
if python3 -m unittest discover -s scripts -p 'test_*.py' -v 2>&1 | tail -20; then
  ok "python3 -m unittest discover -s scripts"
else
  fail "scripts/test_*.py unittest suite failed"
fi
# ci/test_vex.py (the release tooling, kept out of scripts/ so it is not a build
# input): vex/php.openvex.json is valid OpenVEX, .trivyignore is the file
# generated from it, the attestation predicate refuses a Trivy step that did not
# succeed. It does NOT assert that no review-by date has passed: preflight gates
# every build job, so a date-triggered failure here would stop the whole publish
# on the deadline Monday. The deadline gate is Trivy itself (the generated
# .trivyignore lines carry exp:); `python3 ci/vex.py check --warn-within 14`
# warns in CI ahead of time.
if python3 -m unittest discover -s ci -p 'test_*.py' -v 2>&1 | tail -20; then
  ok "python3 -m unittest discover -s ci"
else
  fail "ci/test_*.py unittest suite failed"
fi

# ----------------------------------------------- 7. matrix <-> label consistency
section "7/8 matrix.json <-> local image com.lotuswebagency.compiler labels (report-only for missing)"
# Whatever fpm images already exist locally (from an earlier build-all.sh run,
# or a one-off bake) get cross-checked against matrix.json right now, the same
# comparison tests/smoke.sh makes per image at test time -- catching a stale
# local image before a smoke run wastes time discovering it one image at a
# time. A version with no local image is reported, not failed: this preflight
# runs long before any image exists.
label_check_out="$(mktemp)"
python3 -c '
import json
m = json.load(open("matrix.json"))
for v in sorted(m["versions"], key=lambda s: tuple(int(x) for x in s.split("."))):
    print(v, m["versions"][v]["compiler"])
' | while read -r v want; do
  tag="lotuswebagency/php:${v}-fpm"
  label="$(docker inspect --format '{{index .Config.Labels "com.lotuswebagency.compiler"}}' "$tag" 2>/dev/null || true)"
  if [ -z "$label" ] || [ "$label" = "<no value>" ]; then
    if docker image inspect "$tag" >/dev/null 2>&1; then
      echo "PROBLEM: $tag exists but carries no com.lotuswebagency.compiler label (predates task 37b, or built without docker-bake.hcl)"
    else
      echo "note: $tag not built locally -- nothing to check"
    fi
    continue
  fi
  if [ "$label" = "$want" ]; then
    echo "ok: $tag label=$label matches matrix.json"
  else
    echo "PROBLEM: $tag is labeled compiler=$label but matrix.json says $want for php $v"
  fi
done > "$label_check_out" 2>&1
cat "$label_check_out"
if grep -q '^PROBLEM:' "$label_check_out"; then
  fail "matrix<->label consistency check found mislabelled local image(s) (see above)"
fi
rm -f "$label_check_out"

# --------------------------------- 8. build-all.sh vs bake --print target lists
section "8/8 tests/build-all.sh's target list vs bake --print's target list"
# Task 37c: tests/build-all.sh enumerates every image it builds from
# scripts/gen_matrix.py --github targets -- the same source matrix.gen.hcl's
# TARGETS variable is rendered from -- rather than naming a flavor or a count
# itself, so the two cannot drift apart by construction. Checked here anyway,
# script-checked rather than trusted: a future edit to either side (a new
# flavor, a filtered --github targets, a bake target renamed by hand) would
# otherwise only be caught by noticing build-all.sh silently built fewer or
# more images than bake actually has.
if [ -n "${default_json:-}" ]; then
  gen_targets_file="$(mktemp)"
  bake_json_file="$(mktemp)"
  python3 scripts/gen_matrix.py --github targets > "$gen_targets_file"
  printf '%s' "$default_json" > "$bake_json_file"
  drift_out="$(python3 -c '
import json, sys
gen = json.load(open(sys.argv[1]))
bake = json.load(open(sys.argv[2]))
gen_names = {t["name"] for t in gen["include"]}
bake_names = set(bake.get("target", {}).keys())
missing_from_bake = sorted(gen_names - bake_names)
missing_from_gen = sorted(bake_names - gen_names)
for n in missing_from_bake:
    print(f"PROBLEM: {n} is in scripts/gen_matrix.py --github targets but not in bake --print")
for n in missing_from_gen:
    print(f"PROBLEM: {n} is in bake --print but not in scripts/gen_matrix.py --github targets")
print(f"gen_matrix targets: {len(gen_names)}, bake --print targets: {len(bake_names)}")
' "$gen_targets_file" "$bake_json_file")"
  rm -f "$gen_targets_file" "$bake_json_file"
  echo "$drift_out"
  if grep -q '^PROBLEM:' <<<"$drift_out"; then
    fail "tests/build-all.sh's target list (scripts/gen_matrix.py --github targets) does not match bake --print's target list"
  else
    ok "tests/build-all.sh's target list matches bake --print's target list"
  fi
else
  fail "no bake --print JSON available (section 3) to compare build-all.sh's target list against"
fi

# ------------------------------------------------------------------ summary
echo
echo "=== preflight summary"
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "PREFLIGHT PASSED"
  exit 0
fi
printf 'FAILED: %s\n' "${FAILED[@]}"
exit 1
