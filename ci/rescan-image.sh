#!/usr/bin/env bash
# Scan registry images (by digest) with today's Trivy DB: the vulnerability gate, the KEV gate
# and the OS package floor of ci/test-images.sh, with the same flags.
#
#   ci/rescan-image.sh <repo@sha256:digest>...
#
# A release that copies develop's images runs this on both platform manifests: develop tested
# them with the DB of its own day, and the copy must not publish a fixable CRITICAL/HIGH
# finding that appeared since. Never downloads a DB or a KEV catalog.
#
#   TRIVY_CACHE_DIR     the prepared Trivy DB (default <repo>/.cache/trivy)
#   KEV_CATALOG         default <repo>/.cache/kev/known_exploited_vulnerabilities.json
#   TRIVY_SEVERITY      default CRITICAL,HIGH          TRIVY_MIN_PACKAGES   default 20
set -euo pipefail
[ "$#" -ge 1 ] || { echo "usage: $0 <repo@sha256:digest>..." >&2; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEVERITY="${TRIVY_SEVERITY:-CRITICAL,HIGH}"
MIN_PACKAGES="${TRIVY_MIN_PACKAGES:-20}"
TRIVY_CACHE_DIR="${TRIVY_CACHE_DIR:-$ROOT/.cache/trivy}"
KEV_CATALOG="${KEV_CATALOG:-$ROOT/.cache/kev/known_exploited_vulnerabilities.json}"
command -v trivy >/dev/null || { echo "FAIL: trivy is not on PATH" >&2; exit 2; }
[ -d "$TRIVY_CACHE_DIR/db" ] || { echo "FAIL: no Trivy DB in $TRIVY_CACHE_DIR (this script never downloads one)" >&2; exit 2; }
[ -f "$KEV_CATALOG" ] || { echo "FAIL: no KEV catalog at $KEV_CATALOG" >&2; exit 2; }
for ref in "$@"; do
  case "$ref" in *@sha256:????????????????????????????????????????????????????????????????) ;; *) echo "FAIL: $ref is not a repo@sha256 digest reference" >&2; exit 2 ;; esac
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
TRIVY_ENV=(TRIVY_CACHE_DIR="$TRIVY_CACHE_DIR" TRIVY_SKIP_DB_UPDATE=true TRIVY_SKIP_VERSION_CHECK=true TRIVY_IMAGE_SRC=remote)

trivy_scan() {  # trivy_scan <image> <TRIVY_* assignments...>
  local image="$1"; shift
  env "${TRIVY_ENV[@]}" "$@" trivy image "$image"
}

i=0
for ref in "$@"; do
  i=$((i + 1))
  report="$work/kev-$i.json"
  echo "== rescan $ref"
  trivy_scan "$ref" TRIVY_EXIT_CODE=1 TRIVY_SEVERITY="$SEVERITY" TRIVY_IGNORE_UNFIXED=true
  trivy_scan "$ref" TRIVY_FORMAT=json TRIVY_OUTPUT="$report" TRIVY_EXIT_CODE=0 TRIVY_SCANNERS=vuln TRIVY_LIST_ALL_PKGS=true \
    TRIVY_SEVERITY=UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL
  python3 "$ROOT/ci/kev.py" "$report" --catalog "$KEV_CATALOG"
  count="$(jq '[.Results[]? | select(.Class == "os-pkgs") | .Packages[]?] | length' "$report")"
  echo "$ref: $count OS packages (floor: more than $MIN_PACKAGES)"
  [ "$count" -gt "$MIN_PACKAGES" ] || {
    echo "FAIL: the Trivy scan of $ref saw $count OS packages; an empty scan proves nothing" >&2
    exit 1
  }
done
echo "ok: $# image(s) pass today's vulnerability, KEV and package-floor gates"
