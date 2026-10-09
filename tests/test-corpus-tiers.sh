#!/usr/bin/env bash
# The assertion the corpus exists to satisfy: a tier's corpus has to *run* on
# every matrix.json version that tier serves, not only on the one it was built
# on.
#
#   ./tests/test-corpus-tiers.sh            every tier
#   ./tests/test-corpus-tiers.sh 7.2        one tier
#
# Composer bakes the floor it resolved against into
# vendor/composer/platform_check.php, which autoload.php requires before any
# application code, and WordPress refuses to boot below its own
# $required_php_version. Neither shows up in the corpus image's own tests --
# they only appear when the corpus is mounted into an *older* runtime, which is
# exactly what this script does for every version in the tier. A corpus resolved
# against a single version (say 7.4 for "legacy", 8.2 for "modern") passes its
# own tests yet fatals at autoload on the older versions its tier serves, and
# PGO training would then profile the fatal.
#
# Each version gets the full corpus/verify.sh run -- serve, request every
# declared path, require 200 with a byte floor and an expected substring, and a
# 404 control per app -- because "no error" is an absence assertion. A version
# that boots and answers 200 with an error page passes "it did not fatal".
#
# The control is the other half: every tier is also run against the newest
# matrix version *below* its floor, where it must fail. A harness that has
# never been seen to fail is not evidence.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
ONLY_TIER="${1:-}"

fail() { echo "FAIL: $*" >&2; exit 1; }

image_of() { echo "lotuswebagency/php:${1}-fpm"; }

# run_corpus <php-version> <corpus-volume> <src-volume> <tier> -> exit status, output on stdout
#
# --user 0 --network host, unconditionally: every tier's corpus includes
# PrestaShop, whose database is mariadbd, not a bundled sqlite file
# (php/pgo/corpus/prestashop/db-up.sh). The runtime -fpm images this replays
# against do not ship mariadb-server -- verify.sh's own FATAL if it is missing
# would otherwise fail every tier on that one app -- so it is installed fresh
# before each replay, the way Dockerfile.corpus installs it to build the corpus.
# --network host is for the apt-get (the default bridge network may have no
# outbound); --user 0 is required to install packages. verify.sh does not care
# which uid runs it, and the corpus volume's files stay uid 33 since root never
# chowns anything.
#
# -e CORPUS_TIER: verify.sh serves the apps the tier declares in corpus/tiers,
# and only the corpus image carries that variable, not these runtime images.
run_corpus() {
  docker run --rm --user 0 --network host --entrypoint sh \
    -e "CORPUS_TIER=${4}" -v "${2}:/corpus" -v "${3}:/corpus-src" \
    "$(image_of "$1")" -c '
      apt-get update -qq >/tmp/apt.log 2>&1 \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends mariadb-server >>/tmp/apt.log 2>&1 \
        || { echo "FATAL: could not install mariadb-server for the replay:" >&2; tail -30 /tmp/apt.log >&2; exit 1; }
      exec /corpus-src/verify.sh /corpus /corpus-src /tmp/MANIFEST
    ' 2>&1
}

while IFS=$'\t' read -r tier _release _builder tag versions; do
  [ -z "$ONLY_TIER" ] || [ "$tier" = "$ONLY_TIER" ] || continue

  docker image inspect "$tag" >/dev/null 2>&1 || fail "$tag has not been built"

  corpus_vol="corpus-test-${tier//./_}"
  src_vol="corpus-test-src-${tier//./_}"
  docker volume rm -f "$corpus_vol" "$src_vol" >/dev/null 2>&1 || true
  docker volume create "$corpus_vol" >/dev/null
  docker volume create "$src_vol" >/dev/null
  # --user 0 because a fresh named volume is root-owned; cp -a keeps the
  # corpus files themselves at uid 33, which is what the runtimes need.
  docker run --rm --user 0 --entrypoint sh \
    -v "${corpus_vol}:/dst" -v "${src_vol}:/dst-src" "$tag" \
    -c 'cp -a /corpus/. /dst/ && cp -a /corpus-src/. /dst-src/' >/dev/null

  # What the corpus image itself recorded at build time. Every version in the
  # tier has to reproduce it exactly, not merely "answer some 200s": PGO
  # training replays MANIFEST, so a path that quietly stops serving on one
  # version -- an optional one like /up especially, which nothing else re-checks
  # -- would train fewer paths than intended while this printed ok.
  built_manifest="$(docker run --rm "$tag" cat /corpus/MANIFEST)"
  [ -n "$built_manifest" ] || fail "$tag has an empty /corpus/MANIFEST"

  echo "=== tier $tier ($tag) serves php ${versions//,/ }"
  for version in ${versions//,/ }; do
    if ! docker image inspect "$(image_of "$version")" >/dev/null 2>&1; then
      # CORPUS_TIER_SKIP_MISSING: an explicit escape hatch, same shape as
      # smoke.sh's SMOKE_SKIP_PGO. The default stays fatal (CI builds every
      # version a tier serves, so a missing one there is a real gap), but a
      # local run against whatever happens to be built records the gap loudly
      # instead of refusing to test the versions that are present.
      if [ "${CORPUS_TIER_SKIP_MISSING:-}" = "1" ]; then
        echo "  SKIP: $(image_of "$version") has not been built locally -- not replayed" >&2
        continue
      fi
      fail "$(image_of "$version") has not been built"
    fi
    if out="$(run_corpus "$version" "$corpus_vol" "$src_vol" "$tier")"; then
      # verify.sh prints the manifest it just produced after a "=== MANIFEST"
      # marker; that is the observed set, built from what actually answered 200
      # with the expected content on *this* php.
      fresh="$(sed -n '/^=== MANIFEST$/,$p' <<<"$out" | tail -n +2)"
      [ -n "$fresh" ] || fail "php $version produced no manifest -- verify.sh output was not in the expected shape"
      [ "$fresh" = "$built_manifest" ] || fail "php $version serves a different set than the tier $tier corpus recorded at build time:
$(diff <(echo "$built_manifest") <(echo "$fresh") || true)"
      served="$(grep -c ' -> 200 ' <<<"$out" || true)"
      echo "  ok: php $version reproduces the tier $tier MANIFEST ($served paths answered 200)"
    else
      echo "$out" | tail -25 >&2
      fail "the tier $tier corpus does not run on php $version, which that tier serves"
    fi
  done

  control="$(python3 "${ROOT}/scripts/pgo_tiers.py" control-of "$tier")"
  if [ -n "$control" ] && docker image inspect "$(image_of "$control")" >/dev/null 2>&1; then
    if out="$(run_corpus "$control" "$corpus_vol" "$src_vol" "$tier")"; then
      echo "$out" | tail -10 >&2
      fail "the tier $tier corpus ran clean on php $control, which is below its floor -- this check cannot distinguish a corpus that fits from one that does not"
    fi
    # It has to fail *for the right reason*. A control that fails because the
    # image is missing curl would look identical here while proving nothing
    # about the version floor.
    reason="$(grep -oE 'platform_check|require a PHP version|requires at least|Parse error|syntax error' <<<"$out" | head -1 || true)"
    [ -n "$reason" ] || {
      echo "$out" | tail -15 >&2
      fail "the tier $tier corpus failed on php $control, but not with a version-floor rejection -- the control proves nothing"
    }
    echo "  ok: control -- php $control (below the floor) fails as it must ($reason)"
  else
    echo "  note: no runtime image below floor $tier to use as a control"
  fi

  docker volume rm -f "$corpus_vol" "$src_vol" >/dev/null
done < <(python3 "${ROOT}/scripts/pgo_tiers.py" list)

echo "CORPUS TIER TESTS PASSED"
