# shellcheck shell=bash
# Variables here are read by the scripts that source this file.
# shellcheck disable=SC2034
# Target selection shared by tests/build-all.sh and tests/extended.sh: the
# matrix.json versions and flavors, --only/--flavor validation, and the list of
# bake targets a selection picks. Sourced, never executed; the caller has
# already done `cd "$ROOT"` and fills ONLY and FLAVORS (arrays) from its flags.
#
#   matrix_load            ALL_VERSIONS, ALL_FLAVORS, TARGETS_JSON, ALL_TARGET_COUNT
#   matrix_validate_selection   exit 1 unless every ONLY/FLAVORS entry is in matrix.json
#   matrix_select          ONLY_CSV, FLAVOR_CSV, FULL_RUN, SELECTED (name<TAB>flavor<TAB>php<TAB>tag)
#   matrix_ext_versions    versions whose baseline ext-builder, fpm and cli are all SELECTED
#   matrix_target_field    <target-name> <field> -> that field of the target, e.g. corpus
#
# Versions and flavors come from matrix.json, never a literal list here --
# same reasoning as smoke.sh deriving its expected extension set instead of
# naming it: a list copied into a script would keep passing while silently not
# covering a version that was added, and start failing on one that was removed.
# A typo in --only/--flavor is a loud error rather than a run that quietly
# covers a smaller matrix than intended and still reports a pass.

matrix_load() {
  mapfile -t ALL_VERSIONS < <(python3 -c '
import json
m = json.load(open("matrix.json"))
for v in sorted(m["versions"], key=lambda s: tuple(int(x) for x in s.split("."))):
    print(v)
')
  [ "${#ALL_VERSIONS[@]}" -gt 0 ] || { echo "FAIL: matrix.json yielded no versions"; exit 1; }
  mapfile -t ALL_FLAVORS < <(python3 -c 'import json; print("\n".join(json.load(open("matrix.json"))["flavors"]))')

  # scripts/gen_matrix.py --github targets is the same 50-entry list that feeds
  # matrix.gen.hcl's TARGETS variable -- never a second copy of it. See
  # tests/preflight.sh's check that this list and `bake --print`'s target list
  # can never drift apart.
  TARGETS_JSON="$(python3 scripts/gen_matrix.py --github targets)"
  ALL_TARGET_COUNT="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["include"]))' "$TARGETS_JSON")"
}

matrix_validate_selection() {
  local want have found
  for want in "${ONLY[@]:-}"; do
    [ -n "$want" ] || continue
    found=0
    for have in "${ALL_VERSIONS[@]}"; do [ "$want" = "$have" ] && { found=1; break; }; done
    [ "$found" -eq 1 ] || { echo "FAIL: '$want' is not a version in matrix.json (${ALL_VERSIONS[*]})"; exit 1; }
  done
  for want in "${FLAVORS[@]:-}"; do
    [ -n "$want" ] || continue
    found=0
    for have in "${ALL_FLAVORS[@]}"; do [ "$want" = "$have" ] && { found=1; break; }; done
    [ "$found" -eq 1 ] || { echo "FAIL: '$want' is not a flavor in matrix.json (${ALL_FLAVORS[*]})"; exit 1; }
  done
}

# One line per selected target: name<TAB>flavor<TAB>php<TAB>tag (the first,
# canonical tag -- the one CF-47's inputs-hash label check and tests/smoke.sh
# both key off of).
matrix_select() {
  ONLY_CSV="$(IFS=,; echo "${ONLY[*]:-}")"
  FLAVOR_CSV="$(IFS=,; echo "${FLAVORS[*]:-}")"
  FULL_RUN=0
  [ -z "$ONLY_CSV" ] && [ -z "$FLAVOR_CSV" ] && FULL_RUN=1
  mapfile -t SELECTED < <(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
only = [v for v in sys.argv[2].split(",") if v]
flavors = [f for f in sys.argv[3].split(",") if f]
for t in data["include"]:
    if only and t["php"] not in only:
        continue
    if flavors and t["flavor"] not in flavors:
        continue
    print("\t".join([t["name"], t["flavor"], t["php"], t["tags"][0]]))
' "$TARGETS_JSON" "$ONLY_CSV" "$FLAVOR_CSV")
  [ "${#SELECTED[@]}" -gt 0 ] || { echo "FAIL: no target matched --only/--flavor"; exit 1; }
}

# matrix_ext_versions -> the versions (one per line) whose baseline
# ext-builder, fpm and cli targets are all in SELECTED. tests/test-ext-builder.sh
# copies an extension built in the first into the other two, so it needs all
# three images of one version; a --flavor filter that drops one skips it.
matrix_ext_versions() {
  local row name flavor php tag
  declare -A have=()
  for row in "${SELECTED[@]}"; do
    IFS=$'\t' read -r name flavor php tag <<<"$row"
    case "$name" in *-v3) continue ;; esac
    have["$php/$flavor"]=1
  done
  for php in "${ALL_VERSIONS[@]}"; do
    [ -n "${have["$php/ext-builder"]:-}" ] && [ -n "${have["$php/fpm"]:-}" ] && [ -n "${have["$php/cli"]:-}" ] && echo "$php"
  done
  return 0
}

matrix_target_field() {
  python3 -c '
import json, sys
for t in json.loads(sys.argv[1])["include"]:
    if t["name"] == sys.argv[2]:
        print(t[sys.argv[3]])
        break
' "$TARGETS_JSON" "$1" "$2"
}
