#!/usr/bin/env bash
# Extract statically-linked PECL extensions into php-src/ext so configure
# treats them as core. Must run before ./buildconf --force.
set -euo pipefail
PHP_VERSION="${1:?usage: fetch-pecl.sh <php-version> <php-src-dir>}"
SRC_DIR="${2:?usage: fetch-pecl.sh <php-version> <php-src-dir>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

names=$(python3 - "$PHP_VERSION" "$HERE/ext.json" <<'PY'
import json, sys
version, path = sys.argv[1], sys.argv[2]

def parts(v): return tuple(int(x) for x in v.split("."))

def satisfies(constraint, v):
    for clause in (constraint or "").split(","):
        clause = clause.strip()
        for op in (">=", "<=", "<", ">", "=="):
            if clause.startswith(op):
                b, c = parts(clause[len(op):]), parts(v)
                if not {">=": c >= b, "<=": c <= b, "<": c < b,
                        ">": c > b, "==": c == b}[op]:
                    return False
                break
    return True

for e in json.load(open(path))["extensions"]:
    override = (e.get("overrides") or {}).get(version, {})
    if e["source"] != "pecl":
        continue
    if override.get("linkage", e["linkage"]) != "static":
        continue
    if not satisfies(e["php"], version):
        continue
    print(f"{e['name']}\t{override.get('version', '')}")
PY
)

while IFS=$'\t' read -r name pinned; do
  [ -n "$name" ] || continue
  if [ -n "$pinned" ]; then
    row=$(grep -E "^${name}@${PHP_VERSION}[[:space:]]" "$HERE/pecl.lock" || true)
    version="$pinned"
  else
    row=$(grep -E "^${name}[[:space:]]" "$HERE/pecl.lock" || true)
    version=$(echo "$row" | awk '{print $2}')
  fi
  sha=$(echo "$row" | awk '{print $3}')
  [ -n "$sha" ] || { echo "no sha256 for $name $version in pecl.lock" >&2; exit 1; }

  echo "fetching $name $version"
  bash "${HERE}/../deps/fetch-verified.sh" "https://pecl.php.net/get/${name}-${version}.tgz" "$sha" "/tmp/${name}.tgz"
  mkdir -p "${SRC_DIR}/ext/${name}"
  tar xf "/tmp/${name}.tgz" -C "${SRC_DIR}/ext/${name}" --strip-components=1
  rm -f "/tmp/${name}.tgz" "${SRC_DIR}/ext/${name}/package.xml"
done <<< "$names"
